# frozen_string_literal: true

require 'digest'
require 'time'
require 'uri'
require 'faraday'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/gemini/helpers/callable'
require 'legion/extensions/llm/gemini/provider'

module Legion
  module Extensions
    module Llm
      module Gemini
        module Runners
          # Gemini discovery runner: ONLY the Gemini-specific work. The
          # generic reconcile / claim / activate / probe (cadence + reactive) /
          # replace / weight-publication / health-display pipeline is mixed in
          # from the shared Discovery::Pipeline. Weight is NOT computed here —
          # the shared WeightReconciler recomputes it from live settings at
          # publish.
          #
          # The catalog is Gemini's own list-models API (GET models ->
          # body[:models], entries named `models/<id>`), not OpenAI-shaped, so
          # fetch_raw_models / model_id_from / check_health are overridden.
          # The overrides are the x-goog-api-key auth header (not bearer), the
          # /v1beta base URL, the 8-char-credential physical id, and the
          # offering-draft evidence.
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

            # ── Gemini instance-config keys / connection ─────────────────────
            def catalog_base_url(instance_cfg:)
              (instance_cfg[:gemini_api_base] || instance_cfg[:endpoint] ||
                'https://generativelanguage.googleapis.com/v1beta').to_s
            end

            def auth_token(instance_cfg:)
              token = instance_cfg[:gemini_api_key] || instance_cfg[:api_key] ||
                      instance_cfg.dig(:credentials, :api_key)
              token if token.is_a?(String) && !token.strip.empty?
            end

            # Gemini authenticates with the x-goog-api-key header, not a
            # bearer Authorization header.
            def apply_auth_headers(faraday:, instance_cfg:)
              api_key = instance_cfg[:gemini_api_key] || instance_cfg[:api_key] ||
                        instance_cfg.dig(:credentials, :api_key)
              return unless api_key.is_a?(String) && !api_key.strip.empty?

              faraday.headers['x-goog-api-key'] = api_key
            end

            # Readiness is a safe non-inference models listing
            # (GET models?pageSize=1). The probe is overridden rather than
            # health_path: an absolute path would resolve against the host
            # root and drop the /v1beta prefix of the base URL.
            def check_health(instance_cfg:)
              base_url = catalog_base_url(instance_cfg: instance_cfg)
              conn = build_connection(base_url: base_url, instance_cfg: instance_cfg, timeout: 15, open_timeout: 5)
              response = conn.get('models', { pageSize: 1 })
              models_api_readiness(response: response, base_url: base_url)
            rescue Faraday::ConnectionFailed => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'gemini.runner.discovery.health.connection', base_url: base_url)
              readiness_error_result(error: e, reason: "Gemini models API connection failed: #{e.message}")
            rescue StandardError => e
              raise e if discovery_programming_error?(e)

              handle_exception(e, level: :warn, handled: true,
                                  operation: 'gemini.runner.discovery.health', base_url: base_url)
              readiness_error_result(error: e, reason: "Gemini models API error: #{e.message}")
            end

            # The catalog is GET models -> body[:models] (not the
            # OpenAI-compatible /v1/models -> body[:data]).
            def fetch_raw_models(instance_cfg:)
              base_url = catalog_base_url(instance_cfg: instance_cfg)
              conn = build_connection(base_url: base_url, instance_cfg: instance_cfg,
                                      timeout: 15, open_timeout: 5)
              response = conn.get('models')
              unless response.status.between?(
                200, 299
              )
                raise CatalogFetchFailure,
                      "catalog fetch returned HTTP #{response.status}"
              end

              Array(Legion::JSON.load(response.body)[:models])
            end

            # The models API lists each entry under :name as `models/<id>`.
            def model_id_from(model_data)
              name = model_data[:name] || model_data['name'] || ''
              name.to_s.delete_prefix('models/')
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Gemini::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # ── Secondary physical id (dedup/diagnostics only) ────────────────
            # host:port, or host:port/ak:<8-char credential digest> when a key
            # is present. Never identity — the instance identity is the
            # operator's config name.
            def derive_physical_id(instance_cfg:)
              host_port = extract_host_port(url: catalog_base_url(instance_cfg: instance_cfg))
              api_key = auth_token(instance_cfg: instance_cfg)
              return "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0, 8]}" if api_key

              host_port
            end

            def extract_host_port(url:)
              uri = URI.parse(url.to_s)
              "#{uri.host || 'generativelanguage.googleapis.com'}:#{uri.port}"
            rescue URI::InvalidURIError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'gemini.runner.discovery.extract_host_port', url: url.to_s)
              'unknown:0'
            end

            # ── Offering draft (evidence + metadata; NO weight) ───────────────
            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              tier = instance_cfg[:tier] || :frontier
              generation_methods = extract_generation_methods(model_data: model_data)

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
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

            private

            def models_api_readiness(response:, base_url:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "Gemini models API returned #{response.status}",
                metadata: { status: response.status, base_url: base_url }
              )
            end

            def readiness_error_result(error:, reason:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false, reason: reason, metadata: { error_class: error.class.name }
              )
            end

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
              source = status == :unknown ? :default_false : :provider_catalog
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end

            def build_capability_evidence(generation_methods:)
              {
                completion: cap_from_method(capability: :completion, methods: generation_methods,
                                            action: 'generateContent'),
                streaming: cap_from_method(capability: :streaming, methods: generation_methods,
                                           action: 'streamGenerateContent'),
                embedding: cap_from_method(capability: :embedding, methods: generation_methods,
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

            def build_offering_metadata(model_data:, instance_key:)
              meta = { raw_model: extract_model_id(model_data: model_data) }
              meta[:display_name] = model_data[:displayName].to_s if model_data[:displayName]
              meta[:description]  = model_data[:description].to_s[0, 200] if model_data[:description]
              meta[:instance_id]  = instance_key.instance_id
              meta
            end

            def extract_model_id(model_data:)
              name = model_data[:name] || model_data['name'] || ''
              name.to_s.delete_prefix('models/')
            end
          end
        end
      end
    end
  end
end
