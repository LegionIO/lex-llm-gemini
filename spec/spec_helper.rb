# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

require 'legion/extensions/llm'

# Stub the actor runtime before loading Gemini (discovery_refresh.rb guards
# on defined?(Legion::Extensions::Actors::Every) at load time).
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
  end
end

require 'legion/extensions/llm/gemini'

# Load conformance kit from lex-llm gem's spec/ directory
# (spec/ ships in the gem but is NOT on the load path)
if Gem.loaded_specs['lex-llm']
  kit_path = File.join(Gem.loaded_specs['lex-llm'].full_gem_path, 'spec/legion/extensions/llm/conformance')
  Dir[File.join(kit_path, '**', '*.rb')].each { |f| require f }
end

if defined?(Legion::Logging)
  null_logger = Logger.new(File::NULL)
  null_logger.level = Logger::DEBUG
  Legion::Logging.instance_variable_set(:@log, null_logger)
  Legion::Logging.instance_variable_set(
    :@current_settings,
    {
      level: :debug,
      format: :text,
      async: false,
      trace: false,
      trace_size: 0,
      extended: false,
      log_file: nil,
      log_stdout: false,
      include_pid: false,
      color: false
    }.freeze
  )
  Legion::Logging.instance_variable_set(:@configuration_generation, Legion::Logging.configuration_generation + 1)
end
