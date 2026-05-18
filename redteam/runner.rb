# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "json"
require "aiweb"

if $PROGRAM_NAME == __FILE__
  result = Aiweb::Redteam::Arena.new.run(policy_kernel: Aiweb::Policy::Kernel.new, packet_builder: Aiweb::Tools::DecisionPacket.new)
  puts JSON.pretty_generate(result)
  exit(result["critical_high_bypass_count"].to_i.zero? ? 0 : 1)
end
