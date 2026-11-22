# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Gemini::Provider do
  let(:provider) do
    config = Legion::Extensions::Llm::Configuration.new
    config.gemini_api_key = 'test-key'
    config.gemini_api_base = 'https://gemini.example/v1beta'
    config.max_retries = 0
    described_class.new(config)
  end

  after { provider.disconnect }

  def response_body
    {
      modelVersion: 'selected-model',
      candidates: [{ content: { parts: [{ text: 'OK' }] }, finishReason: 'STOP' }],
      usageMetadata: { promptTokenCount: 3, candidatesTokenCount: 1 }
    }
  end

  def serve_response(env:, stream:)
    return [200, { 'content-type' => 'application/json' }, Legion::JSON.dump(response_body)] unless stream

    env.status = 200
    env.response_headers = { 'content-type' => 'text/event-stream' }
    wire = "data: #{Legion::JSON.dump(response_body)}\n\n"
    midpoint = wire.bytesize / 2
    [wire.byteslice(0, midpoint), wire.byteslice(midpoint..)].each do |part|
      env.request.on_data.call(part, part.bytesize, env)
    end
    [200, env.response_headers, '']
  end

  schemas = {
    closed_zero_argument: { type: 'object', properties: {}, additionalProperties: false },
    open_zero_argument: { type: 'object', properties: {} },
    explicitly_open: { type: 'object', properties: {}, additionalProperties: true },
    nested_constraints: {
      type: 'object', title: 'Lookup options',
      properties: {
        filter: { type: 'object', properties: { label: { type: 'string', minLength: 1 } },
                  required: ['label'], additionalProperties: false },
        labels: { type: 'object', additionalProperties: { type: 'string' } },
        mode: { '$ref': '#/$defs/mode' }
      },
      required: ['filter'], additionalProperties: false,
      '$defs': { mode: { type: 'string', enum: %w[summary detailed] } }
    }
  }.freeze

  streaming_modes = [false, true].freeze
  schemas.each do |label, schema|
    streaming_modes.each do |stream|
      it "preserves #{label} through native HTTP serialization, stream=#{stream}" do
        tool = Legion::Extensions::Llm::Canonical::ToolDefinition.build(
          name: 'lookup', description: 'Look up the requested information.', parameters: schema
        )
        before = Legion::JSON.dump(tool.to_h)
        payloads = []
        operation = stream ? 'streamGenerateContent?alt=sse' : 'generateContent'
        endpoint = "/v1beta/models/selected-model:#{operation}"
        stubs = Faraday::Adapter::Test::Stubs.new do |stub|
          stub.post(endpoint) do |env|
            expect(env.request_headers['Content-Type']).to eq('application/json')
            payloads << Legion::JSON.load(env.body)
            serve_response(env: env, stream: stream)
          end
        end
        provider.connection.connection.builder.adapter :test, stubs
        messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Continue.')]
        tools = { lookup: tool }
        chunks = []
        response = if stream
                     provider.stream_chat(messages, model: 'selected-model', tools: tools) { |chunk| chunks << chunk }
                   else
                     provider.chat(messages, model: 'selected-model', tools: tools)
                   end

        expect(payloads.size).to eq(1)
        declarations = payloads.first.fetch(:tools).first.fetch(:functionDeclarations)
        expect(declarations).to eq([
                                     { name: tool.name, description: tool.description,
                                       parametersJsonSchema: Legion::JSON.load(Legion::JSON.dump(schema)) }
                                   ])
        expect(declarations.first).not_to have_key(:parameters)
        expect(Legion::JSON.dump(tool.to_h)).to eq(before)
        expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
        expect(response.text).to eq('OK')
        expect(chunks).to all(be_a(Legion::Extensions::Llm::Canonical::Chunk))
        expect(chunks.count { |chunk| chunk.type == :done }).to eq(stream ? 1 : 0)
        stubs.verify_stubbed_calls
      end
    end
  end
end
