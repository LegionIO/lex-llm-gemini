# frozen_string_literal: true

require 'json'
require 'faraday'

require 'legion/extensions/llm/error'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/canonical'
require 'legion/extensions/llm/gemini/provider'

module Legion
  module Extensions
    module Llm
      module Gemini
        module Helpers
          # Dispatch-error classification for the Gemini callable (mixed into
          # Callable). Pure functions of the error — no instance state.
          # §8 health firewall: only the explicit Gemini UNAVAILABLE body maps
          # to :instance_unavailable; status codes alone (503/529) are
          # request-local overload conditions.
          module DispatchErrorClassification
            private

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

          # Callable wrapper for a Gemini provider instance. Implements the
          # fleet dispatch ops (chat/stream_chat/embed/count_tokens) by
          # delegating to a per-instance Gemini::Provider, plus the
          # disconnect and normalize_dispatch_error contracts required by
          # Inventory::CallableHandle and Routing::ProviderOutcome. Dispatch
          # errors propagate untouched so normalize_dispatch_error can
          # classify them.
          class Callable
            include DispatchErrorClassification

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

            # Named completion kwargs the base Provider funnel accepts
            # directly (08 F3); everything else in the fleet's **rest is
            # folded wire params that become a Canonical::Params at the
            # boundary (05 O4 — temperature is a params member, never a kwarg).
            COMPLETION_NAMED_KEYS = %i[tools schema thinking tool_prefs headers].freeze
            EMBED_NAMED_KEYS = %i[dimensions headers].freeze

            # Fleet and SelectionDispatch pass model as a RAW STRING (the
            # offering's model id). It passes through untranslated to the
            # provider funnel — the base model_identity and the Gemini
            # renderer both accept the bare string (0.8.0 contract).
            # messages is positional — the 0.8.0 funnel and fleet WorkerExecution
            # both hand the canonical Array<Canonical::Message> positionally.
            def chat(messages, model:, **rest)
              # Canonical boundary (N x N law): pipeline dispatch delivers
              # Canonical::Message objects only. Hash/legacy shapes are the
              # bypass class — reject loudly, never coerce.
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.chat(messages, model: model, params: canonical_params(params), **named)
            end

            def stream_chat(messages, model:, **rest, &)
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.stream_chat(messages, model: model, params: canonical_params(params), **named, &)
            end

            def embed(text:, model:, **rest)
              named, params = split_fleet_kwargs(rest, EMBED_NAMED_KEYS)
              provider.embed(text: text, model: model, params: params, **named)
            end

            def count_tokens(messages:, model:, **rest)
              provider.enforce_canonical_messages!(messages)
              _named, params = split_fleet_kwargs(rest, [])
              provider.count_tokens(messages: messages, model: model, params: params)
            end

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]
              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: classify_dispatch_error(error: error), reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            # The 0.8.0 completion funnel receives canonical values only
            # (08 F3): the folded wire params become a Canonical::Params at
            # the dispatch boundary — the renderer reads params.temperature /
            # params.max_tokens, a raw Hash would NoMethodError.
            def canonical_params(params)
              Legion::Extensions::Llm::Canonical::Params.from_hash(params)
            end

            # Split the fleet's **rest into the base Provider's named kwargs
            # and a payload params hash (any passed :params merged with the
            # remaining unknown keys). Mirrors the shared callable boundary.
            def split_fleet_kwargs(rest, named_keys)
              named = rest.slice(*named_keys)
              extra = rest.reject { |key, _| named.key?(key) }
              params = (extra.delete(:params) || {}).to_h.merge(extra)
              [named, params]
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
          end
        end
      end
    end
  end
end
