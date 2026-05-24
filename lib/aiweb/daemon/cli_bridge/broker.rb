# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"

module Aiweb
  class CodexCliBridge
    private

    def bridge_broker_start(project_path:, command:, args:, argv:, dry_run:, approved:, blocking_issues:)
      broker = {
        broker: "aiweb.backend.side_effect_broker",
        scope: "backend.aiweb_cli",
        project_path: project_path,
        command_name: command,
        command: redact_broker_command(argv),
        dry_run: dry_run,
        approved: approved,
        persist: bridge_broker_persist?(command, dry_run, approved, blocking_issues),
        path: bridge_broker_path(project_path),
        events: []
      }
      decision = blocking_issues.any? ? "deny" : "allow"
      append_bridge_broker_event(broker, "tool.requested", "requested backend aiweb cli execution")
      append_bridge_broker_event(
        broker,
        "policy.decision",
        "backend bridge policy decision",
        "decision" => decision,
        "reason" => decision == "allow" ? "command is allowlisted and backend-controlled flags were validated" : blocking_issues.join("; "),
        "blocking_issues" => blocking_issues
      )
      append_bridge_broker_event(broker, "tool.started", "starting backend aiweb cli execution") if blocking_issues.empty?
      broker
    end

    def bridge_broker_persist?(command, dry_run, approved, blocking_issues)
      return true if blocking_issues.any?
      return false if dry_run
      return true if approved
      return false if READ_ONLY_COMMANDS.include?(command.to_s)

      true
    end

    def bridge_broker_path(project_path)
      run_id = "backend-bridge-#{Time.now.utc.strftime("%Y%m%dT%H%M%S.%6NZ")}-#{SecureRandom.hex(4)}"
      File.join(project_path, ".ai-web", "runs", run_id, "side-effect-broker.jsonl")
    end

    def append_bridge_broker_event(broker, event, message, extra = {})
      payload = {
        "schema_version" => 1,
        "event" => event,
        "created_at" => Time.now.utc.iso8601(6),
        "broker" => broker.fetch(:broker),
        "scope" => broker.fetch(:scope),
        "target" => broker.fetch(:command_name),
        "tool" => File.basename(aiweb_bin),
        "command" => broker.fetch(:command),
        "dry_run" => broker.fetch(:dry_run),
        "approved" => broker.fetch(:approved),
        "message" => message
      }.merge(extra)
      broker.fetch(:events) << payload
      return payload unless broker.fetch(:persist)

      FileUtils.mkdir_p(File.dirname(broker.fetch(:path)))
      File.open(broker.fetch(:path), "a") do |file|
        file.write(JSON.generate(payload))
        file.write("\n")
      end
      payload
    end

    def bridge_broker_finished(broker, result)
      append_bridge_broker_event(
        broker,
        "tool.finished",
        "finished backend aiweb cli execution",
        "status" => result&.success? ? "passed" : "failed",
        "exit_code" => result&.exit_code
      )
    end

    def bridge_broker_blocked(broker, blocking_issues)
      append_bridge_broker_event(
        broker,
        "tool.blocked",
        "blocked backend aiweb cli execution",
        "status" => "blocked",
        "blocking_issues" => blocking_issues
      )
    end

    def bridge_broker_failed(broker, error)
      return if broker.fetch(:events).any? { |event| %w[tool.finished tool.failed tool.blocked].include?(event["event"]) }

      append_bridge_broker_event(
        broker,
        "tool.failed",
        "failed backend aiweb cli execution",
        "status" => "failed",
        "error_class" => error.class.name,
        "error" => error.message.to_s[0, 500]
      )
    end

    def bridge_broker_summary(broker)
      {
        "schema_version" => 1,
        "broker" => broker.fetch(:broker),
        "scope" => broker.fetch(:scope),
        "status" => broker.fetch(:events).last.to_h["event"] == "tool.finished" ? broker.fetch(:events).last.to_h["status"] : "blocked",
        "events_recorded" => broker.fetch(:persist),
        "events_path" => broker.fetch(:persist) ? relative_to_project(broker.fetch(:project_path), broker.fetch(:path)) : nil,
        "event_count" => broker.fetch(:events).length,
        "target" => broker.fetch(:command_name),
        "tool" => File.basename(aiweb_bin),
        "command" => broker.fetch(:command),
        "dry_run" => broker.fetch(:dry_run),
        "approved" => broker.fetch(:approved)
      }.compact
    end

  end
end
