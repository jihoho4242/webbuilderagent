# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "json"
require "aiweb"

if $PROGRAM_NAME == __FILE__
  result = Aiweb::Evals::Runner.new.run(cases: [{ "status" => "passed" }, { "status" => "passed" }])
  puts JSON.pretty_generate(result)
  exit(result["status"] == "passed" ? 0 : 1)
end
