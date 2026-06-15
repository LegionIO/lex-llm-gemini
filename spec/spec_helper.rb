# frozen_string_literal: true

require 'bundler/setup'
require 'legion/extensions/llm'

Legion::Extensions::Llm.config.logger = Logger.new(File::NULL)
Legion::Logging.setup(level: 'fatal', log_file: File::NULL, log_stdout: false, async: false, color: false)

require 'legion/extensions/llm/gemini'
