# frozen_string_literal: true

module Aiweb
  module ProjectSideEffectBroker
    private

    def side_effect_surface_classification(path, line, lines, index)
      if %w[aiweb 웹빌더].include?(path) && line.match?(/\A\s*exec\s+/) && side_effect_surface_safe_launcher_exec?(path, line)
        return side_effect_classification("local_cli_launcher_wrapper", "documented_exception", nil, "root launcher delegates to the repo-local aiweb executable")
      end
      if path.end_with?("lib/aiweb/project/browser_observer_script.js")
        return side_effect_classification("local_browser_observer_template_literal", "documented_exception", nil, "browser observer JavaScript is written by engine-run and executed only through the local browser-observation path; JavaScript template literals are not shell execution")
      end
      if path.end_with?("lib/aiweb/runtime/process_runner.rb") && line.match?(/Open3\.(?:capture3|popen3)/)
        return side_effect_classification("central_runtime_process_runner", "brokered", "aiweb.runtime.process_runner", "central CommandSpec/ProcessRunner executes argv-only local commands with scrubbed environment, timeout, output caps, and redaction")
      end
      if path.end_with?("lib/aiweb/runtime/process_runner.rb") && line.match?(/(?<![.\w-])system\(/)
        return side_effect_classification("central_runtime_process_runner_cleanup", "brokered", "aiweb.runtime.process_runner", "central ProcessRunner uses argv-only taskkill for Windows timeout cleanup after a CommandSpec-brokered subprocess times out")
      end
      if path.end_with?("lib/aiweb/runtime/http_client.rb") && line.match?(/Net::HTTP/)
        return side_effect_classification("central_runtime_http_client", "brokered", "aiweb.runtime.http_client", "central HttpRequestSpec/HttpClient executes external HTTP with explicit method, timeout, body cap, and structured result")
      end
      if path.end_with?("lib/aiweb/runtime/process_launcher.rb") && line.include?("def spawn")
        return side_effect_classification("central_runtime_process_launcher_api", "brokered", "aiweb.runtime.process_launcher", "central ProcessLauncher API requires LaunchSpec for long-running local argv subprocesses")
      end
      if path.end_with?("lib/aiweb/runtime/process_launcher.rb") && line.include?("Process.spawn")
        return side_effect_classification("central_runtime_process_launcher", "brokered", "aiweb.runtime.process_launcher", "central ProcessLauncher starts LaunchSpec-validated long-running local argv commands with scrubbed environment and explicit stdio")
      end
      if path.end_with?("lib/aiweb/project/engine_run/generated_sources.rb") && line.match?(/exec "\$dir\/\$TOOL_NAME"/)
        return side_effect_classification("brokered_generated_tool_broker_delegate", "brokered", "aiweb.engine_run.tool_broker", "generated POSIX tool-broker shim delegates only after package/git/external-network block checks")
      end
      if path.end_with?("lib/aiweb/project/engine_run/generated_sources/tool_broker_shim.rb") && line.match?(/exec "\$dir\/\$TOOL_NAME"/)
        return side_effect_classification("brokered_generated_tool_broker_delegate", "brokered", "aiweb.engine_run.tool_broker", "generated POSIX tool-broker shim delegates only after package/git/external-network block checks")
      end
      side_effect_classification("unclassified_direct_side_effect", "unclassified", nil, "direct process/network surface is not yet classified by side-effect broker audit")
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
