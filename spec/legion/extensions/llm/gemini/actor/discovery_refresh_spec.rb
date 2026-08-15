# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'

RSpec.describe Legion::Extensions::Llm::Gemini::Actor::DiscoveryRefresh do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:gemini_key) { 'AIzaSySpecKey-Local' }
  let(:actor) { described_class.new }
  # The registered settings shape: the credential is an env:// reference under
  # instances.default.credentials (provider_settings nesting).
  let(:settings) do
    {
      instances: {
        default: {
          endpoint: 'https://generativelanguage.googleapis.com/v1beta',
          discovery_interval: 3600,
          credentials: { api_key: 'env://GEMINI_API_KEY' }
        }
      }
    }
  end
  let(:readiness) do
    {
      ready: Legion::Extensions::Llm::Inventory::ReadinessResult.new(
        ready: true, reason: 'Gemini models API returned 200', metadata: { status: 200 }
      ),
      unready: Legion::Extensions::Llm::Inventory::ReadinessResult.new(
        ready: false, reason: 'Gemini models API returned 401', metadata: { status: 401 }
      )
    }
  end

  before { registry.reset! }

  around do |example|
    original = ENV.fetch('GEMINI_API_KEY', nil)
    ENV['GEMINI_API_KEY'] = gemini_key
    example.run
  ensure
    ENV['GEMINI_API_KEY'] = original
  end

  # Builds drafts through the actor's PRODUCTION builder (no harness drift).
  def build_offerings(actor, instance_cfg, model_ids: %w[gemini-2.0-flash])
    instance_id = actor.send(:derive_instance_id, instance_cfg: instance_cfg)
    instance_key = actor.send(:build_instance_key, instance_id: instance_id)
    model_ids.map do |model_id|
      actor.send(
        :build_offering_draft,
        model_id: model_id,
        model_data: {
          name: "models/#{model_id}",
          supportedGenerationMethods: %w[generateContent streamGenerateContent],
          inputTokenLimit: 1_048_576,
          outputTokenLimit: 8192
        },
        instance_cfg: instance_cfg,
        instance_key: instance_key
      )
    end
  end

  def normalized_default(actor, settings)
    actor.send(:normalize_instance_config, config: settings[:instances][:default])
  end

  def key_for(instance_id)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :gemini, instance_id: instance_id
    )
  end

  def instance_id_for(actor, config)
    actor.send(:derive_instance_id, instance_cfg: actor.send(:normalize_instance_config, config: config))
  end

  # ── D9: actor periodicity ───────────────────────────────────────────────────

  describe 'tick interval (time)' do
    it 'returns the registered nested discovery interval (never nil)' do
      allow(actor).to receive(:settings).and_return(settings)
      expect(actor.time).to eq(3600)
    end

    it 'honors an operator override of the nested interval' do
      allow(actor).to receive(:settings).and_return({ instances: { default: { discovery_interval: 60 } } })
      expect(actor.time).to eq(60)
    end

    it 'falls back to the registered default when the interval is missing or non-positive' do
      allow(actor).to receive(:settings).and_return({})
      expect(actor.time).to be_a(Integer).and be_positive

      allow(actor).to receive(:settings).and_return({ instances: { default: { discovery_interval: 0 } } })
      expect(actor.time).to be_a(Integer).and be_positive

      allow(actor).to receive(:settings).and_return({ instances: { default: { discovery_interval: nil } } })
      expect(actor.time).to be_a(Integer).and be_positive
    end
  end

  # ── P1-4: env:// credential resolution in the instances.* path ─────────────

  describe 'instance credential resolution' do
    it 'resolves env:// credentials from the instances.* path' do
      allow(actor).to receive(:settings).and_return(settings)
      instances = actor.send(:configured_instances)

      expect(instances[:default][:gemini_api_key]).to eq(gemini_key)
    end

    it 'fingerprint instance_id off the resolved key, not the env:// placeholder' do
      allow(actor).to receive(:settings).and_return(settings)
      instance_id = instance_id_for(actor, settings[:instances][:default])
      fingerprint = Digest::SHA256.hexdigest(gemini_key)[0, 8]

      expect(instance_id).to eq("generativelanguage.googleapis.com:443/ak:#{fingerprint}")
      expect(instance_id).not_to include(Digest::SHA256.hexdigest('env://GEMINI_API_KEY')[0, 8])
    end

    it 'skips instances whose env credential is unset' do
      ENV['GEMINI_API_KEY'] = nil
      allow(actor).to receive(:settings).and_return(settings)

      expect(actor.send(:configured_instances)).to be_empty
    end

    it 'skips instances with no credentials at all' do
      allow(actor).to receive(:settings)
        .and_return({ instances: { naked: { endpoint: 'https://generativelanguage.googleapis.com/v1beta' } } })

      expect(actor.send(:configured_instances)).to be_empty
    end
  end

  # ── D16: discovery error boundary — programming errors must not become [] ──

  describe 'discovery error boundary (D16)' do
    it 'propagates programming errors instead of publishing zero offerings' do
      allow(actor).to receive(:fetch_models).and_raise(NoMethodError, "undefined method 'id'")

      expect do
        actor.send(:discover_offerings_for_instance, instance_cfg: {}, instance_key: nil)
      end.to raise_error(NoMethodError)
    end

    it 'yields [] only for a transport failure' do
      allow(actor).to receive(:fetch_models)
        .and_raise(Faraday::ConnectionFailed.new('connection refused'))

      expect(actor.send(:discover_offerings_for_instance, instance_cfg: {}, instance_key: nil)).to eq([])
    end
  end

  # ── D4: recovery after initial readiness failure ───────────────────────────

  describe 'initial readiness failure recovery' do
    it 'activates the instance on a later tick once readiness passes' do
      allow(actor).to receive_messages(settings: settings,
                                       discover_offerings_for_instance: build_offerings(
                                         actor, normalized_default(actor, settings)
                                       ))
      allow(actor).to receive(:check_health).and_return(readiness[:unready], readiness[:ready])

      actor.manual # initial discovery: claim + readiness FAILED

      instance_id = instance_id_for(actor, settings[:instances][:default])
      key = key_for(instance_id)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      actor.manual # tick: retry_initial_activation → readiness passes → activate

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end

    it 'stays initializing while readiness keeps failing' do
      allow(actor).to receive_messages(
        settings: settings,
        discover_offerings_for_instance: build_offerings(actor, normalized_default(actor, settings)),
        check_health: readiness[:unready]
      )

      actor.manual
      actor.manual
      actor.manual

      instance_id = instance_id_for(actor, settings[:instances][:default])
      key = key_for(instance_id)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end
  end

  # ── D4/tick reconcile: late-configured and removed instances ───────────────

  describe 'tick reconciliation' do
    it 'adds instances that appear in settings after boot and removes ones that disappear' do
      alpha = { api_key: 'key-alpha', endpoint: 'https://alpha.example.com/v1beta' }
      beta  = { api_key: 'key-beta',  endpoint: 'https://beta.example.com/v1beta' }
      first  = { instances: { alpha: alpha } }
      second = { instances: { beta: beta } }
      allow(actor).to receive(:settings).and_return(first, second)
      allow(actor).to receive_messages(discover_offerings_for_instance: [], check_health: readiness[:ready])

      alpha_id = instance_id_for(actor, alpha)
      beta_id  = instance_id_for(actor, beta)

      actor.manual
      expect(registry.snapshot.instance(instance_key: key_for(alpha_id))).not_to be_nil
      expect(registry.snapshot.instance(instance_key: key_for(beta_id))).to be_nil

      actor.manual
      expect(registry.snapshot.instance(instance_key: key_for(alpha_id))).to be_nil,
                                                                             'removed instance must be retired'
      expect(registry.snapshot.instance(instance_key: key_for(beta_id))).not_to be_nil,
                                                                                'late instance must be claimed'
    end
  end

  # ── P3-7: no replace churn when the model set is unchanged ─────────────────

  describe 'snapshot replace churn' do
    it 'does not replace the snapshot when the model set and evidence are unchanged' do
      allow(actor).to receive_messages(settings: settings, check_health: readiness[:ready])
      allow(actor).to receive(:discover_offerings_for_instance) do
        # Fresh drafts with fresh observed_at on every call — Data#== would
        # say "changed" every tick; the signature compare must not.
        build_offerings(actor, normalized_default(actor, settings))
      end

      actor.manual # initial activate (sequence 0)
      actor.manual # tick 1
      actor.manual # tick 2

      instance_id = instance_id_for(actor, settings[:instances][:default])
      expect(registry.snapshot.publication_status(instance_key: key_for(instance_id)).published_sequence)
        .to eq(0), 'unchanged offerings must not bump the publication sequence'
    end

    it 'replaces the snapshot when the model set actually changes' do
      allow(actor).to receive_messages(settings: settings, check_health: readiness[:ready])
      cfg = normalized_default(actor, settings)
      allow(actor).to receive(:discover_offerings_for_instance)
        .and_return(build_offerings(actor, cfg, model_ids: %w[gemini-2.0-flash]),
                    build_offerings(actor, cfg, model_ids: %w[gemini-2.0-flash gemini-2.5-pro]))

      actor.manual # initial activate with one model
      actor.manual # tick: second model appears → replace

      instance_id = instance_id_for(actor, settings[:instances][:default])
      expect(registry.snapshot.publication_status(instance_key: key_for(instance_id)).published_sequence)
        .to eq(1)
      expect(registry.snapshot.offerings_for(instance_key: key_for(instance_id)).size).to eq(2)
    end
  end

  # ── D14: settings health hash + capabilities after registry commits ────────

  describe 'settings display health (D14)' do
    it 'writes the legacy 4-key health shape plus capabilities after each registry commit' do
      allow(actor).to receive_messages(settings: settings,
                                       discover_offerings_for_instance: build_offerings(
                                         actor, normalized_default(actor, settings)
                                       ))
      allow(actor).to receive(:check_health).and_return(readiness[:unready], readiness[:ready])

      actor.manual # initial failure

      health = settings.dig(:instances, :default, :health)
      expect(health).to include(
        circuit_state: :open, denied: false, available: false, adjustment: -50
      )
      expect(health[:last_probe_outcome]).to eq(:failure)
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(Time)
      expect(settings.dig(:instances, :default, :capabilities)).to include(:completion, :streaming)

      actor.manual # recovery

      health = settings.dig(:instances, :default, :health)
      expect(health).to include(
        circuit_state: :closed, denied: false, available: true, adjustment: 0
      )
      expect(health[:last_probe_outcome]).to eq(:success)
    end

    it 'keys the health hash by the config name, not the derived instance_id' do
      allow(actor).to receive_messages(
        settings: settings,
        discover_offerings_for_instance: build_offerings(actor, normalized_default(actor, settings)),
        check_health: readiness[:ready]
      )

      actor.manual

      expect(settings[:instances].keys).to include(:default)
      instance_id = instance_id_for(actor, settings[:instances][:default])
      expect(settings[:instances].keys).not_to include(instance_id)
      expect(settings.dig(:instances, :default, :health)[:available]).to be(true)
    end

    it 'clears the health hash when the instance is removed' do
      allow(actor).to receive_messages(
        settings: settings,
        discover_offerings_for_instance: build_offerings(actor, normalized_default(actor, settings)),
        check_health: readiness[:ready]
      )

      actor.manual
      expect(settings.dig(:instances, :default, :health)).not_to be_nil

      actor.shutdown
      expect(settings.dig(:instances, :default, :health)).to be_nil
      expect(settings.dig(:instances, :default, :capabilities)).to be_nil
      instance_id = instance_id_for(actor, settings[:instances][:default])
      expect(registry.snapshot.instance(instance_key: key_for(instance_id))).to be_nil
    end
  end
end
