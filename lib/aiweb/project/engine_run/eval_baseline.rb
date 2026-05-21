# frozen_string_literal: true

require_relative "../../constitution/loader"
require_relative "../../tools/decision_packet"
require_relative "eval_baseline/review_pack"
require_relative "eval_baseline/validation"
require_relative "eval_baseline/import_approval"

module Aiweb
  module ProjectEngineRun
    def eval_baseline(action: "validate", source_path: nil, output_path: nil, fixture_id: nil, approved: false, approval_hash: nil, dry_run: false)
      assert_initialized!

      normalized_action = action.to_s.strip.empty? ? "validate" : action.to_s.strip
      unless %w[validate import review-pack].include?(normalized_action)
        raise UserError.new("eval-baseline action must be validate, import, or review-pack", 1)
      end
      if normalized_action == "import" && source_path.to_s.strip.empty?
        raise UserError.new("eval-baseline import requires --path", 1)
      end

      state = load_state
      if normalized_action == "review-pack"
        return eval_baseline_review_pack(
          output_path: output_path.to_s.strip.empty? ? source_path : output_path,
          fixture_id: fixture_id,
          approved: approved,
          dry_run: dry_run,
          state: state
        )
      end

      target_path = File.join(aiweb_dir, "eval", "human-baselines.json")
      validation_path = File.join(aiweb_dir, "eval", "human-baseline-validation.json")
      source = eval_baseline_source_path(source_path, target_path)
      validation = eval_baseline_validation(source, target_path: target_path, fixture_id: fixture_id)
      blockers = Array(validation["blocking_issues"])
      if validation["source_status"] == "ready" && validation["calibrated_fixture_count"].to_i.zero?
        blockers << "human baseline corpus contains no calibrated fixtures with positive reviewer evidence"
      end
      approval_capability = normalized_action == "import" ? eval_baseline_import_approval_capability(source: source, target_path: target_path, validation: validation, fixture_id: fixture_id) : nil
      expected_approval_hash = approval_capability ? eval_baseline_import_approval_hash(approval_capability) : nil
      if normalized_action == "import" && !dry_run && !approved
        blockers << "--approved is required to import human baseline corpus"
      end
      if normalized_action == "import" && !dry_run && approved
        blockers.concat(eval_baseline_import_approval_blockers(supplied_hash: approval_hash, expected_hash: expected_approval_hash))
      end
      blockers = blockers.uniq

      status = if blockers.any?
                 "blocked"
               elsif dry_run
                 "dry_run"
               elsif normalized_action == "import"
                 "imported"
               else
                 "validated"
               end
      action_taken = case [normalized_action, status]
                     when ["import", "imported"]
                       "imported human eval baseline"
                     when ["import", "dry_run"]
                       "planned human eval baseline import"
                     when ["validate", "validated"]
                       "validated human eval baseline"
                     when ["validate", "dry_run"]
                       "planned human eval baseline validation"
                     else
                       "human eval baseline #{normalized_action} blocked"
                     end

      validation_artifact = eval_baseline_validation_artifact(
        validation,
        status: status,
        action: normalized_action,
        approved: approved,
        dry_run: dry_run,
        blockers: blockers,
        target_path: target_path,
        validation_path: validation_path
      )
      changes = []
      if !dry_run && (normalized_action == "validate" || (normalized_action == "import" && approved))
        changes << write_json(validation_path, validation_artifact, false)
      end
      if !dry_run && status == "imported"
        changes << write_json(target_path, validation.fetch("corpus"), false)
      end

      eval_payload = {
        "schema_version" => 1,
        "status" => status,
        "action" => normalized_action,
        "dry_run" => dry_run,
        "approved" => approved,
        "approval_hash" => expected_approval_hash,
        "supplied_approval_hash" => approval_hash.to_s.strip.empty? ? nil : approval_hash.to_s,
        "approval_capability" => approval_capability,
        "source_path" => eval_baseline_path_label(source),
        "target_path" => relative(target_path),
        "validation_path" => dry_run ? nil : (changes.include?(relative(validation_path)) ? relative(validation_path) : nil),
        "planned_target_path" => dry_run || status == "blocked" ? relative(target_path) : nil,
        "planned_validation_path" => dry_run || (status == "blocked" && changes.empty?) ? relative(validation_path) : nil,
        "fixture_filter" => fixture_id.to_s.strip.empty? ? nil : fixture_id.to_s.strip,
        "fixture_count" => validation["fixture_count"],
        "calibrated_fixture_count" => validation["calibrated_fixture_count"],
        "invalid_fixture_count" => validation["invalid_fixture_count"],
        "corpus_readiness" => validation["corpus_readiness"],
        "fixtures" => validation["fixtures"],
        "guardrails" => eval_baseline_guardrails,
        "blocking_issues" => blockers
      }

      {
        "schema_version" => 1,
        "current_phase" => state.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => compact_changes(changes),
        "blocking_issues" => blockers,
        "missing_artifacts" => validation["missing_artifacts"],
        "eval_baseline" => eval_payload,
        "next_action" => eval_baseline_next_action(normalized_action, status, approval_hash: expected_approval_hash)
      }
    end

    private

    def eval_baseline_guardrails
      [
        "no fabricated reviewer evidence",
        "project-local JSON source only",
        "no .env/.env.* reads",
        "no raw secrets or environment values",
        "scores must be numeric 0..100",
        "import requires matching --approval-hash HASH plus --approved",
        "dry-run writes nothing"
      ]
    end

    def eval_baseline_next_action(action, status, approval_hash: nil)
      case [action, status]
      when ["review-pack", "created"]
        "send .ai-web/eval/human-review-pack.json to human reviewers, write .ai-web/eval/candidate-human-baselines.json with real human scores, then run aiweb eval-baseline validate --path .ai-web/eval/candidate-human-baselines.json"
      when ["review-pack", "dry_run"]
        "rerun aiweb eval-baseline review-pack without --dry-run to create the human review pack"
      when ["validate", "validated"]
        "review .ai-web/eval/human-baseline-validation.json, then run aiweb eval-baseline import --path <candidate> --dry-run and review the approval_hash; lower-level import approval must stay explicit evidence handling"
      when ["import", "imported"]
        "run aiweb engine-run so eval-benchmark.json can use the calibrated human baseline"
      when ["validate", "dry_run"], ["import", "dry_run"]
        action == "import" ? "review approval_hash #{approval_hash || "HASH"} for lower-level human-baseline import approval; do not treat import as a friendly web-building runbook" : "rerun without --dry-run to record validation evidence"
      else
        action == "review-pack" ? "fix the reported human review pack issues and rerun aiweb eval-baseline review-pack" : "fix the reported human baseline issues and rerun aiweb eval-baseline validate --path <candidate>"
      end
    end

    def eval_baseline_path_label(path)
      expanded_root = File.expand_path(root)
      expanded_path = File.expand_path(path.to_s)
      root_prefix = expanded_root.end_with?(File::SEPARATOR) ? expanded_root : "#{expanded_root}#{File::SEPARATOR}"
      return relative(expanded_path) if expanded_path == expanded_root || expanded_path.start_with?(root_prefix)

      File.basename(expanded_path)
    end
  end
end
