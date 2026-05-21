# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

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
      Digest::SHA256.hexdigest(json_generate(capability))
    end

    def eval_baseline_import_approval_blockers(supplied_hash:, expected_hash:)
      return ["eval-baseline import approved execution requires --approval-hash HASH from the matching dry-run capability envelope"] if supplied_hash.to_s.strip.empty?
      return ["eval-baseline import approval hash does not match the current human-baseline import capability envelope"] unless supplied_hash.to_s.strip == expected_hash

      []
    end
  end
end
