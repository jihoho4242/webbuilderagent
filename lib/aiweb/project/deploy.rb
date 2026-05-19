# frozen_string_literal: true

require "securerandom"

require_relative "deploy/provider"

module Aiweb
  class Project
    module Deploy
    def deploy_plan(target: nil, dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        ensure_pr19_deploy_defaults!(state)
        plan = deploy_plan_payload(state, target: target, dry_run: dry_run)
        selected_target = plan["target"]
        descriptor_targets = selected_target ? [selected_target] : DEPLOY_PROVIDER_CONFIG_PATHS.keys
        provider_descriptors = descriptor_targets.each_with_object({}) do |descriptor_target, memo|
          path = DEPLOY_PROVIDER_CONFIG_PATHS.fetch(descriptor_target)
          memo[path] = deploy_provider_descriptor(descriptor_target, state)
        end
        planned_changes = [DEPLOY_PLAN_PATH, *provider_descriptors.keys]

        unless dry_run
          changes << write_json(File.join(root, DEPLOY_PLAN_PATH), plan, false)
          provider_descriptors.each do |relative_path, descriptor|
            changes << write_json(File.join(root, relative_path), descriptor, false)
          end
          mark_artifacts_from_files!(state)
          state["deploy"]["latest_plan"] = DEPLOY_PLAN_PATH
          state["deploy"]["deploy_plan_last_planned_at"] = plan["created_at"]
          add_decision!(state, "deploy_plan", "Recorded local-only Cloudflare Pages/Vercel dry-run descriptors; no provider deploy was run")
          state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
          changes << write_yaml(state_path, state, false)
        end

        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = dry_run ? "planned local-only deploy plan" : "recorded local-only deploy plan"
        payload["deploy_plan"] = plan
        payload["provider_config_descriptors"] = provider_descriptors
        payload.merge!(pr19_safety_payload(planned_changes))
        payload["planned_changes"] = planned_changes
        payload["next_action"] = "review #{DEPLOY_PLAN_PATH}; run aiweb deploy --target cloudflare-pages --dry-run or --target vercel --dry-run for a non-writing deployment preview"
      end
      payload
    end

    def deploy(target:, approved: false, dry_run: false, force: false)
      assert_initialized!
      normalized_target = normalize_deploy_target(target)
      state = load_state
      ensure_pr19_deploy_defaults!(state)
      descriptor_path = DEPLOY_PROVIDER_CONFIG_PATHS.fetch(normalized_target)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")
      run_id = "deploy-#{timestamp}-#{SecureRandom.hex(4)}-#{normalized_target}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "deploy.json")
      side_effect_broker_path = File.join(run_dir, "side-effect-broker.jsonl")
      planned_changes = [DEPLOY_PLAN_PATH, descriptor_path, relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path), relative(side_effect_broker_path)]
      deploy_payload = deploy_local_payload(
        normalized_target,
        state,
        dry_run: dry_run,
        force: force,
        approved: approved,
        run_id: run_id,
        run_dir: run_dir,
        stdout_path: stdout_path,
        stderr_path: stderr_path,
        metadata_path: metadata_path,
        side_effect_broker_path: side_effect_broker_path
      )
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = dry_run ? "deploy dry-run planned" : "deploy blocked"
      payload["deploy"] = deploy_payload
      payload["deploy_dry_run"] = deploy_payload if dry_run
      payload.merge!(pr19_safety_payload(planned_changes))
      payload["planned_changes"] = planned_changes
      if dry_run
        payload["next_action"] = "review the deploy plan only; provider execution remains blocked until an engine-run release evidence gate exists"
      else
        payload["blocking_issues"] = (payload["blocking_issues"] + deploy_payload["blocking_issues"]).uniq
        payload["next_action"] = "keep deploy local-only until engine-run release evidence migration replaces the removed verify-loop provenance gate"
      end
      payload
    end

    private

    def ensure_pr19_deploy_defaults!(state)
      state["artifacts"] ||= {}
      {
        "github_sync" => GITHUB_SYNC_PLAN_PATH,
        "deploy_plan" => DEPLOY_PLAN_PATH,
        "deploy_cloudflare_pages" => DEPLOY_PROVIDER_CONFIG_PATHS.fetch("cloudflare-pages"),
        "deploy_vercel" => DEPLOY_PROVIDER_CONFIG_PATHS.fetch("vercel")
      }.each do |key, path|
        state["artifacts"][key] ||= { "path" => path, "status" => "missing" }
      end

      state["deploy"] ||= {}
      state["deploy"]["github_sync_plan"] ||= GITHUB_SYNC_PLAN_PATH
      state["deploy"]["deploy_plan"] ||= DEPLOY_PLAN_PATH
      state["deploy"]["latest_plan"] = nil unless state["deploy"].key?("latest_plan")
      state["deploy"]["provider_config_paths"] ||= DEPLOY_PROVIDER_CONFIG_PATHS.dup
      state["deploy"]["github_last_known_url"] = nil unless state["deploy"].key?("github_last_known_url")
      state["deploy"]["preview_url"] = nil unless state["deploy"].key?("preview_url")
      state["deploy"]["production_url"] = nil unless state["deploy"].key?("production_url")
      state["deploy"]["cloudflare_preview_url"] = nil unless state["deploy"].key?("cloudflare_preview_url")
      state["deploy"]["vercel_preview_url"] = nil unless state["deploy"].key?("vercel_preview_url")
      state["deploy"]["github_sync_last_planned_at"] = nil unless state["deploy"].key?("github_sync_last_planned_at")
      state["deploy"]["deploy_plan_last_planned_at"] = nil unless state["deploy"].key?("deploy_plan_last_planned_at")
      state
    end

    def deploy_plan_payload(state, target:, dry_run:)
      normalized_target = target.to_s.strip.empty? ? nil : normalize_deploy_target(target)
      {
        "schema_version" => 1,
        "status" => "planned",
        "dry_run" => dry_run,
        "created_at" => now,
        "project_id" => state.dig("project", "id"),
        "project_name" => state.dig("project", "name"),
        "mode" => "local_plan_only",
        "planned_artifact_path" => ".ai-web/deploy/deploy-plan.json",
        "planned_config_path" => DEPLOY_PLAN_PATH,
        "artifact_path" => dry_run ? nil : DEPLOY_PLAN_PATH,
        "provider_config_paths" => DEPLOY_PROVIDER_CONFIG_PATHS.dup,
        "target" => normalized_target,
        "supported_targets" => DEPLOY_PROVIDER_CONFIG_PATHS.keys,
        "targets" => normalized_target ? [normalized_target] : DEPLOY_PROVIDER_CONFIG_PATHS.keys,
        "preview_url" => state.dig("deploy", "preview_url"),
        "production_url" => state.dig("deploy", "production_url"),
        "external_actions_allowed" => false,
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "requires_approval" => true,
        "guardrails" => ["no external deploy", "no provider CLI", "no network", "no build/preview/install", "no .env/.env.* access"],
        "blocked_external_actions" => ["provider CLI execution", "build command execution", "preview command execution", "network deployment"]
      }
    end

    def deploy_project_name
      name = File.basename(root).gsub(/[^A-Za-z0-9_-]+/, "-").downcase.sub(/\A-+/, "").sub(/-+\z/, "")
      name.empty? ? "aiweb-project" : name
    end

    def pr19_safety_payload(planned_changes)
      {
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "requires_approval" => true,
        "planned_config_paths" => planned_changes
      }
    end

    def normalize_deploy_target(target)
      normalized = target.to_s.strip.downcase.tr("_", "-")
      aliases = {
        "cloudflare" => "cloudflare-pages",
        "cloudflare-pages" => "cloudflare-pages",
        "pages" => "cloudflare-pages",
        "vercel" => "vercel"
      }
      normalized = aliases[normalized] || normalized
      return normalized if DEPLOY_PROVIDER_CONFIG_PATHS.key?(normalized)

      raise UserError.new("deploy target must be one of #{DEPLOY_PROVIDER_CONFIG_PATHS.keys.join(', ')}", 1)
    end

    def deploy_output_directory(state)
      profile = state.dig("implementation", "scaffold_profile") || state.dig("implementation", "stack_profile")
      case profile
      when "D" then "dist"
      when "S" then ".next"
      else nil
      end
    end

    def deploy_markdown(key, data)
      <<~MD
        # Deploy Plan — Profile #{key}

        ## Baseline
        #{data[:deploy]}

        ## Predeploy requirements
        - Gate 4 predeploy approval must exist.
        - Rollback criteria must be defined before production action.
        - External deploy/provider actions require explicit human approval.

        ## Rollback
        - Keep local `.ai-web` snapshot before deploy.
        - Record deploy target and version/hash.
        - Record dry-run rollback result before release.
      MD
    end

    end
  end
end
