# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

# Faraday 2 sets the stream callback as a method on the request options
# object (req.options.on_data = ...). Stubbed transports use a fake request
# whose options is this Struct, which provides the same method form.
FakeStreamOptions = Struct.new(:on_data) unless defined?(FakeStreamOptions)

require 'legion/extensions/llm'

# Stub the LegionIO host-runtime pieces that are not available in the provider
# gem's spec environment before loading Gemini (the production host always
# loads them; a missing runtime must fail loud at require time, not here).
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        class Every
          def self.every_seconds = 3600
        end
      end
    end

    module Helpers
      module Lex; end unless const_defined?(:Lex, false)
    end

    module Core; end unless const_defined?(:Core, false)
  end
end

require 'legion/extensions/llm/gemini'

# Load the conformance kit shared example groups from the lex-llm gem's spec/
# directory (spec/ ships in the gem but is NOT on the load path). Only the
# example-group files — the kit directory also contains lex-llm's own
# self-test specs, which must not run inside a provider gem's suite.
if Gem.loaded_specs['lex-llm']
  %w[ssot_provider_examples.rb ssot_contract_examples.rb].each do |kit_file_name|
    kit_file = File.join(Gem.loaded_specs['lex-llm'].full_gem_path,
                         "spec/legion/extensions/llm/conformance/#{kit_file_name}")
    require kit_file if File.exist?(kit_file)
  end
end

Legion::Logging.setup(
  level: 'debug',
  format: :text,
  async: false,
  trace: false,
  trace_size: 0,
  extended: false,
  log_file: File::NULL,
  log_stdout: false,
  include_pid: false,
  color: false
)
