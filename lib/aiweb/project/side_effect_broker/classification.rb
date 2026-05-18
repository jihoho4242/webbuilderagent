# frozen_string_literal: true

module Aiweb
  module ProjectSideEffectBroker
    SIDE_EFFECT_DEPLOY_PROVENANCE_PATHS = %w[
      lib/aiweb/project/deploy.rb
      lib/aiweb/project/deploy/execution.rb
      lib/aiweb/project/deploy/provenance.rb
    ].freeze
    SIDE_EFFECT_SETUP_SUPPLY_CHAIN_PATHS = %w[
      lib/aiweb/project/runtime_commands/setup.rb
      lib/aiweb/project/runtime_commands/setup/supply_chain/broker.rb
      lib/aiweb/project/runtime_commands/setup/supply_chain.rb
    ].freeze
    SIDE_EFFECT_AGENT_RUN_WORKER_PATHS = %w[
      lib/aiweb/project/agent_run.rb
      lib/aiweb/project/agent_run/codex_runner.rb
    ].freeze

    private

    def side_effect_surface_classification(path, line, lines, index)
      context = lines[[index - 8, 0].max..[index + 8, lines.length - 1].min].join("\n")
      if path == "bin/check" || path == "bin/engine-runtime-matrix-check"
        return side_effect_classification("local_verification_harness_exception", "documented_exception", nil, "bin/* verification harnesses run local checks only and are not production agent side-effect paths")
      end
      if %w[aiweb 웹빌더].include?(path) && line.match?(/\A\s*exec\s+/) && side_effect_surface_safe_launcher_exec?(path, line)
        return side_effect_classification("local_cli_launcher_wrapper", "documented_exception", nil, "root launcher delegates to the repo-local aiweb executable")
      end
      if path.end_with?("lib/aiweb/project/browser_observer_script.js")
        return side_effect_classification("local_browser_observer_template_literal", "documented_exception", nil, "browser observer JavaScript is written by engine-run and executed only through the local browser-observation path; JavaScript template literals are not shell execution")
      end
      return side_effect_classification("brokered_backend_cli_bridge", "brokered", "aiweb.backend.side_effect_broker", "backend bridge writes broker events before Open3.popen3") if path.end_with?("lib/aiweb/daemon/cli_bridge.rb") && line.include?("Open3.popen3")
      if path.end_with?("lib/aiweb/lazyweb_client.rb") && line.match?(/Net::HTTP/)
        return side_effect_classification("brokered_lazyweb_http", "brokered", "aiweb.lazyweb.side_effect_broker", "LazywebClient emits broker audit events around Net::HTTP")
      end
      if side_effect_path_in?(path, SIDE_EFFECT_DEPLOY_PROVENANCE_PATHS) && line.include?("Open3.capture3") && context.include?("append_side_effect_broker_event")
        return side_effect_classification("brokered_deploy_provider_cli", "brokered", "aiweb.deploy.side_effect_broker", "deploy provider CLI execution is gated by approval/provenance checks and emits side-effect broker events")
      end
      if side_effect_path_in?(path, SIDE_EFFECT_DEPLOY_PROVENANCE_PATHS) && line.match?(/git.*status/)
        return side_effect_classification("local_read_only_git_provenance", "documented_exception", nil, "git status subprocess is local read-only deploy provenance collection")
      end
      if side_effect_path_in?(path, SIDE_EFFECT_DEPLOY_PROVENANCE_PATHS) && line.include?("Open3.capture3")
        return side_effect_classification("local_tool_version_probe", "documented_exception", nil, "tool version subprocesses are short local readiness probes with a timeout and clean environment")
      end
      if path.end_with?("lib/aiweb/project/agent_run/openmanus.rb") && line.include?("image\", \"inspect")
        return side_effect_classification("openmanus_sandbox_image_preflight", "documented_exception", nil, "Docker/Podman image inspect is a local preflight that only checks sandbox image availability")
      end
      if path.end_with?("lib/aiweb/project/agent_run/openmanus.rb") && line.include?("Open3.popen3")
        return side_effect_classification("brokered_openmanus_sandbox_subprocess", "brokered", "aiweb.openmanus.tool_broker", "OpenManus runs in an aiweb-managed sandbox with clean environment, network disabled, PATH-prepended tool broker, and copied-back scoped outputs")
      end
      if side_effect_path_in?(path, SIDE_EFFECT_SETUP_SUPPLY_CHAIN_PATHS) && line.include?("Open3.capture3") && context.include?("append_side_effect_broker_event")
        return side_effect_classification("brokered_setup_supply_chain_command", "brokered", "aiweb.setup.side_effect_broker", "setup package-manager/SBOM/audit subprocess is surrounded by broker events")
      end
      if path.end_with?("lib/aiweb/project/runtime_commands.rb") && line.include?("system(")
        return side_effect_classification("local_process_tree_cleanup", "documented_exception", nil, "taskkill/system calls are local cleanup fallbacks for preview process trees")
      end
      if path.end_with?("lib/aiweb/project/runtime_commands/qa_artifacts.rb") && line.include?("Open3.capture3")
        return side_effect_classification("local_qa_artifact_runner", "documented_exception", nil, "QA artifact subprocess is a local static/browser verification command writing run evidence")
      end
      if path.end_with?("lib/aiweb/runtime/process_runner.rb") && line.match?(/Open3\.(?:capture3|popen3)/)
        return side_effect_classification("central_runtime_process_runner", "brokered", "aiweb.runtime.process_runner", "central CommandSpec/ProcessRunner executes argv-only local commands with scrubbed environment, timeout, output caps, and redaction")
      end
      if path.end_with?("lib/aiweb/runtime/process_launcher.rb") && line.include?("def spawn")
        return side_effect_classification("central_runtime_process_launcher_api", "brokered", "aiweb.runtime.process_launcher", "central ProcessLauncher API is the named boundary for long-running local argv subprocesses")
      end
      if path.end_with?("lib/aiweb/runtime/process_launcher.rb") && line.include?("Process.spawn")
        return side_effect_classification("central_runtime_process_launcher", "brokered", "aiweb.runtime.process_launcher", "central ProcessLauncher starts long-running local argv commands with scrubbed environment and explicit stdio")
      end
      if path.end_with?("lib/aiweb/project/engine_run.rb") && line.include?("Open3.popen3")
        return side_effect_classification("brokered_engine_run_capture_command", "brokered", "aiweb.engine_run.tool_broker", "engine_run_capture_command is invoked with staged tool-broker PATH and emits workspace tool-broker events")
      end
      if path.end_with?("lib/aiweb/project/engine_run/sandbox_process.rb") && line.include?("Open3.capture3") && context.include?("def engine_run_capture_command")
        return side_effect_classification("brokered_engine_run_capture_command", "brokered", "aiweb.engine_run.tool_broker", "engine_run_capture_command is invoked with staged tool-broker PATH and emits workspace tool-broker events")
      end
      if path.end_with?("lib/aiweb/project/engine_run/generated_sources.rb") && line.match?(/exec "\$dir\/\$TOOL_NAME"/)
        return side_effect_classification("brokered_generated_tool_broker_delegate", "brokered", "aiweb.engine_run.tool_broker", "generated POSIX tool-broker shim delegates only after package/git/external-network block checks")
      end
      if path.end_with?("lib/aiweb/project/engine_run/sandbox_process.rb") && line.include?("Open3.capture3")
        return side_effect_classification("sandbox_runtime_attestation_exception", "documented_exception", nil, "Docker/Podman inspect/info/rm commands are local runtime-attestation probes, redacted, and recorded in sandbox-preflight evidence")
      end
      if path.end_with?("lib/aiweb/project/agent_run/diff_policy.rb") && line.match?(/git.*diff|git.*status/)
        return side_effect_classification("local_read_only_git_evidence", "documented_exception", nil, "git diff/status subprocesses are local read-only evidence collection for bounded agent-run")
      end
      if path.end_with?("lib/aiweb/project/agent_run.rb") && line.match?(/git.*diff|git.*status/)
        return side_effect_classification("local_read_only_git_evidence", "documented_exception", nil, "git diff/status subprocesses are local read-only evidence collection for bounded agent-run")
      end
      if side_effect_path_in?(path, SIDE_EFFECT_AGENT_RUN_WORKER_PATHS) && line.include?("Open3.capture3")
        return side_effect_classification("legacy_agent_run_worker_subprocess", "documented_exception", nil, "legacy agent-run worker subprocess is bounded by agent-run context and OpenManus tool-broker log evidence; not a universal broker path")
      end
      if path.end_with?("lib/aiweb/project/runtime_commands.rb") && line.include?("Open3.capture3")
        return side_effect_classification("local_runtime_command_exception", "documented_exception", nil, "verify/QA/git revision subprocesses are project-local runtime commands; setup install commands are separately brokered")
      end
      if path.end_with?("lib/aiweb/daemon/openmanus_readiness.rb") && line.include?("Open3.capture3")
        return side_effect_classification("local_runtime_readiness_probe", "documented_exception", nil, "OpenManus readiness only inspects local Docker/Podman image availability")
      end
      side_effect_classification("unclassified_direct_side_effect", "unclassified", nil, "direct process/network surface is not yet classified by side-effect broker audit")
    end


    def side_effect_path_in?(path, candidates)
      candidates.any? { |candidate| path.end_with?(candidate) }
    end

    def side_effect_surface_safe_launcher_exec?(path, line)
      case path
      when "aiweb"
        line.include?('"$DIR/bin/aiweb" "$@"')
      when "웹빌더"
        line.include?('"$DIR/bin/webbuilder" "$@"')
      else
        false
      end
    end

    def side_effect_classification(classification, coverage_status, broker, rationale)
      {
        "classification" => classification,
        "coverage_status" => coverage_status,
        "broker" => broker,
        "rationale" => rationale
      }
    end
  end
end
