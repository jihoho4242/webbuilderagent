# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_side_effect_broker_plan(command_argv:, broker_path:, dry_run:, approved:, blocked:, blockers:)
      side_effect_broker_plan(
        broker: "aiweb.setup.side_effect_broker",
        scope: "setup.package_install",
        target: "project_dependencies",
        command: command_argv,
        broker_path: broker_path,
        dry_run: dry_run,
        approved: approved,
        blocked: blocked,
        blockers: blockers,
        risk_class: "package_install_network_supply_chain",
        policy_extra: {
          "requires_exact_command" => true,
          "requires_approval" => true,
          "lifecycle_scripts_may_run" => false,
          "lifecycle_script_policy" => "disabled_by_default_with_ignore_scripts"
        }
      )
    end

    def setup_side_effect_broker_context(command_argv:, approved:, scope: "setup.package_install", target: "project_dependencies", network_call_status: "attempted_unknown_result")
      side_effect_broker_context(
        broker: "aiweb.setup.side_effect_broker",
        scope: scope,
        target: target,
        command: command_argv,
        risk_class: "package_install_network_supply_chain",
        approved: approved,
        extra: {
          "package_manager" => command_argv.first.to_s,
          "network_call_status" => network_call_status
        }
      )
    end

    def setup_run_brokered_supply_chain_command(broker_path, events, command_argv, scope:, target:, network_call_status:)
      started_at = now
      context = setup_side_effect_broker_context(
        command_argv: command_argv,
        approved: true,
        scope: scope,
        target: target,
        network_call_status: network_call_status
      )
      append_side_effect_broker_event(broker_path, events, "tool.requested", context.merge("requested_at" => started_at, "dry_run" => false))
      append_side_effect_broker_event(broker_path, events, "policy.decision", context.merge("decision" => "allow", "reason" => "explicit --approved setup supply-chain evidence"))
      append_side_effect_broker_event(broker_path, events, "tool.started", context.merge("started_at" => started_at))
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: command_argv,
          cwd: root,
          env: setup_child_env,
          timeout: 180,
          max_output_bytes: 200_000,
          risk_class: "setup_supply_chain_evidence",
          description: "approved setup supply-chain evidence command"
        )
      )
      status = result.success? ? "passed" : "failed"
      append_side_effect_broker_event(broker_path, events, "tool.finished", context.merge("finished_at" => now, "status" => status, "exit_code" => result.exit_code))
      {
        "command" => command_argv,
        "status" => status,
        "exit_code" => result.exit_code,
        "stdout" => redact_side_effect_process_output(redact_setup_output(result.stdout)),
        "stderr" => redact_side_effect_process_output(redact_setup_output(result.stderr))
      }
    end
  end
end
