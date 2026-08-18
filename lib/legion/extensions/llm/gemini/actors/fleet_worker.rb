# frozen_string_literal: true

begin
  require 'legion/extensions/actors/subscription'
rescue LoadError
  nil
end

unless defined?(Legion::Extensions::Actors::Subscription)
  raise LoadError, 'LegionIO actor runtime is required for Gemini fleet worker'
end

require 'legion/extensions/llm/gemini'
require 'legion/extensions/llm/gemini/runners/fleet_worker'
require 'legion/extensions/llm/fleet/provider_responder'

module Legion
  module Extensions
    module Llm
      module Gemini
        module Actor
          # Subscription actor for Gemini fleet request consumption.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            # The Subscription dispatch path (use_runner? == false) calls
            # runner_class.send(fn, **message) — a String cannot be send-ed,
            # so the runner must be the resolved module constant.
            def runner_class
              Legion::Extensions::Llm::Gemini::Runners::FleetWorker
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(Gemini.discover_instances)
            end
          end
        end
      end
    end
  end
end
