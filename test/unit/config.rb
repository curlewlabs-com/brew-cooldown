# frozen_string_literal: true

require "tmpdir"
require_relative "../../lib/brew_cooldown/config"
require_relative "../../lib/brew_cooldown/homebrew/scope"

def invalid(fragment)
  yield
  raise "Expected configuration error containing #{fragment}"
rescue BrewCooldown::ConfigurationError => error
  raise unless error.message.include?(fragment)
end

Dir.mktmpdir("cooldown-config-") do |directory|
  root = Pathname(directory)
  config = BrewCooldown::Config.new({ "scope" => { "brewfile" => "toolchain/Brewfile" },
                                     "cooldown" => { "patch_days" => 9 },
                                     "packages" => { "formula:homebrew/core/python@3.14" => { "patch_days" => 20 } } }, directory: root)
  package = BrewCooldown::PackageId.new(kind: :formula, tap: "homebrew/core", name: "python@3.14")
  raise "Package override ignored" unless config.delays(package) == { patch: 20 }
  raise "Global override ignored" unless config.delays(package.with(name: "git")) == { patch: 9 }
  raise "Configured relative path uses wrong base" unless config.selected_scope.fetch(:brewfile) == root/"toolchain/Brewfile"
  raise "CLI relative path uses wrong base" unless config.selected_scope(brewfile: "Brewfile", directory: root/"elsewhere").fetch(:brewfile) == root/"elsewhere/Brewfile"
  raise "Explicit installed scope did not override config" unless config.selected_scope(installed: true) == { installed: true }
  invalid("Choose") { config.selected_scope(brewfile: "Brewfile", installed: true) }
  invalid("Specify") { BrewCooldown::Config.new({}, directory: root).selected_scope }
  invalid("Unknown configuration") { BrewCooldown::Config.new({ "silent_typo" => 1 }, directory: root) }
  invalid("Unknown cooldown") { BrewCooldown::Config.new({ "cooldown" => { "patch" => 1 } }, directory: root) }
  invalid("canonical package") { BrewCooldown::Config.new({ "packages" => { "python@3.14" => {} } }, directory: root) }
  invalid("nonnegative integer") { BrewCooldown::Config.new({ "cooldown" => { "patch_days" => 0.5 } }, directory: root) }
  invalid("both") { BrewCooldown::Config.new({ "scope" => { "installed" => true, "brewfile" => "Brewfile" } }, directory: root) }
  invalid("must be true") { BrewCooldown::Config.new({ "scope" => { "installed" => false } }, directory: root) }
  invalid("positive integer") { BrewCooldown::Config.new({ "solver" => { "max_assignments" => 0 } }, directory: root) }
  invalid("not found") { BrewCooldown::Config.load(root/"missing.json") }
  (root/"broken.json").write("{")
  invalid("Cannot read") { BrewCooldown::Config.load(root/"broken.json") }

  # Native Brewfile evaluation honors conditions and versioned/tapped names,
  # without calling the installation hook named by an entry.
  brewfile = root/"Brewfile"
  hook_marker = root/"hook-ran"
  brewfile.write(<<~RUBY)
    brew "homebrew/core/python@3.14", postinstall: "touch #{hook_marker}"
    brew "not-selected" if false
    cask "homebrew/cask/codex"
    tap "example/tap"
  RUBY
  entries = BrewCooldown::HomebrewAdapter::Scope.read({ brewfile: }, installed: [])
  raise "Brewfile conditions or identities changed" unless entries.map { |entry| [entry.kind, entry.name] } ==
    [[:formula, "homebrew/core/python@3.14"], [:cask, "homebrew/cask/codex"], [:tap, "example/tap"]]
  raise "Scope evaluation invoked an install hook" if hook_marker.exist?
end
puts "PASS: strict configuration, canonical overrides, scope precedence, relative paths and native Brewfile evaluation"
