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
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://generativelanguage.googleapis.com',
              default_model: 'gemini-2.0-flash',
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://GEMINI_API_KEY' },
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed],
                lanes: [],
                concurrency: 4,
                queue_suffix: nil
              }
            }
          )
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

          candidates[:settings] = normalize_instance_config(cfg).merge(api_key: api_key,
                                                                       gemini_api_key: api_key,
                                                                       tier: :cloud)
        end

        def self.add_settings_instances(candidates, cfg)
          instances = cfg[:instances] || cfg['instances']
          return unless instances.is_a?(Hash)

          instances.each do |name, config|
            next unless config.is_a?(Hash)

            normalized = normalize_instance_config(config)
            next unless normalized[:gemini_api_key]

            candidates[name.to_sym] = normalized.merge(tier: :cloud)
          end
        end

        def self.normalize_instance_config(config) # rubocop:disable Metrics/AbcSize
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:gemini_api_key] ||= normalized[:api_key]
          normalized[:gemini_api_base] ||= normalized.delete(:base_url)
          normalized[:gemini_api_base] ||= normalized.delete(:api_base)
          normalized[:gemini_api_base] ||= normalized.delete(:endpoint)
          normalized.compact.except(:instances)
        end

        private_class_method :discover_from_env, :discover_from_settings,
                             :add_settings_api_key, :add_settings_instances, :normalize_instance_config

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options) if
          Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
      end
    end
  end
end

Legion::Extensions::Llm::Gemini.register_discovered_instances
