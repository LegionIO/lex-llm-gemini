# frozen_string_literal: true

require 'legion/extensions/llm'

module Legion
  module Extensions
    module Llm
      module Gemini
        # Message-kind predicates over canonical messages. Canonical::Message
        # exposes .tool_calls (Array<ToolCall> | nil) and .tool_call_id; the
        # base funnel rejects anything that is not a Canonical::Message before
        # rendering, so these see canonical values only.
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

        # Gemini request renderer (08 R1/R4): renders the provider wire FROM
        # canonical values. Every Gemini wire-dialect decision lives here —
        # the base funnel enforces canonical input centrally before this runs.
        module MessageFormatter
          private

          def render_payload(messages, **opts)
            model    = opts.fetch(:model)
            tools    = opts.fetch(:tools)
            params   = opts.fetch(:params)
            @model   = model.respond_to?(:id) ? model.id : model.to_s
            build_request_payload(
              messages: messages, tools: tools,
              temperature: maybe_normalize_temperature(params),
              schema: opts[:schema], tool_prefs: opts[:tool_prefs]
            )
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

          # Canonical content only: String | ContentBlock | Array<ContentBlock> | nil.
          def content_parts(content)
            return [] if content.nil?
            return content.map { |block| content_block_part(block) } if content.is_a?(::Array)
            return content_block_part(content) if content.is_a?(Legion::Extensions::Llm::Canonical::ContentBlock)

            [{ text: content.to_s }]
          end

          def content_block_part(block)
            if block.text?
              { text: block.text }
            elsif block.type == :image
              { inline_data: { mime_type: block.media_type, data: block.data } }
            else
              raise ArgumentError,
                    "gemini renderer cannot render a :#{block.type} content block to the Gemini wire"
            end
          end

          def tool_call_parts(message)
            message.tool_calls.map do |tool_call|
              { functionCall: { name: tool_call.name, args: tool_call.arguments } }
            end
          end

          def tool_result_parts(message)
            [{ functionResponse: { name: message.tool_call_id,
                                   response: { name: message.tool_call_id,
                                               content: content_parts(message.content) } } }]
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

        # Gemini response parser (08 R2/R4): parses the provider wire TO
        # canonical types. Gemini wire-dialect translation (finishReason
        # vocabulary, usageMetadata spellings, JSON-object vs JSON-string tool
        # arguments, thought parts) lives here, at the edge.
        module ResponseParser
          private

          # One response-parse boundary (08 R2): returns Canonical::Response.
          def parse_completion_response(response)
            body = response.body
            parts = response_parts(body)

            Canonical::Response.build(
              text: text_content(parts),
              thinking: thinking_from_parts(parts),
              tool_calls: parse_tool_calls(parts),
              usage: usage_from_metadata(body['usageMetadata']),
              stop_reason: stop_reason_from_body(body),
              model: body['modelVersion'] || @model
            )
          end

          # One chunk-parse boundary (08 R2): returns a Canonical::Chunk or an
          # Array of them (nil when the SSE body carried no content).
          def build_chunk(data)
            parts = response_parts(data)
            stop_reason = stop_reason_from_body(data)

            chunks = streaming_chunks_for(parts, stop_reason: stop_reason)
            chunks.concat(chunk_for_usage(usage_from_metadata(data['usageMetadata']), stop_reason))

            return nil if chunks.empty?

            chunks.size == 1 ? chunks.first : chunks
          end

          def streaming_chunks_for(parts, stop_reason:)
            chunks = chunk_for_thinking(thinking_from_parts(parts), stop_reason)
            chunks.concat(chunk_for_text(text_content(parts), stop_reason))
            function_calls = parts.filter_map { |part| part['functionCall'] }.compact
            chunks.concat(streaming_tool_call_chunks(function_calls, stop_reason: stop_reason))
            chunks
          end

          # Gemini's final frame usually carries finishReason and
          # usageMetadata together (often with no text part), so the
          # usage chunk carries the frame's stop_reason — the
          # usage_chunk factory has no slot for it.
          def chunk_for_usage(usage, stop_reason)
            return [] if usage.nil?

            [Canonical::Chunk.build(type: :usage, usage: usage, request_id: nil, stop_reason: stop_reason)]
          end

          def chunk_for_thinking(thinking, stop_reason)
            return [] unless thinking

            [Canonical::Chunk.thinking_delta(delta: thinking.content.to_s, request_id: nil,
                                             signature: thinking.signature, stop_reason: stop_reason)]
          end

          def chunk_for_text(text, stop_reason)
            return [] if text.nil?

            [Canonical::Chunk.text_delta(delta: text, request_id: nil, stop_reason: stop_reason)]
          end

          def streaming_tool_call_chunks(function_calls, stop_reason:)
            function_calls.map do |function_call|
              # Gemini streams a complete functionCall per chunk; the
              # accumulator assembles arguments as JSON fragments, so the
              # wire object is serialized to its JSON spelling here (10 U2).
              fragment = { id: nil, name: function_call['name'],
                           arguments: Legion::JSON.generate(function_call['args'] || {}), index: nil,
                           signature: function_call['thoughtSignature'] }
              Canonical::Chunk.build(type: :tool_call_delta, tool_call: fragment, request_id: nil,
                                     stop_reason: stop_reason)
            end
          end

          def response_parts(body)
            body.dig('candidates', 0, 'content', 'parts') || []
          end

          def text_content(parts)
            text = parts.reject { |part| part['thought'] }.filter_map { |part| part['text'] }.join
            text.empty? ? nil : text
          end

          # Gemini marks reasoning with the per-part `thought` flag; the
          # thought signature rides on the part (commonly a functionCall).
          def thinking_from_parts(parts)
            thinking_text = parts.select { |part| part['thought'] }.filter_map { |part| part['text'] }.join
            signature = parts.filter_map { |part| part['thoughtSignature'] }.first
            return nil if thinking_text.empty? && signature.nil?

            Canonical::Thinking.build(content: thinking_text, signature: signature)
          end

          def usage_from_metadata(usage_metadata)
            return nil if usage_metadata.nil?

            Canonical::Usage.build(
              input_tokens: usage_metadata['promptTokenCount'],
              output_tokens: output_tokens_from_metadata(usage_metadata),
              cache_read_tokens: usage_metadata['cachedContentTokenCount'],
              thinking_tokens: usage_metadata['thoughtsTokenCount']
            )
          end

          # Gemini reports output as candidatesTokenCount + thoughtsTokenCount
          # (thoughts are billed output); nil when the metadata reports none.
          def output_tokens_from_metadata(usage_metadata)
            total = (usage_metadata['candidatesTokenCount'] || 0) + (usage_metadata['thoughtsTokenCount'] || 0)
            total.positive? ? total : nil
          end

          def stop_reason_from_body(body)
            finish_reason = body.dig('candidates', 0, 'finishReason')
            return nil if finish_reason.nil?

            stop_reason_lookup(finish_reason)
          end

          # Sync tool calls → Array<ToolCall> (canonical; the legacy Hash-of-
          # calls shape is gone). The ONE strict arguments parser (10 U2) runs
          # on the JSON-string spelling; a wire object passes through as the
          # canonical Hash.
          def parse_tool_calls(parts)
            parts.filter_map do |part|
              function_call = part['functionCall']
              next if function_call.nil?

              Canonical::ToolCall.build(name: function_call['name'].to_s,
                                        arguments: gemini_tool_arguments(function_call['args']),
                                        metadata: { signature: function_call['thoughtSignature'] }.compact)
            end
          end

          def gemini_tool_arguments(raw)
            return {} if raw.nil?
            return raw if raw.is_a?(::Hash)

            Legion::Extensions::Llm::Responses::ToolArguments.parse!(raw)
          end
        end

        # Gemini operation parsers: provider-native model facts (Model::Info,
        # D1) and the embed operation's documented artifact (05 §3, O07 —
        # a Hash shape, not a canonical type).
        module OperationParsers
          private

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

          def modalities_for(methods)
            return [%w[text], %w[embeddings]] if methods.include?('embedContent')

            [%w[text image audio video], %w[text]]
          end

          def render_embedding_payload(text, model:, dimensions:)
            {
              model: model_path(model),
              content: { parts: [{ text: text.to_s }] },
              outputDimensionality: dimensions
            }.compact
          end

          def parse_embedding_response(response, model:, text:)
            {
              text: text,
              model: model,
              embedding: response.body.dig('embedding', 'values'),
              usage: Canonical::Usage.build(
                input_tokens: response.body.dig('usageMetadata', 'promptTokenCount')
              )
            }
          end
        end

        # Gemini provider implementation for the Legion::Extensions::Llm base provider contract.
        class Provider < Legion::Extensions::Llm::Provider
          include Legion::Logging::Helper
          include MessageKinds
          include MessageFormatter
          include ResponseParser
          include OperationParsers

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

          # StopReasonMapping mixin override: the shared vocabulary covers the
          # common spellings; these are the Gemini wire finishReason additions
          # (R4: dialect at the parser edge).
          def stop_reason_map_additions
            {
              'STOP' => :end_turn,
              'MAX_TOKENS' => :max_tokens,
              'SAFETY' => :content_filter,
              'RECITATION' => :content_filter,
              'PROHIBITED_CONTENT' => :content_filter,
              'SPII' => :content_filter,
              'IMAGE_SAFETY' => :content_filter
            }
          end
        end
      end
    end
  end
end
