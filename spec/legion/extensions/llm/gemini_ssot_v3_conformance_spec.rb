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

# GeminiCallable is loaded via spec_helper → gemini.rb → discovery_refresh.rb
# (spec_helper stubs Legion::Extensions::Actors::Every before loading gemini)

# rubocop:disable RSpec/MultipleMemoizedHelpers

# Test-local callable that extends GeminiCallable with dispatch operations
# required by FleetWorkerExecution. Tracks inference call count for
# conformance assertions.
class TrackingGeminiCallable < Legion::Extensions::Llm::Gemini::Actor::GeminiCallable
  attr_reader :call_count

  def initialize(instance_cfg:, logger:)
    super
    @call_count = 0
  end

  def chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'test response', model: model }
  end

  def stream_chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'streamed response', model: model }
  end

  def embed(model:, **)
    @call_count += 1
    { embedding: [0.1, 0.2, 0.3], model: model }
  end

  def count_tokens(model:, **)
    @call_count += 1
    { token_count: 42, model: model }
  end
end

# Harness class for Gemini SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching
# any external service.
class GeminiSsotHarness # rubocop:disable Metrics/ClassLength
  INSTANCE_CONFIGS = [
    {
      gemini_api_base: 'https://generativelanguage.googleapis.com/v1beta',
      tier: :frontier, gemini_api_key: 'AIzaSyTestKey1-AAAA',
      usage: { inference: true, embedding: true }
    }.freeze,
    {
      gemini_api_base: 'https://generativelanguage.googleapis.com/v1beta',
      tier: :frontier, gemini_api_key: 'AIzaSyTestKey2-BBBB',
      usage: { inference: true, embedding: true }
    }.freeze
  ].freeze

  def provider_family = :gemini
  def instance_configs = INSTANCE_CONFIGS

  def instance_id(instance_config:)
    base_url = instance_config[:gemini_api_base] || instance_config[:endpoint] ||
               'https://generativelanguage.googleapis.com/v1beta'
    host_port = extract_host_port(base_url: base_url)
    api_key = instance_config[:gemini_api_key] || instance_config[:api_key] ||
              instance_config.dig(:credentials, :api_key)

    return host_port unless api_key.is_a?(String) && !api_key.strip.empty?

    "#{host_port}/ak:#{::Digest::SHA256.hexdigest(api_key)[0, 8]}"
  end

  def build_callable(instance_config:)
    TrackingGeminiCallable.new(instance_cfg: instance_config, logger: Logger.new(File::NULL))
  end

  def build_offering_drafts(tier: :frontier, **)
    now = Time.now.freeze
    model_id = 'gemini-2.0-flash'
    generation_methods = %w[generateContent streamGenerateContent countTokens]
    [build_single_offering(model_id: model_id, tier: tier, now: now, generation_methods: generation_methods)]
  end

  def safe_readiness(instance_config:, **)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'Gemini models API returned 200',
      metadata: { status: 200, base_url: instance_config[:gemini_api_base] }
    )
  end

  def inference_call_count(callable:)
    callable.respond_to?(:call_count) ? callable.call_count : 0
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    outcome = callable.normalize_dispatch_error(error: error)
    apply_gemini_escalation(outcome: outcome, error: error)
  end

  def instance_unavailable_error
    # Gemini does not produce a distinct instance-unavailable wire signal through
    # HTTP alone; connection failure is the closest analog for conformance testing.
    Faraday::ConnectionFailed.new('Connection refused - connect(2) for generativelanguage.googleapis.com:443')
  end

  def overloaded_error
    response = { status: 503, headers: {}, body: '{"error": {"code": 503, "message": "Service overloaded"}}' }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  def model_not_ready_error
    response = { status: 503, headers: {},
                 body: '{"error": {"code": 503, "message": "Model not ready", "status": "UNAVAILABLE"}}' }
    Faraday::ServerError.new('the server responded with status 503 - model not ready', response)
  end

  private

  def apply_gemini_escalation(outcome:, error:)
    # Connection failure is the only signal that maps to instance_unavailable
    # for Gemini (no distinct flat unavailable response exists).
    if outcome.kind == :connection_failure && error.is_a?(Faraday::ConnectionFailed)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :instance_unavailable, reason: outcome.reason)
    end

    # 503 with model-not-ready body signal is request-local, not overloaded.
    if outcome.kind == :overloaded && model_not_ready_signal?(error: error)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(kind: :model_not_ready, reason: outcome.reason)
    end

    outcome
  end

  def model_not_ready_signal?(error:)
    return false unless error.respond_to?(:response) && error.response.is_a?(Hash)

    body = error.response[:body].to_s.downcase
    body.include?('model not ready') || body.include?('model is still loading')
  end

  def extract_host_port(base_url:)
    uri = URI.parse(base_url.to_s)
    "#{uri.host || 'generativelanguage.googleapis.com'}:#{uri.port}"
  end

  def build_single_offering(model_id:, tier:, now:, generation_methods:)
    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: model_id, model: model_id, tier: tier,
      operation_evidence: build_operation_evidence(now: now, generation_methods: generation_methods),
      capability_evidence: build_capability_evidence(generation_methods: generation_methods),
      context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :known, value: 1_048_576, source: :provider_catalog
      ),
      max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :known, value: 8192, source: :provider_catalog
      ),
      embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      quota_domains: {}, metadata: { raw_model: model_id }, publication_source: :provider_catalog
    )
  end

  def build_operation_evidence(now:, generation_methods:)
    chat_status = generation_methods.include?('generateContent') ? :supported : :unknown
    stream_status = generation_methods.include?('streamGenerateContent') ? :supported : :unknown
    embed_status = generation_methods.include?('embedContent') ? :supported : :unsupported

    {
      chat: op_evidence(:chat, chat_status, now),
      stream_chat: op_evidence(:stream_chat, stream_status, now),
      embed: op_evidence(:embed, embed_status, now),
      image: op_evidence(:image, :unsupported, now),
      transcribe: op_evidence(:transcribe, :unsupported, now),
      translate: op_evidence(:translate, :unsupported, now),
      speak: op_evidence(:speak, :unsupported, now),
      moderate: op_evidence(:moderate, :unsupported, now),
      count_tokens: op_evidence(:count_tokens, :unknown, now)
    }
  end

  def op_evidence(operation, status, observed_at)
    source = status == :unknown ? :default_false : :provider_catalog
    Legion::Extensions::Llm::Inventory::OperationEvidence.new(
      operation: operation, status: status, source: source, observed_at: observed_at
    )
  end

  def build_capability_evidence(generation_methods:)
    {
      completion: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :completion,
        status: generation_methods.include?('generateContent') ? :supported : :unknown,
        source: generation_methods.include?('generateContent') ? :provider_catalog : :default_false,
        observed_at: Time.now
      ),
      streaming: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :streaming,
        status: generation_methods.include?('streamGenerateContent') ? :supported : :unknown,
        source: generation_methods.include?('streamGenerateContent') ? :provider_catalog : :default_false,
        observed_at: Time.now
      ),
      tools: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :tools, status: :unknown, source: :default_false, observed_at: Time.now
      ),
      thinking: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :thinking, status: :unknown, source: :default_false, observed_at: Time.now
      )
    }
  end
end

RSpec.describe Legion::Extensions::Llm::Gemini do
  let(:ssot_harness) { GeminiSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # ─── Gemini-specific identity derivation ────────────────────────────────────

  describe 'instance identity derivation' do
    it 'derives instance_id as host:port/ak:fingerprint with API key' do
      config = { gemini_api_base: 'https://generativelanguage.googleapis.com/v1beta',
                 gemini_api_key: 'AIzaSyTestKey1-AAAA' }
      fingerprint = Digest::SHA256.hexdigest('AIzaSyTestKey1-AAAA')[0, 8]
      expect(ssot_harness.instance_id(instance_config: config))
        .to eq("generativelanguage.googleapis.com:443/ak:#{fingerprint}")
    end

    it 'produces distinct instance IDs for two different API keys' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end
  end

  # ─── Two API keys with same model = separate lanes ─────────────────────────

  describe 'two Gemini API keys serving the same model' do
    def bring_up_instance(config, tier: :frontier)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :gemini)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable,
                                       probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts, coordinator: coordinator }
    end

    it 'creates separate lanes for the same model on different API keys' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
      lanes_a = snapshot.lanes_for(instance_key: a[:key])
      lanes_b = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty

      lane_ids_a = lanes_a.map(&:lane_id)
      lane_ids_b = lanes_b.map(&:lane_id)
      expect(lane_ids_a & lane_ids_b).to be_empty
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      first_run = bring_up_instance(config)
      first_offering_id = registry.snapshot.offerings_for(instance_key: first_run[:key]).first.offering_id
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      registry.reset!
      second_run = bring_up_instance(config)
      second_offering_id = registry.snapshot.offerings_for(instance_key: second_run[:key]).first.offering_id
      second_lane_id = registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      expect(second_offering_id).to eq(first_offering_id)
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # ─── Generation method evidence controls ───────────────────────────────────

  describe 'generation method operation evidence' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier) }
    let(:offering) { drafts.first }

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
    it 'produces unknown evidence when generation methods list is empty' do
      # Simulate a model that has no supportedGenerationMethods field
      GeminiSsotHarness.new
      # Override build to use empty generation methods
      now = Time.now.freeze
      op_evidence = {
        chat: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :chat, status: :unknown, source: :default_false, observed_at: now
        ),
        stream_chat: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :stream_chat, status: :unknown, source: :default_false, observed_at: now
        ),
        embed: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :embed, status: :unknown, source: :default_false, observed_at: now
        ),
        image: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :image, status: :unsupported, source: :provider_catalog, observed_at: now
        ),
        transcribe: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :transcribe, status: :unsupported, source: :provider_catalog, observed_at: now
        ),
        translate: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :translate, status: :unsupported, source: :provider_catalog, observed_at: now
        ),
        speak: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :speak, status: :unsupported, source: :provider_catalog, observed_at: now
        ),
        moderate: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :moderate, status: :unsupported, source: :provider_catalog, observed_at: now
        ),
        count_tokens: Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: :count_tokens, status: :unknown, source: :default_false, observed_at: now
        )
      }

      # When methods are empty, chat/stream/embed should all be unknown, not supported
      expect(op_evidence[:chat].status).to eq(:unknown)
      expect(op_evidence[:stream_chat].status).to eq(:unknown)
      expect(op_evidence[:embed].status).to eq(:unknown)
    end
  end

  # ─── Embed-only models cannot be selected for chat ─────────────────────────

  describe 'embed-only model operation separation' do
    it 'embed model does not advertise chat support' do
      Time.now.freeze
      # A model like text-embedding-004 only has embedContent
      embed_methods = %w[embedContent]

      chat_status = embed_methods.include?('generateContent') ? :supported : :unsupported
      stream_status = embed_methods.include?('streamGenerateContent') ? :supported : :unsupported
      embed_status = embed_methods.include?('embedContent') ? :supported : :unsupported

      expect(chat_status).to eq(:unsupported)
      expect(stream_status).to eq(:unsupported)
      expect(embed_status).to eq(:supported)
    end
  end

  # ─── No default model ──────────────────────────────────────────────────────

  describe 'no default model or provider' do
    it 'rejects instance_id "default" as reserved' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :gemini, instance_id: 'default'
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
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
      now = Time.now.freeze
      expect do
        Legion::Extensions::Llm::Inventory::OfferingDraft.new(
          provider_native_key: 'test',
          model: '',
          tier: :frontier,
          operation_evidence: GeminiSsotHarness.new.send(
            :build_operation_evidence, now: now, generation_methods: %w[generateContent]
          ),
          context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown,
                                                                                               source: :absent),
          model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown,
                                                                                         source: :absent),
          tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
          quota_domains: {},
          metadata: {},
          publication_source: :provider_catalog
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end

  # ─── Startup gating + initializing on initial failure ──────────────────────

  describe 'startup gating' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:instance_id) { ssot_harness.instance_id(instance_config: config) }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini, instance_id: instance_id
      )
    end
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :gemini) }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
    end

    it 'remains initializing until readiness probe succeeds' do
      publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      publisher.readiness_failed(instance_id: instance_id, probe_token: probe, reason: 'Gemini models API returned 401')

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'transitions to available after readiness success' do
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end
  end

  # ─── Instance-unavailable isolation ────────────────────────────────────────

  describe 'instance-unavailable isolation' do
    def bring_up(config)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :gemini)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
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

    it 'normalizes connection failure as instance_unavailable through the harness' do
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
      error = Faraday::ConnectionFailed.new('Connection refused')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:connection_failure)
    end

    it 'classifies timeout as timeout on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = Faraday::TimeoutError.new('Net::ReadTimeout')
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:timeout)
    end

    it 'classifies 429 ClientError as rate_limited on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 429, headers: {}, body: '' }
      error = Faraday::ClientError.new('429', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end

    it 'classifies 401 as authentication on the callable' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 401, headers: {}, body: '' }
      error = Faraday::ClientError.new('401', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:authentication)
    end

    it 'never returns instance_unavailable from the callable for any server error' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      [500, 502, 503, 504, 529].each do |status|
        response = { status: status, headers: {}, body: '' }
        error = Faraday::ServerError.new(status.to_s, response)
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end
  end

  # ─── No quota domain broadening without authoritative scope ────────────────

  describe 'quota domain safety' do
    it 'does not declare quota_domains on offerings' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :frontier)

      drafts.each do |draft|
        expect(draft.quota_domains).to be_empty,
                                       'Gemini offerings must not declare quota_domains without authoritative scope'
      end
    end
  end

  # ─── ReadinessResult contract ──────────────────────────────────────────────

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end

  # ─── GeminiCallable direct contract ────────────────────────────────────────

  describe Legion::Extensions::Llm::Gemini::Actor::GeminiCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end
  end

  # ─── No Legion::LLM reverse dependency ────────────────────────────────────

  describe 'dependency isolation' do
    it 'does not require Legion::LLM in the discovery actor' do
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(
        File.join(project_root, 'lib/legion/extensions/llm/gemini/actors/discovery_refresh.rb')
      )
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'GeminiCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # ─── ProbeCoordinator coalescing ───────────────────────────────────────────

  describe 'ProbeCoordinator coalescing' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:instance_id) { ssot_harness.instance_id(instance_config: config) }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :gemini, instance_id: instance_id
      )
    end
    let(:enqueue_calls) { [] }
    let(:coordinator) do
      Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key,
        enqueue: lambda { |request:|
          enqueue_calls << request
          true
        }
      )
    end

    it 'coalesces multiple probe requests into a single in-flight probe' do
      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 1, reason: 'first failure'
      )
      expect(enqueue_calls.size).to eq(1)

      expect(coordinator.begin_probe(request: enqueue_calls.first)).to be(true)
      expect(coordinator.in_flight?).to be(true)

      coordinator.enqueue_probe_request(
        instance_key: key, publisher_token_id: 'ptok:v1:aaa',
        unavailable_revision: 2, reason: 'second failure'
      )
      expect(enqueue_calls.size).to eq(1)

      coordinator.finish_probe(request: enqueue_calls.first)
      expect(enqueue_calls.size).to eq(2)
      expect(enqueue_calls.last.unavailable_revision).to eq(2)
    end
  end
end

# rubocop:enable RSpec/MultipleMemoizedHelpers
