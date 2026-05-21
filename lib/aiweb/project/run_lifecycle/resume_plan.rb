# frozen_string_literal: true

require "shellwords"

module Aiweb
  module ProjectRunLifecycle
    private

    def run_resume_plan(target, metadata)
      kind = target["kind"].to_s
      command = case kind
                when "verify-loop"
                  verify_loop_handoff_command(metadata)
                when "deploy"
                  target_name = metadata["target"].to_s
                  target_name.empty? ? nil : ["aiweb", "deploy", "--target", target_name, "--dry-run"]
                when "workbench-serve"
                  command = ["aiweb", "workbench", "--serve", "--dry-run"]
                  command += ["--host", metadata["host"].to_s] unless metadata["host"].to_s.empty?
                  command += ["--port", metadata["port"].to_s] unless metadata["port"].to_s.empty?
                  command
                when "setup"
                  ["aiweb", "setup", "--install", "--dry-run"]
                when "agent-run"
                  command = ["aiweb", "agent-run", "--task", "latest", "--agent", metadata["agent"].to_s.empty? ? "codex" : metadata["agent"].to_s, "--dry-run"]
                  command += ["--sandbox", metadata["sandbox"].to_s] unless metadata["sandbox"].to_s.empty?
                  command
                when "engine-run"
                  command = ["aiweb", "engine-run", "--resume", target.fetch("run_id"), "--agent", metadata["agent"].to_s.empty? ? "codex" : metadata["agent"].to_s, "--mode", metadata["mode"].to_s.empty? ? "agentic_local" : metadata["mode"].to_s, "--dry-run"]
                  command += ["--sandbox", metadata["sandbox"].to_s] unless metadata["sandbox"].to_s.empty?
                  command
                end
      return nil unless command

      {
        "schema_version" => 1,
        "status" => "planned",
        "run_id" => target.fetch("run_id"),
        "kind" => kind,
        "created_at" => now,
        "source_metadata_path" => target["metadata_path"],
        "command" => command,
        "next_command" => command.shelljoin,
        "executes_process" => false,
        "writes_only_descriptor" => true,
        "guardrails" => ["resume records a descriptor only", "next_command is dry-run/hash-discovery only", "real execution still requires a matching approval_hash plus --approved", "no provider CLI or agent process is launched by run-resume", "no .env/.env.* access"]
      }
    end

    def verify_loop_handoff_command(metadata)
      agent = metadata["agent"].to_s.empty? ? "codex" : metadata["agent"].to_s
      command = ["aiweb", "engine-run", "--agent", agent, "--mode", "agentic_local", "--max-cycles", metadata.fetch("max_cycles", 3).to_s, "--dry-run"]
      command += ["--sandbox", metadata["sandbox"].to_s] unless metadata["sandbox"].to_s.empty?
      command
    end
  end
end
