# frozen_string_literal: true

require_relative "exact_map"
require "tmpdir"
require "sandbox"

module BrewCooldown
  module Executor
    # The parent owns this temporary handoff until the synchronous worker exits.
    # Nothing in it survives as history or grants permission to a later run.
    module Postinstall
      def self.with_map(map)
        raise Refused, "post-install map already active" if Executor.worker_plan

        Dir.mktmpdir("brew-cooldown-worker-") do |directory|
          stage = Pathname(directory).realpath
          contents = JSON.generate(map.candidates.values.map(&:worker_record))
          (stage/"recipes.json").write(contents)
          FileUtils.copy_file(File.join(__dir__, "worker.rb"), stage/"worker.rb")
          Executor.worker_plan = stage
          with_env(HOMEBREW_COOLDOWN_WORKER_PLAN: (stage/"recipes.json").to_s,
                   HOMEBREW_COOLDOWN_WORKER_DIGEST: Digest::SHA256.hexdigest(contents)) do
            yield
          end
        ensure
          Executor.worker_plan = nil
        end
      end
    end

    module PostinstallSandbox
      def run_or_fork(*args, step:, **options, &configure)
        return super unless step == "running post-install"

        stage = Executor.worker_plan
        expected = (HOMEBREW_LIBRARY_PATH/"postinstall.rb").to_s
        unless stage && args[-2].to_s == expected && args[-3] == "--"
          raise Refused, "unexpected post-install subprocess"
        end
        raise Refused, "post-install requires the native sandbox" unless use_for?(step)

        worker_args = args.dup.insert(-4, "-r", (stage/"worker.rb").to_s)
        super(*worker_args, step:, **options) do |sandbox|
          configure.call(sandbox)
          sandbox.deny_write_path(stage)
          # The native launcher must not start a separate, unconstrained resolver.
          sandbox.deny_read(path: HOMEBREW_BREW_FILE)
        end
      end
    end
  end
end

Sandbox.singleton_class.prepend(BrewCooldown::Executor::PostinstallSandbox)
