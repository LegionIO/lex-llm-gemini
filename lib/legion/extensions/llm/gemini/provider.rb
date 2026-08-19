# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Gemini
        # Message-kind predicates over the two boundary-accepted message shapes
        # (Canonical::Message and provider-native Message). Both expose
        # .tool_calls and .tool_call_id; the render seam rejects anything else.
        module MessageKinds
          private

          def tool_call_message?(message)
            calls = message.tool_calls
            !calls.nil? && !calls.empty?
          end

          def tool_result_message?(message)
            tool_call_id = message.tool_call_id
            !tool_call_id.nil? && !tool_call_id.to_s.empty?
          end
        end

        # Message formatting helpers mixed into Provider.
        module MessageFormatter
          private

          def render_payload(messages, **opts)
            # Canonical boundary (N x N law): reject non-object message shapes loudly.
            enforce_message_boundary!(messages)
            model       = opts.fetch(:model)
            tools       = opts.fetch(:tools)
            temperature = opts.fetch(:temperature)
            @model      = model.id
            build_request_payload(messages: messages, tools: tools, temperature: temperature,
                                  schema: opts[:schema], tool_prefs: opts[:tool_prefs])
          end

          def build_request_payload(messages:, tools:, temperature:, schema:, tool_prefs:)
            payload = { contents: format_messages(messages), generationConfig: generation_config(temperature, schema) }
            payload[:systemInstruction] = system_instruction(messages)
            payload[:tools] = format_tools(tools) unless tools.empty?
            payload[:toolConfig] = tool_config(tool_prefs) if tool_prefs
            payload.compact
          end

          def generation_config(temperature, schema)
            {
              temperature: temperature,
              responseMimeType: ('application/json' if schema),
              responseSchema: schema_hash(schema)
            }.compact
          end

          def schema_hash(schema)
            return unless schema

            schema.respond_to?(:to_h) ? schema.to_h.fetch(:schema, schema.to_h) : schema
          end

          def system_instruction(messages)
            system_messages = messages.select { |message| message.role == :system }
            parts = system_messages.flat_map { |message| content_parts(message.content) }
            return nil if parts.empty?

            { parts: parts }
          end

          def format_messages(messages)
            messages.reject { |message| message.role == :system }.map do |message|
              { role: gemini_role(message), parts: message_parts(message) }
            end
          end

          def gemini_role(message)
            return 'model' if message.role == :assistant
            return 'function' if tool_result_message?(message)

            message.role.to_s
          end

          def message_parts(message)
            return tool_call_parts(message) if tool_call_message?(message)
            return tool_result_parts(message) if tool_result_message?(message)

            content_parts(message.content)
          end

          def content_parts(content)
            return Array(content.value) if content.is_a?(Legion::Extensions::Llm::Content::Raw)
            return [{ text: Legion::JSON.generate(content) }] if content.is_a?(Hash) || content.is_a?(Array)
            return [{ text: content.to_s }] unless content.is_a?(Legion::Extensions::Llm::Content)

            parts = []
            parts << { text: content.text } if content.text
            content.attachments.each { |attachment| parts << attachment_part(attachment) }
            parts
          end

          def attachment_part(attachment)
            if attachment.text?
              { text: attachment.for_llm }
            else
              { inline_data: { mime_type: attachment.mime_type, data: attachment.encoded } }
            end
          end

          def tool_call_parts(message)
            calls = message.tool_calls.is_a?(Hash) ? message.tool_calls.values : Array(message.tool_calls)
            calls.map do |tool_call|
              { functionCall: { name: tool_call.name, args: tool_call.arguments } }
            end
          end

          def tool_result_parts(message)
            [{
              functionResponse: {
                name: message.tool_call_id,
                response: { name: message.tool_call_id, content: content_parts(message.content) }
              }
            }]
          end

          def format_tools(tools)
            [{
              functionDeclarations: tools.values.map do |tool|
                schema = Legion::Extensions::Llm::Canonical::ToolSchema.extract(tool)
                {
                  name: Legion::Extensions::Llm::Canonical::ToolSchema.tool_name(tool),
                  description: Legion::Extensions::Llm::Canonical::ToolSchema.tool_description(tool),
                  parameters: schema
                }
              end
            }]
          end

          def tool_config(tool_prefs)
            choice = tool_prefs[:choice] || tool_prefs['choice']
            return unless choice

            { functionCallingConfig: { mode: choice.to_s } }
          end

          def model_path(model)
            value = model.respond_to?(:id) ? model.id : model.to_s
            value.start_with?('models/') ? value : "models/#{value}"
          end
        end

        # Response parsing helpers mixed into Provider.
        module ResponseParser
          private

          def parse_completion_response(response)
            body = response.body
            parts = response_parts(body)

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: text_content(parts),
              tool_calls: parse_tool_calls(parts),
              input_tokens: body.dig('usageMetadata', 'promptTokenCount'),
              output_tokens: output_tokens(body),
              cached_tokens: body.dig('usageMetadata', 'cachedContentTokenCount'),
              thinking_tokens: body.dig('usageMetadata', 'thoughtsTokenCount'),
              model_id: body['modelVersion'] || @model,
              raw: body
            )
          end

          def build_chunk(data)
            parts = response_parts(data)

            Legion::Extensions::Llm::Chunk.new(
              role: :assistant,
              content: text_content(parts),
              tool_calls: parse_tool_calls(parts),
              input_tokens: data.dig('usageMetadata', 'promptTokenCount'),
              output_tokens: output_tokens(data),
              cached_tokens: data.dig('usageMetadata', 'cachedContentTokenCount'),
              thinking_tokens: data.dig('usageMetadata', 'thoughtsTokenCount'),
              model_id: data['modelVersion'] || @model,
              raw: data
            )
          end

          def response_parts(body)
            body.dig('candidates', 0, 'content', 'parts') || []
          end

          def text_content(parts)
            text = parts.reject { |part| part['thought'] }.filter_map { |part| part['text'] }.join
            text.empty? ? nil : text
          end

          def output_tokens(body)
            candidates = body.dig('usageMetadata', 'candidatesTokenCount') || 0
            thoughts = body.dig('usageMetadata', 'thoughtsTokenCount') || 0
            total = candidates + thoughts
            total.positive? ? total : nil
          end

          def parse_tool_calls(parts)
            tool_calls = parts.each_with_object({}) do |part, result|
              function_call = part['functionCall']
              next unless function_call

              id = SecureRandom.uuid
              result[id] = Legion::Extensions::Llm::ToolCall.new(
                id: id,
                name: function_call['name'],
                arguments: function_call['args'] || {}
              )
            end

            tool_calls.empty? ? nil : tool_calls
          end

          def parse_list_models_response(response, provider, capabilities)
            Array(response.body['models']).map do |model_data|
              model_id = model_data.fetch('name').delete_prefix('models/')
              methods = Array(model_data['supportedGenerationMethods'])
              input_mods, output_mods = modalities_for(methods)

              Legion::Extensions::Llm::Model::Info.new(
                id: model_id,
                name: model_data['displayName'] || model_id,
                provider: provider,
                context_length: model_data['inputTokenLimit'],
                capabilities: capabilities.critical_capabilities_for(model_data),
                modalities_input: input_mods,
                modalities_output: output_mods,
                metadata: {
                  max_output_tokens: model_data['outputTokenLimit'],
                  version: model_data['version'],
                  description: model_data['description'],
                  supported_generation_methods: methods
                }
              )
            end
          end

          def render_embedding_payload(text, model:, dimensions:)
            {
              model: model_path(model),
              content: { parts: [{ text: text.to_s }] },
              outputDimensionality: dimensions
            }.compact
          end

          def parse_embedding_response(response, model:, **)
            Legion::Extensions::Llm::Embedding.new(
              vectors: response.body.dig('embedding', 'values'),
              model: model,
              input_tokens: response.body.dig('usageMetadata', 'promptTokenCount').to_i
            )
          end
        end

        # Offering and capability building helpers mixed into Provider.
        module OfferingBuilder
          private

          def offering_from_model(model, health: {})
            policy = Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: real_capabilities_from(model),
              provider_catalog: {},
              probe: {},
              provider_envelope: {},
              provider_config: provider_capability_config,
              instance_config: instance_capability_config,
              model_config: model_capability_config(model.id)
            )

            build_model_offering(model, policy, health)
          end

          def build_model_offering(model, policy, health)
            Routing::ModelOffering.new(
              provider_family: slug.to_sym,
              provider_instance: model.instance || provider_instance_id,
              transport: offering_transport,
              tier: offering_tier,
              model: model.id,
              canonical_model_alias: model.name,
              model_family: model.family,
              usage_type: offering_usage_type(model),
              capabilities: policy[:capabilities],
              capability_sources: policy[:sources],
              limits: offering_limits(model),
              health:,
              metadata: offering_metadata(model)
            )
          end

          def real_capabilities_from(model)
            meta = model.respond_to?(:metadata) ? (model.metadata || {}) : {}
            methods = Array(meta[:supported_generation_methods] || meta['supported_generation_methods'])
            {
              streaming: methods.include?('streamGenerateContent'),
              embedding: methods.include?('embedContent'),
              vision: Legion::Extensions::Llm::Gemini::Provider::Capabilities.vision?(
                meta.merge('name' => "models/#{model.id}")
              )
            }.compact
          end

          def provider_capability_config
            conf = Legion::Extensions::Llm::CredentialSources.setting(:extensions, :llm, :gemini)
            conf.is_a?(Hash) ? conf.to_h.except(:instances, 'instances') : {}
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'gemini.provider_capability_config')
            {}
          end

          def instance_capability_config
            config.to_h.slice(*Legion::Extensions::Llm::Provider::CAPABILITY_CONFIG_KEYS)
          end

          def model_capability_config(model_id)
            hash = resolve_models_config
            return {} unless hash.is_a?(Hash)

            hash[model_id.to_s] || hash[model_id.to_sym] || {}
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'gemini.model_capability_config')
            {}
          end

          def resolve_models_config
            config.to_h[:models]
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'gemini.resolve_models_config')
            nil
          end

          def modalities_for(methods)
            return [%w[text], %w[embeddings]] if methods.include?('embedContent')

            [%w[text image audio video], %w[text]]
          end
        end

        # Gemini provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Logging::Helper
          include MessageKinds
          include MessageFormatter
          include ResponseParser
          include OfferingBuilder

          class << self
            def slug = 'gemini'
            def configuration_options = %i[gemini_api_key gemini_api_base]
            def configuration_requirements = %i[gemini_api_key]
            def capabilities = Capabilities
          end

          # Capability predicates for Gemini API models.
          module Capabilities
            module_function

            def chat?(model) = supported?(model, 'generateContent')
            def streaming?(model) = supported?(model, 'streamGenerateContent')
            def embeddings?(model) = supported?(model, 'embedContent')
            def vision?(model) = chat?(model) && model_id(model).match?(/gemini|flash|pro/)
            def functions?(model) = chat?(model)

            def critical_capabilities_for(model)
              [
                ('streaming' if streaming?(model)),
                ('embedding' if embeddings?(model)),
                ('tools' if functions?(model)),
                ('vision' if vision?(model))
              ].compact
            end

            # When generation methods are absent, treat all capabilities as unknown
            # (unknown = unsupported for selection). Only fall back to name heuristic
            # for embedContent to preserve legacy embedding detection.
            def supported?(model, action)
              methods = generation_methods(model)
              return model_id(model).include?('embedding') if methods.empty?

              methods.include?(action)
            end

            def generation_methods(model)
              metadata = metadata_for(model)
              Array(metadata[:supported_generation_methods] || metadata['supported_generation_methods'] ||
                    metadata['supportedGenerationMethods'])
            end

            def model_id(model)
              return model.fetch('name', '').delete_prefix('models/') if model.is_a?(Hash)

              model.respond_to?(:id) ? model.id.to_s : model.to_s
            end

            def metadata_for(model)
              return model if model.is_a?(Hash)
              return model.metadata if model.respond_to?(:metadata)

              {}
            end
          end

          def settings
            Gemini.default_settings
          end

          def api_base
            config.gemini_api_base || settings[:instances][:default][:endpoint]
          end

          def headers
            identity_headers.merge('x-goog-api-key' => config.gemini_api_key)
          end

          def completion_url = generate_content_url(model: @model)
          def stream_url = stream_generate_content_url(model: @model)
          def models_url = 'models'
          def embedding_url(model:) = embed_content_url(model:)

          def generate_content_url(model:)
            "#{model_path(model)}:generateContent"
          end

          def stream_generate_content_url(model:)
            "#{model_path(model)}:streamGenerateContent?alt=sse"
          end

          def embed_content_url(model:)
            "#{model_path(model)}:embedContent"
          end

          def list_models(**)
            log.info { 'listing available Gemini models' }
            super.tap do |models|
              log.info { "discovered #{models.size} Gemini model(s)" }
            end
          end

          private

          # Canonical boundary: pipeline dispatch delivers Canonical::Message
          # objects; the provider-native Chat facade delivers lex-llm Message.
          # Both are object shapes this spoke renders to the Gemini wire. Plain
          # Hashes are the bypass class (the 2026-08-19 incident) — reject
          # loudly, never silently re-canonicalize.
          def enforce_message_boundary!(messages)
            messages.each do |message|
              next if message.is_a?(Legion::Extensions::Llm::Canonical::Message)
              next if message.is_a?(Legion::Extensions::Llm::Message)

              raise ArgumentError,
                    "gemini provider input must be Canonical::Message objects, got #{message.class} — " \
                    'non-canonical message shapes must not cross the dispatch boundary'
            end
          end
        end
      end
    end
  end
end
