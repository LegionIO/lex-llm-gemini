# frozen_string_literal: true

require 'legion/extensions/llm/discovery/actor'

# The base discovery actor only exists inside the daemon (it inherits the
# LegionIO time-based Every actor). In a standalone load, define nothing.
return unless defined?(Legion::Extensions::Llm::Discovery::Actor)

module Legion
  module Extensions
    module Llm
      module Gemini
        module Actor
          # Gemini discovery actor: an EMPTY subclass of the shared base. The
          # timer, dispatch, and runner-resolution convention are inherited —
          # this class redefines nothing. The Gemini-specific work lives in
          # Gemini::Runners::Discovery, resolved by the base from this
          # namespace.
          class Discovery < Legion::Extensions::Llm::Discovery::Actor; end
        end
      end
    end
  end
end
