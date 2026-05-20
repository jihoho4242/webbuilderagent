# frozen_string_literal: true

require_relative "../../constitution/loader"
require_relative "../../tools/decision_packet"

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
      pack_id = "human-review-pack-#{Digest::SHA256.hexdigest(JSON.generate(["human-review-pack", created_at, template_fixture_id, relative(review_pack_path)]))[0, 16]}"
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

    def eval_baseline_source_path(source_path, target_path)
      text = source_path.to_s.strip
      text.empty? ? target_path : File.expand_path(text, root)
    end

    def eval_baseline_validation(source_path, target_path:, fixture_id: nil)
      missing_artifacts = []
      path_issues = eval_baseline_source_path_issues(source_path)
      unless path_issues.empty?
        return eval_baseline_blocked_validation(source_path, path_issues, missing_artifacts)
      end

      unless File.file?(source_path)
        missing_artifacts << eval_baseline_path_label(source_path)
        return eval_baseline_blocked_validation(source_path, ["human baseline source file does not exist"], missing_artifacts)
      end

      if File.size(source_path) > 512 * 1024
        return eval_baseline_blocked_validation(source_path, ["human baseline source file must be 512KB or smaller"], missing_artifacts)
      end

      data = JSON.parse(File.read(source_path))
      unless data.is_a?(Hash)
        return eval_baseline_blocked_validation(source_path, ["human baseline corpus root must be a JSON object"], missing_artifacts)
      end

      blocking_issues = []
      blocking_issues << "human baseline corpus schema_version must be 1" unless data["schema_version"] == 1
      blocking_issues << "human baseline corpus must contain fixtures" unless data.key?("fixtures")
      if JSON.generate(data).match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || JSON.generate(data).match?(/\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL)[A-Z0-9_]*=/i)
        blocking_issues << "human baseline corpus must not contain raw secrets or environment values"
      end

      entries = eval_baseline_fixture_entries(data["fixtures"])
      blocking_issues << "human baseline fixtures must be an object or array" if entries.nil?
      entries ||= []
      requested_fixture_id = fixture_id.to_s.strip
      if !requested_fixture_id.empty? && !requested_fixture_id.match?(/\Adesign-fixture-[a-f0-9]{16}\z/)
        blocking_issues << "human baseline --fixture-id must match design-fixture-<16 lowercase hex>"
      end

      selected_entries = requested_fixture_id.empty? ? entries : entries.select { |entry| entry.fetch("fixture_id") == requested_fixture_id }
      if !requested_fixture_id.empty? && selected_entries.empty?
        blocking_issues << "human baseline fixture #{requested_fixture_id} was not found"
      end

      duplicate_ids = entries.map { |entry| entry.fetch("fixture_id") }.reject(&:empty?).tally.select { |_id, count| count > 1 }.keys
      blocking_issues << "human baseline corpus contains duplicate fixture ids: #{duplicate_ids.join(", ")}" unless duplicate_ids.empty?

      fixture_summaries = selected_entries.map do |entry|
        eval_baseline_fixture_summary(entry.fetch("fixture_id"), entry.fetch("baseline"), entry.fetch("index"))
      end
      blocking_issues.concat(fixture_summaries.flat_map { |summary| Array(summary["issues"]) })
      calibrated_count = fixture_summaries.count { |summary| summary["human_calibrated"] == true }
      invalid_count = fixture_summaries.count { |summary| Array(summary["issues"]).any? }
      corpus_readiness = eval_baseline_corpus_readiness(data, selected_entries, fixture_summaries)

      {
        "source_status" => "ready",
        "source_path" => eval_baseline_path_label(source_path),
        "target_path" => eval_baseline_path_label(target_path),
        "fixture_count" => fixture_summaries.length,
        "calibrated_fixture_count" => calibrated_count,
        "invalid_fixture_count" => invalid_count,
        "corpus_readiness" => corpus_readiness,
        "fixtures" => fixture_summaries,
        "blocking_issues" => blocking_issues.uniq,
        "missing_artifacts" => missing_artifacts,
        "corpus" => data
      }
    rescue JSON::ParserError => e
      eval_baseline_blocked_validation(source_path, ["human baseline source file must be valid JSON: #{e.message}"], missing_artifacts)
    rescue SystemCallError => e
      eval_baseline_blocked_validation(source_path, ["human baseline source file is unreadable: #{e.class}"], missing_artifacts)
    end

    def eval_baseline_blocked_validation(source_path, issues, missing_artifacts)
      {
        "source_status" => "blocked",
        "source_path" => eval_baseline_path_label(source_path),
        "target_path" => nil,
        "fixture_count" => 0,
        "calibrated_fixture_count" => 0,
        "invalid_fixture_count" => 0,
        "corpus_readiness" => {
          "status" => "blocked",
          "production_ready" => false,
          "multi_fixture_required_for_production" => true,
          "minimum_calibrated_fixture_count" => 2,
          "blocking_issues" => issues.uniq
        },
        "fixtures" => [],
        "blocking_issues" => issues.uniq,
        "missing_artifacts" => missing_artifacts,
        "corpus" => { "schema_version" => 1, "fixtures" => {} }
      }
    end

    def eval_baseline_source_path_issues(path)
      issues = []
      label = eval_baseline_path_label(path)
      expanded_root = File.expand_path(root)
      expanded_path = File.expand_path(path.to_s)
      root_prefix = expanded_root.end_with?(File::SEPARATOR) ? expanded_root : "#{expanded_root}#{File::SEPARATOR}"
      unless expanded_path == expanded_root || expanded_path.start_with?(root_prefix)
        issues << "unsafe human baseline source path blocked: #{File.basename(expanded_path)} is outside the project"
        return issues
      end

      parts = label.split(/[\/\\]+/)
      if parts.any? { |part| part.match?(/\A\.env(?:\.|\z)/) }
        issues << "unsafe human baseline source path blocked: .env/.env.* paths are not allowed"
      end
      if parts.any? { |part| %w[.git node_modules dist build coverage tmp vendor].include?(part) }
        issues << "unsafe human baseline source path blocked: generated, dependency, and VCS paths are not allowed"
      end
      issues
    end

    def eval_baseline_corpus_readiness(corpus, selected_entries, fixture_summaries)
      metadata = corpus.to_h["corpus_metadata"].is_a?(Hash) ? corpus.fetch("corpus_metadata") : {}
      entries_by_fixture = Array(selected_entries).to_h { |entry| [entry.fetch("fixture_id").to_s, entry.fetch("baseline")] }
      calibrated_summaries = Array(fixture_summaries).select { |summary| summary["human_calibrated"] == true }
      reviewer_ids = entries_by_fixture.values.flat_map do |baseline|
        Array(baseline.to_h["human_ratings"]).filter_map do |rating|
          next unless rating.is_a?(Hash)

          rating["reviewer_id"].to_s.strip
        end
      end.reject(&:empty?).uniq.sort
      declared_reviewer_count = metadata["reviewer_count"].is_a?(Integer) ? metadata["reviewer_count"] : nil
      axes = calibrated_summaries.flat_map { |summary| Array(summary["score_axes"]) }.uniq.sort
      fixtures_without_rating_evidence = calibrated_summaries.filter_map do |summary|
        baseline = entries_by_fixture[summary["fixture_id"].to_s].to_h
        ratings = Array(baseline["human_ratings"]).select { |rating| rating.is_a?(Hash) }
        summary["fixture_id"] if ratings.empty? || ratings.any? { |rating| rating["reviewer_id"].to_s.strip.empty? }
      end

      issues = []
      issues << "production human baseline corpus requires at least 2 calibrated fixtures" if calibrated_summaries.length < 2
      issues << "production human baseline corpus requires corpus_metadata.reviewer_count >= 2" unless declared_reviewer_count && declared_reviewer_count >= 2
      issues << "production human baseline corpus requires at least 2 unique human reviewer ids" if reviewer_ids.length < 2
      unless fixtures_without_rating_evidence.empty?
        issues << "production human baseline corpus requires human_ratings reviewer_id evidence for each calibrated fixture: #{fixtures_without_rating_evidence.join(", ")}"
      end

      {
        "status" => if issues.empty?
                       "production_ready_multi_fixture"
                     elsif calibrated_summaries.any?
                       "calibrated_but_not_production_corpus"
                     else
                       "not_human_calibrated"
                     end,
        "production_ready" => issues.empty?,
        "multi_fixture_required_for_production" => true,
        "minimum_calibrated_fixture_count" => 2,
        "fixture_count" => Array(fixture_summaries).length,
        "calibrated_fixture_count" => calibrated_summaries.length,
        "declared_reviewer_count" => declared_reviewer_count,
        "unique_reviewer_count" => reviewer_ids.length,
        "reviewer_ids" => reviewer_ids,
        "score_axes" => axes,
        "blocking_issues" => issues
      }
    end

    def eval_baseline_fixture_entries(fixtures)
      case fixtures
      when Hash
        fixtures.each_with_index.map do |(key, baseline), index|
          fixture_id = baseline.is_a?(Hash) && !baseline["fixture_id"].to_s.empty? ? baseline["fixture_id"].to_s : key.to_s
          { "fixture_id" => fixture_id, "baseline" => baseline, "index" => index }
        end
      when Array
        fixtures.each_with_index.map do |baseline, index|
          fixture_id = baseline.is_a?(Hash) ? baseline["fixture_id"].to_s : ""
          { "fixture_id" => fixture_id, "baseline" => baseline, "index" => index }
        end
      else
        nil
      end
    end

    def eval_baseline_fixture_summary(fixture_id, baseline, index)
      issues = []
      unless fixture_id.to_s.match?(/\Adesign-fixture-[a-f0-9]{16}\z/)
        issues << "human baseline fixture #{index} must declare fixture_id matching design-fixture-<16 lowercase hex>"
      end
      unless baseline.is_a?(Hash)
        return {
          "fixture_id" => fixture_id.to_s.empty? ? nil : fixture_id,
          "index" => index,
          "status" => "invalid",
          "average_score" => nil,
          "reviewer_count" => 0,
          "rating_count" => 0,
          "score_axes" => [],
          "human_calibrated" => false,
          "issues" => (issues + ["human baseline fixture #{index} must be an object"]).uniq
        }
      end

      issues.concat(engine_run_eval_human_baseline_issues(baseline, fixture_id.to_s))
      reviewer_count = baseline["reviewer_count"].is_a?(Integer) ? baseline["reviewer_count"] : 0
      score_axes = baseline["human_scores"].is_a?(Hash) ? baseline["human_scores"].keys.map(&:to_s).sort : []
      rating_count = baseline["human_ratings"].is_a?(Array) ? baseline["human_ratings"].length : 0
      has_human_scores = score_axes.any?
      has_human_ratings = rating_count.positive?
      unless reviewer_count.positive? && (has_human_scores || has_human_ratings)
        issues << "human baseline fixture #{fixture_id} is not human-calibrated: positive reviewer_count and human_scores or human_ratings are required"
      end
      human_calibrated = issues.empty? && reviewer_count.positive? && (has_human_scores || has_human_ratings)

      {
        "fixture_id" => fixture_id,
        "index" => index,
        "status" => human_calibrated ? "calibrated" : "invalid",
        "average_score" => baseline["average_score"].is_a?(Numeric) ? baseline["average_score"] : nil,
        "reviewer_count" => reviewer_count,
        "rating_count" => rating_count,
        "score_axes" => score_axes,
        "human_calibrated" => human_calibrated,
        "issues" => issues.uniq
      }
    end

    def eval_baseline_validation_artifact(validation, status:, action:, approved:, dry_run:, blockers:, target_path:, validation_path:)
      {
        "schema_version" => 1,
        "status" => status,
        "action" => action,
        "validated_at" => now,
        "dry_run" => dry_run,
        "approved" => approved,
        "source_path" => validation["source_path"],
        "target_path" => relative(target_path),
        "validation_path" => relative(validation_path),
        "fixture_count" => validation["fixture_count"],
        "calibrated_fixture_count" => validation["calibrated_fixture_count"],
        "invalid_fixture_count" => validation["invalid_fixture_count"],
        "corpus_readiness" => validation["corpus_readiness"],
        "fixtures" => validation["fixtures"],
        "guardrails" => eval_baseline_guardrails,
        "blocking_issues" => blockers
      }
    end

    def eval_baseline_import_approval_capability(source:, target_path:, validation:, fixture_id:)
      {
        "schema_version" => 1,
        "capability" => "aiweb.eval_baseline.import.v1",
        "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash,
        "policy_kernel_version" => Aiweb::Tools::DecisionPacket::POLICY_KERNEL_VERSION,
        "source_path" => eval_baseline_path_label(source),
        "source_sha256" => File.file?(source) ? Digest::SHA256.file(source).hexdigest : nil,
        "target_path" => relative(target_path),
        "fixture_filter" => fixture_id.to_s.strip.empty? ? nil : fixture_id.to_s.strip,
        "corpus_readiness" => validation["corpus_readiness"],
        "fixture_count" => validation["fixture_count"],
        "calibrated_fixture_count" => validation["calibrated_fixture_count"],
        "invalid_fixture_count" => validation["invalid_fixture_count"],
        "fixtures" => validation["fixtures"],
        "execution_boundary" => {
          "requires_dry_run_review" => true,
          "requires_matching_approval_hash" => true,
          "writes_under" => %w[.ai-web/eval/human-baselines.json .ai-web/eval/human-baseline-validation.json],
          "forbidden" => %w[fabricated_reviewer_evidence env_read raw_secret_output uncalibrated_corpus_import production_ready_overclaim]
        }
      }
    end

    def eval_baseline_import_approval_hash(capability)
      Digest::SHA256.hexdigest(JSON.generate(capability))
    end

    def eval_baseline_import_approval_blockers(supplied_hash:, expected_hash:)
      return ["eval-baseline import approved execution requires --approval-hash HASH from the matching dry-run capability envelope"] if supplied_hash.to_s.strip.empty?
      return ["eval-baseline import approval hash does not match the current human-baseline import capability envelope"] unless supplied_hash.to_s.strip == expected_hash

      []
    end

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
