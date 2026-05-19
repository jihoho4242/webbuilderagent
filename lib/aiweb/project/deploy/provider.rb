# frozen_string_literal: true

module Aiweb
  class Project
    module Deploy
      private

    def deploy_provider_descriptor(target, state)
      {
        "schema_version" => 1,
        "target" => target,
        "created_at" => now,
        "project_id" => state.dig("project", "id"),
        "mode" => "dry_run_descriptor_only",
        "planned_config_path" => DEPLOY_PROVIDER_CONFIG_PATHS.fetch(target),
        "build_command" => state.dig("implementation", "scaffold_build_command"),
        "output_directory" => deploy_output_directory(state),
        "preview_url_slot" => target == "cloudflare-pages" ? "cloudflare_preview_url" : "vercel_preview_url",
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "requires_approval" => true,
        "provider_cli_invoked" => false,
        "network_calls_performed" => false
      }
    end

    def deploy_local_payload(target, state, dry_run:, force:, approved:, run_id:, run_dir:, stdout_path:, stderr_path:, metadata_path:, side_effect_broker_path:)
      descriptor = deploy_provider_descriptor(target, state)
      command = deploy_provider_command(target, descriptor)
      release_gate = deploy_release_gate(state, dry_run: dry_run)
      provider_readiness = deploy_provider_readiness(target, descriptor, command)
      blockers = []
      blockers << "--approved is required for real deploy adapter execution" if !dry_run && !approved
      blockers.concat(release_gate.fetch("blocking_issues"))
      blockers.concat(provider_readiness.fetch("blocking_issues"))
      blockers << "provider CLI execution has been removed from this local deploy adapter until engine-run owns release evidence and external side-effect approval" unless dry_run
      blocked = !dry_run && !blockers.empty?
      {
        "schema_version" => 1,
        "status" => dry_run ? "planned" : (blocked ? "blocked" : "ready"),
        "target" => target,
        "dry_run" => dry_run,
        "force" => force,
        "approved" => approved,
        "run_id" => run_id,
        "run_dir" => relative(run_dir),
        "stdout_log" => relative(stdout_path),
        "stderr_log" => relative(stderr_path),
        "metadata_path" => relative(metadata_path),
        "side_effect_broker_path" => relative(side_effect_broker_path),
        "planned_artifact_path" => descriptor.fetch("planned_config_path"),
        "planned_config_path" => descriptor.fetch("planned_config_path"),
        "planned_changes" => [DEPLOY_PLAN_PATH, descriptor.fetch("planned_config_path"), relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path), relative(side_effect_broker_path)],
        "descriptor" => descriptor,
        "release_gate" => release_gate,
        "provider_readiness" => provider_readiness,
        "command" => command,
        "side_effect_broker" => deploy_side_effect_broker_plan(
          target: target,
          command: command,
          broker_path: side_effect_broker_path,
          dry_run: dry_run,
          approved: approved,
          blocked: blocked,
          blockers: blockers
        ),
        "side_effect_broker_events" => [],
        "blocking_issues" => blocked ? blockers.uniq : [],
        "external_actions_allowed" => false,
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "provider_executed" => false,
        "requires_approval" => !approved,
        "requires_engine_run_release_evidence" => true,
        "legacy_verify_loop_gate_removed" => true,
        "writes_performed" => false,
        "provider_cli_invoked" => false,
        "network_calls_performed" => false
      }
    end

    def deploy_release_gate(_state, dry_run: false)
      return {
        "status" => "not_checked",
        "gate" => "engine_run_release_evidence",
        "dry_run" => true,
        "path" => nil,
        "legacy_verify_loop_gate_removed" => true,
        "provider_cli_execution_available" => false,
        "policy" => "Deploy dry-run is plan-only and does not check external release evidence.",
        "blocking_issues" => []
      } if dry_run

      blockers = ["engine-run release evidence gate is not implemented yet; removed verify-loop provenance must not unlock deploy"]
      {
        "status" => "blocked",
        "gate" => "engine_run_release_evidence",
        "dry_run" => false,
        "path" => nil,
        "legacy_verify_loop_gate_removed" => true,
        "provider_cli_execution_available" => false,
        "policy" => "Provider deploy remains disabled until engine-run owns release provenance, HITL approval, rollback evidence, and PolicyKernel side-effect approval.",
        "blocking_issues" => blockers
      }
    end

    def deploy_provider_command(target, descriptor)
      output_directory = descriptor["output_directory"].to_s
      case target
      when "cloudflare-pages"
        ["wrangler", "pages", "deploy", output_directory, "--project-name", deploy_project_name]
      when "vercel"
        ["vercel", "deploy", output_directory, "--prebuilt"]
      else
        [target]
      end
    end

    def deploy_provider_readiness(target, descriptor, command)
      blockers = []
      output_directory = descriptor["output_directory"].to_s
      blockers << "deploy output directory is missing for #{target}: #{output_directory}" if output_directory.empty? || !Dir.exist?(File.join(root, output_directory))
      executable = command.first.to_s
      blockers << "provider CLI executable is missing from PATH: #{executable}" if executable_path(executable).nil?
      {
        "status" => blockers.empty? ? "ready" : "blocked",
        "target" => target,
        "output_directory" => output_directory,
        "executable" => executable,
        "command" => command,
        "blocking_issues" => blockers
      }
    end

    def deploy_side_effect_broker_plan(target:, command:, broker_path:, dry_run:, approved:, blocked:, blockers:)
      side_effect_broker_plan(
        broker: "aiweb.deploy.side_effect_broker",
        scope: "deploy.provider_cli",
        target: target,
        command: command,
        broker_path: broker_path,
        dry_run: dry_run,
        approved: approved,
        blocked: blocked,
        blockers: blockers,
        risk_class: "external_network_deploy",
        policy_extra: {
          "requires_engine_run_release_evidence" => true,
          "legacy_verify_loop_gate_removed" => true,
          "requires_ready_provider_cli" => true
        }
      )
    end

    def deploy_side_effect_broker_context(target:, command:, deploy_payload:)
      side_effect_broker_context(
        broker: "aiweb.deploy.side_effect_broker",
        scope: "deploy.provider_cli",
        target: target,
        command: command,
        risk_class: "external_network_deploy",
        approved: deploy_payload.fetch("approved"),
        extra: {
          "release_gate_status" => deploy_payload.dig("release_gate", "status"),
          "provider_readiness_status" => deploy_payload.dig("provider_readiness", "status")
        }
      )
    end

    end
  end
end
