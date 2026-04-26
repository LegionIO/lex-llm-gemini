# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Gemini do
  it 'exposes provider defaults with inherited fleet settings' do
    settings = described_class.default_settings

    expect(settings[:provider_family]).to eq(:gemini)
    expect(settings[:fleet]).to include(:enabled)
    expect(settings.dig(:instances, :default, :endpoint)).to eq('https://generativelanguage.googleapis.com')
    expect(settings.dig(:instances, :default, :usage, :embedding)).to be true
  end
end
