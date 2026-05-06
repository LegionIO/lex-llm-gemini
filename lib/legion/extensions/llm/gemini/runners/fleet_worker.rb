# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/gemini/provider'

module Legion
  module Extensions
    module Llm
      module Gemini
        module Runners
          # Runner entrypoint for Gemini fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Gemini::PROVIDER_FAMILY,
                provider_class: Gemini::Provider,
                provider_instances: -> { Gemini.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
