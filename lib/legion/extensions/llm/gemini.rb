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
      end

      Configuration.register_provider_options(Gemini::Provider.configuration_options)
    end
  end
end
