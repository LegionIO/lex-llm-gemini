# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Gemini do
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }

  before do
    Legion::Extensions::Llm.config.gemini_api_key = 'test-key'
  end

  it 'exposes provider defaults through the shared provider settings shape' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings[:enabled]).to be true
    expect(settings[:provider_family]).to eq(:gemini)
    expect(instance[:endpoint]).to eq('https://generativelanguage.googleapis.com/v1beta')
    expect(instance).not_to have_key(:default_model)
    expect(instance.dig(:credentials, :api_key)).to eq('env://GEMINI_API_KEY')
    expect(instance.dig(:fleet, :respond_to_requests)).to be false
    expect(instance.dig(:usage, :embedding)).to be true
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

  it 'builds Gemini content endpoints from model ids' do
    expect(provider.generate_content_url(model: 'gemini-2.0-flash')).to eq(generation_url)
  end

  it 'renders chat payloads in the Gemini generateContent format' do
    payload = chat_payload

    expect(payload[:generationConfig]).to eq({ temperature: 0.2 })
    expect(payload[:systemInstruction]).to eq({ parts: [{ text: 'Be terse.' }] })
    expect(payload[:contents]).to eq([{ role: 'user', parts: [{ text: 'hello' }] }])
  end

  it 'renders canonical messages to the identical Gemini wire payload (wire format unchanged)' do
    messages = [
      Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'Be terse.'),
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    ]

    payload = provider.send(:render_payload, messages, tools: {}, params: params_with_temperature,
                                                       model: 'gemini-2.0-flash', stream: false, schema: nil,
                                                       thinking: nil, tool_prefs: nil)

    expect(payload).to eq(chat_payload)
  end

  it 'carries the folded system message through the actual callable into systemInstruction' do
    captured_payload = nil
    connection = instance_double(Legion::Extensions::Llm::Connection)
    provider.instance_variable_set(:@connection, connection)
    allow(connection).to receive(:post) do |_url, payload, &_block|
      captured_payload = payload
      fake_response(completion_response_body)
    end
    callable = described_class::Helpers::Callable.new(
      instance_cfg: { gemini_api_key: 'test-key' }, logger: instance_double(Logger).as_null_object,
      provider: provider
    )
    messages = [
      Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'Follow the exact system law.'),
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    ]

    callable.chat(messages, model: 'gemini-2.0-flash')

    expect(captured_payload[:systemInstruction]).to eq(
      parts: [{ text: 'Follow the exact system law.' }]
    )
    expect(captured_payload[:contents]).to eq([{ role: 'user', parts: [{ text: 'hello' }] }])
  end

  it 'parses Gemini completion responses to a Canonical::Response (asserted by type)' do
    response = completion_message
    expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(response.text).to eq('hi')
    expect(response.model).to eq('gemini-2.0-flash')
    expect(response.usage).to be_a(Legion::Extensions::Llm::Canonical::Usage)
    expect(response.usage.input_tokens).to eq(3)
    expect(response.usage.output_tokens).to eq(4)
    expect(response.stop_reason).to be_nil
  end

  it 'maps Gemini finishReason STOP to the canonical :end_turn stop reason' do
    candidates = [{ 'content' => { 'parts' => [{ 'text' => 'hi' }] }, 'finishReason' => 'STOP' }]
    body = completion_response_body.merge('candidates' => candidates)

    response = provider.send(:parse_completion_response, fake_response(body))

    expect(response.stop_reason).to eq(:end_turn)
  end

  it 'parses Gemini tool call responses to canonical ToolCall objects' do
    body = {
      'modelVersion' => 'gemini-2.0-flash',
      'candidates' => [{
        'content' => { 'parts' => [{ 'functionCall' => { 'name' => 'get_weather', 'args' => { 'city' => 'SF' } } }] },
        'finishReason' => 'STOP'
      }]
    }

    response = provider.send(:parse_completion_response, fake_response(body))

    expect(response.tool_calls.size).to eq(1)
    tool_call = response.tool_calls.first
    expect(tool_call).to be_a(Legion::Extensions::Llm::Canonical::ToolCall)
    expect(tool_call.name).to eq('get_weather')
    expect(tool_call.arguments).to eq('city' => 'SF')
    expect(response.stop_reason).to eq(:end_turn)
  end

  it 'parses Gemini thought parts into a canonical Thinking member' do
    body = {
      'modelVersion' => 'gemini-2.0-flash',
      'candidates' => [{
        'content' => { 'parts' => [
          { 'text' => 'pondering', 'thought' => true },
          { 'text' => 'the answer' }
        ] },
        'finishReason' => 'STOP'
      }],
      'usageMetadata' => { 'promptTokenCount' => 3, 'candidatesTokenCount' => 4, 'thoughtsTokenCount' => 9 }
    }

    response = provider.send(:parse_completion_response, fake_response(body))

    expect(response.thinking).to be_a(Legion::Extensions::Llm::Canonical::Thinking)
    expect(response.thinking.content).to eq('pondering')
    expect(response.text).to eq('the answer')
    expect(response.usage.thinking_tokens).to eq(9)
    expect(response.usage.output_tokens).to eq(13)
  end

  it 'builds Canonical::Chunk objects from streaming SSE bodies (asserted by type)' do
    chunk = provider.send(:build_chunk, stream_chunk_body)

    expect(chunk).to be_a(Legion::Extensions::Llm::Canonical::Chunk)
    expect(chunk.type).to eq(:text_delta)
    expect(chunk.delta).to eq('Hel')
  end

  it 'streams a full SSE exchange through the canonical chunk pipeline ending in one done chunk' do
    events = [
      { 'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'Hel' }] } }] },
      { 'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'lo' }] } }] },
      {
        'candidates' => [{ 'content' => { 'parts' => [{ 'text' => '' }] }, 'finishReason' => 'STOP' }],
        'usageMetadata' => { 'promptTokenCount' => 3, 'candidatesTokenCount' => 2 }
      }
    ].map { |body| "data: #{Legion::JSON.dump(body)}\n\n" }

    chunks, response = capture_stream(provider, events)

    expect(chunks.size).to be > 0
    expect(chunks).to all(be_a(Legion::Extensions::Llm::Canonical::Chunk))
    expect(chunks.count(&:done?)).to eq(1)
    expect(chunks.last).to be_done
    text_deltas = chunks.select(&:text_delta?)
    expect(text_deltas.map(&:delta).join).to eq('Hello')
    expect(chunks.last.stop_reason).to eq(:end_turn)
    expect(chunks.last.usage.output_tokens).to eq(2)
    expect(response).to be_a(Legion::Extensions::Llm::Canonical::Response)
    expect(response.text).to eq('Hello')
  end

  it 'does not expose a registry_publisher class method on Provider (§2 single engine)' do
    expect(described_class::Provider).not_to respond_to(:registry_publisher)
  end

  it 'parses Gemini embedding responses to the documented artifact shape' do
    expect(embedding[:embedding]).to eq([0.1, 0.2])
    expect(embedding[:text]).to eq('hello')
    expect(embedding[:model]).to eq('gemini-embedding-001')
    expect(embedding[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
    expect(embedding[:usage].input_tokens).to eq(2)
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

    it 'preserves an explicit tier from extension settings' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ api_key: 'gk-settings', tier: :private })

      instances = described_class.discover_instances

      expect(instances[:settings]).to include(gemini_api_key: 'gk-settings', tier: :private)
    end

    it 'normalizes generic settings keys to provider config keys' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ api_key: 'gk-settings', endpoint: 'https://gemini.example/v1beta' })

      instances = described_class.discover_instances

      expect(instances[:settings]).to include(gemini_api_key: 'gk-settings',
                                              gemini_api_base: 'https://gemini.example/v1beta',
                                              tier: :cloud)
      expect(instances[:settings]).not_to have_key(:endpoint)
      expect(instances[:settings]).not_to have_key(:api_key)
    end

    it 'discovers named instances from the settings instances sub-key' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ instances: { staging: { api_key: 'gk-staging', base_url: 'https://staging.example' } } })

      instances = described_class.discover_instances

      expect(instances[:staging]).to include(gemini_api_key: 'gk-staging',
                                             gemini_api_base: 'https://staging.example',
                                             tier: :cloud)
      expect(instances[:staging]).not_to have_key(:api_key)
    end

    it 'preserves an explicit tier for named instances' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ instances: { staging: { api_key: 'gk-staging', tier: :private } } })

      instances = described_class.discover_instances

      expect(instances[:staging]).to include(gemini_api_key: 'gk-staging', tier: :private)
    end

    it 'excludes a disabled instance with a valid credential from claimable instances' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({ instances: { staging: { api_key: 'gk-staging', enabled: false } } })

      instances = described_class.discover_instances

      expect(instances).not_to have_key(:staging)
      expect(instances).to eq({})
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

  def params_with_temperature
    Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.2)
  end

  def chat_payload
    messages = [
      Legion::Extensions::Llm::Canonical::Message.build(role: :system, content: 'Be terse.'),
      Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')
    ]

    provider.send(:render_payload, messages, tools: {}, params: params_with_temperature, model: 'gemini-2.0-flash',
                                             stream: false, schema: nil, thinking: nil, tool_prefs: nil)
  end

  def stream_chunk_body
    { 'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'Hel' }] } }] }
  end

  # Drives the real streaming funnel (Streaming#stream_response) with a stubbed
  # transport: the connection post yields a request whose on_data callback is
  # fed the given SSE frames. Returns the chunks yielded to the block plus the
  # accumulated Canonical::Response.
  def capture_stream(target_provider, sse_events)
    stub_stream_connection(target_provider, sse_events)

    chunks = []
    messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')]
    response = target_provider.stream_chat(messages, model: 'gemini-2.0-flash') { |chunk| chunks << chunk }
    [chunks, response]
  end

  def stub_stream_connection(target_provider, sse_events)
    connection = instance_double(Legion::Extensions::Llm::Connection)
    fake_request = Struct.new(:options).new(FakeStreamOptions.new)
    allow(connection).to receive(:post) do |_url, _payload, &block|
      block&.call(fake_request)
      env = Struct.new(:status).new(200)
      sse_events.each { |event| fake_request.options.on_data.call(event, 0, env) }
      fake_response({})
    end
    target_provider.instance_variable_set(:@connection, connection)
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

  def embedding
    response = fake_response(embedding_response_body)
    provider.send(:parse_embedding_response, response, model: 'gemini-embedding-001', text: 'hello')
  end

  def embedding_response_body
    {
      'embedding' => { 'values' => [0.1, 0.2] },
      'usageMetadata' => { 'promptTokenCount' => 2 }
    }
  end
end
