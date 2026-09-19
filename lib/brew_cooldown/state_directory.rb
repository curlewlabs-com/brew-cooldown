# frozen_string_literal: true

require "digest"
require "pathname"

module BrewCooldown
  module StateDirectory
    def self.path
      prefix_id = Digest::SHA256.hexdigest(HOMEBREW_PREFIX.realpath.to_s)
      root = Pathname(ENV.fetch("HOMEBREW_COOLDOWN_STATE_HOME") { ENV.fetch("XDG_STATE_HOME") { File.join(Dir.home, ".local/state") } })
      root/"brew-cooldown"/prefix_id
    end
  end
end
