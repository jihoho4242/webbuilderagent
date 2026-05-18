# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_missing_human_calibration(path)
      {
        "status" => "missing",
        "baseline_source" => {
          "type" => "none",
          "path" => relative(path),
          "status" => "missing",
          "reason" => "no human-calibrated eval baseline exists for this fixture"
        }
      }
    end

    def engine_run_seeded_human_calibration(path, design_fixture)
      fixture = design_fixture.to_h
      baseline = fixture["stored_baseline_verdict"].is_a?(Hash) ? fixture["stored_baseline_verdict"] : {}
      average = baseline["average_score"].is_a?(Numeric) ? baseline["average_score"] : nil
      {
        "status" => "seeded",
        "baseline_source" => {
          "type" => "deterministic_design_fixture_seed",
          "path" => relative(path),
          "status" => "seeded",
          "fixture_id" => fixture["fixture_id"].to_s,
          "average_score" => average,
          "reviewer_count" => 0,
          "rating_count" => 0,
          "score_axes" => [],
          "human_calibrated" => false,
          "reason" => "no human-calibrated eval baseline exists for this fixture; seeded from deterministic design fixture evidence"
        }
      }
    end

    def engine_run_eval_viewport_matrix(design_fixture, screenshot_evidence)
      expected = Array(design_fixture.to_h["viewport_expected_outcomes"]).each_with_object({}) { |entry, memo| memo[entry["viewport"].to_s] = entry if entry.is_a?(Hash) }
      screenshots = Array(screenshot_evidence.to_h["screenshots"]).each_with_object({}) { |entry, memo| memo[entry["viewport"].to_s] = entry if entry.is_a?(Hash) }
      viewports = (expected.keys + screenshots.keys + %w[desktop tablet mobile]).uniq
      viewports.map do |viewport|
        {
          "viewport" => viewport,
          "expected" => expected.dig(viewport, "expected"),
          "evidence_required" => Array(expected.dig(viewport, "evidence_required")),
          "screenshot_path" => screenshots.dig(viewport, "path"),
          "screenshot_sha256" => screenshots.dig(viewport, "sha256"),
          "status" => screenshots.key?(viewport) ? "captured" : "missing"
        }
      end
    end

    def engine_run_eval_time_to_pass(final_status, events)
      first_at = events.first && events.first["at"]
      last_at = events.last && events.last["at"]
      duration = if first_at && last_at
                   (Time.parse(last_at) - Time.parse(first_at)).round(3)
                 end
      {
        "status" => %w[passed no_changes].include?(final_status) ? "recorded" : "not_passed",
        "seconds" => duration,
        "start_event_at" => first_at,
        "end_event_at" => last_at
      }
    rescue ArgumentError
      {
        "status" => "unsupported",
        "seconds" => nil,
        "reason" => "event timestamps could not be parsed"
      }
    end

    def engine_run_eval_token_tool_cost(events)
      tool_events = events.count { |event| event["type"].to_s.start_with?("tool.") }
      {
        "status" => "partial",
        "tool_event_count" => tool_events,
        "token_count" => nil,
        "estimated_cost_usd" => nil,
        "reason" => "local engine-run records tool events but has no provider token accounting yet"
      }
    end

    def engine_run_fixture_excerpt(relative_path)
      return nil if relative_path.to_s.strip.empty?

      expanded_root = File.expand_path(root)
      path = File.expand_path(relative_path.to_s, expanded_root)
      return nil unless path.start_with?("#{expanded_root}#{File::SEPARATOR}") && File.file?(path)

      File.read(path, 16 * 1024).lines.first(40).join.strip
    rescue SystemCallError, ArgumentError
      nil
    end

    def engine_run_apply_design_gate_to_policy(policy, design_verdict, contract, paths)
      required = contract && contract["status"] == "ready"
      policy["design_gate_required"] = !!required
      policy["design_gate_status"] = required ? design_verdict["status"] : "skipped"
      policy["design_gate_artifact"] = required ? relative(paths.fetch(:design_verdict_path)) : nil
      policy["design_gate_blocking_issues"] = Array(design_verdict["blocking_issues"])
      policy["design_gate_contract_hash"] = contract && contract["contract_hash"]
      if required && design_verdict["status"] == "failed"
        policy["status"] = "repair"
      end
      policy
    end

  end
end
