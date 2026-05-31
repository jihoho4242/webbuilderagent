# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "json"
require "aiweb"

if $PROGRAM_NAME == __FILE__
  result = Aiweb::Evals::Runner.new.run(cases: Aiweb::Evals::Runner.pack_cases)
  puts JSON.pretty_generate(result)
  exit(result["failure_count"].to_i.zero? && result["expanded_fixture_gate_passed"] ? 0 : 1)
end
