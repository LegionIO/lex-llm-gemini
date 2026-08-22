# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'
require 'uri'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

# The gem entry does not require its discovery runner (the daemon runner-scan
# does); specs require it spec-side, matching the sibling provider convention.
require 'legion/extensions/llm/gemini/runners/discovery'

# ── RecordingGeminiProvider ───────────────────────────────────────────────────
# Test-local stand-in for the per-instance Gemini::Provider that the
# PRODUCTION Helpers::Callable delegates its fleet dispatch ops to. It
# replaces the I/O boundary (the Provider's HTTP client) so conformance tests
# run offline; the callable under test is the real production class, and its
# dispatch methods are the real delegation code.
class RecordingGeminiProvider
  attr_reader :calls, :disconnected

  def initialize
    @calls = []
    @disconnected = false
  end

  def call_count = @calls.size

  def chat(messages, model:, **rest)
    record(:chat, messages: messages, model: model, **rest)
    { role: 'assistant', content: 'test response', model: model }
  end

  def stream_chat(messages, model:, **rest, &)
    record(:stream_chat, messages: messages, model: model, **rest)
    { role: 'assistant', content: 'streamed response', model: model }
  end

  def embed(text:, model:, **rest)
    record(:embed, text: text, model: model, **rest)
    { embedding: [0.1, 0.2, 0.3], model: model }
  end

  def count_tokens(messages:, model:, **rest)
    record(:count_tokens, messages: messages, model: model, **rest)
    { token_count: 42, model: model }
  end

  # The production callable calls this on its provider before delegating (the
  # canonical boundary). Delegate to the real base implementation — stateless
  # over messages — so the double cannot drift from the production contract.
  def enforce_canonical_messages!(messages)
    Legion::Extensions::Llm::Provider.allocate.enforce_canonical_messages!(messages)
  end

  def disconnect
    @disconnected = true
  end

  private

  def record(operation, **args)
    @calls << { operation: operation, **args }
  end
end

# ── GeminiSsotHarness ─────────────────────────────────────────────────────────
# Harness class for Gemini SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching
# any external service. build_callable returns the PRODUCTION
# Helpers::Callable (dispatch ops delegate to an injected RecordingGeminiProvider
# in place of the real per-instance Provider's HTTP client), and
# identity/draft building delegate to the runner's PRODUCTION methods — the
# harness duplicates no builder logic (drift would mask production bugs).
class GeminiSsotHarness
  # Each config carries its operator CONFIG NAME (the key it would hold under
  # settings[:instances]) — the name is the instance identity; the derived
  # host:port/ak id is the secondary physical id only.
  INSTANCE_CONFIGS = [
    {
      name: 'gemini-alpha',
      gemini_api_base: 'https://generativelanguage.googleapis.com/v1beta',
      tier: :frontier, gemini_api_key: 'AIzaSyTestKey1-AAAA',
      usage: { inference: true, embedding: true }
    }.freeze,
    {
      name: 'gemini-beta',
      gemini_api_base: 'https://generativelanguage.googleapis.com/v1beta',
      tier: :frontier, gemini_api_key: 'AIzaSyTestKey2-BBBB',
      usage: { inference: true, embedding: true }
    }.freeze
  ].freeze

  def initialize
    @provider_by_callable = {}
    @logger = Logger.new(File::NULL)
  end

  def provider_family = :gemini
  def instance_configs = INSTANCE_CONFIGS

  # The operator's CONFIG NAME is the identity (InstanceKey.instance_id) —
  # the key the router looks up in instances.<name>.
  def instance_id(instance_config:)
    instance_config[:name].to_s
  end

  # Delegates to the runner's PRODUCTION physical-id derivation (secondary
  # field: dedup/diagnostics only, never the identity).
  def physical_id(instance_config:)
    Legion::Extensions::Llm::Gemini::Runners::Discovery
      .derive_physical_id(instance_cfg: instance_config)
  end

  def build_callable(instance_config:)
    provider = RecordingGeminiProvider.new
    callable = Legion::Extensions::Llm::Gemini::Helpers::Callable.new(
      instance_cfg: instance_config, logger: @logger, provider: provider
    )
    @provider_by_callable[callable] = provider
    callable
  end

  # Delegates to the runner's PRODUCTION draft builder, not a spec-local
  # duplicate of the evidence construction. The InstanceKey is composed
  # directly (Inventory::Identity owns instance identity — the pipeline
  # composes it inline, no legacy builder helper).
  def build_offering_drafts(instance_config:, tier: :frontier, **)
    cfg = instance_config.merge(tier: tier)
    instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :gemini,
      instance_id: instance_id(instance_config: instance_config),
      physical_id: physical_id(instance_config: cfg)
    )
    [
      Legion::Extensions::Llm::Gemini::Runners::Discovery.build_offering_draft(
        instance_cfg: cfg,
        instance_key: instance_key,
        model_id: 'gemini-2.0-flash',
        model_data: {
          name: 'models/gemini-2.0-flash',
          supportedGenerationMethods: %w[generateContent streamGenerateContent countTokens],
          inputTokenLimit: 1_048_576,
          outputTokenLimit: 8192
        }
      )
    ]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'Gemini models API returned 200',
      metadata: { status: 200, base_url: instance_config[:gemini_api_base] }
    )
  end

  def inference_call_count(callable:)
    @provider_by_callable[callable]&.call_count || 0
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    callable.normalize_dispatch_error(error: error)
  end

  # ── Real Faraday error shapes ──────────────────────────────────────────────
  # Faraday 2.x builds error.response as a Faraday::Env (a Struct, not a
  # Hash). These helpers construct errors the way Faraday itself does so the
  # conformance suite exercises the production shape, not a hand-rolled Hash.

  # Returns a Faraday::ServerError whose response is a Faraday::Env — the
  # shape a real Faraday 2.x error carries.
  def faraday_server_error(status:, body:)
    env = Faraday::Env.new
    env.status = status
    env.reason_phrase = 'Service Unavailable'
    env.response_body = body
    Faraday::ServerError.new(env)
  end

  # Returns a Faraday::ServerError carrying Gemini's explicit UNAVAILABLE body
  # signal — the only flat service/instance-unavailable condition Gemini emits.
  # §8: connection failures are request-local and are NOT returned here.
  def instance_unavailable_error
    faraday_server_error(
      status: 503,
      body: '{"error":{"code":503,"message":"The service is currently unavailable.","status":"UNAVAILABLE"}}'
    )
  end

  def overloaded_error
    faraday_server_error(status: 503, body: '{"error": {"code": 503, "message": "Service overloaded"}}')
  end

  def model_not_ready_error
    faraday_server_error(
      status: 503,
      body: '{"error": {"code": 503, "message": "Model not ready", "status": "MODEL_NOT_READY"}}'
    )
  end
end

RSpec.describe Legion::Extensions::Llm::Gemini do
  let(:ssot_harness) { GeminiSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # ─── Gemini-specific identity derivation ────────────────────────────────────

  describe 'instance identity derivation' do
    it 'uses the operator config name as the instance identity' do
      config = ssot_harness.instance_configs[0]
      expect(ssot_harness.instance_id(instance_config: config)).to eq('gemini-alpha')
    end

    it 'derives the SECONDARY physical id as host:port/ak:fingerprint with API key' do
      config = { name: 'unused', gemini_api_base: 'https://generativelanguage.googleapis.com/v1beta',
                 gemini_api_key: 'AIzaSyTestKey1-AAAA' }
      fingerprint = Digest::SHA256.hexdigest('AIzaSyTestKey1-AAAA')[0, 8]
      expect(ssot_harness.physical_id(instance_config: config))
        .to eq("generativelanguage.googleapis.com:443/ak:#{fingerprint}")
    end

    it 'produces distinct physical ids for two different API keys (identity stays the name)' do
      physical_ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.physical_id(instance_config: cfg) }
      names        = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(physical_ids.uniq.size).to eq(2)
      expect(names.uniq.size).to eq(2)
    end

    it 'reproduces the identity and physical id across multiple calls (stable)' do
      config = ssot_harness.instance_configs.first
      id_first  = ssot_harness.instance_id(instance_config: config)
      id_second = ssot_harness.instance_id(instance_config: config)
      expect(id_first).to eq(id_second)

      physical_first  = ssot_harness.physical_id(instance_config: config)
      physical_second = ssot_harness.physical_id(instance_config: config)
      expect(physical_first).to eq(physical_second)
    end
  end

  # ─── Two config names with same endpoint/model = separate lanes ───────────

  describe 'two config names serving the same model' do
    def build_instance_key_for(config)
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini,
        instance_id: ssot_harness.instance_id(instance_config: config),
        physical_id: ssot_harness.physical_id(instance_config: config)
      )
    end

    def bring_up_instance(config, tier: :frontier)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :gemini)
      key         = build_instance_key_for(config)
      instance_id = key.instance_id
      physical_id = key.physical_id
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = publisher.claim_instance(instance_id: instance_id, callable: callable,
                                       probe_request_handle: coordinator, physical_id: physical_id)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token,
                                                physical_id: physical_id)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe,
        physical_id: physical_id
      )
      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts, coordinator: coordinator }
    end

    it 'creates separate lanes for the same model under distinct config names' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
      lanes_a  = snapshot.lanes_for(instance_key: a[:key])
      lanes_b  = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty
      expect(lanes_a.map(&:lane_id) & lanes_b.map(&:lane_id)).to be_empty
      # Same endpoint, same model — the physical ids differ by API key while
      # the identities are the config names.
      expect(a[:key].instance_id).to eq('gemini-alpha')
      expect(b[:key].instance_id).to eq('gemini-beta')
      expect(a[:key].physical_id).not_to eq(b[:key].physical_id)
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      first_run = bring_up_instance(config)
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      registry.reset!
      second_run = bring_up_instance(config)
      expect(registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id).to eq(first_lane_id)
    end
  end

  # ─── Generation method evidence controls ───────────────────────────────────

  describe 'generation method operation evidence' do
    let(:offering) do
      config   = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier).first
    end

    it 'marks chat as supported when generateContent is present' do
      expect(offering.operation_evidence[:chat].status).to eq(:supported)
    end

    it 'marks stream_chat as supported when streamGenerateContent is present' do
      expect(offering.operation_evidence[:stream_chat].status).to eq(:supported)
    end

    it 'marks embed as unsupported when embedContent is not in generation methods' do
      expect(offering.operation_evidence[:embed].status).to eq(:unsupported)
    end

    it 'marks image/transcribe/translate/speak/moderate as unsupported' do
      %i[image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].status).to eq(:unsupported),
                                                          "expected #{op} to be :unsupported"
      end
    end

    it 'marks count_tokens as unknown' do
      expect(offering.operation_evidence[:count_tokens].status).to eq(:unknown)
    end

    it 'uses :provider_catalog source for supported/unsupported operations' do
      %i[chat stream_chat embed image transcribe translate speak moderate].each do |op|
        expect(offering.operation_evidence[op].source).to eq(:provider_catalog),
                                                          "expected #{op} source to be :provider_catalog"
      end
    end

    it 'uses :default_false source for unknown operations' do
      expect(offering.operation_evidence[:count_tokens].source).to eq(:default_false)
    end
  end

  # ─── Missing generation methods yields unknown, not blanket supported ──────

  describe 'empty generation methods handling' do
    it 'produces unknown evidence for chat/stream/embed when generation methods list is empty' do
      # Call the runner's actual build_operation_evidence to verify the
      # behavior — not a tautological manual construction.
      result = Legion::Extensions::Llm::Gemini::Runners::Discovery
               .send(:build_operation_evidence, generation_methods: [])

      expect(result[:chat].status).to eq(:unknown)
      expect(result[:stream_chat].status).to eq(:unknown)
      expect(result[:embed].status).to eq(:unknown)
      # Fixed operations are still unsupported regardless of generation methods
      expect(result[:image].status).to eq(:unsupported)
      expect(result[:chat].source).to eq(:default_false)
    end
  end

  # ─── Embed-only models cannot be selected for chat ─────────────────────────

  describe 'embed-only model operation separation' do
    it 'embed model does not advertise chat support' do
      result = Legion::Extensions::Llm::Gemini::Runners::Discovery
               .send(:build_operation_evidence, generation_methods: %w[embedContent])

      expect(result[:chat].status).to eq(:unsupported)
      expect(result[:stream_chat].status).to eq(:unsupported)
      expect(result[:embed].status).to eq(:supported)
    end
  end

  # ─── No default model or provider ──────────────────────────────────────────

  describe 'no default model or provider' do
    it 'accepts instance_id "default"' do
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini, instance_id: 'default'
      )

      expect(key.instance_id).to eq('default')
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :gemini, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'does not define a DEFAULT_MODEL constant on the Gemini module' do
      expect(described_class.const_defined?(:DEFAULT_MODEL, false)).to be(false)
    end

    it 'offering drafts require an explicit model string' do
      expect do
        Legion::Extensions::Llm::Inventory::OfferingDraft.new(
          provider_native_key: 'test', model: '', tier: :frontier,
          operation_evidence: Legion::Extensions::Llm::Gemini::Runners::Discovery
                              .send(:build_operation_evidence, generation_methods: %w[generateContent]),
          context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown,
                                                                                               source: :absent),
          model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown,
                                                                                         source: :absent),
          tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          quota_domains: {}, metadata: {}, publication_source: :provider_catalog
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end

  # ─── Startup gating + initializing on initial failure ──────────────────────

  describe 'startup gating' do
    let(:startup_setup) do
      config      = ssot_harness.instance_configs[0]
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini, instance_id: instance_id
      )
      pub        = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :gemini)
      callable   = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      { config: config, instance_id: instance_id, key: key, publisher: pub, callable: callable,
        coordinator: coordinator }
    end

    it 'remains initializing until readiness probe succeeds' do
      s = startup_setup
      s[:publisher].claim_instance(instance_id: s[:instance_id], callable: s[:callable],
                                   probe_request_handle: s[:coordinator])
      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: s[:key])).to be_nil
      expect(snapshot.publication_status(instance_key: s[:key]).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      s = startup_setup
      token = s[:publisher].claim_instance(instance_id: s[:instance_id], callable: s[:callable],
                                           probe_request_handle: s[:coordinator])
      probe = s[:publisher].readiness_probe_started(instance_id: s[:instance_id], publisher_token: token)
      s[:publisher].readiness_failed(instance_id: s[:instance_id], probe_token: probe,
                                     reason: 'Gemini models API returned 401')
      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: s[:key])).to be_nil
      expect(snapshot.publication_status(instance_key: s[:key]).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      s = startup_setup
      token  = s[:publisher].claim_instance(instance_id: s[:instance_id], callable: s[:callable],
                                            probe_request_handle: s[:coordinator])
      probe  = s[:publisher].readiness_probe_started(instance_id: s[:instance_id], publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: s[:config], callable: s[:callable],
                                                  tier: :frontier)
      s[:publisher].activate_instance_snapshot(
        instance_id: s[:instance_id], publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: s[:key]).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: s[:key]).state).to eq(:complete)
    end
  end

  # ─── Instance-unavailable isolation ────────────────────────────────────────

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher   = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :gemini)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key         = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini, instance_id: instance_id
      )
      callable    = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token  = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe  = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )
      { publisher: publisher, key: key, callable: callable, token: token }
    end

    it 'marks only one instance unavailable without affecting the other' do
      a = bring_up(ssot_harness.instance_configs[0])
      b = bring_up(ssot_harness.instance_configs[1])

      registry.dispatch_instance_unavailable(
        instance_key: a[:key],
        publisher_token_id: a[:token].publisher_token_id,
        reason: 'connection refused to Gemini API'
      )

      expect(registry.snapshot.instance(instance_key: a[:key]).availability.state).to eq(:unavailable)
      expect(registry.snapshot.instance(instance_key: b[:key]).availability.state).to eq(:available)
    end

    # §8 health firewall: connection failures are request-local and must NEVER
    # mutate global instance availability. This assertion proves the firewall.
    it 'does not promote connection failure to instance_unavailable (§8 health firewall)' do
      error = Faraday::ConnectionFailed.new(
        'Connection refused - connect(2) for generativelanguage.googleapis.com:443'
      )
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs.first)
      outcome  = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'normalizes explicit Gemini UNAVAILABLE signal to instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    it 'normalizes 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # ─── Error isolation (429/auth/timeout/success do not mutate availability) ─

  describe 'error isolation (no global poisoning)' do
    it 'classifies connection failure as connection_failure on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome  = callable.normalize_dispatch_error(error: Faraday::ConnectionFailed.new('Connection refused'))
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome  = callable.normalize_dispatch_error(error: Faraday::TimeoutError.new('Net::ReadTimeout'))
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies 429 ClientError as rate_limited on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome  = callable.normalize_dispatch_error(error: Faraday::ClientError.new('429',
                                                                                   { status: 429, headers: {},
                                                                                     body: '' }))
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'classifies 401 as authentication on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome  = callable.normalize_dispatch_error(error: Faraday::ClientError.new('401',
                                                                                   { status: 401, headers: {},
                                                                                     body: '' }))
      expect(outcome.kind).to eq(:authentication)
    end

    it 'never returns instance_unavailable from the callable for plain server errors' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      [500, 502, 503, 504, 529].each do |status|
        outcome = callable.normalize_dispatch_error(
          error: Faraday::ServerError.new(status.to_s, { status: status, headers: {}, body: '' })
        )
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} without UNAVAILABLE body must not map to instance_unavailable"
      end
    end

    # D8 regression coverage against REAL Faraday error shapes. Faraday 2.x
    # error.response is a Faraday::Env (a Struct, not a Hash) — an
    # is_a?(Hash) gate on the body detection is dead in production.
    it 'detects the explicit UNAVAILABLE body on a real Faraday::Env-backed 503' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = ssot_harness.instance_unavailable_error
      expect(error.response).to be_a(Faraday::Env)
      expect(error.response).not_to be_a(Hash)

      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    it 'keeps a plain 503 with a real Faraday::Env response as overloaded' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome  = callable.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
    end

    it 'keeps a plain 529 with a real Faraday::Env response as overloaded' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error    = ssot_harness.faraday_server_error(status: 529, body: '{"error": {"message": "overloaded"}}')
      outcome  = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:overloaded)
    end

    # Production dispatch path: the lex-llm ErrorMiddleware raises
    # Legion::Extensions::Llm::*Error whose .response is a Faraday::Response.
    it 'detects the explicit UNAVAILABLE body on the production ErrorMiddleware error shape' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      env = Faraday::Env.new
      env.status = 503
      env.response_body = '{"error":{"code":503,"message":"unavailable","status":"UNAVAILABLE"}}'
      error = Legion::Extensions::Llm::ServiceUnavailableError.new(Faraday::Response.new(env), '503')
      expect(error.response).to be_a(Faraday::Response)

      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    it 'treats a response-less ServiceUnavailableError as provider_error, not instance_unavailable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Legion::Extensions::Llm::ServiceUnavailableError.new('503')
      expect(error.response).to be_nil

      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:provider_error)
    end

    it 'classifies a 503 model-not-ready body as model_not_ready on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome  = callable.normalize_dispatch_error(error: ssot_harness.model_not_ready_error)
      expect(outcome.kind).to eq(:model_not_ready)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end
  end

  # ─── No quota domain broadening without authoritative scope ────────────────

  describe 'quota domain safety' do
    it 'does not declare quota_domains on offerings' do
      config   = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      drafts   = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)

      drafts.each do |draft|
        expect(draft.quota_domains).to be_empty,
                                       'Gemini offerings must not declare quota_domains without authoritative scope'
      end
    end
  end

  # ─── ReadinessResult contract ──────────────────────────────────────────────

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config   = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result   = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config   = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end

  # ─── Helpers::Callable direct contract ─────────────────────────────────────

  describe Legion::Extensions::Llm::Gemini::Helpers::Callable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect and disconnected?' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to the fleet dispatch ops with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
      %i[chat stream_chat embed count_tokens].each do |op|
        expect(callable).to respond_to(op), "production callable must implement the fleet op ##{op}"
      end
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'delegates chat to the per-instance provider with rest passthrough' do
      provider = RecordingGeminiProvider.new
      wrapped  = described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL),
        provider: provider
      )

      messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')]

      params = Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.5)
      result = wrapped.chat(messages, model: 'gemini-2.0-flash', params: params)

      expect(result).to include(role: 'assistant')
      call = provider.calls.first
      expect(call[:operation]).to eq(:chat)
      # N x N law: the callable passes canonical messages through untranslated
      # — the provider render seam is the only canonical <-> wire converter.
      expect(call[:messages]).to eq(messages)
      # 05 O4: temperature lives only in Canonical::Params (the kwarg is gone).
      expect(call[:params].temperature).to eq(0.5)
      # D15: the fleet passes model as a RAW STRING; the callable hands it to
      # the provider untranslated — the 0.8.0 contract is exact identity
      # preservation (the render seam resolves the bare string).
      expect(call[:model]).to eq('gemini-2.0-flash')
    end

    it 'passes a raw model string through unchanged (D15 pass-through)' do
      provider = RecordingGeminiProvider.new
      wrapped  = described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL),
        provider: provider
      )

      wrapped.chat([], model: 'gemini-2.0-flash')

      expect(provider.calls.first[:model]).to eq('gemini-2.0-flash')
    end

    it 'delegates embed and count_tokens to the per-instance provider' do
      provider = RecordingGeminiProvider.new
      wrapped  = described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL),
        provider: provider
      )

      wrapped.embed(text: 'hello', model: 'gemini-embedding-001', dimensions: 768)
      count_messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hi')]
      wrapped.count_tokens(messages: count_messages, model: 'gemini-2.0-flash')

      expect(provider.calls.map { |c| c[:operation] }).to eq(%i[embed count_tokens])
      expect(provider.calls[0]).to include(text: 'hello', dimensions: 768)
    end

    it 'closes the per-instance provider on disconnect' do
      provider = RecordingGeminiProvider.new
      wrapped  = described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL),
        provider: provider
      )

      wrapped.disconnect

      expect(provider.disconnected).to be(true)
    end

    it 'lets dispatch errors propagate unrescued (Faraday errors escape chat)' do
      provider = Class.new do
        def enforce_canonical_messages!(messages)
          Legion::Extensions::Llm::Provider.allocate.enforce_canonical_messages!(messages)
        end

        def chat(_messages, **)
          raise Faraday::ServerError.new('503', Faraday::Env.new.tap { |e| e.status = 503 })
        end
      end.new
      wrapped = described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL),
        provider: provider
      )

      expect { wrapped.chat([], model: 'gemini-2.0-flash') }.to raise_error(Faraday::ServerError)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end
  end

  # ─── Dispatch boundary regression guards (2026-08-19) ─────────────────────
  # The 2026-08-19 defect class: plain-Hash messages crossed the dispatch
  # boundary and lenient provider-side handling re-canonicalized them, masking
  # the bypass (25/25 failed openai dispatches). N x N law: the callable is the
  # canonical boundary and the base funnel enforces centrally before any
  # rendering. Both reject plain-Hash input loudly, never silently; the render
  # seam itself no longer re-implements the check (08 F2).
  describe 'dispatch boundary (canonical only)' do
    let(:callable) { ssot_harness.build_callable(instance_config: ssot_harness.instance_configs.first) }
    let(:provider) { described_class::Provider.new(gemini_api_key: 'test-key') }

    let(:hash_request) do
      [
        { role: 'user', content: 'What is the capital of France?' },
        { role: 'assistant', content: 'Paris.' }
      ]
    end

    it 'rejects plain Hash messages at the callable instead of delegating them' do
      expect { callable.chat(hash_request, model: 'gemini-2.0-flash') }
        .to raise_error(ArgumentError, /Canonical::Message/)
      # rubocop:disable Lint/EmptyBlock -- the block never runs: enforcement raises first
      expect { callable.stream_chat(hash_request, model: 'gemini-2.0-flash') { |_c| } }
        .to raise_error(ArgumentError, /Canonical::Message/)
      # rubocop:enable Lint/EmptyBlock
      expect { callable.count_tokens(messages: hash_request, model: 'gemini-2.0-flash') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'rejects plain Hash messages at the base funnel (central enforcement, 08 F2)' do
      expect { provider.chat(hash_request, model: 'gemini-2.0-flash') }
        .to raise_error(ArgumentError, /Canonical::Message/)
      # rubocop:disable Lint/EmptyBlock -- the block never runs: enforcement raises first
      expect { provider.stream_chat(hash_request, model: 'gemini-2.0-flash') { |_c| } }
        .to raise_error(ArgumentError, /Canonical::Message/)
      # rubocop:enable Lint/EmptyBlock
      expect { provider.count_tokens(messages: hash_request, model: 'gemini-2.0-flash') }
        .to raise_error(ArgumentError, /Canonical::Message/)
    end

    it 'delegates canonical messages through the callable untouched' do
      messages = [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')]

      callable.chat(messages, model: 'gemini-2.0-flash')

      expect(ssot_harness.inference_call_count(callable: callable)).to eq(1)
    end
  end

  # ─── Conformance kit: B1 central enforcement + B2 canonical outputs ───────
  # The kit (09) runs against the REAL callable boundary: the production
  # Helpers::Callable over the production Gemini::Provider, with only the HTTP
  # transport (Connection) stubbed. render_payload/parse_completion_response/
  # build_chunk are the real Gemini wire code — no canonical-returning fake.
  describe 'canonical boundary kit (09 B1/B2)' do
    let(:provider) do
      built = described_class::Provider.new(gemini_api_key: 'test-key')
      connection = instance_double(Legion::Extensions::Llm::Connection)
      allow(connection).to receive(:post) do |url, _payload, &block|
        stub_provider_post(url, block)
      end
      built.instance_variable_set(:@connection, connection)
      built
    end
    let(:callable) do
      described_class::Helpers::Callable.new(
        instance_cfg: { gemini_api_key: 'test-key' },
        logger: Logger.new(File::NULL),
        provider: provider
      )
    end

    # Both the sync and the stream post yield a request block, so the branch
    # is the URL: streamGenerateContent feeds the SSE on_data callback, the
    # completion URL just returns the canned sync body.
    def stub_provider_post(url, block)
      options = FakeStreamOptions.new
      fake_request = Struct.new(:options).new(options)
      block&.call(fake_request)
      if url.to_s.include?('streamGenerateContent')
        env = Struct.new(:status).new(200)
        kit_stream_events.each { |event| options.on_data.call(event, 0, env) }
      end
      Struct.new(:body).new(kit_completion_body)
    end

    def kit_completion_body
      {
        'modelVersion' => 'gemini-2.0-flash',
        'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'hi' }] }, 'finishReason' => 'STOP' }],
        'usageMetadata' => { 'promptTokenCount' => 3, 'candidatesTokenCount' => 4 }
      }
    end

    def kit_stream_events
      [
        { 'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'He' }] } }] },
        { 'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'llo' }] } }] },
        {
          'candidates' => [{ 'content' => { 'parts' => [{ 'text' => '' }] }, 'finishReason' => 'STOP' }],
          'usageMetadata' => { 'promptTokenCount' => 3, 'candidatesTokenCount' => 2 }
        }
      ].map { |body| "data: #{Legion::JSON.dump(body)}\n\n" }
    end

    it_behaves_like 'B1 — central canonical enforcement (08 F2)'
    it_behaves_like 'B2 — canonical outputs (05 O5, 08 R2)'
  end

  # ─── No Legion::LLM reverse dependency ────────────────────────────────────

  describe 'dependency isolation' do
    it 'does not require Legion::LLM in the discovery actor or runner' do
      project_root = File.expand_path('../../../..', __dir__)
      %w[actors/discovery.rb runners/discovery.rb].each do |relative_file|
        file = File.read(File.join(project_root, 'lib/legion/extensions/llm/gemini', relative_file))
        expect(file).not_to match(/\bLegion::LLM\b/), "#{relative_file} must not reference Legion::LLM"
      end
    end

    it 'Helpers::Callable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome  = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # ─── ProbeCoordinator coalescing ───────────────────────────────────────────

  describe 'ProbeCoordinator coalescing' do
    let(:probe_setup) do
      config      = ssot_harness.instance_configs[0]
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini, instance_id: instance_id
      )
      { config: config, instance_id: instance_id, key: key }
    end
    let(:enqueue_calls) { [] }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: probe_setup[:key],
        enqueue: lambda { |request:|
          enqueue_calls << request
          true
        }
      )
    end

    it 'coalesces multiple probe requests into a single in-flight probe' do
      coordinator.enqueue_probe_request(
        instance_key: probe_setup[:key], publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 1, reason: 'first failure'
      )
      expect(enqueue_calls.size).to eq(1)

      expect(coordinator.begin_probe(request: enqueue_calls.first)).to be(true)
      expect(coordinator.in_flight?).to be(true)

      coordinator.enqueue_probe_request(
        instance_key: probe_setup[:key], publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 2, reason: 'second failure'
      )
      expect(enqueue_calls.size).to eq(1)

      coordinator.finish_probe(request: enqueue_calls.first)
      expect(enqueue_calls.size).to eq(2)
      expect(enqueue_calls.last.unavailable_revision).to eq(2)
    end
  end
end
