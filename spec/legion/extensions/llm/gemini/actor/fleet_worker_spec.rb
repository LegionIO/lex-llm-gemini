# frozen_string_literal: true

require 'spec_helper'

module Legion
  module Extensions
    module Actors
      unless const_defined?(:Subscription, false)
        class Subscription
          def initialize(*) = true
        end
      end
    end
  end
end

require 'legion/extensions/llm/gemini/actors/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Gemini::Actor::FleetWorker do
  subject(:actor) { described_class.new }

  it 'resolves the runner to the module constant (Subscription dispatch calls runner_class.send)' do
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Gemini::Runners::FleetWorker)
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  # D13 regression: the Subscription dispatch path (use_runner? == false) runs
  # runner_class.send(fn, **message). A String runner_class raised NoMethodError
  # before the fix — this exercises the exact dispatch shape the framework uses.
  it 'dispatches a fleet message through the framework path (constant runner_class + kwargs)' do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:dispatched)
    message = {
      request_id: 'req-1', provider: 'gemini', provider_instance: 'local',
      routing_key: 'llm.gemini.fleet_worker.#', message_id: 'msg-1'
    }

    expect(actor.runner_class.send(actor.runner_function, **message)).to eq(:dispatched)
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Gemini).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })

    expect(actor.enabled?).to be(true)
  end
end
