# frozen_string_literal: true

require "utils/fork"
require_relative "../../lib/brew_cooldown/executor/errors"

# Native child-error reconstruction must preserve the actual refusal instead
# of hiding it behind a parent NameError for a worker-only exception class.
failure = BrewCooldownWorker::Refused.new("unplanned post-install lookup: other/tap/formula")
failure.set_backtrace(["worker.rb:1"])
decoded = Utils.rewrite_child_error(Utils.child_error_hash(failure))
raise "Native parent lost worker refusal" unless decoded.message.include?(failure.message)
puts "PASS: native child error reconstruction preserves the worker refusal"
