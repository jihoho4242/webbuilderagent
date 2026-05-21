# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def eval_baseline_review_pack(output_path:, fixture_id:, approved:, dry_run:, state:)
      review_pack_path = eval_baseline_review_pack_output_path(output_path)
      target_path = File.join(aiweb_dir, "eval", "human-baselines.json")
      candidate_path = File.join(aiweb_dir, "eval", "candidate-human-baselines.json")
      requested_fixture_id = fixture_id.to_s.strip
      blockers = eval_baseline_review_pack_path_issues(review_pack_path)
      unless requested_fixture_id.empty? || requested_fixture_id.match?(/\Adesign-fixture-[a-f0-9]{16}\z/)
        blockers << "human review pack --fixture-id must match design-fixture-<16 lowercase hex>"
      end

      fixture_source = eval_baseline_review_pack_fixture_source(requested_fixture_id)
      effective_fixture_id = requested_fixture_id.empty? ? fixture_source["fixture_id"].to_s : requested_fixture_id
      template_fixture_id = effective_fixture_id.empty? ? "design-fixture-<16 lowercase hex>" : effective_fixture_id
      blockers = blockers.uniq
      status = if blockers.any?
                 "blocked"
               elsif dry_run
                 "dry_run"
               else
                 "created"
               end
      artifact = eval_baseline_review_pack_artifact(
        status: status == "created" ? "ready" : status,
        review_pack_path: review_pack_path,
        candidate_path: candidate_path,
        target_path: target_path,
        fixture_id: effective_fixture_id.empty? ? nil : effective_fixture_id,
        template_fixture_id: template_fixture_id,
        fixture_source: fixture_source,
        blockers: blockers
      )

      changes = []
      changes << write_json(review_pack_path, artifact, false) if !dry_run && status == "created"
      action_taken = case status
                     when "created"
                       "created human eval review pack"
                     when "dry_run"
                       "planned human eval review pack"
                     else
                       "human eval review pack blocked"
                     end

      eval_payload = {
        "schema_version" => 1,
        "status" => status,
        "action" => "review-pack",
        "dry_run" => dry_run,
        "approved" => approved,
        "review_pack_path" => changes.empty? ? nil : relative(review_pack_path),
        "planned_review_pack_path" => dry_run || status == "blocked" ? relative(review_pack_path) : nil,
        "candidate_path" => relative(candidate_path),
        "target_path" => relative(target_path),
        "fixture_filter" => requested_fixture_id.empty? ? nil : requested_fixture_id,
        "fixture_count" => template_fixture_id.empty? ? 0 : 1,
        "calibrated_fixture_count" => 0,
        "invalid_fixture_count" => blockers.any? ? 1 : 0,
        "fixtures" => [
          {
            "fixture_id" => template_fixture_id,
            "status" => effective_fixture_id.empty? ? "placeholder_requires_engine_run_fixture" : "ready_for_human_review",
            "human_calibrated" => false,
            "issues" => blockers
          }
        ],
        "guardrails" => eval_baseline_review_pack_guardrails,
        "blocking_issues" => blockers
      }

      {
        "schema_version" => 1,
        "current_phase" => state.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => compact_changes(changes),
        "blocking_issues" => blockers,
        "missing_artifacts" => [],
        "eval_baseline" => eval_payload,
        "next_action" => eval_baseline_next_action("review-pack", status)
      }
    end

    def eval_baseline_review_pack_output_path(output_path)
      text = output_path.to_s.strip
      text.empty? ? File.join(aiweb_dir, "eval", "human-review-pack.json") : File.expand_path(text, root)
    end

    def eval_baseline_review_pack_path_issues(path)
      issues = eval_baseline_source_path_issues(path).map { |issue| issue.sub("human baseline source path", "human review pack output path") }
      label = eval_baseline_path_label(path)
      issues << "human review pack output path must be a .json file" unless File.extname(label).casecmp(".json").zero?
      if label.tr("\\", "/") == ".ai-web/eval/human-baselines.json"
        issues << "unsafe human review pack output path must not overwrite .ai-web/eval/human-baselines.json"
      end
      issues.uniq
    end

    def eval_baseline_review_pack_fixture_source(requested_fixture_id)
      fixture_paths = Dir.glob(File.join(aiweb_dir, "runs", "*", "qa", "design-fixture.json"))
      candidates = fixture_paths.filter_map do |path|
        data = JSON.parse(File.read(path, 256 * 1024))
        next unless data.is_a?(Hash)

        {
          "status" => "found",
          "path" => relative(path),
          "fixture_id" => data["fixture_id"].to_s,
          "recorded_at" => data["recorded_at"],
          "design_status" => data["status"],
          "mtime" => File.mtime(path).to_i
        }
      rescue JSON::ParserError, SystemCallError
        nil
      end
      selected = if requested_fixture_id.to_s.empty?
                   candidates.max_by { |entry| entry["mtime"].to_i }
                 else
                   candidates.select { |entry| entry["fixture_id"] == requested_fixture_id }.max_by { |entry| entry["mtime"].to_i }
                 end
      return selected.reject { |key, _value| key == "mtime" } if selected

      {
        "status" => "missing",
        "path" => nil,
        "fixture_id" => requested_fixture_id.to_s.empty? ? nil : requested_fixture_id,
        "reason" => requested_fixture_id.to_s.empty? ? "no engine-run design fixture found; template requires a real fixture id before import" : "no matching engine-run design fixture found in .ai-web/runs"
      }
    end

    def eval_baseline_review_pack_artifact(status:, review_pack_path:, candidate_path:, target_path:, fixture_id:, template_fixture_id:, fixture_source:, blockers:)
      created_at = now
      pack_id = "human-review-pack-#{Digest::SHA256.hexdigest(json_generate(["human-review-pack", created_at, template_fixture_id, relative(review_pack_path)]))[0, 16]}"
      score_axes = %w[hierarchy spacing typography contrast interaction action_recovery browser_action_loop accessibility]
      {
        "schema_version" => 1,
        "status" => status,
        "pack_id" => pack_id,
        "created_at" => created_at,
        "fixture_id" => fixture_id,
        "fixture_source" => fixture_source,
        "output_paths" => {
          "review_pack_path" => relative(review_pack_path),
          "candidate_human_baselines_path" => relative(candidate_path),
          "import_target_path" => relative(target_path),
          "validation_path" => ".ai-web/eval/human-baseline-validation.json"
        },
        "review_protocol" => {
          "purpose" => "collect human-calibrated eval baselines without agent-fabricated reviewer evidence",
          "minimum_reviewer_count" => 2,
          "score_range" => { "minimum" => 0, "maximum" => 100 },
          "score_axes" => score_axes,
          "evidence_required" => %w[reviewer_id overall_score axis_scores notes reviewed_fixture_or_screenshot_refs],
          "reviewer_requirements" => [
            "reviewers must be real humans or an explicitly approved human review panel",
            "agents must not invent reviewer identities, scores, notes, or evidence references",
            "candidate corpus must be validated before import and import still requires matching --approval-hash HASH plus --approved"
          ]
        },
        "human_input_contract" => {
          "prepopulated_human_scores" => false,
          "agent_must_not_fill_scores" => true,
          "required_human_fields" => [
            "corpus_metadata.collected_at",
            "corpus_metadata.reviewer_count",
            "fixtures.<fixture_id>.average_score",
            "fixtures.<fixture_id>.reviewer_count",
            "fixtures.<fixture_id>.human_scores",
            "fixtures.<fixture_id>.human_ratings[].reviewer_id",
            "fixtures.<fixture_id>.human_ratings[].overall_score",
            "fixtures.<fixture_id>.human_ratings[].scores"
          ],
          "candidate_schema" => "engine-run-human-baselines.schema.json",
          "candidate_template_status" => "not_importable_until_human_completed"
        },
        "candidate_baseline_template" => {
          "schema_version" => 1,
          "corpus_metadata" => {
            "source" => "manual-human-review",
            "collected_at" => "<human collection timestamp>",
            "review_protocol" => "two-or-more human reviewers score the referenced design fixture using 0..100 axes",
            "reviewer_count" => "<integer >= 2>"
          },
          "fixtures" => {
            template_fixture_id => {
              "fixture_id" => template_fixture_id,
              "average_score" => "<human average 0..100>",
              "reviewer_count" => "<integer >= 2>",
              "source" => "manual-human-review",
              "review_protocol" => "score hierarchy, spacing, typography, contrast, interaction, action recovery, browser action loop, and accessibility",
              "human_scores" => score_axes.each_with_object({}) { |axis, memo| memo[axis] = "<human score 0..100>" },
              "human_ratings" => [
                {
                  "reviewer_id" => "<human reviewer id>",
                  "overall_score" => "<human score 0..100>",
                  "scores" => score_axes.each_with_object({}) { |axis, memo| memo[axis] = "<human score 0..100>" },
                  "notes" => "<human notes; no secrets or environment values>"
                }
              ]
            }
          }
        },
        "anti_fabrication_policy" => {
          "requires_human_reviewer_evidence" => true,
          "agent_must_not_fill_scores" => true,
          "agent_must_not_invent_reviewer_ids" => true,
          "template_contains_placeholders_only" => true,
          "import_requires_hash_bound_approval" => true,
          "validate_rejects_uncalibrated_or_secret_corpus" => true
        },
        "next_steps" => [
          "Give this review pack to human reviewers with the referenced design fixture/screenshots.",
          "Humans fill #{relative(candidate_path)} using numeric 0..100 scores and reviewer evidence.",
          "Run aiweb eval-baseline validate --path #{relative(candidate_path)}.",
          "After human approval, run aiweb eval-baseline import --path #{relative(candidate_path)} --dry-run and review the approval_hash; lower-level import approval must stay an explicit evidence-handling action, not a friendly runbook.",
          "Run aiweb engine-run so eval-benchmark.json can enforce the calibrated human baseline."
        ],
        "guardrails" => eval_baseline_review_pack_guardrails,
        "blocking_issues" => blockers
      }
    end

    def eval_baseline_review_pack_guardrails
      [
        "review pack creates placeholders only",
        "no fabricated reviewer evidence",
        "no prepopulated human scores",
        "project-local JSON output only",
        "no .env/.env.* writes",
        "human baseline import still requires validation plus matching --approval-hash HASH and --approved"
      ]
    end
  end
end
