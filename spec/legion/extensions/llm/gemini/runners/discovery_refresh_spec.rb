# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'faraday'

require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/gemini/runners/discovery'

# Lifecycle coverage for Gemini discovery through the SHARED Discovery::Pipeline:
# the provider-specific boundary of Runners::Discovery (instance catalog +
# credential shape, physical-id fingerprint, catalog fetch + error boundary,
# offering-draft evidence, publish-time weight from the gemini settings path,
# display health) driven by the real pipeline entrypoint `refresh`.
#
# Generic pipeline internals (replace-churn matrix, sequence allocation,
# dormant-weight tracking, probe coalescing, race handling) belong to the
# shared Discovery::Pipeline — lex-llm's specs own them; this spec keeps the
# gemini slice only.
RSpec.describe Legion::Extensions::Llm::Gemini::Runners::Discovery do
  let(:runner) { described_class }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:settings_tree) { Legion::Settings.loader.settings[:extensions][:llm][:gemini] }

  # Plain methods (not lets) to stay under RSpec/MultipleMemoizedHelpers.

  def gemini_key = 'AIzaSySpecKey-Local'

  def ready
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true, reason: 'Gemini models API returned 200', metadata: { status: 200 }
    )
  end

  def unready
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: false, reason: 'Gemini models API returned 401', metadata: { status: 401 }
    )
  end

  # The registered default template shape: a NAMED operator instance whose
  # credential is nested under credentials (provider_settings nesting). The
  # instance identity is the config NAME — the key the router looks up in
  # instances.<name>; the derived host:port/ak id is the secondary physical
  # id only.
  def primary_config(api_key: gemini_key, endpoint: 'https://generativelanguage.googleapis.com/v1beta')
    { endpoint: endpoint, credentials: { api_key: api_key } }
  end

  # The Gemini catalog shape: GET models -> body[:models], entries named
  # `models/<id>`.
  def catalog(model_ids: %w[gemini-2.0-flash])
    model_ids.map do |model_id|
      {
        name: "models/#{model_id}",
        supportedGenerationMethods: %w[generateContent streamGenerateContent],
        inputTokenLimit: 1_048_576,
        outputTokenLimit: 8192
      }
    end
  end

  def primary_instance_config
    Legion::Extensions::Llm::Gemini.discover_instances.fetch(:primary)
  end

  def primary_physical_id
    runner.derive_physical_id(instance_cfg: primary_instance_config)
  end

  def primary_key
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :gemini, instance_id: 'primary', physical_id: primary_physical_id
    )
  end

  def key_for(instance_id)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :gemini, instance_id: instance_id
    )
  end

  def stub_discovery(readiness: ready)
    allow(runner).to receive_messages(
      fetch_raw_models: catalog,
      check_health: readiness
    )
  end

  before do
    registry.reset!
    runner.reset_state!
    settings_tree.replace({})
  end

  after do
    registry.reset!
    runner.reset_state!
    settings_tree.replace({})
  end

  # GEMINI_API_KEY feeds the provider's :env candidate in
  # discover_instances; keep it out of the settings-path tests so the
  # configured instance is the only claimable one.
  around do |example|
    original = ENV.delete('GEMINI_API_KEY')
    example.run
  ensure
    ENV['GEMINI_API_KEY'] = original unless original.nil?
  end

  # ── D9: actor periodicity ───────────────────────────────────────────────────

  describe 'tick interval (actor time)' do
    let(:actor) { Legion::Extensions::Llm::Gemini::Actor::Discovery.new }

    it 'returns the registered nested discovery interval' do
      settings_tree.replace(instances: { default: { discovery_interval: 3600 } })
      expect(actor.time).to eq(3600)
    end

    it 'honors an operator override of the nested interval' do
      settings_tree.replace(instances: { default: { discovery_interval: 60 } })
      expect(actor.time).to eq(60)
    end

    it 'falls back to the registered default (300) when the interval is missing or non-positive' do
      expect(actor.time).to eq(300)

      settings_tree.replace(instances: { default: { discovery_interval: 0 } })
      expect(actor.time).to eq(300)

      settings_tree.replace(instances: { default: { discovery_interval: nil } })
      expect(actor.time).to eq(300)
    end
  end

  # ── P1-4: instance credential resolution (provider-layer catalog) ──────────

  describe 'instance credential resolution' do
    it 'surfaces a named instance configured with the registered nested credentials shape' do
      settings_tree.replace(instances: { primary: primary_config })
      instances = Legion::Extensions::Llm::Gemini.discover_instances

      expect(instances[:primary]).to include(gemini_api_key: gemini_key, tier: :cloud)
      expect(instances[:primary]).not_to have_key(:api_key)
    end

    it 'skips a nested credential that is still an unresolved env:// placeholder' do
      settings_tree.replace(instances: { primary: primary_config(api_key: 'env://GEMINI_API_KEY') })

      expect(Legion::Extensions::Llm::Gemini.discover_instances).to be_empty
    end

    it 'skips instances with no credentials at all' do
      settings_tree.replace(
        instances: { naked: { endpoint: 'https://generativelanguage.googleapis.com/v1beta' } }
      )

      expect(Legion::Extensions::Llm::Gemini.discover_instances).to be_empty
    end

    it 'does not skip a configured "default" carrying a real API key' do
      settings_tree.replace(instances: { default: primary_config(api_key: 'AIzaSyConfiguredDefault') })

      instances = Legion::Extensions::Llm::Gemini.discover_instances

      expect(instances).to have_key(:default)
      expect(instances[:default][:gemini_api_key]).to eq('AIzaSyConfiguredDefault')
    end

    it 'surfaces the :env instance from GEMINI_API_KEY' do
      ENV['GEMINI_API_KEY'] = 'gk-env-1'

      expect(Legion::Extensions::Llm::Gemini.discover_instances[:env])
        .to include(gemini_api_key: 'gk-env-1', tier: :cloud)
    end
  end

  # ── Identity: config name is the instance_id, derived id is physical ───────

  describe 'instance identity (config name + secondary physical id)' do
    it 'fingerprints the physical id off the resolved key, not the env:// placeholder' do
      settings_tree.replace(instances: { primary: primary_config })
      fingerprint = Digest::SHA256.hexdigest(gemini_key)[0, 8]

      expect(primary_physical_id).to eq("generativelanguage.googleapis.com:443/ak:#{fingerprint}")
      expect(primary_physical_id)
        .not_to include(Digest::SHA256.hexdigest('env://GEMINI_API_KEY')[0, 8])
    end

    it 'publishes the config name as InstanceKey.instance_id with the derived id as physical_id' do
      settings_tree.replace(instances: { primary: primary_config })
      stub_discovery
      runner.refresh

      record = registry.snapshot.instance(instance_key: primary_key)
      expect(record).not_to be_nil
      expect(record.instance_key.instance_id).to eq('primary')
      expect(record.instance_key.physical_id).to eq(primary_physical_id)
    end

    it 'keeps two config names on the same endpoint as distinct instances' do
      shared_endpoint = 'https://shared.example.com/v1beta'
      settings_tree.replace(
        instances: {
          apollo: primary_config(api_key: 'key-apollo', endpoint: shared_endpoint),
          apollo_embed: primary_config(api_key: 'key-apollo-embed', endpoint: shared_endpoint)
        }
      )
      stub_discovery
      runner.refresh

      expect(registry.snapshot.instance(instance_key: key_for('apollo'))).not_to be_nil
      expect(registry.snapshot.instance(instance_key: key_for('apollo_embed'))).not_to be_nil
    end
  end

  # ── D16: discovery error boundary — programming errors must not become [] ──

  describe 'discovery error boundary (D16)' do
    def cfg_and_key
      settings_tree.replace(instances: { primary: primary_config })
      [primary_instance_config, primary_key]
    end

    it 'propagates programming errors instead of publishing zero offerings' do
      cfg, key = cfg_and_key
      allow(runner).to receive(:fetch_raw_models).and_raise(NameError, "undefined method 'id'")

      expect { runner.build_offerings(instance_cfg: cfg, instance_key: key) }.to raise_error(NameError)

      allow(runner).to receive(:fetch_raw_models).and_raise(ArgumentError, 'bad catalog entry')
      expect { runner.build_offerings(instance_cfg: cfg, instance_key: key) }.to raise_error(ArgumentError)
    end

    it 'wraps a transport failure in CatalogFetchFailure (never a zero-offering success)' do
      cfg, key = cfg_and_key
      allow(runner).to receive(:fetch_raw_models)
        .and_raise(Faraday::ConnectionFailed.new('connection refused'))

      expect { runner.build_offerings(instance_cfg: cfg, instance_key: key) }
        .to raise_error(Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure)
    end

    it 'keeps the last published snapshot when the catalog fetch fails on a tick' do
      settings_tree.replace(instances: { primary: primary_config })
      stub_discovery
      runner.refresh
      expect(registry.snapshot.lanes_for(instance_key: primary_key).size).to eq(1)

      allow(runner).to receive(:fetch_raw_models)
        .and_raise(Faraday::ConnectionFailed.new('connection refused'))
      runner.refresh

      expect(registry.snapshot.publication_status(instance_key: primary_key).published_sequence).to eq(0)
      expect(registry.snapshot.lanes_for(instance_key: primary_key).size).to eq(1)
    end
  end

  # ── D4: recovery after initial readiness failure ───────────────────────────

  describe 'initial readiness failure recovery' do
    it 'activates the instance on a later tick once readiness passes' do
      settings_tree.replace(instances: { primary: primary_config })
      allow(runner).to receive(:fetch_raw_models).and_return(catalog)
      allow(runner).to receive(:check_health).and_return(unready, ready)

      runner.refresh # initial discovery: claim + readiness FAILED

      expect(registry.snapshot.instance(instance_key: primary_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: primary_key).state).to eq(:initializing)

      runner.refresh # tick: retry initial activation — readiness passes

      expect(registry.snapshot.instance(instance_key: primary_key).availability.state).to eq(:available)
      expect(registry.snapshot.publication_status(instance_key: primary_key).state).to eq(:complete)
    end

    it 'stays initializing while readiness keeps failing' do
      settings_tree.replace(instances: { primary: primary_config })
      stub_discovery(readiness: unready)

      3.times { runner.refresh }

      expect(registry.snapshot.instance(instance_key: primary_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: primary_key).state).to eq(:initializing)
    end
  end

  # ── D4/tick reconcile: late-configured and removed instances ───────────────

  describe 'tick reconciliation' do
    it 'adds instances that appear in settings after boot and removes ones that disappear' do
      alpha = { endpoint: 'https://alpha.example.com/v1beta', credentials: { api_key: 'key-alpha' } }
      beta  = { endpoint: 'https://beta.example.com/v1beta', credentials: { api_key: 'key-beta' } }
      settings_tree.replace(instances: { alpha: alpha })
      stub_discovery

      runner.refresh
      expect(registry.snapshot.instance(instance_key: key_for('alpha'))).not_to be_nil
      expect(registry.snapshot.instance(instance_key: key_for('beta'))).to be_nil

      settings_tree[:instances].replace(beta: beta)
      runner.refresh

      expect(registry.snapshot.instance(instance_key: key_for('alpha')))
        .to be_nil, 'removed instance must be retired'
      expect(registry.snapshot.instance(instance_key: key_for('beta')))
        .not_to be_nil, 'late instance must be claimed'
    end
  end

  # ── P3-7: no replace churn when the catalog is unchanged ───────────────────

  describe 'snapshot replace (publish-time evidence)' do
    it 'does not bump the publication sequence when the catalog is unchanged' do
      settings_tree.replace(instances: { primary: primary_config })
      stub_discovery

      3.times { runner.refresh }

      expect(registry.snapshot.publication_status(instance_key: primary_key).published_sequence).to eq(0)
    end

    it 'publishes a replacement when the model set actually changes' do
      settings_tree.replace(instances: { primary: primary_config })
      allow(runner).to receive(:check_health).and_return(ready)
      allow(runner).to receive(:fetch_raw_models)
        .and_return(catalog(model_ids: %w[gemini-2.0-flash]),
                    catalog(model_ids: %w[gemini-2.0-flash gemini-2.5-pro]))

      runner.refresh # initial activate with one model
      runner.refresh # tick: second model appears

      expect(registry.snapshot.publication_status(instance_key: primary_key).published_sequence).to eq(1)
      expect(registry.snapshot.lanes_for(instance_key: primary_key).size).to eq(2)
    end
  end

  # ── Write-time weight publication from the gemini settings path ────────────

  describe 'write-time weight publication (gemini settings path)' do
    around do |example|
      root = Legion::Settings.loader.settings
      original_llm = root[:llm]
      example.run
    ensure
      root[:llm] = original_llm
    end

    def configure_weights(provider: 110, instance: 115, model: 120, tier: 150)
      settings_tree.replace(
        weight: provider,
        instances: {
          primary: {
            endpoint: 'https://generativelanguage.googleapis.com/v1beta',
            tier: :frontier,
            credentials: { api_key: gemini_key },
            weight: instance,
            models: { 'gemini-2.0-flash' => { weight: model } }
          }
        }
      )
      Legion::Settings.loader.settings[:llm] = { routing: { tier_weights: { frontier: tier } } }
    end

    it 'stores the exact four-axis pair and product on the published lane' do
      configure_weights
      stub_discovery
      runner.refresh

      lane = registry.snapshot.lanes_for(instance_key: primary_key).first
      expect(lane.weight_inputs).to eq(tier: 150, provider: 110, instance: 115, model_or_offering: 120)
      expect(lane.base_weight).to eq(227_700_000)
      expect(lane.base_weight).to eq(lane.weight_inputs.values.reduce(1, :*))
    end

    it 'publishes one replacement and updates the lane when a weight-only settings change lands' do
      configure_weights
      stub_discovery
      runner.refresh

      settings_tree[:weight] = 100
      runner.refresh

      expect(registry.snapshot.publication_status(instance_key: primary_key).published_sequence).to eq(1)
      lane = registry.snapshot.lanes_for(instance_key: primary_key).first
      expect(lane.weight_inputs).to eq(tier: 150, provider: 100, instance: 115, model_or_offering: 120)
      expect(lane.base_weight).to eq(207_000_000)
    end
  end

  # ── D14: settings display health after registry commits ────────────────────

  describe 'settings display health (D14)' do
    it 'writes the 5-key health hash into the instance settings after each registry commit' do
      settings_tree.replace(instances: { primary: primary_config })
      allow(runner).to receive(:fetch_raw_models).and_return(catalog)
      allow(runner).to receive(:check_health).and_return(unready, ready)

      runner.refresh # initial failure

      health = settings_tree.dig(:instances, :primary, :health)
      expect(health.keys).to match_array(%i[state reason observed_at last_probe_outcome source])
      expect(health[:state]).to eq(:initializing)
      expect(health[:last_probe_outcome]).to eq(:failure)
      expect(health[:source]).to eq(:startup_readiness)
      expect(health[:reason]).to be_a(String)
      expect(settings_tree.dig(:instances, :primary, :capabilities)).to eq([])

      runner.refresh # recovery

      health = settings_tree.dig(:instances, :primary, :health)
      expect(health[:state]).to eq(:available)
      expect(health[:last_probe_outcome]).to eq(:success)
      expect(settings_tree.dig(:instances, :primary, :capabilities)).to include(:completion, :streaming)
    end

    it 'keys the health hash by the config name; the registry identity is the name too' do
      settings_tree.replace(instances: { primary: primary_config })
      stub_discovery
      runner.refresh

      expect(settings_tree[:instances].keys).to include(:primary)
      expect(settings_tree[:instances].keys).not_to include(primary_physical_id.to_sym),
                                                    'the derived physical id is never a settings/identity key'
      record = registry.snapshot.instance(instance_key: primary_key)
      expect(record.instance_key.instance_id).to eq('primary')
      expect(settings_tree.dig(:instances, :primary, :health)[:state]).to eq(:available)
    end

    it 'clears the health hash and registry state when the actor shuts down' do
      settings_tree.replace(instances: { primary: primary_config })
      stub_discovery
      runner.refresh
      expect(settings_tree.dig(:instances, :primary, :health)).not_to be_nil

      Legion::Extensions::Llm::Gemini::Actor::Discovery.new.shutdown

      expect(settings_tree.dig(:instances, :primary, :health)).to be_nil
      expect(settings_tree.dig(:instances, :primary, :capabilities)).to be_nil
      expect(registry.snapshot.instance(instance_key: primary_key)).to be_nil
      expect(runner.states.keys).to be_empty
    end
  end
end
