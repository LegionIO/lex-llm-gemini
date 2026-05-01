# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Gemini do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:flash_model) { Legion::Extensions::Llm::Model::Info.new(id: 'gemini-2.0-flash', provider: :gemini) }
  let(:registry_publisher) { instance_double(Legion::Extensions::Llm::RegistryPublisher) }

  before do
    Legion::Extensions::Llm.config.gemini_api_key = 'test-key'
  end

  it 'exposes provider defaults with the new flat settings shape' do
    settings = described_class.default_settings

    expect(settings[:enabled]).to be false
    expect(settings[:default_model]).to eq('gemini-2.0-flash')
    expect(settings[:api_key]).to be_nil
    expect(settings[:model_whitelist]).to eq([])
    expect(settings[:model_blacklist]).to eq([])
    expect(settings[:model_cache_ttl]).to eq(3600)
    expect(settings[:tls]).to eq(enabled: false, verify: :peer)
    expect(settings[:instances]).to eq({})
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
    expect(models.first.capabilities).to include(:streaming, :function_calling, :vision)
    expect(models.last.capabilities).to eq([:embeddings])
    expect(models.last.modalities.to_h).to eq(input: ['text'], output: ['embeddings'])
  end

  it 'publishes discovered models asynchronously through the base registry publisher' do
    stub_registry_publisher
    stub_model_discovery

    models = provider.list_models

    expect_registry_publish(models)
  end

  it 'builds sanitized lex-llm registry events for Gemini model availability' do
    events = capture_registry_events([flash_model], readiness: { ready: true })

    expect(events.first.to_h).to include(event_type: :offering_available)
    expect(events.first.to_h.dig(:offering, :provider_family)).to eq(:gemini)
    expect(events.first.to_h.dig(:offering, :model)).to eq('gemini-2.0-flash')
  end

  it 'parses Gemini embedding responses' do
    expect([embedding.vectors, embedding.input_tokens]).to eq([[0.1, 0.2], 2])
  end

  it 'uses the base RegistryPublisher parameterized with :gemini' do
    publisher = described_class::Provider.registry_publisher
    expect(publisher).to be_a(Legion::Extensions::Llm::RegistryPublisher)
    expect(publisher.provider_family).to eq(:gemini)
  end

  describe '.discover_instances' do
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:env).and_call_original
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:env).with('GEMINI_API_KEY').and_return(nil)
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).and_return(nil)
    end

    it 'returns an empty hash when no credentials are available' do
      expect(described_class.discover_instances).to eq({})
    end

    it 'discovers an :env instance from the GEMINI_API_KEY environment variable' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:env).with('GEMINI_API_KEY').and_return('gk-123')

      instances = described_class.discover_instances

      expect(instances[:env]).to include(gemini_api_key: 'gk-123', tier: :cloud)
    end

    it 'discovers a :settings instance from extension settings' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ api_key: 'gk-settings' })

      instances = described_class.discover_instances

      expect(instances[:settings]).to include(gemini_api_key: 'gk-settings', tier: :cloud)
    end

    it 'discovers named instances from the settings instances sub-key' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ instances: { staging: { gemini_api_key: 'gk-staging' } } })

      instances = described_class.discover_instances

      expect(instances[:staging]).to include(gemini_api_key: 'gk-staging', tier: :cloud)
    end

    it 'deduplicates credentials when env and settings share the same key' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:env).with('GEMINI_API_KEY').and_return('gk-same')
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ api_key: 'gk-same' })

      instances = described_class.discover_instances

      expect(instances.keys).to eq([:env])
    end

    it 'keeps both instances when credentials differ' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:env).with('GEMINI_API_KEY').and_return('gk-env')
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ api_key: 'gk-settings' })

      instances = described_class.discover_instances

      expect(instances.keys).to contain_exactly(:env, :settings)
    end
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

  def stub_registry_publisher
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)
  end

  def stub_model_discovery
    allow(provider.connection).to receive(:get).with('models').and_return(fake_response(models_response_body))
  end

  def expect_registry_publish(models)
    expect(registry_publisher).to have_received(:publish_models_async)
      .with(models, readiness: hash_including(provider: :gemini, live: false))
  end

  def capture_registry_events(models, readiness:)
    publisher = Legion::Extensions::Llm::RegistryPublisher.new(provider_family: :gemini)
    events = []
    allow(publisher).to receive(:publishing_available?).and_return(true)
    allow(publisher).to receive(:publish_event) { |event| events << event }
    allow(Thread).to receive(:new).and_yield
    publisher.publish_models_async(models, readiness:)
    events
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
