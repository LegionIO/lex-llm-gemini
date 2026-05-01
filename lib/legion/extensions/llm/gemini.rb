# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/gemini/provider'
require 'legion/extensions/llm/gemini/version'

module Legion
  module Extensions
    # LLM provider framework namespace (reopened by provider extensions).
    module Llm
      # Gemini provider extension namespace.
      module Gemini
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :gemini

        def self.default_settings
          {
            enabled: false,
            default_model: 'gemini-2.0-flash',
            api_key: nil,
            model_whitelist: [],
            model_blacklist: [],
            model_cache_ttl: 3600,
            tls: { enabled: false, verify: :peer },
            instances: {}
          }
        end

        def self.provider_class
          Provider
        end

        def self.discover_instances
          candidates = {}
          discover_from_env(candidates)
          discover_from_settings(candidates)
          CredentialSources.dedup_credentials(candidates)
        end

        def self.discover_from_env(candidates)
          env_key = CredentialSources.env('GEMINI_API_KEY')
          return unless env_key

          candidates[:env] = { api_key: env_key, gemini_api_key: env_key, tier: :cloud }
        end

        def self.discover_from_settings(candidates)
          settings_cfg = CredentialSources.setting(:extensions, :llm, :gemini)
          return unless settings_cfg.is_a?(Hash)

          add_settings_api_key(candidates, settings_cfg)
          add_settings_instances(candidates, settings_cfg)
        end

        def self.add_settings_api_key(candidates, cfg)
          api_key = cfg[:api_key] || cfg['api_key']
          return if api_key.nil? || api_key.to_s.strip.empty?

          candidates[:settings] = { api_key: api_key, gemini_api_key: api_key, tier: :cloud }
        end

        def self.add_settings_instances(candidates, cfg)
          instances = cfg[:instances] || cfg['instances']
          return unless instances.is_a?(Hash)

          instances.each { |name, config| candidates[name.to_sym] = config.merge(tier: :cloud) }
        end

        private_class_method :discover_from_env, :discover_from_settings,
                             :add_settings_api_key, :add_settings_instances
      end

      Configuration.register_provider_options(Gemini::Provider.configuration_options)
    end
  end
end

Legion::Extensions::Llm::Gemini.register_discovered_instances
