# frozen_string_literal: true

require "json"
require_relative "../../lib/brew_cooldown/homebrew/cask_history"

fixture = JSON.parse(File.read(File.join(__dir__, "../fixtures/cask_history.json")))
current = BrewCooldown::HomebrewAdapter::CurrentCask.validate(fixture.fetch("current"), name: "codex")
log = ->(**_event) {}
history = BrewCooldown::HomebrewAdapter::CaskHistory.new(current:, log:, request: lambda do |url|
  uri = URI(url)
  query = URI.decode_www_form(uri.query).to_h
  raise "Wrong history authority" unless uri.host == "api.github.com"
  if uri.path.end_with?("/commits")
    raise "History was not anchored to current source" unless query["sha"] == current.fetch("tap_git_head")
    fixture.fetch("commits")
  else
    fixture.fetch("contents").fetch(query.fetch("ref"))
  end
end)
entries = history.entries
entry = entries.find { |record| record.commit == "00799c30022f4a3b89f837f8137387a298717a9f" }
raise "Recorded publication date changed" unless entry.published_at == Time.iso8601("2026-07-18T15:51:23Z")
record = history.source_record(entry)
raise "Wrong immutable source checksum" unless record.fetch("source_sha256") == "508e4115af80643a04f873bace7929a39f47019edd6738e5ebbede8641f88977"

# A returned blob cannot inherit an official commit's authority after its
# content changes, even if the response still advertises the old blob ID.
corrupt = fixture.fetch("contents").fetch(entry.commit).merge("content" => ["changed recipe\n"].pack("m0"))
begin
  BrewCooldown::HomebrewAdapter::CaskHistory.new(current:, log:, request: ->(_url) { corrupt }).source_record(entry)
rescue BrewCooldown::HomebrewAdapter::RegistryError => error
  raise unless error.message.include?("blob differs")
  rejected = true
end
raise "Changed recipe blob accepted" unless rejected

# Missing age evidence starts the existing observation fallback; it cannot
# borrow a date from another release or silently become an old candidate.
undated = fixture.fetch("commits").first.merge("commit" => { "committer" => {} })
fallback = BrewCooldown::HomebrewAdapter::CaskHistory.new(current:, log:, request: ->(_url) { [undated] }).entries.first
raise "Missing publication time became an age" unless fallback.published_at.nil?
begin
  BrewCooldown::HomebrewAdapter::CaskHistory.new(current:, log:, request: ->(_url) { [undated, undated] }).entries.to_a
rescue BrewCooldown::HomebrewAdapter::RegistryError
  duplicate_rejected = true
end
raise "Repeated history accepted" unless duplicate_rejected
begin
  BrewCooldown::HomebrewAdapter::CaskHistory.new(current:, log:, request: ->(_url) { [] }).entries.first
rescue BrewCooldown::HomebrewAdapter::RegistryError => error
  raise unless error.message.include?("history is empty")
  empty_rejected = true
end
raise "Empty official history looked like a cask without releases" unless empty_rejected

# A retained historical download must not evade Homebrew's current rollback.
begin
  BrewCooldown::HomebrewAdapter::CurrentCask.verify_candidate!(current.merge("version" => "0.144.5"), "0.144.6")
rescue BrewCooldown::HomebrewAdapter::RegistryError => error
  raise unless error.message.include?("possible rollback")
  rollback_rejected = true
end
raise "Candidate ahead of current Homebrew accepted" unless rollback_rejected

# GitHub's full page is not evidence that history has ended. Keep following
# the anchored query until its final shorter page, even across a page boundary.
full_page = 100.times.map do |index|
  fixture.fetch("commits").first.merge("sha" => index.to_s(16).rjust(40, "0"))
end
pages = []
paginated_history = BrewCooldown::HomebrewAdapter::CaskHistory.new(current:, log:, request: lambda do |url|
  page = URI.decode_www_form(URI(url).query).to_h.fetch("page")
  pages << page
  page == "1" ? full_page : fixture.fetch("commits")
end)
paginated = paginated_history.entries.to_a
raise "History pagination dropped a later candidate" unless paginated.last.commit == fixture.fetch("commits").last.fetch("sha") &&
  paginated.length == full_page.length + fixture.fetch("commits").length

# Discovery stops at the installed version and revalidation at the selected
# commit. Neither may pay for the older pages of a long-lived cask's history.
pages.clear
found = paginated_history.entries.find { |record| record.commit == full_page.last.fetch("sha") }
raise "Early stop lost the requested commit" unless found
raise "A caller that stopped early still fetched later pages: #{pages}" unless pages == ["1"]

[current.merge("disabled" => true), current.merge("tap" => "elsewhere/cask"),
 current.merge("ruby_source_path" => "../codex.rb"), current.merge("version" => "latest")].each do |invalid|
  begin
    BrewCooldown::HomebrewAdapter::CurrentCask.validate(invalid, name: "codex")
  rescue BrewCooldown::HomebrewAdapter::RegistryError
    next
  end
  raise "Invalid current cask source accepted"
end
puts "PASS: official cask source anchoring, immutable blob identity, publication evidence and withdrawals"
