# frozen_string_literal: true

module BrewCooldown
  module Executor
    class Refused < StandardError; end
  end
end

# Homebrew reconstructs child exceptions by class name in the parent process.
module BrewCooldownWorker
  class Refused < StandardError; end
end
