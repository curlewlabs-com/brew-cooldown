# frozen_string_literal: true

require_relative "../../lib/brew_cooldown/homebrew/registry"

FIXTURES = Pathname(__dir__).parent/"fixtures/registry"
INDEX_BODY = (FIXTURES/"index.json").read
PLATFORM_BODY = (FIXTURES/"platform.json").read
PAGE = JSON.parse((FIXTURES/"page.json").read)

def expect_error(fragment)
  yield
  raise "Expected registry error containing #{fragment}"
rescue BrewCooldown::HomebrewAdapter::RegistryError => error
  raise unless error.message.include?(fragment)
end

class RecordedRegistry
  attr_reader :requests

  def initialize(responses: [], immutable: {})
    @responses, @immutable, @requests = responses, immutable, []
  end

  def fresh(url)
    @requests << url
    value = @responses.shift
    raise value if value.is_a?(Exception)
    raise "Unexpected fresh request: #{url}" unless value

    value
  end

  def immutable(name:, digest:)
    raise "Unexpected fixture package" unless name == "pcre2"

    @immutable.fetch(digest)
  end
end

def response(body, headers = {})
  BrewCooldown::HomebrewAdapter::RegistryResponse.new(body:, headers:)
end

def registry(transport)
  BrewCooldown::HomebrewAdapter::Registry.new(transport:)
end

first = response(JSON.generate(PAGE.fetch("body")), "link" => PAGE.fetch("link"))
last = response(JSON.generate("name" => "homebrew/core/pcre2", "tags" => ["10.47"]))
transport = RecordedRegistry.new(responses: [first, last])
tags = registry(transport).tags("pcre2", page_size: 5)
raise "History lost paginated entries" unless tags == [*PAGE.fetch("body").fetch("tags"), "10.47"]
raise "Relative pagination was resolved incorrectly" unless transport.requests.last ==
  "https://ghcr.io/v2/homebrew/core/pcre2/tags/list?last=10.38_1&n=5"

# No prefix of the history is a successful answer after a later page fails.
transport = RecordedRegistry.new(responses: [first, BrewCooldown::HomebrewAdapter::RegistryError.new("network failed")])
expect_error("network failed") { registry(transport).tags("pcre2", page_size: 5) }
[
  '<https://elsewhere.example/v2/homebrew/core/pcre2/tags/list>; rel="next"',
  '</v2/homebrew/core/another/tags/list>; rel="next"',
  '<https://credentials@ghcr.io/v2/homebrew/core/pcre2/tags/list>; rel="next"',
  '<http://ghcr.io/v2/homebrew/core/pcre2/tags/list>; rel="next"',
].each do |link|
  transport = RecordedRegistry.new(responses: [first.with(headers: { "link" => link })])
  expect_error("left the package") { registry(transport).tags("pcre2") }
  raise "Unexpected origin was requested" unless transport.requests.length == 1
end
transport = RecordedRegistry.new(responses: [first.with(headers: { "link" => '</v2/homebrew/core/pcre2/tags/list?n=5>; rel="next"' })])
expect_error("repeated a page") { registry(transport).tags("pcre2", page_size: 5) }
transport = RecordedRegistry.new(responses: [first.with(headers: { "link" => "unrecognized" })])
expect_error("Unsupported registry pagination") { registry(transport).tags("pcre2") }
transport = RecordedRegistry.new(responses: [response('{"name":"wrong","tags":[]}')])
expect_error("Invalid tag list") { registry(transport).tags("pcre2") }
expect_error("unqualified core") { registry(RecordedRegistry.new).tags("../private") }

index = JSON.parse(INDEX_BODY)
platform = JSON.parse(PLATFORM_BODY)
index_digest = Digest::SHA256.hexdigest(INDEX_BODY)
platform_digest = Digest::SHA256.hexdigest(PLATFORM_BODY)
transport = RecordedRegistry.new(
  responses: [response(INDEX_BODY, "docker-content-digest" => "sha256:#{index_digest}")],
  immutable: { index_digest => index, platform_digest => platform },
)
metadata = registry(transport).resolve("pcre2", "10.47", platform: :arm64_tahoe)
raise "Wrong historical bottle" unless metadata.bottle_sha256 == "10bd8c1cf3784ab8a736f01b7f85d091276d69c5a8d48bd022b01209fb4eb870"
raise "Wrong platform publication" unless metadata.published_at == Time.iso8601("2025-10-21T11:24:29Z")

# A moving tag cannot substitute other bytes under a previously claimed digest.
transport = RecordedRegistry.new(responses: [response(INDEX_BODY + " ", "docker-content-digest" => "sha256:#{index_digest}")])
expect_error("no matching immutable digest") { registry(transport).resolve("pcre2", "10.47", platform: :arm64_tahoe) }

def metadata_reader(index = JSON.parse(INDEX_BODY))
  BrewCooldown::HomebrewAdapter::RegistryMetadata.new(name: "pcre2", tag: "10.47", platform: :arm64_tahoe,
                                                     index:, index_sha256: Digest::SHA256.hexdigest(INDEX_BODY))
end

# Native selection, including older-OS fallback, must decide which platform
# to evaluate. Merely matching the host's current tag would strand old bottles.
if Utils::Bottles.tag.to_sym == :arm64_tahoe
  automatic = BrewCooldown::HomebrewAdapter::RegistryMetadata.new(name: "pcre2", tag: "10.47", platform: nil,
                                                                index:, index_sha256: index_digest)
  raise "Native platform selection changed" unless automatic.complete(platform).platform == "arm64_tahoe"
  older = Marshal.load(Marshal.dump(index))
  older["manifests"].reject! { |entry| entry.dig("annotations", "org.opencontainers.image.ref.name") == "10.47.arm64_tahoe" }
  fallback = BrewCooldown::HomebrewAdapter::RegistryMetadata.new(name: "pcre2", tag: "10.47", platform: nil,
                                                               index: older, index_sha256: index_digest)
  expected = older.fetch("manifests").find { |entry| entry.dig("annotations", "org.opencontainers.image.ref.name") == "10.47.arm64_sequoia" }
  raise "Native older-platform fallback failed" unless fallback.platform_sha256 == expected.fetch("digest").delete_prefix("sha256:")
end

changed_index = Marshal.load(Marshal.dump(index))
changed_index["annotations"]["org.opencontainers.image.created"] = "2026-09-19T00:00:00Z"
raise "Index clock displaced platform publication" unless metadata_reader(changed_index).complete(platform).published_at == metadata.published_at
without_date = Marshal.load(Marshal.dump(platform))
without_date["annotations"].delete("org.opencontainers.image.created")
raise "Missing platform clock inherited another date" unless metadata_reader.complete(without_date).published_at.nil?

[
  ["Index identity", ->(row) { row["annotations"]["org.opencontainers.image.title"] = "another" }],
  ["version and rebuild", ->(row) { row["annotations"]["org.opencontainers.image.version"] = "10.48" }],
  ["Missing or ambiguous", ->(row) { row["manifests"] = [] }],
  ["Missing or ambiguous", ->(row) { row["manifests"] *= 2 }],
].each do |fragment, mutate|
  changed = Marshal.load(Marshal.dump(index))
  mutate.call(changed)
  expect_error(fragment) { metadata_reader(changed) }
end
[
  ["identity differs", ->(row) { row["annotations"]["org.opencontainers.image.title"] = "another" }],
  ["annotations disagree", ->(row) { row["annotations"]["sh.brew.bottle.digest"] = "0" * 64 }],
  ["Unexpected bottle layers", ->(row) { row["layers"] *= 2 }],
  ["Invalid platform metadata", ->(row) { row["annotations"]["org.opencontainers.image.created"] = "2026-02-31T00:00:00Z" }],
  ["runtime receipts differ", ->(row) { row["annotations"]["sh.brew.tab"] = '{"runtime_dependencies":[{}]}' }],
].each do |fragment, mutate|
  changed = Marshal.load(Marshal.dump(platform))
  mutate.call(changed)
  expect_error(fragment) { metadata_reader.complete(changed) }
end

puts "PASS: recorded pagination, incomplete history, origin binding, immutable identity and platform clocks"
