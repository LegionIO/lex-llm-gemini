# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/gemini/provider_settings'
require 'legion/extensions/llm/gemini/version'

module Legion
  module Extensions
    module Llm
      # Gemini provider extension namespace.
      module Gemini
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :gemini

        def self.default_settings
          ProviderSettings.build(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://generativelanguage.googleapis.com',
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://GEMINI_API_KEY' },
              usage: { inference: true, embedding: true },
              limits: { concurrency: 4 }
            }
          )
        end
      end
    end
  end
end
