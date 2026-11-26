# frozen_string_literal: true

require "global"
require "formulary"
require "digest"
require "tmpdir"
require_relative "../../lib/brew_cooldown/executor/postinstall"
require_relative "../../lib/brew_cooldown/executor/recipe_source"

# A recipe read out of a bottle is a binary string. One carrying a non-ASCII
# byte stopped the post-install worker's map from being written at all, and
# evaluated as binary it would give the recipe's string literals different
# values in the parent than in the worker, which receives UTF-8 from JSON.
Candidate = Data.define(:worker_record)
Map = Data.define(:candidates)

# Each evaluation gets its own path, so Formulary cannot reuse a class it
# already defined from another source.
def evaluated_desc(source, namespace)
  Formulary.from_contents("library", Pathname("/tmp/#{namespace}/library.rb"), source).desc
end

def homebrew_read(bytes)
  Dir.mktmpdir do |directory|
    path = Pathname(directory)/"library.rb"
    path.binwrite(bytes)
    Formulary.formula_contents(path).dup
  end
end

bytes = <<~RUBY.b
  class Library < Formula
    desc "Library \u2014 test fixture"
    url "https://example.com/library-1.0.0.tar.gz"
    sha256 "#{"0" * 64}"
  end
RUBY
raise "Fixture does not carry a non-ASCII byte" if bytes.ascii_only?

native = homebrew_read(bytes)
source = BrewCooldown::Executor::RecipeSource.from_bytes(bytes)
raise "Relabeling changed the recipe's bytes" unless source.b == bytes
raise "Relabeled source differs from Homebrew's own read" unless source == native

record = { "name" => "library", "version" => "1.0.0", "path" => "/tmp/library.rb",
           "recipe" => source, "recipe_sha256" => Digest::SHA256.hexdigest(bytes) }
worker = nil
BrewCooldown::Executor::Postinstall.with_map(Map.new(candidates: { "library" => Candidate.new(record) })) do
  written = JSON.parse(File.binread(ENV.fetch("HOMEBREW_COOLDOWN_WORKER_PLAN"))).fetch(0)
  worker = written.fetch("recipe")
  raise "Recipe digest no longer holds in the worker" unless Digest::SHA256.hexdigest(worker) == record["recipe_sha256"]
end

parent_desc = evaluated_desc(source, "Parent")
raise "Parent and worker evaluate the recipe differently" unless parent_desc == evaluated_desc(worker, "Worker")
raise "Parent and Homebrew evaluate the recipe differently" unless parent_desc == evaluated_desc(native, "Native")

# A recipe may declare a legacy source encoding, which Homebrew honors while
# evaluating it. Relabeling must not refuse one or read it differently.
legacy = <<~RUBY.b
  # encoding: ISO-8859-1
  class Library < Formula
    desc "Caf\xE9 test fixture"
    url "https://example.com/library-1.0.0.tar.gz"
    sha256 "#{"0" * 64}"
  end
RUBY
legacy_desc = evaluated_desc(BrewCooldown::Executor::RecipeSource.from_bytes(legacy), "Legacy")
native_legacy_desc = evaluated_desc(homebrew_read(legacy), "LegacyNative")
raise "A recipe in a declared legacy encoding evaluates differently" unless legacy_desc == native_legacy_desc
raise "Legacy fixture lost its declared encoding" unless legacy_desc.encoding == Encoding::ISO_8859_1

puts "PASS: a non-ASCII recipe evaluates alike in the adapter, its worker and Homebrew"
