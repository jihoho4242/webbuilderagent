# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "timeout"

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
        payload["next_action"] = "obtain explicit approval and passing verify-loop evidence before any provider deployment; this dry-run wrote nothing and ran no provider CLI"
      elsif deploy_payload["status"] == "blocked"
        payload["blocking_issues"] = (payload["blocking_issues"] + deploy_payload["blocking_issues"]).uniq
        payload["next_action"] = "resolve deploy gates, then rerun aiweb deploy --target #{normalized_target} --approved"
      else
        active_record = active_run_begin!(
          kind: "deploy",
          run_id: run_id,
          run_dir: run_dir,
          metadata_path: metadata_path,
          command: deploy_payload.fetch("command"),
          force: force
        )
        begin
        changes = []
        mutation(dry_run: false) do
          FileUtils.mkdir_p(run_dir)
          changes << relative(run_dir)
          started_at = now
          command = deploy_payload.fetch("command")
          side_effect_broker_events = []
          side_effect_context = deploy_side_effect_broker_context(
            target: normalized_target,
            command: command,
            deploy_payload: deploy_payload
          )
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.requested",
            side_effect_context.merge(
              "requested_at" => started_at,
              "dry_run" => false
            )
          )
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "policy.decision",
            side_effect_context.merge(
              "decision" => "allow",
              "reason" => "explicit --approved deploy with passing verify-loop evidence and ready provider CLI"
            )
          )
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.started",
            side_effect_context.merge("started_at" => started_at)
          )
          stdout, stderr, process_status = begin
            Open3.capture3(*command, chdir: root)
          rescue StandardError => error
            append_side_effect_broker_event(
              side_effect_broker_path,
              side_effect_broker_events,
              "tool.failed",
              side_effect_context.merge(
                "finished_at" => now,
                "error_class" => error.class.name,
                "error_message" => error.message.to_s[0, 240]
              )
            )
            raise
          end
          status = process_status.success? ? "passed" : "failed"
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.finished",
            side_effect_context.merge(
              "finished_at" => now,
              "status" => status,
              "exit_code" => process_status.exitstatus
            )
          )
          blocking_issues = process_status.success? ? [] : ["#{command.first} exited with status #{process_status.exitstatus}"]
          stdout = redact_side_effect_process_output(stdout)
          stderr = redact_side_effect_process_output(stderr)
          changes << write_file(stdout_path, stdout, false)
          changes << write_file(stderr_path, stderr, false)
          changes << relative(side_effect_broker_path)
          deploy_payload = deploy_payload.merge(
            "status" => status,
            "started_at" => started_at,
            "finished_at" => now,
            "exit_code" => process_status.exitstatus,
            "stdout_log" => relative(stdout_path),
            "stderr_log" => relative(stderr_path),
            "metadata_path" => relative(metadata_path),
            "side_effect_broker_path" => relative(side_effect_broker_path),
            "side_effect_broker_events" => side_effect_broker_events,
            "side_effect_broker" => deploy_payload.fetch("side_effect_broker").merge(
              "status" => status,
              "events_recorded" => true,
              "events_path" => relative(side_effect_broker_path),
              "event_count" => side_effect_broker_events.length
            ),
            "blocking_issues" => blocking_issues,
            "provider_executed" => true,
            "provider_cli_invoked" => true,
            "external_deploy_performed" => process_status.success?,
            "network_calls_performed" => true,
            "network_call_status" => process_status.success? ? "performed" : "attempted_unknown_result",
            "writes_performed" => true
          )
          changes << write_json(metadata_path, deploy_payload, false)
          state["deploy"]["latest_deploy"] = relative(metadata_path)
          state["deploy"]["latest_deploy_target"] = normalized_target
          state["deploy"]["latest_deploy_status"] = status
          state["deploy"]["latest_deploy_at"] = deploy_payload["finished_at"]
          state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
          add_decision!(state, "deploy_adapter", "Ran approved #{normalized_target} deploy adapter after passing verify-loop gate")
          changes << write_yaml(state_path, state, false)
          payload = status_hash(state: state, changed_files: compact_changes(changes))
          payload["action_taken"] = status == "passed" ? "ran approved deploy adapter" : "approved deploy adapter failed"
          payload["deploy"] = deploy_payload
          payload.merge!(pr19_safety_payload(planned_changes))
          payload["external_deploy_performed"] = deploy_payload["external_deploy_performed"]
          payload["requires_approval"] = false
          payload["blocking_issues"] = blocking_issues
          payload["next_action"] = status == "passed" ? "review #{relative(metadata_path)} before treating the provider deployment as accepted" : "inspect #{relative(stderr_path)} and provider readiness, then rerun deploy after fixing the blocker"
        end
        active_run_finish!(active_record, payload.dig("deploy", "status") || "completed")
        active_record = nil
        ensure
          active_run_finish!(active_record, "failed") if active_record
        end
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

    def deploy_workspace_provenance(state, include_tool_versions:)
      output_directory = deploy_output_directory(state)
      {
        "schema_version" => 1,
        "captured_at" => now,
        "workspace" => {
          "git" => git_workspace_provenance(deploy_git_provenance_paths(output_directory)),
          "source" => deploy_source_tree_provenance,
          "package" => deploy_package_provenance
        },
        "output" => deploy_output_provenance(output_directory),
        "tool_versions" => include_tool_versions ? deploy_tool_versions : {}
      }
    end

    def deploy_provenance_comparison(expected, current)
      checks = [
        ["git.commit_sha", expected.dig("workspace", "git", "commit_sha"), current.dig("workspace", "git", "commit_sha")],
        ["git.dirty", expected.dig("workspace", "git", "dirty"), current.dig("workspace", "git", "dirty")],
        ["git.status_sha256", expected.dig("workspace", "git", "status_sha256"), current.dig("workspace", "git", "status_sha256")],
        ["source.sha256", expected.dig("workspace", "source", "sha256"), current.dig("workspace", "source", "sha256")],
        ["package.sha256", expected.dig("workspace", "package", "sha256"), current.dig("workspace", "package", "sha256")],
        ["output.directory", expected.dig("output", "directory"), current.dig("output", "directory")],
        ["output.sha256", expected.dig("output", "sha256"), current.dig("output", "sha256")]
      ]
      expected_tools = expected["tool_versions"].is_a?(Hash) ? expected["tool_versions"] : {}
      current_tools = current["tool_versions"].is_a?(Hash) ? current["tool_versions"] : {}
      (expected_tools.keys | current_tools.keys).sort.each do |tool|
        checks << ["tool_versions.#{tool}", expected_tools[tool], current_tools[tool]]
      end

      mismatches = checks.each_with_object([]) do |(field, expected_value, current_value), memo|
        next if expected_value == current_value

        memo << {
          "field" => field,
          "expected" => expected_value,
          "current" => current_value
        }
      end
      {
        "status" => mismatches.empty? ? "matched" : "mismatched",
        "mismatches" => mismatches,
        "blocking_issues" => mismatches.map { |entry| "verify-loop provenance mismatch for #{entry.fetch("field")}; rerun aiweb verify-loop --max-cycles 3 --approved before deploy" }
      }
    end

    def git_workspace_provenance(paths)
      commit = git_commit_sha
      scope_paths = Array(paths).map { |path| path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "") }
                                .reject { |path| path.empty? || unsafe_env_path?(path) || deploy_hash_excluded_path?(path) }
                                .uniq
                                .sort
      stdout, _stderr, status = Open3.capture3("git", "status", "--porcelain=v1", "-uall", "--", *scope_paths, chdir: root)
      if status.success?
        normalized = stdout.lines.map(&:chomp).sort.join("\n")
        {
          "available" => true,
          "commit_sha" => commit,
          "dirty" => !normalized.empty?,
          "status_sha256" => Digest::SHA256.hexdigest(normalized),
          "scope_paths" => scope_paths
        }
      else
        {
          "available" => false,
          "commit_sha" => commit,
          "dirty" => nil,
          "status_sha256" => nil,
          "scope_paths" => scope_paths
        }
      end
    rescue StandardError
      {
        "available" => false,
        "commit_sha" => "unknown",
        "dirty" => nil,
        "status_sha256" => nil,
        "scope_paths" => []
      }
    end

    def deploy_git_provenance_paths(output_directory)
      paths = deploy_source_provenance_paths + %w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb]
      paths << output_directory unless output_directory.to_s.empty?
      paths.select { |path| File.exist?(File.join(root, path)) }
    end

    def deploy_source_tree_provenance
      deploy_hash_paths(deploy_source_provenance_paths, "source")
    end

    def deploy_package_provenance
      deploy_hash_paths(%w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb], "package")
    end

    def deploy_output_provenance(output_directory)
      return { "directory" => nil, "exists" => false, "file_count" => 0, "sha256" => nil } if output_directory.to_s.empty?

      deploy_hash_paths([output_directory], "output").merge("directory" => output_directory)
    end

    def deploy_source_provenance_paths
      candidates = %w[
        src
        public
        astro.config.mjs
        astro.config.js
        next.config.js
        next.config.mjs
        tsconfig.json
        tailwind.config.js
        tailwind.config.mjs
        vite.config.js
        vite.config.mjs
      ]
      candidates.select { |path| File.exist?(File.join(root, path)) }
    end

    def deploy_hash_paths(paths, label)
      files = deploy_hashable_files(paths)
      digest = Digest::SHA256.new
      files.each do |path|
        full = File.join(root, path)
        digest.update("#{path}\0")
        digest.update(Digest::SHA256.file(full).hexdigest)
        digest.update("\0")
      end
      {
        "label" => label,
        "exists" => !files.empty?,
        "file_count" => files.length,
        "sha256" => files.empty? ? nil : digest.hexdigest
      }
    end

    def deploy_hashable_files(paths)
      Array(paths).flat_map do |path|
        normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
        next [] if normalized.empty? || unsafe_env_path?(normalized)

        full = File.join(root, normalized)
        if File.file?(full)
          [normalized]
        elsif File.directory?(full)
          files = []
          Find.find(full) do |entry|
            rel = relative(entry)
            if deploy_hash_excluded_path?(rel)
              Find.prune if File.directory?(entry)
              next
            end
            files << rel if File.file?(entry)
          end
          files
        else
          []
        end
      end.compact.uniq.sort
    end

    def deploy_hash_excluded_path?(path)
      normalized = path.to_s.tr("\\", "/")
      return true if normalized.empty?
      return true if unsafe_env_path?(normalized)

      normalized.split("/").any? { |part| %w[.git .ai-web node_modules].include?(part) }
    end

    def deploy_tool_versions
      {
        "ruby" => RUBY_VERSION,
        "pnpm" => executable_version("pnpm", "--version"),
        "playwright" => executable_version(File.join("node_modules", ".bin", "playwright"), "--version"),
        "axe" => executable_version(File.join("node_modules", ".bin", "axe"), "--version"),
        "lighthouse" => executable_version(File.join("node_modules", ".bin", "lighthouse"), "--version")
      }
    end

    def executable_version(executable, *args)
      command = if executable.include?(File::SEPARATOR)
                  path = File.join(root, executable)
                  return nil unless File.executable?(path)

                  [path, *args]
                else
                  path = executable_path(executable)
                  return nil unless path

                  [path, *args]
                end
      stdout = ""
      Timeout.timeout(2) do
        stdout, _stderr, status = Open3.capture3(subprocess_path_env, *command, chdir: root, unsetenv_others: true)
        return nil unless status.success?
      end
      stdout.lines.first.to_s.strip[0, 120]
    rescue StandardError
      nil
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
