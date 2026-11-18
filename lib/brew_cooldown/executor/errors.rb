# frozen_string_literal: true

module BrewCooldown
  module Executor
    class Refused < StandardError; end
  end
end

# Homebrew reconstructs child exceptions by class name in the parent process,
# so the worker's copy of the class is defined beside the one it mirrors.
module BrewCooldownWorker # rubocop:disable Style/OneClassPerFile
  class Refused < StandardError; end
end
