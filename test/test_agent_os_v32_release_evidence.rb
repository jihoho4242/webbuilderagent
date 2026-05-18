# frozen_string_literal: true

require "json"
require "yaml"
require "time"
require "digest"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32ReleaseEvidenceTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def test_p5_gate_builds_release_ready_evidence_bundle
    evidence = Aiweb::Ops::P5Gate.new.evidence(validation: { "unit" => "test" })
    assert_equal "v0.3.2-rc1", evidence.fetch("release_id")
    assert_equal true, evidence.fetch("release_ready"), evidence.fetch("blocking_issues").join("\n")
    assert_match(/^sha256:/, evidence.fetch("constitution_hash"))
    assert_equal 0, evidence.dig("redteam", "critical_high_bypass_count")
    assert_equal false, evidence.dig("self_improvement", "proposal", "source_changed")
    assert_equal true, evidence.dig("replay", "side_effect_free_replay")
    assert_equal "passed", evidence.dig("hitl_v2", "status")
  end

  def test_release_evidence_files_exist_and_reference_p5_gate
    %w[release_manifest.yaml evidence_integrity_manifest.yaml p5_gate_report.md].each do |name|
      assert File.file?(File.join(REPO_ROOT, "releases", "v0.3.2-rc1", name)), "missing #{name}"
    end
    manifest = YAML.safe_load(File.read(File.join(REPO_ROOT, "releases", "v0.3.2-rc1", "release_manifest.yaml")), permitted_classes: [], aliases: false)
    assert_equal "v0.3.2-rc1", manifest.fetch("release_id")
    assert_match(/^sha256:/, manifest.fetch("constitution_hash"))

    integrity = YAML.safe_load(File.read(File.join(REPO_ROOT, "releases", "v0.3.2-rc1", "evidence_integrity_manifest.yaml")), permitted_classes: [], aliases: false)
    integrity.fetch("files").each do |entry|
      absolute = File.join(REPO_ROOT, entry.fetch("path"))
      assert_equal "sha256:#{Digest::SHA256.file(absolute).hexdigest}", entry.fetch("sha256")
    end
  end
end
