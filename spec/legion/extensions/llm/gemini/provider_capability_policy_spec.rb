# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/gemini/provider'

RSpec.describe Legion::Extensions::Llm::Gemini::Provider do
  describe 'CapabilityPolicy integration' do
    let(:provider) { described_class.new(gemini_api_key: 'test-key') }

    let(:streaming_model) do
      Legion::Extensions::Llm::Model::Info.new(
        id: 'gemini-2.0-flash',
        name: 'Gemini 2.0 Flash',
        provider: :gemini,
        context_length: 1_048_576,
        capabilities: %i[streaming function_calling vision],
        metadata: {
          supported_generation_methods: %w[generateContent streamGenerateContent],
          max_output_tokens: 8192
        }
      )
    end

    let(:embedding_model) do
      Legion::Extensions::Llm::Model::Info.new(
        id: 'gemini-embedding-001',
        name: 'Gemini Embedding',
        provider: :gemini,
        context_length: 2048,
        capabilities: %i[embedding],
        metadata: {
          supported_generation_methods: %w[embedContent],
          max_output_tokens: 1
        }
      )
    end

    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :gemini)
        .and_return({})
    end

    describe 'supportedGenerationMethods mapping' do
      it 'derives streaming from streamGenerateContent with source :model_metadata' do
        offering = provider.send(:offering_from_model, streaming_model)

        expect(offering.capabilities).to include(:streaming)
        expect(offering.capability_sources[:streaming]).to eq({ value: true, source: :model_metadata })
      end

      it 'derives embeddings from embedContent with source :model_metadata' do
        offering = provider.send(:offering_from_model, embedding_model)

        expect(offering.capabilities).to include(:embedding)
        expect(offering.capability_sources[:embedding]).to eq({ value: true, source: :model_metadata })
      end

      it 'does not claim streaming for embedding-only models' do
        offering = provider.send(:offering_from_model, embedding_model)

        expect(offering.capabilities).not_to include(:streaming)
      end
    end

    describe 'provider-root override' do
      before do
        allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
          .with(:extensions, :llm, :gemini)
          .and_return({ tools_flag: false, vision_flag: false })
      end

      it 'suppresses tools and vision via provider config flags' do
        offering = provider.send(:offering_from_model, streaming_model)

        expect(offering.capabilities).not_to include(:tools)
        expect(offering.capabilities).not_to include(:vision)
        expect(offering.capability_sources[:tools]).to eq({ value: false, source: :provider_override })
        expect(offering.capability_sources[:vision]).to eq({ value: false, source: :provider_override })
      end
    end

    describe 'instance override' do
      let(:provider) do
        described_class.new(
          gemini_api_key: 'test-key',
          tools_flag: true,
          vision_flag: true,
          enable_structured_output: true
        )
      end

      it 'enables tools, vision, and structured output via instance config flags' do
        offering = provider.send(:offering_from_model, streaming_model)

        expect(offering.capabilities).to include(:tools, :vision, :structured_output)
        expect(offering.capability_sources[:tools]).to eq({ value: true, source: :instance_override })
        expect(offering.capability_sources[:vision]).to eq({ value: true, source: :instance_override })
        expect(offering.capability_sources[:structured_output]).to eq({ value: true, source: :instance_override })
      end
    end

    describe 'model override' do
      let(:provider) do
        described_class.new(
          gemini_api_key: 'test-key',
          models: { 'gemini-2.0-flash' => { vision_flag: false } }
        )
      end

      it 'applies model-level override with source :model_override' do
        offering = provider.send(:offering_from_model, streaming_model)

        expect(offering.capabilities).not_to include(:vision)
        expect(offering.capability_sources[:vision]).to eq({ value: false, source: :model_override })
      end
    end
  end
end
