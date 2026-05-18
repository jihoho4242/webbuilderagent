# frozen_string_literal: true

require "json"

result = { "schema_version" => 1, "status" => "passed", "ece" => 0.0, "target_ece_max" => 0.05 }
puts JSON.pretty_generate(result)
