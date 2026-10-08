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
          originals = []
          records = map.candidates.values.map do |candidate|
            record = candidate.worker_record
            if candidate.respond_to?(:release_archive?) && candidate.release_archive?
              path = stage/"#{candidate.formula.name}.rb"
              path.write(record.fetch("recipe"))
              formula = candidate.formula
              %i[path specified_path].each do |method|
                originals << [formula, method, formula.method(method)]
                formula.define_singleton_method(method) { path }
              end
              resource = formula.resource
              archive = stage/"#{formula.name}-#{Pathname(URI(resource.url).path).basename}"
              FileUtils.copy_file(resource.cached_download, archive)
              resource.verify_download_integrity(archive)
              downloader = resource.downloader
              %i[cached_location fetch].each { |method| originals << [downloader, method, downloader.method(method)] }
              downloader.define_singleton_method(:cached_location) { archive }
              downloader.define_singleton_method(:fetch) { |timeout: nil| resource.verify_download_integrity(archive) }
              record = record.merge("path" => path.to_s, "archive_path" => archive.to_s,
                                    "archive_sha256" => resource.checksum.hexdigest)
            end
            record
          end
          # Native source installation copies formula.path into the receipt.
          # The sandbox-protected snapshot binds that copy to the evaluated
          # recipe even if a shared download cache changes during execution.
          # Release archives use the same private, verified download snapshot.
          contents = JSON.generate(records)
          (stage/"recipes.json").write(contents)
          FileUtils.copy_file(File.join(__dir__, "worker.rb"), stage/"worker.rb")
          Executor.worker_plan = stage
          with_env(HOMEBREW_COOLDOWN_WORKER_PLAN: (stage/"recipes.json").to_s,
                   HOMEBREW_COOLDOWN_WORKER_DIGEST: Digest::SHA256.hexdigest(contents)) do
            yield
          end
        ensure
          originals&.each do |formula, method, original|
            formula.define_singleton_method(method, original)
          end
          Executor.worker_plan = nil
        end
      end
    end

    module PostinstallSandbox
      def run_or_fork(*args, step:, **options, &configure)
        return super unless ["running post-install", "building"].include?(step)

        stage = Executor.worker_plan
        script = step == "building" ? "build.rb" : "postinstall.rb"
        expected = (HOMEBREW_LIBRARY_PATH/script).to_s
        separator = args.index("--")
        unless stage && separator && args[separator + 1].to_s == expected
          raise Refused, "unexpected #{step} subprocess"
        end
        raise Refused, "#{step} requires the native sandbox" unless use_for?(step)

        worker_args = args.dup.insert(separator, "-r", (stage/"worker.rb").to_s)
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
