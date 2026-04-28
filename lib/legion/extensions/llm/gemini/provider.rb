# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Gemini
        # Gemini provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider # rubocop:disable Metrics/ClassLength
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
            def vision?(model) = model_id(model).match?(/gemini|flash|pro/)
            def functions?(model) = chat?(model)

            def critical_capabilities_for(model)
              [
                ('streaming' if streaming?(model)),
                ('embeddings' if embeddings?(model)),
                ('function_calling' if functions?(model)),
                ('vision' if vision?(model))
              ].compact
            end

            def supported?(model, action)
              methods = generation_methods(model)
              return model_id(model).include?('embedding') if action == 'embedContent' && methods.empty?
              return true if methods.empty? && action != 'embedContent'

              methods.include?(action)
            end

            def generation_methods(model)
              metadata = metadata_for(model)
              Array(metadata[:supported_generation_methods] || metadata['supported_generation_methods'])
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

          def api_base
            config.gemini_api_base || 'https://generativelanguage.googleapis.com/v1beta'
          end

          def headers
            { 'x-goog-api-key' => config.gemini_api_key }
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

          private

          def model_path(model)
            value = model.to_s
            value.start_with?('models/') ? value : "models/#{value}"
          end

          # rubocop:disable Metrics/ParameterLists,Lint/UnusedMethodArgument
          def render_payload(messages, tools:, temperature:, model:, stream:, schema:, thinking:, tool_prefs:)
            @model = model.id
            payload = { contents: format_messages(messages), generationConfig: generation_config(temperature, schema) }
            payload[:systemInstruction] = system_instruction(messages)
            payload[:tools] = format_tools(tools) unless tools.empty?
            payload[:toolConfig] = tool_config(tool_prefs) if tool_prefs
            payload.compact
          end
          # rubocop:enable Metrics/ParameterLists,Lint/UnusedMethodArgument

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
            return 'function' if message.tool_result?

            message.role.to_s
          end

          def message_parts(message)
            return tool_call_parts(message) if message.tool_call?
            return tool_result_parts(message) if message.tool_result?

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
            message.tool_calls.values.map do |tool_call|
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
                declaration = { name: tool.name, description: tool.description }
                declaration[:parameters] = tool.params_schema if tool.params_schema
                declaration
              end
            }]
          end

          def tool_config(tool_prefs)
            choice = tool_prefs[:choice] || tool_prefs['choice']
            return unless choice

            { functionCallingConfig: { mode: choice.to_s } }
          end

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

              Legion::Extensions::Llm::Model::Info.new(
                id: model_id,
                name: model_data['displayName'] || model_id,
                provider: provider,
                context_window: model_data['inputTokenLimit'],
                max_output_tokens: model_data['outputTokenLimit'],
                capabilities: capabilities.critical_capabilities_for(model_data),
                modalities: modalities_for(methods),
                metadata: {
                  version: model_data['version'],
                  description: model_data['description'],
                  supported_generation_methods: methods
                }
              )
            end
          end

          def modalities_for(methods)
            return { input: %w[text], output: %w[embeddings] } if methods.include?('embedContent')

            { input: %w[text image audio video], output: %w[text] }
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
      end
    end
  end
end
