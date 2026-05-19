# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "json"
require "aiweb"

puts JSON.pretty_generate(Aiweb::Redteam::SecretCanary.safe_report)
