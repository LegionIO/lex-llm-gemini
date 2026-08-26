# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/gemini/provider'
require 'legion/extensions/llm/gemini/version'
require 'legion/extensions/llm/gemini/helpers/callable'
require 'legion/extensions/llm/gemini/actors/discovery'

module Legion
  module Extensions
    # LLM provider framework namespace (reopened by provider extensions).
    module Llm
      # Gemini provider extension namespace.
      module Gemini
        extend Legion::Logging::Helper
        extend Legion::Extensions::Llm::AutoRegistration

        PROVIDER_FAMILY = :gemini

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://generativelanguage.googleapis.com/v1beta',
              discovery_interval: 3600,
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://GEMINI_API_KEY' },
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed tools]
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
          CredentialSources.dedup_credentials(candidates).transform_values { |config| sanitize_instance_config(config) }
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
                                                                       tier: cfg[:tier] || cfg['tier'] || :cloud)
        end

        def self.add_settings_instances(candidates, cfg)
          instances = cfg[:instances] || cfg['instances']
          return unless instances.is_a?(Hash)

          instances.each do |name, config|
            add_settings_instance(candidates, name, config)
          end
        end

        def self.add_settings_instance(candidates, name, config)
          return unless config.is_a?(Hash)

          normalized = normalize_instance_config(config)
          # enabled: false is a skip, not a credential: a disabled instance
          # is never claimed (the discovery pipeline reads this method as
          # the single claimable source).
          return if normalized[:enabled] == false
          return unless normalized[:gemini_api_key]
          return if unresolved_env_reference?(normalized[:gemini_api_key])

          normalized[:api_key] = normalized[:gemini_api_key]
          normalized[:tier] ||= :cloud
          candidates[name.to_sym] = normalized
        end

        # env:// resolution is the settings host's job (legion-settings
        # Resolver, at boot); a literal placeholder must never be published as
        # a key or fingerprinted.
        def self.unresolved_env_reference?(value)
          value.to_s.start_with?('env://')
        end

        def self.normalize_instance_config(config)
          normalized = symbolize_config_keys(config)
          promote_api_key(normalized)
          promote_api_base(normalized)
          normalized.compact.except(:instances)
        end

        def self.symbolize_config_keys(config)
          config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        end

        def self.promote_api_key(normalized)
          normalized[:gemini_api_key] ||= normalized.delete(:api_key)
          # The registered default template nests the credential at
          # credentials: { api_key: }; the shared pipeline's auth_token
          # consumes that shape, so the catalog must see it too.
          normalized[:gemini_api_key] ||=
            (normalized[:credentials] || {}).is_a?(Hash) ? normalized.dig(:credentials, :api_key) : nil
        end

        def self.promote_api_base(normalized)
          normalized[:gemini_api_base] ||= normalized.delete(:base_url)
          normalized[:gemini_api_base] ||= normalized.delete(:api_base)
          normalized[:gemini_api_base] ||= normalized.delete(:endpoint)
        end

        def self.sanitize_instance_config(config)
          config.except(:api_key)
        end

        private_class_method :discover_from_env, :discover_from_settings,
                             :add_settings_api_key, :add_settings_instances, :add_settings_instance,
                             :unresolved_env_reference?, :normalize_instance_config,
                             :symbolize_config_keys, :promote_api_key, :promote_api_base,
                             :sanitize_instance_config

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options)
      end
    end
  end
end
