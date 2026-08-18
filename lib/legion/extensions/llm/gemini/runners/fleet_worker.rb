# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/gemini'

module Legion
  module Extensions
    module Llm
      module Gemini
        module Runners
          # Runner entrypoint for Gemini fleet request execution.
          #
          # The Subscription dispatch path invokes this as
          # runner_class.send(fn, **message) where message is the fleet
          # request envelope merged with transport metadata (routing_key,
          # message_id, headers, ...). The responder parses the envelope out
          # of that hash; unknown keys are inert.
          module FleetWorker
            module_function

            def handle_fleet_request(**opts)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: opts,
                provider_family: Gemini::PROVIDER_FAMILY,
                provider_class: Gemini::Provider,
                provider_instances: -> { Gemini.discover_instances },
                delivery: opts[:delivery],
                properties: opts[:properties]
              )
            end
          end
        end
      end
    end
  end
end
