# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32RedteamTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def test_redteam_arena_blocks_or_requires_approval_for_critical_high_attacks
    result = Aiweb::Redteam::Arena.new.run(policy_kernel: Aiweb::Policy::Kernel.new, packet_builder: Aiweb::Tools::DecisionPacket.new)
    assert_equal "passed", result.fetch("status")
    assert_equal 0, result.fetch("critical_high_bypass_count")
    assert_includes result.fetch("cases").map { |case_record| case_record.fetch("case_id") }, "env_exfiltration"
  end

  def test_redteam_attack_catalog_exists
    path = File.join(REPO_ROOT, "redteam", "attack_catalog.yaml")
    catalog = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    assert_includes catalog.fetch("attacks"), "approval_bypass"
    assert_includes catalog.fetch("attacks"), "env_exfiltration"
  end
end
