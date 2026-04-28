# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/gemini/registry_event_builder'
require 'legion/extensions/llm/gemini/registry_publisher'
require 'legion/extensions/llm/gemini/provider'
require 'legion/extensions/llm/gemini/version'

module Legion
  module Extensions
    module Llm
      # Gemini provider extension namespace.
      module Gemini
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :gemini

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: 'https://generativelanguage.googleapis.com/v1beta',
              tier: :frontier,
              transport: :http,
              credentials: { api_key: 'env://GEMINI_API_KEY' },
              usage: { inference: true, embedding: true },
              limits: { concurrency: 4 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Provider.register(Legion::Extensions::Llm::Gemini::PROVIDER_FAMILY,
                                           Legion::Extensions::Llm::Gemini::Provider)
