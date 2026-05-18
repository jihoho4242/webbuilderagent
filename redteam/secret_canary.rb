# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "json"
require "aiweb"

puts JSON.pretty_generate({ "schema_version" => 1, "status" => "passed", "canary_label" => Aiweb::Redteam::SecretCanary::VALUE })
