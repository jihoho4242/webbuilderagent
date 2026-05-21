# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_design_fixture(contract, design_verdict, screenshot_evidence, paths)
      selected = contract.to_h
      target_brief_path = selected.dig("artifacts", "selected_design", "path") || ".ai-web/design-candidates/selected.md"
      golden_path = selected["selected_candidate_path"]
      baseline = {
        "status" => design_verdict["status"],
        "scores" => design_verdict["scores"],
        "average_score" => design_verdict["average_score"],
        "blocking_issues" => Array(design_verdict["blocking_issues"])
      }
      basis = {
        "contract_hash" => selected["contract_hash"],
        "selected_candidate_sha256" => selected["selected_candidate_sha256"],
        "baseline" => baseline
      }
      {
        "schema_version" => 1,
        "status" => selected["status"] == "ready" ? "ready" : "missing",
        "fixture_id" => "design-fixture-#{Digest::SHA256.hexdigest(json_generate(basis))[0, 16]}",
        "recorded_at" => now,
        "human_approved_target_brief" => {
          "path" => target_brief_path,
          "excerpt" => engine_run_fixture_excerpt(target_brief_path)
        },
        "golden_reference" => {
          "selected_candidate" => selected["selected_candidate"],
          "path" => golden_path,
          "sha256" => selected["selected_candidate_sha256"],
          "excerpt" => engine_run_fixture_excerpt(golden_path)
        },
        "viewport_expected_outcomes" => %w[desktop tablet mobile].map do |viewport|
          {
            "viewport" => viewport,
            "expected" => "match selected OpenDesign first-view hierarchy, typography, spacing, contrast, component state, and route intent",
            "evidence_required" => %w[screenshot dom_snapshot a11y_report computed_style interaction_states keyboard_focus action_recovery action_loop]
          }
        end,
        "allowed_variance_thresholds" => design_verdict.fetch("thresholds", {}),
        "stored_baseline_verdict" => baseline,
        "evidence_refs" => {
          "browser_evidence_path" => relative(paths.fetch(:screenshot_evidence_path)),
          "design_verdict_path" => relative(paths.fetch(:design_verdict_path)),
          "opendesign_contract_path" => relative(paths.fetch(:opendesign_contract_path)),
          "screenshot_count" => Array(screenshot_evidence["screenshots"]).length
        }
      }
    end
  end
end
