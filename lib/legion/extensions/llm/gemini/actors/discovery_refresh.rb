# frozen_string_literal: true

require 'concurrent'
require 'digest'
require 'json'
require 'uri'
require 'faraday'

begin
  require 'legion/extensions/actors/every'
rescue LoadError
  nil
end

unless defined?(Legion::Extensions::Actors::Every)
  raise LoadError, 'LegionIO actor runtime is required for Gemini discovery'
end

require 'legion/extensions/llm/gemini/provider'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/scoped_refresher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/weight_reconciler'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

module Legion
  module Extensions
    module Llm
      module Gemini
        module Actor
          # ── Evidence building helpers ────────────────────────────────────────
          module EvidenceBuilder
            private

            def extract_generation_methods(model_data:)
              Array(
                model_data[:supportedGenerationMethods] ||
                model_data[:supported_generation_methods] ||
                model_data['supportedGenerationMethods'] ||
                model_data['supported_generation_methods']
              )
            end

            def build_operation_evidence(generation_methods:)
              now = Time.now.freeze
              chat_status    = resolve_operation_status(generation_methods: generation_methods,
                                                        action: 'generateContent')
              stream_status  = resolve_operation_status(generation_methods: generation_methods,
                                                        action: 'streamGenerateContent')
              embed_status   = resolve_operation_status(generation_methods: generation_methods, action: 'embedContent')
              {
                chat: op_evidence(operation: :chat, status: chat_status, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: stream_status, observed_at: now),
                embed: op_evidence(operation: :embed,        status: embed_status,  observed_at: now),
                image: op_evidence(operation: :image,        status: :unsupported,  observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unknown, observed_at: now)
              }
            end

            def resolve_operation_status(generation_methods:, action:)
              return :unknown if generation_methods.empty?

              generation_methods.include?(action) ? :supported : :unsupported
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_catalog
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(generation_methods:, **)
              {
                completion: cap_from_method(capability: :completion, methods: generation_methods,
                                            action: 'generateContent'),
                streaming: cap_from_method(capability: :streaming,  methods: generation_methods,
                                           action: 'streamGenerateContent'),
                embedding: cap_from_method(capability: :embedding,  methods: generation_methods,
                                           action: 'embedContent'),
                tools: cap_evidence(capability: :tools, status: :unknown, source: :default_false),
                thinking: cap_evidence(capability: :thinking, status: :unknown, source: :default_false),
                vision: cap_evidence(capability: :vision, status: :unknown, source: :default_false)
              }
            end

            def cap_from_method(capability:, methods:, action:)
              present = methods.include?(action)
              cap_evidence(
                capability: capability,
                status: present ? :supported : :unknown,
                source: present ? :provider_catalog : :default_false
              )
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: Time.now.freeze
              )
            end
          end

          # ── Value evidence helpers ────────────────────────────────────────────
          module ValueEvidenceBuilder
            private

            def build_context_evidence(model_data:)
              ctx = model_data[:inputTokenLimit] || model_data['inputTokenLimit'] || model_data[:input_token_limit]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: ctx,
                                                                      source: :provider_catalog)
              else
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
              end
            end

            def build_max_output_evidence(model_data:)
              max_out = model_data[:outputTokenLimit] || model_data['outputTokenLimit'] ||
                        model_data[:output_token_limit]
              if max_out.is_a?(Integer) && max_out.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: max_out,
                                                                      source: :provider_catalog)
              else
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
              end
            end

            def build_embedding_dimensions_evidence(model_data:, generation_methods:)
              unless generation_methods.include?('embedContent')
                return Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
              end

              dims = extract_valid_dimensions(model_data: model_data)
              if dims
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :known, value: dims,
                                                                      source: :provider_catalog)
              else
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
              end
            end

            def extract_valid_dimensions(model_data:)
              dims = model_data[:embedding_dimensions] || model_data['embeddingDimensions']
              return nil unless dims.is_a?(Array) && !dims.empty?
              return nil unless dims.all? { |d| d.is_a?(Integer) && d.positive? }

              dims.uniq.sort
            end

            def build_model_revision_evidence(model_data:)
              revision = model_data[:version] || model_data['version']
              if revision.is_a?(String) && !revision.strip.empty?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: revision.strip, source: :provider_catalog
                )
              else
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
              end
            end

            def build_tokenizer_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end
          end

          # ── Model discovery helpers ──────────────────────────────────────────
          module ModelDiscovery
            private

            # Only transport and body-parse failures yield "no offerings".
            # Programming errors (NameError/NoMethodError/ArgumentError) must
            # propagate to the caller's loud log path — rescuing them here
            # would publish an activated instance with ZERO offerings
            # (invisible to the router) while looking healthy.
            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              models = fetch_models(instance_cfg: instance_cfg)
              models.filter_map do |model_data|
                model_id = extract_model_id(model_data: model_data)
                next if model_id.empty?

                build_offering_draft(
                  model_id: model_id, model_data: model_data,
                  instance_cfg: instance_cfg, instance_key: instance_key
                )
              end
            rescue Faraday::Error, Legion::JSON::ParseError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.discover_offerings')
              []
            end

            def fetch_models(instance_cfg:)
              base_url = resolve_api_base(instance_cfg: instance_cfg)
              conn = build_api_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get('models')
              body = Legion::JSON.load(response.body)
              Array(body[:models])
            end

            def extract_model_id(model_data:)
              name = model_data[:name] || model_data['name'] || ''
              name.to_s.delete_prefix('models/')
            end

            def build_offering_draft(model_id:, model_data:, instance_cfg:, instance_key:)
              tier = instance_cfg[:tier] || :frontier
              generation_methods = extract_generation_methods(model_data: model_data)
              weight_inputs = Legion::Extensions::Llm::Inventory::WeightSchema.weight_inputs(
                settings: Legion::Settings,
                instance_key: instance_key,
                provider_native_key: model_id,
                model: model_id,
                tier: tier
              )

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
                weight_inputs: weight_inputs,
                base_weight: Legion::Extensions::Llm::Inventory::WeightSchema.base_weight(weight_inputs),
                operation_evidence: build_operation_evidence(generation_methods: generation_methods),
                capability_evidence: build_capability_evidence(generation_methods: generation_methods),
                context_evidence: build_context_evidence(model_data: model_data),
                max_output_evidence: build_max_output_evidence(model_data: model_data),
                embedding_dimensions_evidence: build_embedding_dimensions_evidence(
                  model_data: model_data, generation_methods: generation_methods
                ),
                model_revision_evidence: build_model_revision_evidence(model_data: model_data),
                tokenizer_evidence: build_tokenizer_evidence,
                quota_domains: {},
                metadata: build_offering_metadata(model_data: model_data, instance_key: instance_key),
                publication_source: :provider_catalog
              )
            end

            def build_offering_metadata(model_data:, instance_key:)
              meta = { raw_model: extract_model_id(model_data: model_data) }
              meta[:display_name] = model_data[:displayName].to_s if model_data[:displayName]
              meta[:description]  = model_data[:description].to_s[0, 200] if model_data[:description]
              meta[:instance_id]  = instance_key.instance_id
              meta
            end
          end

          # ── Instance configuration helpers ───────────────────────────────────
          module ConfigResolver
            private

            def configured_instances
              instances = {}
              cfg_instances = settings[:instances]
              if cfg_instances.is_a?(Hash)
                cfg_instances.each do |name, config|
                  normalized = claimable_instance_config(config: config)
                  instances[name.to_sym] = normalized if normalized
                end
              end
              if instances.empty?
                auto_instance = build_auto_instance
                instances[:default_instance] = auto_instance if auto_instance
              end
              instances
            end

            # Returns the normalized config when the entry is claimable, else
            # nil: the always-present synthetic instances.default template is
            # loudly skipped while unmodified, and every other entry needs a
            # resolvable API key.
            def claimable_instance_config(config:)
              normalized = normalize_instance_config(config: config)

              return unless resolvable_api_key?(normalized[:gemini_api_key])

              normalized
            end

            # The synthetic instances.default section — ProviderSettings.build
            # always nests the extension's own instance defaults (endpoint,
            # discovery_interval, the env://GEMINI_API_KEY placeholder
            # credential, fleet/limits blocks) there. It is "configured" only
            # when the operator changed the entry: while it is still the
            # unmodified template (placeholder credential included) it is a
            # phantom the provider layer must never claim. A 'default' entry
            # the operator modified (a real API key, a different endpoint) is
            # a plain instance label — v2 accepted 'default' as an ordinary
            # name — and passes through to the claim path.
            def unconfigured_default?(name:, config:)
              name.to_s == 'default' && deep_symbolize(config) == synthetic_default_instance
            end

            # The nested template, straight from the extension's registered
            # defaults — compared by value against the live template, never
            # against a hardcoded literal.
            def synthetic_default_instance
              @synthetic_default_instance ||=
                Legion::Extensions::Llm::Gemini.default_settings.dig(:instances, :default)
            end

            # Settings entries arrive with string or symbol keys (YAML vs
            # JSON vs the nested template); canonicalize before comparing.
            def deep_symbolize(value)
              case value
              when Hash
                value.to_h { |key, inner| [key.respond_to?(:to_sym) ? key.to_sym : key, deep_symbolize(inner)] }
              when Array
                value.map { |inner| deep_symbolize(inner) }
              else
                value
              end
            end

            def build_auto_instance
              api_key = settings.dig(:credentials, :api_key)
              api_key = resolve_env_credential(api_key) if env_credential?(api_key)
              return nil unless resolvable_api_key?(api_key)

              {
                gemini_api_base: settings[:endpoint],
                gemini_api_key: api_key,
                tier: settings[:tier]
              }
            end

            def resolvable_api_key?(api_key)
              api_key.is_a?(String) && !api_key.strip.empty?
            end

            def env_credential?(value)
              value.is_a?(String) && value.start_with?('env://')
            end

            def resolve_env_credential(value)
              ENV.fetch(value.delete_prefix('env://'), nil)
            end

            def normalize_instance_config(config:)
              normalized = config.to_h.transform_keys(&:to_sym)
              resolve_instance_api_base(normalized: normalized)
              resolve_instance_credentials(normalized: normalized)
              normalized[:tier] ||= :frontier
              normalized
            end

            def resolve_instance_api_base(normalized:)
              normalized[:gemini_api_base] ||= normalized.delete(:base_url)
              normalized[:gemini_api_base] ||= normalized.delete(:api_base)
              normalized[:gemini_api_base] ||= normalized.delete(:endpoint)
              normalized[:gemini_api_base] ||= 'https://generativelanguage.googleapis.com/v1beta'
            end

            # Resolves env:// credential references in the instances.* path so an
            # env-only deployment claims the real key instead of the literal
            # 'env://GEMINI_API_KEY' placeholder (which would 4xx and pin the
            # instance in :initializing with a placeholder-fingerprinted id).
            def resolve_instance_credentials(normalized:)
              normalized[:gemini_api_key] ||= normalized.delete(:api_key)
              creds = normalized.delete(:credentials)
              if creds.is_a?(Hash)
                creds = creds.transform_keys(&:to_sym)
                normalized[:gemini_api_key] ||= creds[:api_key]
              end
              return unless env_credential?(normalized[:gemini_api_key])

              normalized[:gemini_api_key] = resolve_env_credential(normalized[:gemini_api_key])
            end
          end

          # ── HTTP connection helpers ──────────────────────────────────────────
          module HttpClient
            private

            def resolve_api_base(instance_cfg:)
              (instance_cfg[:gemini_api_base] || instance_cfg[:endpoint] ||
               'https://generativelanguage.googleapis.com/v1beta').to_s
            end

            def build_api_connection(base_url:, instance_cfg:)
              Faraday.new(url: base_url) do |f|
                f.options.timeout      = 15
                f.options.open_timeout = 5
                f.headers['Accept']    = 'application/json'
                apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def apply_auth_header(faraday:, instance_cfg:)
              api_key = instance_cfg[:gemini_api_key] || instance_cfg[:api_key] ||
                        instance_cfg.dig(:credentials, :api_key)
              return unless api_key.is_a?(String) && !api_key.strip.empty?

              faraday.headers['x-goog-api-key'] = api_key
            end

            # SECONDARY physical id (InstanceKey.physical_id): the derived
            # host:port/ak fingerprint, kept for dedup and diagnostics only.
            # Instance IDENTIFICATION is the operator's config name — see
            # claim_and_activate_instance. Never the identity itself.
            def derive_physical_id(instance_cfg:)
              base_url   = instance_cfg[:gemini_api_base] || instance_cfg[:endpoint] ||
                           'https://generativelanguage.googleapis.com/v1beta'
              host_port  = extract_host_port(url: base_url)
              api_key    = instance_cfg[:gemini_api_key] || instance_cfg[:api_key] ||
                           instance_cfg.dig(:credentials, :api_key)

              return host_port unless api_key.is_a?(String) && !api_key.strip.empty?

              fingerprint = ::Digest::SHA256.hexdigest(api_key)[0, 8]
              "#{host_port}/ak:#{fingerprint}"
            end

            def extract_host_port(url:)
              uri  = URI.parse(url.to_s)
              host = uri.host || 'generativelanguage.googleapis.com'
              "#{host}:#{uri.port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.extract_host_port', url: url.to_s)
              'unknown:0'
            end
          end

          # ── Readiness probe helpers ──────────────────────────────────────────
          module ProbeRunner
            private

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              run_instance_probe(instance_id: instance_id, state: state, coordinator: coordinator)
              sync_display_health(state: state)
            rescue StandardError => e
              finish_probe_on_error(coordinator: coordinator)
              handle_exception(e, level: :warn, operation: 'gemini.actor.cadence_probe', instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = tracked_instance_state(instance_id)
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              run_instance_probe(instance_id: instance_id, state: state, coordinator: coordinator, request: request)
              sync_display_health(state: state)
            rescue StandardError => e
              finish_probe_on_error(coordinator: coordinator, request: request)
              handle_exception(e, level: :warn, operation: 'gemini.actor.reactive_probe', instance_id: instance_id)
            end

            # Shared probe body: starts the publisher probe, checks health,
            # finishes the coordinator probe (coalesced probes pass their
            # request token), and reports the outcome.
            def run_instance_probe(instance_id:, state:, coordinator:, request: nil)
              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token],
                physical_id: state[:instance_key].physical_id
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              if request
                coordinator.finish_probe(request: request)
              else
                coordinator.finish_probe
              end
              report_probe_result(instance_id: instance_id, state: state,
                                  probe_token: probe_token, readiness: readiness)
            end

            # Best-effort probe release on the error path — a failure to
            # release is logged, never raised over the original error.
            def finish_probe_on_error(coordinator:, request: nil)
              if request
                coordinator&.finish_probe(request: request)
              else
                coordinator&.finish_probe
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.probe.finish_probe')
            end

            def report_probe_result(instance_id:, state:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(
                  instance_id: instance_id, physical_id: state[:instance_key].physical_id, probe_token: probe_token
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id, physical_id: state[:instance_key].physical_id,
                  probe_token: probe_token, reason: readiness.reason
                )
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'gemini.actor.probe_enqueue', instance_id: instance_id)
                false
              end
            end
          end

          # ── Health check helpers ─────────────────────────────────────────────
          module HealthChecker
            private

            def check_health(instance_cfg:)
              base_url = resolve_api_base(instance_cfg: instance_cfg)
              conn     = build_api_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get('models', { pageSize: 1 })
              build_readiness_from_response(response: response, base_url: base_url)
            rescue Faraday::ConnectionFailed => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.check_health.connection',
                                  base_url: base_url)
              readiness_failure(reason: "Gemini models API connection failed: #{e.message}", error: e)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.check_health', base_url: base_url)
              readiness_failure(reason: "Gemini models API error: #{e.message}", error: e)
            end

            def build_readiness_from_response(response:, base_url:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "Gemini models API returned #{response.status}",
                metadata: { status: response.status, base_url: base_url }
              )
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false,
                reason: reason,
                metadata: { error_class: error.class.name }
              )
            end
          end

          # ── Instance lifecycle helpers ───────────────────────────────────────
          # ── Offering change comparison helpers ───────────────────────────────
          module OfferingComparison
            SCALAR_EVIDENCE_FIELDS = %i[
              context_evidence max_output_evidence embedding_dimensions_evidence
              model_revision_evidence tokenizer_evidence
            ].freeze

            private

            # Every catalog pass rebuilds evidence observation timestamps. The
            # timestamps are telemetry, but every other draft field remains
            # authoritative. Catalog order is not authoritative; multiplicity is.
            def offerings_changed?(previous:, current:)
              offering_comparison_multiset(current) != offering_comparison_multiset(previous)
            end

            def offering_comparison_multiset(offerings)
              Array(offerings).map { |draft| offering_comparison_state(draft) }.tally
            end

            def offering_comparison_state(draft)
              state = draft.to_h
              state[:operation_evidence] = comparison_evidence_map(draft.operation_evidence)
              state[:capability_evidence] = comparison_evidence_map(draft.capability_evidence)
              SCALAR_EVIDENCE_FIELDS.each do |field|
                state[field] = comparison_evidence(draft.public_send(field))
              end
              state
            end

            def comparison_evidence_map(evidence)
              evidence.transform_values { |entry| comparison_evidence(entry) }
            end

            def comparison_evidence(evidence)
              evidence.to_h.except(:observed_at)
            end
          end

          # ── Settings display health helpers (D14) ────────────────────────────
          module DisplayHealth
            private

            # Display-only health/capabilities for the status API, written after
            # each registry commit. The key is the CONFIG name
            # (settings[:instances] key), never the derived instance_id.
            # Routing authority stays the in-memory AvailabilityFact; this hash
            # is never read by the router.
            def sync_display_health(state:)
              entry = instance_settings_entry(name: state[:name])
              return unless entry.is_a?(Hash)

              entry.merge!(display_health_entry(state: state))
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.sync_display_health',
                                  instance_id: state[:instance_id])
            end

            def display_health_entry(state:)
              record = publisher.snapshot.instance(instance_key: state[:instance_key])
              status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
              {
                health: display_health(availability: record&.availability, status: status),
                capabilities: instance_capabilities(state[:offerings])
              }
            end

            def clear_display_health(name:)
              entry = instance_settings_entry(name: name)
              return unless entry.is_a?(Hash)

              entry.delete(:health)
              entry.delete(:capabilities)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.clear_display_health',
                                  instance_name: name.to_s)
            end

            def instance_settings_entry(name:)
              instances = settings[:instances]
              return nil unless instances.is_a?(Hash)

              instances[name] || instances[name.to_s]
            end

            def display_health(availability:, status:)
              available = availability&.state == :available
              {
                circuit_state: available ? :closed : :open,
                denied: false,
                available: available,
                adjustment: available ? 0 : -50,
                reason: health_reason(availability: availability, status: status),
                observed_at: health_observed_at(availability: availability, status: status),
                last_probe_outcome: status.last_probe_outcome,
                source: health_source(availability: availability)
              }
            end

            def health_reason(availability:, status:)
              availability&.reason || status.last_error
            end

            def health_observed_at(availability:, status:)
              availability&.observed_at || status.last_probe_completed_at
            end

            def health_source(availability:)
              availability&.source || :initial_readiness
            end

            def instance_capabilities(offerings)
              offerings.flat_map do |draft|
                draft.capability_evidence.filter_map do |capability, evidence|
                  evidence.supported? ? capability : nil
                end
              end.uniq.sort
            end
          end

          # ── Instance component helpers ───────────────────────────────────────
          module InstanceComponents
            private

            def build_instance_key(instance_id:, physical_id: nil)
              Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :gemini, instance_id: instance_id, physical_id: physical_id
              )
            end

            def build_instance_components(instance_id:, instance_cfg:, instance_key:)
              callable = GeminiCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key, enqueue: build_probe_enqueue(instance_id: instance_id)
              )
              publisher_token = publisher.claim_instance(
                instance_id: instance_id, callable: callable, probe_request_handle: probe_coordinator,
                physical_id: instance_key.physical_id
              )
              { callable: callable, probe_coordinator: probe_coordinator, publisher_token: publisher_token }
            end

            def claim_and_activate_instance(name:, instance_cfg:)
              # Identity is the operator's CONFIG NAME (the key the router
              # looks up in instances.<name>); the derived host:port/ak id is
              # the secondary physical id (dedup/diagnostics only).
              instance_id  = name.to_s
              physical_id  = derive_physical_id(instance_cfg: instance_cfg)
              instance_key = build_instance_key(instance_id: instance_id, physical_id: physical_id)
              offerings    = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)
              components   = build_instance_components(instance_id: instance_id, instance_cfg: instance_cfg,
                                                       instance_key: instance_key)
              state        = {
                name: name,
                instance_id: instance_id,
                instance_key: instance_key,
                instance_cfg: instance_cfg,
                callable: components[:callable],
                probe_coordinator: components[:probe_coordinator],
                publisher_token: components[:publisher_token],
                sequence: 0,
                offerings: offerings,
                published: false
              }
              Legion::Extensions::Llm::Inventory::WeightReconciler.track_initializing!(
                states: @instance_states, state_key: instance_id, state: state, mutex: @instance_state_mutex
              )
              settle_initial_readiness(instance_id: instance_id, state: state)
              sync_display_health(state: state) if tracked_instance_state(instance_id).equal?(state)
            end

            def drop_instance(instance_id:, state:)
              removed = @instance_state_mutex.synchronize do
                next false unless @instance_states[instance_id].equal?(state)

                publisher.remove_instance(
                  instance_id: instance_id, publisher_token: state[:publisher_token],
                  physical_id: state[:instance_key].physical_id
                )
                @instance_states.delete(instance_id)
                true
              end
              return false unless removed

              state[:callable]&.disconnect
              clear_display_health(name: state[:name])
              true
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.remove_instance',
                                  instance_id: instance_id)
              false
            end
          end

          # Shared weight-reconciliation bindings and synchronized state access.
          module WeightPublication
            private

            def commit_discovered_offerings(instance_id:, state:, offerings:)
              Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
                settings: Legion::Settings,
                instance_id: instance_id,
                state: state,
                discovered_offerings: offerings,
                mutex: @instance_state_mutex,
                equivalent: lambda do |previous, current|
                  !offerings_changed?(previous: previous, current: current)
                end,
                replace: method(:replace_weight_snapshot)
              )
            end

            def replace_weight_snapshot(instance_id:, state:, offerings:, sequence:)
              publisher.replace_instance_snapshot(
                instance_id: instance_id,
                publisher_token: state.fetch(:publisher_token),
                offerings: offerings,
                sequence: sequence,
                physical_id: state.fetch(:instance_key).physical_id
              )
            end

            def activate_weight_snapshot(instance_id:, state:, offerings:, sequence:, probe_token:)
              publisher.activate_instance_snapshot(
                instance_id: instance_id,
                publisher_token: state.fetch(:publisher_token),
                offerings: offerings,
                sequence: sequence,
                probe_token: probe_token,
                physical_id: state.fetch(:instance_key).physical_id
              )
            end

            def tracked_instance_state(instance_id)
              return unless @instance_states && @instance_state_mutex

              @instance_state_mutex.synchronize { @instance_states[instance_id] }
            end

            def instance_states_snapshot
              @instance_state_mutex.synchronize { @instance_states.each_pair.to_h }
            end

            def observe_dormant_weights
              Legion::Extensions::Llm::Inventory::WeightReconciler.observe_dormant!(
                settings: Legion::Settings,
                provider_family: :gemini,
                states: @instance_states,
                mutex: @instance_state_mutex,
                tracker: @dormant_weight_tracker,
                dormant_logger: lambda do |key|
                  log.info do
                    "[llm][gemini] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true"
                  end
                end
              )
            end
          end

          # Per-instance SSOT lifecycle: reconcile configured instances each
          # tick, run the readiness state machine (initial probe, recovery
          # while :initializing, cadence probes, snapshot replacement), and
          # retire instances on shutdown.
          module InstanceLifecycle
            private

            def initial_discovery
              @instance_states = Concurrent::Map.new
              @instance_state_mutex = Mutex.new
              @dormant_weight_tracker = Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
              reconcile_and_refresh
            end

            def tick_refresh = reconcile_and_refresh

            # Re-scans configured instances every tick so instances configured
            # after boot appear without a restart and instances removed from
            # settings are retired from the registry. Instances claimed THIS
            # tick are not refreshed again in the same pass — their initial
            # probe just ran; refresh and cadence probes start next tick.
            def reconcile_and_refresh
              configured = configured_instances
              existing = instance_states_snapshot.keys
              add_newly_configured_instances(configured: configured)
              remove_unconfigured_instances(configured: configured)
              instance_states_snapshot.each do |instance_id, state|
                next unless existing.include?(instance_id)

                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'gemini.actor.refresh_instance',
                                    instance_id: instance_id)
              end
              observe_dormant_weights
            end

            def add_newly_configured_instances(configured:)
              configured.each do |name, instance_cfg|
                # Dedup on the CONFIG NAME (the identity), not the physical
                # id: two config names pointing at the same endpoint are
                # distinct instances (the physical id never participates in
                # identity).
                next if tracked_instance_state(name.to_s)

                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'gemini.actor.claim_instance', instance_name: name.to_s)
              end
            end

            def remove_unconfigured_instances(configured:)
              instance_states_snapshot.each_value do |state|
                next if configured.key?(state[:name])

                drop_instance(instance_id: state[:instance_id], state: state)
              end
            end

            # Starts the readiness probe and settles it: on success activates
            # the current offerings (sequence 0 — valid only while the scope
            # is still :initializing), on failure records it and the instance
            # stays :initializing for the next tick's retry.
            def settle_initial_readiness(instance_id:, state:)
              physical_id = state[:instance_key].physical_id
              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id, publisher_token: state[:publisher_token], physical_id: physical_id
              )
              readiness = check_health(instance_cfg: state[:instance_cfg])
              if readiness.ready?
                Legion::Extensions::Llm::Inventory::WeightReconciler.activate_tracked!(
                  settings: Legion::Settings,
                  instance_id: instance_id,
                  state_key: instance_id,
                  state: state,
                  states: @instance_states,
                  mutex: @instance_state_mutex,
                  probe_token: probe_token,
                  activate: method(:activate_weight_snapshot),
                  activation_sequence: ->(tracked) { tracked.fetch(:sequence) }
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id, probe_token: probe_token, reason: readiness.reason,
                  physical_id: physical_id
                )
              end
            end

            def refresh_instance(instance_id:, state:)
              if publication_state(instance_key: state[:instance_key]) == :initializing
                retry_initial_activation(instance_id: instance_id, state: state)
              else
                replace_offerings_if_changed(instance_id: instance_id, state: state)
                run_cadence_probe(instance_id: instance_id, state: state)
              end
            end

            def publication_state(instance_key:)
              publisher.snapshot.publication_status(instance_key: instance_key).state
            end

            # An instance that failed initial readiness stays :initializing —
            # readiness_succeeded and replace_instance_snapshot both refuse to
            # operate on an :initializing scope, so without this re-activation
            # path a transient outage at boot pins the instance for the process
            # lifetime. Re-probe each tick and activate once readiness passes.
            def retry_initial_activation(instance_id:, state:)
              offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              commit_discovered_offerings(instance_id: instance_id, state: state, offerings: offerings)
              settle_initial_readiness(instance_id: instance_id, state: state)
              sync_display_health(state: state) if tracked_instance_state(instance_id).equal?(state)
            end

            def replace_offerings_if_changed(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg], instance_key: state[:instance_key]
              )
              changed = commit_discovered_offerings(
                instance_id: instance_id, state: state, offerings: new_offerings
              )
              sync_display_health(state: state) if changed
            end

            def remove_all_instances
              return unless @instance_states

              instance_states_snapshot.each_value do |state|
                drop_instance(instance_id: state[:instance_id], state: state)
              end
              @instance_state_mutex.synchronize do
                @instance_states.clear
                @dormant_weight_tracker.clear!
              end
            end
          end

          # SSOT v3 periodic discovery actor for Gemini provider instances.
          # Claims configured instances, discovers models via the Gemini models
          # API, probes health via model listing, and publishes complete
          # OfferingDraft snapshots through the Inventory::Publisher. Recovers
          # instances that fail initial readiness and supports coalesced
          # reactive probes after dispatch-triggered instance_unavailable
          # transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper
            include EvidenceBuilder
            include ValueEvidenceBuilder
            include ModelDiscovery
            include ConfigResolver
            include HttpClient
            include ProbeRunner
            include HealthChecker
            include OfferingComparison
            include DisplayHealth
            include InstanceComponents
            include WeightPublication
            include InstanceLifecycle

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            # The registered discovery interval lives under instances.default
            # (provider_settings nests it there). Never return nil — a nil
            # execution_interval makes the TimerTask fire exactly once and then
            # stop, killing all refresh, probes, and recovery.
            def time
              interval = settings.dig(:instances, :default, :discovery_interval)
              return interval if interval.is_a?(::Integer) && interval.positive?

              Legion::Extensions::Llm::Gemini.default_settings.dig(:instances, :default, :discovery_interval)
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'gemini.actor.discovery_refresh.shutdown')
            end

            private

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(
                provider_family: :gemini,
                compatibility_adapter: Legion::Extensions::Llm::Inventory::ScopedRefresher::LegacyCoordinatorAdapter.new(
                  provider_family: :gemini
                )
              )
            end
          end

          # Callable wrapper for a Gemini provider instance. Implements the
          # fleet dispatch ops (chat/stream_chat/embed/count_tokens) by
          # delegating to a per-instance Gemini::Provider, plus the
          # disconnect and normalize_dispatch_error contracts required by
          # Inventory::CallableHandle and Routing::ProviderOutcome. Dispatch
          # errors propagate untouched so normalize_dispatch_error can
          # classify them.
          class GeminiCallable
            def initialize(instance_cfg:, logger:, provider: nil)
              @instance_cfg  = instance_cfg
              @logger        = logger
              @provider      = provider
              @disconnected  = false
            end

            def disconnected? = @disconnected

            def disconnect
              @disconnected = true
              @provider&.disconnect
              @logger.debug { '[gemini][callable] disconnected' }
            end

            # Fleet and SelectionDispatch pass model as a RAW STRING (the
            # offering's model id). Gemini's render path calls model.id
            # (MessageFormatter#render_payload), so a raw string must be
            # wrapped before delegation; Model::Info instances pass through.
            def chat(messages:, model:, **rest)
              provider.chat(messages: messages, model: llm_model(model), **rest)
            end

            def stream_chat(messages:, model:, **rest, &)
              provider.stream_chat(messages: messages, model: llm_model(model), **rest, &)
            end

            def embed(text:, model:, **rest)
              provider.embed(text: text, model: llm_model(model), **rest)
            end

            def count_tokens(messages:, model:, **rest)
              provider.count_tokens(messages: messages, model: llm_model(model), **rest)
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]
              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: classify_dispatch_error(error: error), reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def llm_model(model)
              return model if model.respond_to?(:id)

              Legion::Extensions::Llm::Model::Info.new(id: model.to_s, provider: :gemini)
            end

            def provider = @provider ||= build_provider

            def build_provider
              Legion::Extensions::Llm::Gemini::Provider.new(
                {
                  gemini_api_key: @instance_cfg[:gemini_api_key] || @instance_cfg[:api_key] ||
                                  @instance_cfg.dig(:credentials, :api_key),
                  gemini_api_base: @instance_cfg[:gemini_api_base] || @instance_cfg[:endpoint]
                }.compact
              )
            end

            def classify_dispatch_error(error:)
              return :connection_failure if error.is_a?(Faraday::ConnectionFailed)
              return :timeout if error.is_a?(Faraday::TimeoutError)
              return :overloaded if error.is_a?(Legion::Extensions::Llm::OverloadedError)
              return classify_by_status(error: error) if http_status_error?(error)

              :provider_error
            end

            def http_status_error?(error)
              error.is_a?(Faraday::ClientError) || error.is_a?(Faraday::ServerError) ||
                error.is_a?(Legion::Extensions::Llm::Error)
            end

            # §8 health firewall: only the explicit Gemini UNAVAILABLE body
            # signal maps to :instance_unavailable. Status code alone (503/529)
            # never does — those are request-local overload conditions.
            def classify_by_status(error:)
              return :instance_unavailable if explicit_service_unavailable?(error: error)

              status = dispatch_status(error)
              return :model_not_ready if status.is_a?(::Integer) && status >= 500 &&
                                         model_not_ready_signal?(error: error)

              status_kind(status)
            end

            def status_kind(status)
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              when 503, 529 then :overloaded
              when 400...500 then :invalid_request
              else :provider_error
              end
            end

            # Returns true only when the Gemini API response body explicitly
            # carries "status":"UNAVAILABLE" — the flat service-level
            # unavailability signal distinct from throttling
            # (RESOURCE_EXHAUSTED) or model loading.
            def explicit_service_unavailable?(error:)
              body = response_body_string(error)
              return false if body.nil?

              (body.include?('"status":"UNAVAILABLE"') || body.include?('"status": "UNAVAILABLE"')) &&
                !body.include?('RESOURCE_EXHAUSTED')
            end

            def model_not_ready_signal?(error:)
              body = response_body_string(error)&.downcase
              body.to_s.include?('model not ready') || body.to_s.include?('model is still loading')
            end

            # Reads the body from every real Faraday error shape: Faraday::Env
            # (Faraday 2.x — a Struct, NOT a Hash, which is why an
            # is_a?(Hash) gate here is dead in production), Faraday::Response
            # (lex-llm ErrorMiddleware), or the plain response Hash (Faraday
            # RaiseError middleware / Faraday 1.x).
            def response_body_string(error)
              response = error.respond_to?(:response) ? error.response : nil
              return nil unless response

              body = response.respond_to?(:body) ? response.body : (response[:body] if response.respond_to?(:[]))
              return body if body.is_a?(String)

              body && ::JSON.generate(body)
            end

            def dispatch_status(error)
              return error.response_status if error.respond_to?(:response_status) && error.response_status

              response = error.respond_to?(:response) ? error.response : nil
              response.respond_to?(:status) ? response.status : nil
            end
          end
        end
      end
    end
  end
end
