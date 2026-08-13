# frozen_string_literal: true

require 'digest'
require 'uri'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Gemini
        module Actor
          # SSOT v3 periodic discovery actor for Gemini provider instances.
          # Claims instances, discovers models via the Gemini models API,
          # probes health via model listing, and publishes complete OfferingDraft
          # snapshots through the Inventory::Publisher. Supports coalesced reactive
          # probes after dispatch-triggered instance_unavailable transitions.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Metrics/ClassLength
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              settings[:discovery_interval] || self.class.every_seconds
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

            # ── Publisher ──────────────────────────────────────────────────────

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :gemini)
            end

            # ── Initial discovery ─────────────────────────────────────────────

            def initial_discovery
              @instance_states = {}
              configured_instances.each do |name, instance_cfg|
                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'gemini.actor.claim_instance', instance_name: name.to_s)
              end
            end

            def claim_and_activate_instance(name:, instance_cfg:) # rubocop:disable Metrics/AbcSize
              instance_id = derive_instance_id(instance_cfg: instance_cfg)
              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :gemini, instance_id: instance_id
              )

              callable = GeminiCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id: instance_id)
              )

              publisher_token = publisher.claim_instance(
                instance_id: instance_id,
                callable: callable,
                probe_request_handle: probe_coordinator
              )

              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: publisher_token
              )

              readiness = check_health(instance_cfg: instance_cfg)

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: publisher_token,
                  offerings: offerings,
                  sequence: 0,
                  probe_token: probe_token
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end

              @instance_states[instance_id] = {
                name: name,
                instance_key: instance_key,
                instance_cfg: instance_cfg,
                callable: callable,
                probe_coordinator: probe_coordinator,
                publisher_token: publisher_token,
                sequence: 0,
                offerings: offerings
              }
            end

            # ── Tick refresh ──────────────────────────────────────────────────

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'gemini.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key]
              )

              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token],
                  offerings: new_offerings,
                  sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
              end

              run_cadence_probe(instance_id: instance_id, state: state)
            end

            # ── Readiness probing ─────────────────────────────────────────────

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe

              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              coordinator&.finish_probe rescue nil # rubocop:disable Style/RescueModifier
              handle_exception(e, level: :warn, operation: 'gemini.actor.cadence_probe',
                                  instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)

              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              coordinator&.finish_probe(request: request) rescue nil # rubocop:disable Style/RescueModifier
              handle_exception(e, level: :warn, operation: 'gemini.actor.reactive_probe',
                                  instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'gemini.actor.probe_enqueue',
                                    instance_id: instance_id)
                false
              end
            end

            # ── Health check (model listing — non-billable) ──────────────────

            def check_health(instance_cfg:)
              base_url = resolve_api_base(instance_cfg: instance_cfg)
              conn = build_api_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get('models', { pageSize: 1 })
              build_readiness_from_response(response: response, base_url: base_url)
            rescue Faraday::ConnectionFailed => e
              readiness_failure(reason: "Gemini models API connection failed: #{e.message}", error: e)
            rescue StandardError => e
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

            # ── Model discovery ───────────────────────────────────────────────

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              models = fetch_models(instance_cfg: instance_cfg)

              models.filter_map do |model_data|
                model_id = extract_model_id(model_data: model_data)
                next if model_id.empty?

                build_offering_draft(
                  model_id: model_id,
                  model_data: model_data,
                  instance_cfg: instance_cfg,
                  instance_key: instance_key
                )
              end
            rescue StandardError => e
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

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
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

            # ── Generation method extraction ─────────────────────────────────

            def extract_generation_methods(model_data:)
              Array(
                model_data[:supportedGenerationMethods] ||
                model_data[:supported_generation_methods] ||
                model_data['supportedGenerationMethods'] ||
                model_data['supported_generation_methods']
              )
            end

            # ── Operation evidence ────────────────────────────────────────────

            def build_operation_evidence(generation_methods:)
              now = Time.now.freeze
              chat_status = resolve_operation_status(generation_methods: generation_methods, action: 'generateContent')
              stream_status = resolve_operation_status(generation_methods: generation_methods,
                                                       action: 'streamGenerateContent')
              embed_status = resolve_operation_status(generation_methods: generation_methods, action: 'embedContent')

              {
                chat: op_evidence(operation: :chat, status: chat_status, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: stream_status, observed_at: now),
                embed: op_evidence(operation: :embed, status: embed_status, observed_at: now),
                image: op_evidence(operation: :image, status: :unsupported, observed_at: now),
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
              source = if status == :unknown
                         :default_false
                       else
                         :provider_catalog
                       end
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation,
                status: status,
                source: source,
                observed_at: observed_at
              )
            end

            # ── Capability evidence ───────────────────────────────────────────

            def build_capability_evidence(generation_methods:, **)
              {
                completion: cap_from_method(capability: :completion, methods: generation_methods,
                                            action: 'generateContent'),
                streaming: cap_from_method(capability: :streaming, methods: generation_methods,
                                           action: 'streamGenerateContent'),
                embedding: cap_from_method(capability: :embedding, methods: generation_methods, action: 'embedContent'),
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
                capability: capability,
                status: status,
                source: source,
                observed_at: Time.now.freeze
              )
            end

            # ── Value evidence builders ───────────────────────────────────────

            def build_context_evidence(model_data:)
              ctx = model_data[:inputTokenLimit] || model_data['inputTokenLimit'] || model_data[:input_token_limit]
              if ctx.is_a?(Integer) && ctx.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: ctx, source: :provider_catalog
                )
              else
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :unknown, source: :absent
                )
              end
            end

            def build_max_output_evidence(model_data:)
              max_out = model_data[:outputTokenLimit] || model_data['outputTokenLimit'] ||
                        model_data[:output_token_limit]
              if max_out.is_a?(Integer) && max_out.positive?
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: max_out, source: :provider_catalog
                )
              else
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :unknown, source: :absent
                )
              end
            end

            def build_embedding_dimensions_evidence(model_data:, generation_methods:)
              unless generation_methods.include?('embedContent')
                return Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
              end

              dims = extract_valid_dimensions(model_data: model_data)
              if dims
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :known, value: dims, source: :provider_catalog
                )
              else
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :unknown, source: :absent
                )
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
                Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                  status: :unknown, source: :absent
                )
              end
            end

            def build_tokenizer_evidence
              # Gemini API does not expose tokenizer metadata
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :unknown, source: :absent
              )
            end

            # ── Offering metadata ─────────────────────────────────────────────

            def build_offering_metadata(model_data:, instance_key:)
              meta = { raw_model: extract_model_id(model_data: model_data) }
              meta[:display_name] = model_data[:displayName].to_s if model_data[:displayName]
              meta[:description] = model_data[:description].to_s[0, 200] if model_data[:description]
              meta[:instance_id] = instance_key.instance_id
              meta
            end

            # ── Instance ID derivation ────────────────────────────────────────

            def derive_instance_id(instance_cfg:)
              base_url = instance_cfg[:gemini_api_base] || instance_cfg[:endpoint] ||
                         'https://generativelanguage.googleapis.com/v1beta'
              host_port = extract_host_port(url: base_url)
              api_key = instance_cfg[:gemini_api_key] || instance_cfg[:api_key] ||
                        instance_cfg.dig(:credentials, :api_key)

              if api_key.is_a?(String) && !api_key.strip.empty?
                fingerprint = ::Digest::SHA256.hexdigest(api_key)[0, 8]
                "#{host_port}/ak:#{fingerprint}"
              else
                host_port
              end
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              host = uri.host || 'generativelanguage.googleapis.com'
              port = uri.port
              "#{host}:#{port}"
            rescue URI::InvalidURIError
              'unknown:0'
            end

            # ── Graceful shutdown ─────────────────────────────────────────────

            def remove_all_instances
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token]
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'gemini.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end

            # ── Configuration ─────────────────────────────────────────────────

            def configured_instances
              instances = {}

              cfg_instances = settings[:instances]
              if cfg_instances.is_a?(Hash)
                cfg_instances.each do |name, config|
                  instances[name.to_sym] = normalize_instance_config(config: config)
                end
              end

              # Auto-discover from env/top-level settings if no instances configured
              if instances.empty?
                auto_instance = build_auto_instance
                instances[:default_instance] = auto_instance if auto_instance
              end

              instances
            end

            def build_auto_instance
              api_key = settings.dig(:credentials, :api_key)
              api_key = resolve_env_credential(api_key) if api_key.is_a?(String) && api_key.start_with?('env://')
              return nil unless api_key.is_a?(String) && !api_key.strip.empty?

              {
                gemini_api_base: settings[:endpoint] || 'https://generativelanguage.googleapis.com/v1beta',
                gemini_api_key: api_key,
                tier: settings[:tier] || :frontier
              }
            end

            def resolve_env_credential(value)
              env_name = value.delete_prefix('env://')
              ENV.fetch(env_name, nil)
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

            def resolve_instance_credentials(normalized:)
              normalized[:gemini_api_key] ||= normalized.delete(:api_key)
              creds = normalized.delete(:credentials)
              return unless creds.is_a?(Hash)

              creds = creds.transform_keys(&:to_sym)
              normalized[:gemini_api_key] ||= creds[:api_key]
            end

            # ── HTTP connections ───────────────────────────────────────────────

            def resolve_api_base(instance_cfg:)
              (instance_cfg[:gemini_api_base] || instance_cfg[:endpoint] ||
               'https://generativelanguage.googleapis.com/v1beta').to_s
            end

            def build_api_connection(base_url:, instance_cfg:)
              require 'faraday'
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 15
                f.options.open_timeout = 5
                f.headers['Accept'] = 'application/json'
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
          end

          # Callable wrapper for a Gemini provider instance. Implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          class GeminiCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @logger.debug { '[gemini][callable] disconnected' }
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]

              kind = case error
                     when Faraday::ConnectionFailed
                       :connection_failure
                     when Faraday::TimeoutError
                       :timeout
                     when Faraday::ClientError
                       classify_client_error(error: error)
                     when Faraday::ServerError
                       classify_server_error(error: error)
                     when Legion::Extensions::Llm::OverloadedError
                       :overloaded
                     else
                       :provider_error
                     end

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            def classify_client_error(error:)
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else :invalid_request
              end
            end

            def classify_server_error(error:)
              # NEVER classify raw 503/529/5xx as instance_unavailable by status alone.
              # Only an explicit flat Gemini service/instance-unavailable body signal
              # would justify instance_unavailable. Everything else is request-local.
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
              when 503, 529 then :overloaded
              else :provider_error
              end
            end
          end
        end
      end
    end
  end
end
