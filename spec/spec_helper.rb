# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

# Faraday 2 sets the stream callback as a method on the request options
# object (req.options.on_data = ...). Stubbed transports use a fake request
# whose options is this Struct, which provides the same method form.
FakeStreamOptions = Struct.new(:on_data) unless defined?(FakeStreamOptions)

require 'legion/extensions/llm'

require 'legion/settings'
require 'legion/logging'

# Load the declared host test dependency without starting services or actors.
require 'legion/transport'
require 'legion/extensions/helpers/lex'
require 'legion/extensions/actors/every'
require 'legion/extensions/actors/subscription'

require 'legion/extensions/llm/gemini'

# Seed the gemini extension settings subtree so specs can drive the real
# Legion::Settings tree (CredentialSources.setting, the pipeline's weight
# reads, and the D14 display write-back all read this same live object).
settings_root = Legion::Settings.loader.settings
settings_root[:extensions][:llm] ||= {}
settings_root[:extensions][:llm][:gemini] ||= {}

# Load the conformance kit shared example groups from the lex-llm gem's spec/
# directory (spec/ ships in the gem but is NOT on the load path). Only the
# example-group files — the kit directory also contains lex-llm's own
# self-test specs, which must not run inside a provider gem's suite.
conformance_dir = File.join(Gem.loaded_specs.fetch('lex-llm').full_gem_path,
                            'spec', 'legion', 'extensions', 'llm', 'conformance')
%w[ssot_provider_examples.rb ssot_contract_examples.rb].each do |kit_file_name|
  require File.join(conformance_dir, kit_file_name)
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
