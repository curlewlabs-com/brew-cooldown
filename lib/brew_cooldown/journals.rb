# frozen_string_literal: true

require_relative "../../prototype/journal"

module BrewCooldown
  # The coordinator owns the set; each native component retains its existing
  # journal lock. Filesystem locks survive parent death while a child owns them.
  class Journals
    def initialize(directory)
      @directory = Pathname(directory)
      @directory.mkpath
    end

    def with_lock
      File.open(@directory/"upgrade.lock", File::RDWR | File::CREAT, 0600) do |lock|
        raise Prototype::Refused, "Another brew-cooldown upgrade or recovery owns #{@directory}" unless
          lock.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end

    def pending
      paths = [@directory/"active.json", *@directory.glob("components/*/active.json")].select(&:file?).sort
      paths.map { |path| Prototype::Journal.new(path.dirname) }
    end

    def component_directory(packages)
      identities = packages.map { |package| [package.kind.to_s, package.tap, package.name] }.sort
      @directory/"components"/Digest::SHA256.hexdigest(JSON.generate(identities))
    end
  end
end
