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
      verify_gate = deploy_verify_loop_gate(state, dry_run: dry_run)
      provider_readiness = deploy_provider_readiness(target, descriptor, command)
      blockers = []
      blockers << "--approved is required for real deploy adapter execution" if !dry_run && !approved
      blockers.concat(verify_gate.fetch("blocking_issues"))
      blockers.concat(provider_readiness.fetch("blocking_issues"))
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
        "verify_loop_gate" => verify_gate,
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
        "external_actions_allowed" => approved && verify_gate["status"] == "passed" && provider_readiness["status"] == "ready",
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "provider_executed" => false,
        "requires_approval" => !approved,
        "writes_performed" => false,
        "provider_cli_invoked" => false,
        "network_calls_performed" => false
      }
    end

    def deploy_verify_loop_gate(state, dry_run: false)
      path = state.dig("implementation", "latest_verify_loop").to_s.strip
      blockers = []
      metadata = nil
      expected_provenance = nil
      current_provenance = nil
      provenance_comparison = nil
      if path.empty?
        blockers << "passing verify-loop evidence is required before deploy"
      elsif unsafe_env_path?(path)
        blockers << "verify-loop evidence path is unsafe"
      else
        full = File.expand_path(path, root)
        if !full.start_with?(aiweb_dir + File::SEPARATOR) || !File.file?(full)
          blockers << "verify-loop evidence is missing: #{path}"
        else
          begin
            metadata = JSON.parse(File.read(full))
          rescue JSON::ParserError
            blockers << "verify-loop evidence is malformed: #{path}"
          end
        end
      end
      if metadata
        blockers << "verify-loop must pass before deploy" unless metadata["status"] == "passed"
        blockers << "verify-loop evidence must be from an approved real run" unless metadata["approved"] == true && metadata["dry_run"] == false
        expected_provenance = metadata["provenance"]
        if expected_provenance.nil?
          blockers << "verify-loop evidence is missing deployment provenance; rerun aiweb verify-loop --max-cycles 3 --approved"
        elsif !dry_run
          current_provenance = deploy_workspace_provenance(state, include_tool_versions: true)
          provenance_comparison = deploy_provenance_comparison(expected_provenance, current_provenance)
          blockers.concat(provenance_comparison.fetch("blocking_issues"))
        else
          provenance_comparison = {
            "status" => "not_checked",
            "dry_run" => true,
            "blocking_issues" => [],
            "note" => "deploy --dry-run does not execute git/tool version checks"
          }
        end
      end
      {
        "status" => blockers.empty? ? "passed" : "blocked",
        "path" => path.empty? ? nil : path,
        "verify_loop_status" => metadata && metadata["status"],
        "approved" => metadata && metadata["approved"],
        "dry_run" => metadata && metadata["dry_run"],
        "provenance" => {
          "expected" => expected_provenance,
          "current" => current_provenance,
          "comparison" => provenance_comparison
        },
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
          "requires_passing_verify_loop" => true,
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
          "verify_loop_status" => deploy_payload.dig("verify_loop_gate", "status"),
          "provider_readiness_status" => deploy_payload.dig("provider_readiness", "status")
        }
      )
    end

    end
  end
end
