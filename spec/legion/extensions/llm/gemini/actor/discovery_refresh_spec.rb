# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/registry'

RSpec.describe Legion::Extensions::Llm::Gemini::Actor::DiscoveryRefresh do
  let(:gemini_key) { 'AIzaSySpecKey-Local' }
  let(:actor) { described_class.new }
  # The registered settings shape: a NAMED operator instance whose credential
  # is an env:// reference under credentials (provider_settings nesting). The
  # instance identity is the config NAME (:primary) — the key the router looks
  # up in instances.<name>; the derived host:port/ak id is the secondary
  # physical id only.
  let(:settings) do
    {
      instances: {
        primary: {
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
  after { registry.reset! }

  around do |example|
    original = ENV.fetch('GEMINI_API_KEY', nil)
    ENV['GEMINI_API_KEY'] = gemini_key
    example.run
  ensure
    ENV['GEMINI_API_KEY'] = original
  end

  # Builds drafts through the actor's PRODUCTION builder (no harness drift).
  def build_offerings(actor, instance_cfg, name: 'primary', model_ids: %w[gemini-2.0-flash])
    instance_key = actor.send(
      :build_instance_key,
      instance_id: name.to_s,
      physical_id: actor.send(:derive_physical_id, instance_cfg: instance_cfg)
    )
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

  def registry = Legion::Extensions::Llm::Inventory::Registry

  def normalized_primary(actor, settings)
    actor.send(:normalize_instance_config, config: settings[:instances][:primary])
  end

  def key_for(instance_id, physical_id: nil)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :gemini, instance_id: instance_id, physical_id: physical_id
    )
  end

  def physical_id_for(actor, config)
    actor.send(:derive_physical_id, instance_cfg: actor.send(:normalize_instance_config, config: config))
  end

  def full_weight_settings(provider: 100, instance: 100, model: 100, tier: 100)
    {
      extensions: {
        llm: {
          gemini: {
            weight: provider,
            instances: {
              primary: {
                weight: instance,
                models: { 'gemini-2.0-flash' => { weight: model } }
              }
            }
          }
        }
      },
      llm: { routing: { tier_weights: { frontier: tier } } }
    }
  end

  def stub_live_settings(live_settings)
    allow(Legion::Settings).to receive(:dig) { |*path| live_settings.dig(*path) }
  end

  def primary_state(actor)
    actor.instance_variable_get(:@instance_states).fetch('primary')
  end

  # ── D9: actor periodicity ───────────────────────────────────────────────────

  describe 'tick interval (time)' do
    it 'returns the registered nested discovery interval (never nil)' do
      allow(actor).to receive(:settings).and_return(settings)
      expect(actor.time).to be_a(Integer).and be_positive
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

      expect(instances[:primary][:gemini_api_key]).to eq(gemini_key)
    end

    it 'fingerprints the physical id off the resolved key, not the env:// placeholder' do
      allow(actor).to receive(:settings).and_return(settings)
      physical_id = physical_id_for(actor, settings[:instances][:primary])
      fingerprint = Digest::SHA256.hexdigest(gemini_key)[0, 8]

      expect(physical_id).to eq("generativelanguage.googleapis.com:443/ak:#{fingerprint}")
      expect(physical_id).not_to include(Digest::SHA256.hexdigest('env://GEMINI_API_KEY')[0, 8])
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

    it 'includes the default template when its placeholder resolves' do
      template = Legion::Extensions::Llm::Gemini.default_settings.dig(:instances, :default)
      allow(actor).to receive(:settings).and_return({ instances: { default: template } })

      expect(actor.send(:configured_instances)).to have_key(:default)
    end

    it 'does not skip a configured "default" (real API key) — provider-layer claimable set' do
      # v2 parity: 'default' is an ordinary instance label once the operator
      # has actually configured the entry. This asserts the PROVIDER-LAYER
      # decision (configured_instances) only — a full claim through
      # InstanceKey is out of scope here (lex-llm 0.7.2 still reserves the
      # name; the 0.7.3 relaxation is in flight and unpublished).
      configured = {
        instances: {
          default: {
            endpoint: 'https://generativelanguage.googleapis.com/v1beta',
            credentials: { api_key: 'AIzaSyConfiguredDefault' }
          }
        }
      }
      allow(actor).to receive(:settings).and_return(configured)

      instances = actor.send(:configured_instances)

      expect(instances).to have_key(:default)
      expect(instances[:default][:gemini_api_key]).to eq('AIzaSyConfiguredDefault')
    end
  end

  # ── Identity: config name is the instance_id, derived id is physical ───────

  describe 'instance identity (config name + secondary physical id)' do
    it 'publishes the config name as InstanceKey.instance_id with the derived id as physical_id' do
      allow(actor).to receive_messages(settings: settings,
                                       discover_offerings_for_instance: build_offerings(
                                         actor, normalized_primary(actor, settings)
                                       ))
      allow(actor).to receive(:check_health).and_return(readiness[:ready])

      actor.manual

      physical_id = physical_id_for(actor, settings[:instances][:primary])
      record = registry.snapshot.instance(instance_key: key_for('primary', physical_id: physical_id))
      expect(record).not_to be_nil
      expect(record.instance_key.instance_id).to eq('primary')
      expect(record.instance_key.physical_id).to eq(physical_id)
    end

    it 'keeps two config names on the same endpoint as distinct instances' do
      shared = { api_key: 'key-shared', endpoint: 'https://shared.example.com/v1beta' }
      first  = { instances: { apollo: shared, apollo_embed: shared } }
      allow(actor).to receive(:settings).and_return(first)
      allow(actor).to receive_messages(discover_offerings_for_instance: [], check_health: readiness[:ready])

      actor.manual

      expect(registry.snapshot.instance(instance_key: key_for('apollo'))).not_to be_nil
      expect(registry.snapshot.instance(instance_key: key_for('apollo_embed'))).not_to be_nil
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
                                         actor, normalized_primary(actor, settings)
                                       ))
      allow(actor).to receive(:check_health).and_return(readiness[:unready], readiness[:ready])

      actor.manual # initial discovery: claim + readiness FAILED

      key = key_for('primary', physical_id: physical_id_for(actor, settings[:instances][:primary]))
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      actor.manual # tick: retry_initial_activation → readiness passes → activate

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:complete)
    end

    it 'stays initializing while readiness keeps failing' do
      allow(actor).to receive_messages(
        settings: settings,
        discover_offerings_for_instance: build_offerings(actor, normalized_primary(actor, settings)),
        check_health: readiness[:unready]
      )

      actor.manual
      actor.manual
      actor.manual

      key = key_for('primary', physical_id: physical_id_for(actor, settings[:instances][:primary]))
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

      actor.manual
      expect(registry.snapshot.instance(instance_key: key_for('alpha'))).not_to be_nil
      expect(registry.snapshot.instance(instance_key: key_for('beta'))).to be_nil

      actor.manual
      expect(registry.snapshot.instance(instance_key: key_for('alpha'))).to be_nil,
                                                                            'removed instance must be retired'
      expect(registry.snapshot.instance(instance_key: key_for('beta'))).not_to be_nil,
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
        build_offerings(actor, normalized_primary(actor, settings))
      end

      actor.manual # initial activate (sequence 0)
      actor.manual # tick 1
      actor.manual # tick 2

      expect(registry.snapshot.publication_status(instance_key: key_for('primary')).published_sequence)
        .to eq(0), 'unchanged offerings must not bump the publication sequence'
    end

    it 'replaces the snapshot when the model set actually changes' do
      allow(actor).to receive_messages(settings: settings, check_health: readiness[:ready])
      cfg = normalized_primary(actor, settings)
      allow(actor).to receive(:discover_offerings_for_instance)
        .and_return(build_offerings(actor, cfg, model_ids: %w[gemini-2.0-flash]),
                    build_offerings(actor, cfg, model_ids: %w[gemini-2.0-flash gemini-2.5-pro]))

      actor.manual # initial activate with one model
      actor.manual # tick: second model appears → replace

      expect(registry.snapshot.publication_status(instance_key: key_for('primary')).published_sequence)
        .to eq(1)
      expect(registry.snapshot.offerings_for(instance_key: key_for('primary')).size).to eq(2)
    end
  end

  describe 'write-time weight publication on the ordinary actor cadence' do
    let(:live_settings) { full_weight_settings(provider: 110, instance: 115, model: 120, tier: 150) }

    before do
      stub_live_settings(live_settings)
      allow(actor).to receive_messages(settings: settings, check_health: readiness[:ready])
      allow(actor).to receive(:discover_offerings_for_instance) do
        build_offerings(actor, normalized_primary(actor, settings))
      end
    end

    it 'stores the exact four-axis pair and product on drafts built by the production writer' do
      draft = build_offerings(actor, normalized_primary(actor, settings)).first

      expect(draft.weight_inputs).to eq(
        tier: 150, provider: 110, instance: 115, model_or_offering: 120
      )
      expect(draft.base_weight).to eq(227_700_000)
    end

    it 'publishes one replacement for a weight-only change on the next ordinary pass' do
      live_settings[:extensions][:llm][:gemini][:weight] = 100
      actor.manual
      live_settings[:extensions][:llm][:gemini][:weight] = 110

      actor.manual

      key = key_for('primary', physical_id: physical_id_for(actor, settings[:instances][:primary]))
      status = registry.snapshot.publication_status(instance_key: key)
      offering = registry.snapshot.offerings_for(instance_key: key).first
      expect(status.published_sequence).to eq(1)
      expect(offering.weight_inputs[:provider]).to eq(110)
      expect(offering.base_weight).to eq(227_700_000)
    end

    it 'publishes nothing when settings change without changing the weight pair' do
      actor.manual
      live_settings[:extensions][:llm][:gemini][:unrelated] = 'changed'

      actor.manual

      expect(primary_state(actor)[:sequence]).to eq(0)
    end

    it 'preserves zero as a disable component and raises on false' do
      live_settings[:extensions][:llm][:gemini][:weight] = 0
      instance_cfg = normalized_primary(actor, settings)
      expect(build_offerings(actor, instance_cfg).first.weight_inputs[:provider]).to eq(0)

      live_settings[:extensions][:llm][:gemini][:weight] = false
      expect { build_offerings(actor, instance_cfg) }.to raise_error(ArgumentError, /Integer >= 0/)
    end

    it 'logs each dormant weight once, clears on appearance, and logs on re-disappearance' do
      messages = []
      logger = instance_double(Logger).as_null_object
      allow(logger).to receive(:info) do |message = nil, &block|
        messages << (message || block.call)
      end
      allow(actor).to receive(:log).and_return(logger)
      provider = live_settings[:extensions][:llm][:gemini]
      provider[:instances][:ghost] = { weight: 125 }

      actor.manual
      actor.manual
      provider[:instances].delete(:ghost)
      actor.manual
      provider[:instances][:ghost] = { weight: 125 }
      actor.manual

      expected = '[llm][gemini] action=dormant_weight weight_key=[:gemini, :instance, "ghost"] ' \
                 'no_lane_published=true'
      expect(messages.count(expected)).to eq(2)
    end

    it 'does not replace or advance sequence across ten unchanged ordinary passes' do
      actor.manual
      10.times { actor.manual }

      expect(primary_state(actor)[:sequence]).to eq(0)
    end

    it 'does not couple actor cadence or shutdown to the Legion::Settings lifecycle' do
      %i[on_reload reload! reset! off_reload].each do |method_name|
        allow(Legion::Settings).to receive(method_name)
      end

      actor.manual
      actor.shutdown

      %i[on_reload reload! reset! off_reload].each do |method_name|
        expect(Legion::Settings).not_to have_received(method_name)
      end
    end

    it 'serializes interleaved ordinary passes with monotonic publications and matching final cache' do
      actor.manual
      published = []
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_wrap_original do |original, **kwargs|
        published << kwargs
        original.call(**kwargs)
      end
      allow(actor).to receive(:discover_offerings_for_instance) do
        build_offerings(
          actor, normalized_primary(actor, settings), model_ids: Thread.current[:gemini_models]
        )
      end
      threads = [%w[gemini-2.5-pro], %w[gemini-2.5-flash]].map do |model_ids|
        Thread.new do
          Thread.current[:gemini_models] = model_ids
          actor.send(:replace_offerings_if_changed, instance_id: 'primary', state: primary_state(actor))
        end
      end
      threads.each(&:join)

      expect(published.map { |entry| entry[:sequence] }).to eq([1, 2])
      expect(published.map { |entry| entry[:offerings].first.model }.uniq.length).to eq(2)
      expect(primary_state(actor)[:offerings]).to eq(published.last[:offerings])
      expect(primary_state(actor)[:sequence]).to eq(2)
    end

    it 'leaves cache and sequence unchanged on replacement failure and retries on the next pass' do
      actor.manual
      state = primary_state(actor)
      original_offerings = state[:offerings]
      publisher = actor.send(:publisher)
      allow(actor).to receive(:discover_offerings_for_instance)
        .and_return(build_offerings(
                      actor, normalized_primary(actor, settings), model_ids: %w[gemini-2.5-pro]
                    ))
      allow(publisher).to receive(:replace_instance_snapshot).and_raise(StandardError, 'publish failed')

      expect do
        actor.send(:replace_offerings_if_changed, instance_id: 'primary', state: state)
      end.to raise_error(StandardError, 'publish failed')
      expect(state[:sequence]).to eq(0)
      expect(state[:offerings]).to equal(original_offerings)

      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      actor.send(:replace_offerings_if_changed, instance_id: 'primary', state: state)
      expect(state[:sequence]).to eq(1)
      expect(state[:offerings].first.model).to eq('gemini-2.5-pro')
    end

    it 'rebuilds from current settings after draft construction and before initial activation' do
      live_settings[:extensions][:llm][:gemini][:weight] = 100
      entered_readiness = Queue.new
      resume_readiness = Queue.new
      allow(actor).to receive(:check_health) do
        entered_readiness << true
        resume_readiness.pop
        readiness[:ready]
      end

      worker = Thread.new { actor.manual }
      entered_readiness.pop
      live_settings[:extensions][:llm][:gemini][:weight] = 125
      resume_readiness << true
      worker.join

      state = primary_state(actor)
      expect(state[:published]).to be(true)
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(125)
      key = key_for('primary', physical_id: physical_id_for(actor, settings[:instances][:primary]))
      expect(registry.snapshot.offerings_for(instance_key: key).first.weight_inputs[:provider]).to eq(125)
    end

    it 'updates an unpublished cache without replacing or counting it as a dormant match' do
      messages = []
      logger = instance_double(Logger).as_null_object
      allow(logger).to receive(:info) do |message = nil, &block|
        messages << (message || block.call)
      end
      allow(actor).to receive_messages(log: logger, check_health: readiness[:unready])
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      live_settings[:extensions][:llm][:gemini][:weight] = 100
      actor.manual
      live_settings[:extensions][:llm][:gemini][:weight] = 130

      actor.manual

      state = primary_state(actor)
      expect(state[:published]).to be(false)
      expect(state[:offerings].first.weight_inputs[:provider]).to eq(130)
      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(messages).to include(
        '[llm][gemini] action=dormant_weight weight_key=[:gemini, :provider] no_lane_published=true'
      )
    end

    it 'lets removal win a paused readiness race without late activation or display writes' do
      entered_readiness = Queue.new
      resume_readiness = Queue.new
      allow(actor).to receive(:check_health) do
        entered_readiness << true
        resume_readiness.pop
        readiness[:ready]
      end
      allow(actor).to receive(:sync_display_health).and_call_original
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:activate_instance_snapshot).and_call_original

      worker = Thread.new { actor.manual }
      entered_readiness.pop
      state = primary_state(actor)
      actor.send(:drop_instance, instance_id: 'primary', state: state)
      allow(actor).to receive(:settings).and_return({ instances: {} })
      resume_readiness << true
      worker.join

      expect(publisher).not_to have_received(:activate_instance_snapshot)
      expect(actor).not_to have_received(:sync_display_health)
      expect(actor.instance_variable_get(:@instance_states).key?('primary')).to be(false)
    end

    it 'keeps activation state unpublished on publisher failure and permits a later retry' do
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:activate_instance_snapshot).and_raise(StandardError, 'activation failed')

      actor.manual

      state = primary_state(actor)
      expect(state[:published]).to be(false)
      expect(state[:sequence]).to eq(0)
      original_offerings = state[:offerings]

      allow(publisher).to receive(:activate_instance_snapshot).and_call_original
      actor.manual
      expect(state[:published]).to be(true)
      expect(state[:sequence]).to eq(0)
      expect(state[:offerings]).not_to equal(original_offerings)
    end
  end

  # ── D14: settings health hash + capabilities after registry commits ────────

  describe 'settings display health (D14)' do
    it 'writes the legacy 4-key health shape plus capabilities after each registry commit' do
      allow(actor).to receive_messages(settings: settings,
                                       discover_offerings_for_instance: build_offerings(
                                         actor, normalized_primary(actor, settings)
                                       ))
      allow(actor).to receive(:check_health).and_return(readiness[:unready], readiness[:ready])

      actor.manual # initial failure

      health = settings.dig(:instances, :primary, :health)
      expect(health).to include(
        circuit_state: :open, denied: false, available: false, adjustment: -50
      )
      expect(health[:last_probe_outcome]).to eq(:failure)
      expect(health[:reason]).to be_a(String)
      expect(health[:observed_at]).to be_a(Time)
      expect(settings.dig(:instances, :primary, :capabilities)).to include(:completion, :streaming)

      actor.manual # recovery

      health = settings.dig(:instances, :primary, :health)
      expect(health).to include(
        circuit_state: :closed, denied: false, available: true, adjustment: 0
      )
      expect(health[:last_probe_outcome]).to eq(:success)
    end

    it 'keys the health hash by the config name; the registry identity is the name too' do
      allow(actor).to receive_messages(
        settings: settings,
        discover_offerings_for_instance: build_offerings(actor, normalized_primary(actor, settings)),
        check_health: readiness[:ready]
      )

      actor.manual

      physical_id = physical_id_for(actor, settings[:instances][:primary])
      expect(settings[:instances].keys).to include(:primary)
      expect(settings[:instances].keys).not_to include(physical_id.to_sym),
                                               'the derived physical id is never a settings/identity key'
      record = registry.snapshot.instance(instance_key: key_for('primary', physical_id: physical_id))
      expect(record.instance_key.instance_id).to eq('primary')
      expect(settings.dig(:instances, :primary, :health)[:available]).to be(true)
    end

    it 'clears the health hash when the instance is removed' do
      allow(actor).to receive_messages(
        settings: settings,
        discover_offerings_for_instance: build_offerings(actor, normalized_primary(actor, settings)),
        check_health: readiness[:ready]
      )

      actor.manual
      expect(settings.dig(:instances, :primary, :health)).not_to be_nil

      actor.shutdown
      expect(settings.dig(:instances, :primary, :health)).to be_nil
      expect(settings.dig(:instances, :primary, :capabilities)).to be_nil
      expect(registry.snapshot.instance(instance_key: key_for('primary'))).to be_nil
    end
  end
end
