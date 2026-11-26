# frozen_string_literal: true

module BrewCooldown
  module Executor
    # How a recipe's bytes become the Ruby source the adapter evaluates.
    module RecipeSource
      # Ruby evaluates a string in that string's own encoding unless the recipe
      # declares another. A recipe read out of a bottle or a downloaded archive
      # arrives binary, while Homebrew reads a recipe file as UTF-8 without
      # validating it (Formulary.formula_contents) and the post-install worker
      # receives it as UTF-8 from JSON. Relabeling the same way keeps the bytes
      # the recipe digest covers, so every evaluation of one recipe reads the
      # same source; a non-ASCII byte left in a binary string also stops
      # JSON.generate writing the worker's map.
      def self.from_bytes(bytes)
        bytes.b.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
