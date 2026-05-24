# frozen_string_literal: true

module Aiweb
  module ProjectEngineSchedulerService
    private

    def engine_scheduler_supervisor_record(target:, run_id:, approval_hash:, approved:, execute:, dry_run:, max_ticks:, interval_seconds:, workers:)
      selected_run = target && target["run_id"] ? run_lifecycle_record("run_id" => target.fetch("run_id")) : nil
      selected_run_id = selected_run && selected_run["run_id"]
      run_selector = run_id.to_s.strip.empty? ? "latest" : run_id.to_s.strip
      selected_metadata = selected_run_id ? (read_json_file(File.join(run_lifecycle_run_dir(selected_run_id), "engine-run.json")) || {}) : {}
      selected_resume_context = selected_run_id ? engine_run_resume_context(selected_run_id) : nil
      approval_evidence = selected_run_id ? engine_scheduler_resume_approval_evidence(selected_metadata, selected_run_id, selected_resume_context) : {}
      expected_approval_hash = approval_evidence["approval_hash"]
      supervisor_hash = approval_hash.to_s.strip.empty? ? (expected_approval_hash || "HASH") : approval_hash.to_s.strip
      daemon_argv = ["aiweb", "engine-scheduler", "daemon", "--max-ticks", max_ticks.to_s, "--interval-seconds", interval_seconds.to_s, "--workers", workers.to_s]
      daemon_argv.concat(["--run-id", selected_run_id]) if selected_run_id
      daemon_argv.concat(["--approval-hash", supervisor_hash])
      daemon_argv << "--approved"
      daemon_argv << "--execute"
      blocking = []
      blocking << "engine scheduler supervisor cannot install or execute OS service managers from aiweb; use generated artifacts for manual/operator install" if execute
      status = blocking.empty? ? "recorded" : "blocked"
      {
        "schema_version" => 1,
        "status" => status,
        "supervisor_driver" => ENGINE_SCHEDULER_SUPERVISOR_DRIVER,
        "daemon_driver" => ENGINE_SCHEDULER_DAEMON_DRIVER,
        "worker_pool_driver" => ENGINE_SCHEDULER_WORKER_POOL_DRIVER,
        "service_type" => "project_local_scheduler_supervisor_contract",
        "action" => "supervisor",
        "decision" => status == "blocked" ? "blocked" : "supervisor_plan_recorded",
        "run_selector" => run_selector,
        "selected_run_id" => selected_run_id,
        "approved" => approved == true,
        "expected_approval_hash" => expected_approval_hash,
        "approval_hash_derivation" => approval_evidence.empty? ? nil : approval_evidence,
        "execute" => execute == true,
        "dry_run" => dry_run == true,
        "install_performed" => false,
        "install_status" => "not_installed_by_aiweb",
        "supervisor_artifact_path" => ENGINE_SCHEDULER_SUPERVISOR_PATH,
        "daemon_artifact_path" => ENGINE_SCHEDULER_DAEMON_PATH,
        "heartbeat_path" => ENGINE_SCHEDULER_HEARTBEAT_PATH,
        "worker_pool_path" => ENGINE_SCHEDULER_WORKER_POOL_PATH,
        "leases_path" => ENGINE_SCHEDULER_LEASES_PATH,
        "queue_ledger_path" => ENGINE_SCHEDULER_QUEUE_LEDGER_PATH,
        "ledger_path" => ENGINE_SCHEDULER_LEDGER_PATH,
        "max_ticks" => max_ticks,
        "interval_seconds" => interval_seconds,
        "workers" => workers,
        "daemon_command" => {
          "argv" => daemon_argv,
          "working_directory" => ".",
          "operator_must_set_working_directory_to_project_root" => true,
          "approval_boundary" => "--approval-hash HASH --approved --execute resumes only through the engine-run bridge"
        },
        "restart_policy" => {
          "mode" => "external_supervisor_restart_on_failure",
          "restart" => "on_failure",
          "heartbeat_timeout_seconds" => ENGINE_SCHEDULER_LEASE_TTL_SECONDS,
          "lease_timeout_seconds" => ENGINE_SCHEDULER_LEASE_TTL_SECONDS,
          "max_backoff_seconds" => 60,
          "duplicate_claim_guard" => "leases.json duplicate active claim keys block restart; stale leases may be recovered after timeout"
        },
        "health_checks" => [
          {
            "name" => "heartbeat_recent",
            "path" => ENGINE_SCHEDULER_HEARTBEAT_PATH,
            "rule" => "recorded_at must be newer than heartbeat_timeout_seconds"
          },
          {
            "name" => "lease_staleness",
            "path" => ENGINE_SCHEDULER_LEASES_PATH,
            "rule" => "active leases older than lease_timeout_seconds are expired before duplicate checks"
          },
          {
            "name" => "queue_ledger_append_only",
            "path" => ENGINE_SCHEDULER_QUEUE_LEDGER_PATH,
            "rule" => "scheduler.tick and scheduler.lease.* events are append-only JSONL"
          }
        ],
        "service_unit_templates" => engine_scheduler_supervisor_unit_templates(daemon_argv),
        "operator_runbook" => [
          "review #{ENGINE_SCHEDULER_SUPERVISOR_PATH}",
          "install the matching service unit outside aiweb with operator privileges if desired",
          "keep working directory pinned to the project root",
          "monitor #{ENGINE_SCHEDULER_HEARTBEAT_PATH}, #{ENGINE_SCHEDULER_LEASES_PATH}, and #{ENGINE_SCHEDULER_QUEUE_LEDGER_PATH}",
          "do not expose scheduler control remotely without tenant/project/user authz"
        ],
        "production_readiness" => {
          "supervisor_contract_recorded" => true,
          "os_service_installed" => false,
          "distributed_worker_cluster" => false,
          "remote_queue" => false,
          "node_body_executor" => "engine_run_resume_bridge"
        },
        "limitations" => [
          "supervisor artifact only; aiweb does not install systemd, launchd, or Windows Task Scheduler services",
          "worker pool remains project-local lease/slot evidence, not a distributed cluster",
          "node bodies still execute through the engine-run resume bridge"
        ],
        "blocking_issues" => blocking
      }
    end

    def engine_scheduler_supervisor_unit_templates(daemon_argv)
      command = daemon_argv.join(" ")
      {
        "systemd_user_service" => [
          "[Unit]",
          "Description=aiweb engine scheduler daemon",
          "[Service]",
          "WorkingDirectory=<project-root>",
          "ExecStart=#{command}",
          "Restart=on-failure",
          "RestartSec=10",
          "[Install]",
          "WantedBy=default.target"
        ],
        "launchd_plist" => [
          "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
          "<plist version=\"1.0\"><dict>",
          "<key>Label</key><string>local.aiweb.engine-scheduler</string>",
          "<key>WorkingDirectory</key><string>&lt;project-root&gt;</string>",
          "<key>ProgramArguments</key><array>#{daemon_argv.map { |part| "<string>#{part}</string>" }.join}</array>",
          "<key>KeepAlive</key><true/>",
          "</dict></plist>"
        ],
        "windows_task_command" => "schtasks /Create /TN aiweb-engine-scheduler /SC ONSTART /TR \"#{command}\"",
        "portable_foreground_command" => command
      }
    end
  end
end
