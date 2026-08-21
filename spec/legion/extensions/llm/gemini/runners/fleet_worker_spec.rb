# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/gemini/runners/fleet_worker'

FleetWorkerSpecProperties = Class.new unless defined?(FleetWorkerSpecProperties)

RSpec.describe Legion::Extensions::Llm::Gemini::Runners::FleetWorker do
  let(:envelope) do
    {
      request_id: 'req-1', correlation_id: 'cor-1', idempotency_key: 'idem-1',
      operation: 'chat', provider: 'gemini', provider_instance: 'local', model: 'gemini-2.0-flash',
      params: { messages: [] }, reply_to: 'legion-llm.fleet.reply', protocol_version: 2
    }
  end
  # The Subscription framework merges transport metadata into the message hash
  # that is splatted as kwargs into the runner function.
  let(:message) { envelope.merge(routing_key: 'llm.gemini.fleet_worker.#', message_id: 'msg-1') }
  let(:properties) { instance_double(FleetWorkerSpecProperties) }

  it 'delegates fleet execution to the shared lex-llm responder helper' do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    result = described_class.handle_fleet_request(**message, properties: properties)

    expect(result).to eq(:ok)
    expect(Legion::Extensions::Llm::Fleet::ProviderResponder).to have_received(:call).with(
      payload: message.merge(properties: properties),
      provider_family: :gemini,
      delivery: nil,
      properties: properties
    )
  end

  it 'accepts a bare envelope hash with no transport metadata' do
    allow(Legion::Extensions::Llm::Fleet::ProviderResponder).to receive(:call).and_return(:ok)

    expect(described_class.handle_fleet_request(**envelope)).to eq(:ok)
  end
end
