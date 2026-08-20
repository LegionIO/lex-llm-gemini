# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/gemini/provider'

# The 0.8.0 canonical funnel contract (08 F3, 05 O4): chat/stream_chat take
# the canonical messages positionally (the single completion funnel),
# temperature lives only in Canonical::Params (no kwarg), and the
# side-channel operations keep their keyword shapes.
RSpec.describe Legion::Extensions::Llm::Gemini::Provider do
  it 'takes the canonical messages positionally in the completion funnel' do
    %i[chat stream_chat].each do |method_name|
      params = described_class.instance_method(method_name).parameters
      expect(params).to include(%i[req messages]), "#{method_name}: positional canonical messages (0.8.0 funnel)"
    end
  end

  it 'has no temperature kwarg (05 O4: it lives in Canonical::Params)' do
    %i[chat stream_chat].each do |method_name|
      params = described_class.instance_method(method_name).parameters
      expect(params).not_to include(%i[key temperature]), "#{method_name}: temperature lives in Canonical::Params"
    end
  end

  it 'exposes keyword-only side-channel operations' do
    expect(described_class.instance_method(:embed).parameters).not_to include(%i[req text])
    expect(described_class.instance_method(:count_tokens).parameters).not_to include(%i[req messages])
    expect(described_class.instance_method(:image).parameters).not_to include(%i[req prompt])
  end
end
