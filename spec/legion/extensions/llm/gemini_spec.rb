# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Gemini do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:flash_model) { Legion::Extensions::Llm::Model::Info.new(id: 'gemini-2.0-flash', provider: :gemini) }

  before do
    Legion::Extensions::Llm.config.gemini_api_key = 'test-key'
  end

  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:gemini)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('https://generativelanguage.googleapis.com/v1beta')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end

  it 'registers the Legion::Extensions::Llm provider class' do
    expect(Legion::Extensions::Llm::Provider.resolve(:gemini)).to eq(described_class::Provider)
  end

  it 'exposes Gemini API base and model listing helpers' do
    expect(provider.api_base).to eq('https://generativelanguage.googleapis.com/v1beta')
    expect(provider.models_url).to eq('models')
  end

  it 'exposes Gemini content endpoint helpers' do
    expect(provider.generate_content_url(model: 'gemini-2.0-flash')).to eq(generation_url)
    expect(provider.stream_generate_content_url(model: 'gemini-2.0-flash'))
      .to eq('models/gemini-2.0-flash:streamGenerateContent?alt=sse')
    expect(provider.embed_content_url(model: 'gemini-embedding-001')).to eq('models/gemini-embedding-001:embedContent')
  end

  it 'renders chat payloads in the Gemini generateContent format' do
    payload = chat_payload

    expect(payload[:generationConfig]).to eq({ temperature: 0.2 })
    expect(payload[:systemInstruction]).to eq({ parts: [{ text: 'Be terse.' }] })
    expect(payload[:contents]).to eq([{ role: 'user', parts: [{ text: 'hello' }] }])
  end

  it 'parses Gemini completion responses' do
    expect(completion_message.to_h).to include(role: :assistant, content: 'hi', model_id: 'gemini-2.0-flash')
    expect([completion_message.input_tokens, completion_message.output_tokens]).to eq([3, 4])
  end

  it 'parses Gemini model listings' do
    expect(models.first.to_h).to include(id: 'gemini-2.0-flash', provider: :gemini)
    expect(models.first.capabilities).to include('streaming', 'function_calling', 'vision')
    expect(models.last.capabilities).to eq(['embeddings'])
    expect(models.last.modalities.to_h).to eq(input: ['text'], output: ['embeddings'])
  end

  it 'parses Gemini embedding responses' do
    expect([embedding.vectors, embedding.input_tokens]).to eq([[0.1, 0.2], 2])
  end

  def chat_payload
    messages = [
      Legion::Extensions::Llm::Message.new(role: :system, content: 'Be terse.'),
      Legion::Extensions::Llm::Message.new(role: :user, content: 'hello')
    ]

    provider.send(:render_payload, messages, tools: {}, temperature: 0.2, model: flash_model, stream: false,
                                             schema: nil, thinking: nil, tool_prefs: nil)
  end

  def fake_response(body)
    Struct.new(:body).new(body)
  end

  def generation_url
    'models/gemini-2.0-flash:generateContent'
  end

  def completion_message
    provider.send(:parse_completion_response, fake_response(completion_response_body))
  end

  def completion_response_body
    {
      'modelVersion' => 'gemini-2.0-flash',
      'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hi' }] } }],
      'usageMetadata' => { 'promptTokenCount' => 3, 'candidatesTokenCount' => 4 }
    }
  end

  def models
    provider.send(:parse_list_models_response, fake_response(models_response_body), :gemini,
                  described_class::Provider::Capabilities)
  end

  def models_response_body
    {
      'models' => [{
        'name' => 'models/gemini-2.0-flash',
        'displayName' => 'Gemini 2.0 Flash',
        'inputTokenLimit' => 1_048_576,
        'outputTokenLimit' => 8192,
        'supportedGenerationMethods' => %w[generateContent streamGenerateContent]
      }, {
        'name' => 'models/gemini-embedding-001',
        'displayName' => 'Gemini Embedding',
        'inputTokenLimit' => 2048,
        'outputTokenLimit' => 1,
        'supportedGenerationMethods' => %w[embedContent]
      }]
    }
  end

  def embedding
    provider.send(:parse_embedding_response, fake_response(embedding_response_body), model: 'gemini-embedding-001')
  end

  def embedding_response_body
    {
      'embedding' => { 'values' => [0.1, 0.2] },
      'usageMetadata' => { 'promptTokenCount' => 2 }
    }
  end
end
