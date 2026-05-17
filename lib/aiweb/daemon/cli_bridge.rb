# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "../redaction"

module Aiweb
  class CodexCliBridge
    DEFAULT_ALLOWED_COMMANDS = %w[
      status runtime-plan scaffold-status intent init start interview run design-brief design-research
      run-status run-timeline observability-summary run-cancel run-resume
      design-system design-prompt design select-design ingest-reference scaffold setup build preview qa-playwright
      qa-screenshot qa-a11y qa-lighthouse visual-critique repair visual-polish workbench
      component-map visual-edit engine-run agent-run verify-loop github-sync deploy-plan deploy qa-checklist qa-report
      next-task advance rollback resolve-blocker snapshot supabase-secret-qa
    ].freeze

    UNSAFE_ARG_PATTERN = /(?:\A|=|[\x00\/\\])\.env(?:\.|\z|[\/\\])/.freeze
    BACKEND_CONTROLLED_ARG_PATTERN = /\A--(?:path(?:=|\z)|json\z|dry-run\z|approved\z)/.freeze
    COMMAND_TIMEOUT_SECONDS = 180
    READ_ONLY_COMMANDS = %w[status runtime-plan scaffold-status run-status run-timeline observability-summary qa-report].freeze
    attr_reader :engine_root, :aiweb_bin, :allowed_commands, :command_timeout

    def initialize(engine_root: File.expand_path("../../..", __dir__), allowed_commands: DEFAULT_ALLOWED_COMMANDS, command_timeout: COMMAND_TIMEOUT_SECONDS)
      @engine_root = File.expand_path(engine_root)
      @aiweb_bin = File.join(@engine_root, "bin", "aiweb")
      @allowed_commands = allowed_commands.map(&:to_s).freeze
      @command_timeout = Float(command_timeout)
    end

    def metadata
      {
        "schema_version" => 1,
        "engine_root" => engine_root,
        "aiweb_bin" => aiweb_bin,
        "ruby" => RbConfig.ruby,
        "command_timeout_seconds" => command_timeout,
        "allowed_commands" => allowed_commands,
        "source_patch_agent_command" => "agent-run",
        "guardrails" => guardrails
      }
    end

    def guardrails
      [
        "frontend sends structured JSON only; no raw shell commands",
        "every /api/* request requires X-Aiweb-Token",
        "backend invokes bin/aiweb by absolute path through Ruby argv, never through shell interpolation",
        "project path is required and --path is controlled by backend",
        "frontend-supplied backend flags (--path, --json, --dry-run, --approved) are rejected inside command args",
        ".env and .env.* path segments are rejected before bridge execution",
        "bridge commands time out instead of blocking the backend indefinitely",
        "backend bridge command execution is recorded through aiweb.backend.side_effect_broker evidence before process launch",
        "approved agent-run/setup/verify-loop execution requires a matching X-Aiweb-Approval-Token header or the API token when no separate approval token is configured",
        "engine-run is called by the dedicated backend job API; frontend generic command requests for engine-run are rejected",
        "engine-run exposes the agentic sandbox task runtime through structured command envelopes",
        "agent-run maps to aiweb agent-run --agent codex|openmanus and keeps approval semantics",
          "engine-run maps to aiweb engine-run --agent codex|openmanus|openhands|langgraph|openai_agents_sdk and keeps sandbox approval semantics",
        "deploy is exposed as dry-run planning only through this bridge"
      ]
    end

    def run(project_path:, command:, args: [], dry_run: false, approved: false)
      project_path = safe_project_path!(project_path)
      command = command.to_s.strip
      raise UserError.new("bridge command is required", 1) if command.empty?
      raise UserError.new("bridge command #{command.inspect} is not allowed", 5) unless allowed_commands.include?(command)

      args = normalize_args(args)
      validate_args!(args)

      argv = [RbConfig.ruby, aiweb_bin, "--path", project_path, command]
      argv.concat(args)
      argv << "--approved" if %w[agent-run engine-run setup verify-loop].include?(command) && approved
      argv << "--dry-run" if dry_run
      argv << "--json"

      blocking_issues = []
      blocking_issues << "bridge deploy is dry-run only" if command == "deploy" && !dry_run
      broker = bridge_broker_start(project_path: project_path, command: command, args: args, argv: argv, dry_run: dry_run, approved: approved, blocking_issues: blocking_issues)
      if blocking_issues.any?
        bridge_broker_blocked(broker, blocking_issues)
        raise UserError.new(blocking_issues.first, 5)
      end

      stdout, stderr, status = capture_argv(argv)
      bridge_broker_finished(broker, status)
      parsed = parse_json(stdout)
      public_args = redact_broker_command(args)
      public_argv = redact_broker_command(argv)
      {
        "schema_version" => 1,
        "status" => status.success? ? "passed" : "failed",
        "exit_code" => status.exitstatus,
        "bridge" => metadata.merge(
          "project_path" => project_path,
          "command" => command,
          "args" => public_args,
          "dry_run" => dry_run,
          "approved" => approved,
          "argv" => public_argv,
          "side_effect_broker" => bridge_broker_summary(broker),
          "side_effect_broker_events" => broker.fetch(:events)
        ),
        "stdout_json" => parsed,
        "stdout" => parsed ? nil : stdout.to_s[0, 20_000],
        "stderr" => stderr.to_s[0, 20_000]
      }
    rescue StandardError => e
      bridge_broker_failed(broker, e) if defined?(broker) && broker
      raise
    end

    def agent_run(project_path:, task: "latest", agent: "codex", sandbox: nil, dry_run: true, approved: false)
      agent_name = agent.to_s.strip.empty? ? "codex" : agent.to_s.strip
      raise UserError.new("bridge agent-run agent must be codex or openmanus", 5) unless %w[codex openmanus].include?(agent_name)
      sandbox_name = sandbox.to_s.strip.downcase
      raise UserError.new("bridge agent-run sandbox must be docker or podman", 5) unless sandbox_name.empty? || %w[docker podman].include?(sandbox_name)

      args = ["--task", task.to_s, "--agent", agent_name]
      args.concat(["--sandbox", sandbox_name]) unless sandbox_name.empty?
      run(
        project_path: project_path,
        command: "agent-run",
        args: args,
        dry_run: dry_run,
        approved: approved
      )
    end

    def engine_run(project_path:, goal: nil, agent: "codex", mode: "agentic_local", sandbox: nil, max_cycles: 3, approval_hash: nil, resume: nil, run_id: nil, dry_run: true, approved: false)
      agent_name = agent.to_s.strip.empty? ? "codex" : agent.to_s.strip
      mode_name = mode.to_s.strip.empty? ? "agentic_local" : mode.to_s.strip
      sandbox_name = sandbox.to_s.strip.downcase
      cycles = parse_max_cycles(max_cycles)
      requested_run_id = run_id.to_s.strip
      raise UserError.new("bridge engine-run agent must be codex, openmanus, openhands, langgraph, or openai_agents_sdk", 5) unless %w[codex openmanus openhands langgraph openai_agents_sdk].include?(agent_name)
      raise UserError.new("bridge engine-run mode must be safe_patch, agentic_local, or external_approval", 5) unless %w[safe_patch agentic_local external_approval].include?(mode_name)
      raise UserError.new("bridge engine-run sandbox is only supported with openmanus, openhands, langgraph, or openai_agents_sdk", 5) if !sandbox_name.empty? && !%w[openmanus openhands langgraph openai_agents_sdk].include?(agent_name)
      raise UserError.new("bridge engine-run sandbox must be docker or podman", 5) unless sandbox_name.empty? || %w[docker podman].include?(sandbox_name)
      validate_run_id!(requested_run_id, "engine-run run_id") unless requested_run_id.empty?

      args = ["--agent", agent_name, "--mode", mode_name, "--max-cycles", cycles.to_s]
      args.concat(["--goal", goal.to_s]) unless goal.to_s.strip.empty?
      args.concat(["--sandbox", sandbox_name]) unless sandbox_name.empty?
      args.concat(["--approval-hash", approval_hash.to_s]) unless approval_hash.to_s.strip.empty?
      args.concat(["--resume", resume.to_s]) unless resume.to_s.strip.empty?
      args.concat(["--run-id", requested_run_id]) unless requested_run_id.empty?
      run(
        project_path: project_path,
        command: "engine-run",
        args: args,
        dry_run: dry_run,
        approved: approved
      )
    end

    private

    def parse_max_cycles(value)
      number = Integer(value || 3)
      raise ArgumentError if number < 1 || number > 10

      number
    rescue ArgumentError, TypeError
      raise UserError.new("bridge engine-run max_cycles must be an integer between 1 and 10", 1)
    end

    def parse_json(stdout)
      JSON.parse(stdout)
    rescue JSON::ParserError
      nil
    end

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

    def bridge_broker_finished(broker, status)
      append_bridge_broker_event(
        broker,
        "tool.finished",
        "finished backend aiweb cli execution",
        "status" => status&.success? ? "passed" : "failed",
        "exit_code" => status&.exitstatus
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

    def redact_broker_command(command)
      Aiweb::Redaction.redact_command(command)
    end

    def relative_to_project(project_path, path)
      File.expand_path(path).sub(%r{\A#{Regexp.escape(File.expand_path(project_path))}[\\/]?}, "").tr("\\", "/")
    end

    def capture_argv(argv)
      stdout_data = +""
      stderr_data = +""
      status = nil
      timed_out = false

      Open3.popen3(*argv, **popen_options) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        stdout_reader = Thread.new { read_stream(stdout) }
        stderr_reader = Thread.new { read_stream(stderr) }

        unless wait_thr.join(command_timeout)
          timed_out = true
          terminate_process_tree(wait_thr.pid)
          close_stream(stdout)
          close_stream(stderr)
        end

        unless stdout_reader.join(1) && stderr_reader.join(1)
          terminate_process_tree(wait_thr.pid)
          close_stream(stdout)
          close_stream(stderr)
        end

        stdout_data = reader_value(stdout_reader)
        stderr_data = reader_value(stderr_reader)
        status = wait_thr.value if wait_thr.join(1)
      end

      raise UserError.new("bridge command timed out after #{command_timeout}s", 5) if timed_out

      [stdout_data, stderr_data, status]
    end

    def read_stream(stream)
      stream.read.to_s
    rescue IOError
      ""
    end

    def reader_value(thread)
      return thread.value.to_s if thread.join(0)

      thread.kill
      ""
    end

    def close_stream(stream)
      stream.close unless stream.closed?
    rescue IOError
      nil
    end

    def terminate_process_tree(pid)
      if windows?
        kill_process(pid, "KILL")
        return
      end

      kill_process(-pid, "TERM") || kill_process(pid, "TERM")
      sleep 0.2
      kill_process(-pid, "KILL") || kill_process(pid, "KILL")
    end

    def popen_options
      windows? ? {} : { pgroup: true }
    end

    def windows?
      RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
    end

    def kill_process(target, signal)
      Process.kill(signal, target)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def safe_project_path!(value)
      text = value.to_s.strip
      raise UserError.new("project path is required for backend bridge commands", 1) if text.empty?

      reject_unsafe_path!(text, "project path")
      File.expand_path(text)
    end

    def normalize_args(args)
      case args
      when nil then []
      when Array then args.map(&:to_s)
      else
        raise UserError.new("bridge args must be an array", 1)
      end
    end

    def validate_args!(args)
      args.each do |arg|
        raise UserError.new("bridge args must not contain null bytes", 5) if arg.include?("\x00")
        if arg.match?(BACKEND_CONTROLLED_ARG_PATTERN)
          raise UserError.new("bridge args must not include backend-controlled flags (--path, --json, --dry-run, --approved)", 5)
        end
        reject_unsafe_path!(arg, "argument")
      end
    end

    def reject_unsafe_path!(value, label)
      if value.to_s.match?(UNSAFE_ARG_PATTERN) || File.basename(value.to_s).match?(/\A\.env(?:\.|\z)/)
        raise UserError.new("unsafe #{label} blocked: .env/.env.* paths are not allowed", 5)
      end
    end

    def validate_run_id!(value, label)
      if value.include?("/") || value.include?("\\") || value.include?("..") || value.start_with?(".") || value.match?(UNSAFE_ARG_PATTERN)
        raise UserError.new("unsafe #{label} blocked", 5)
      end
      unless value.match?(/\Aengine-run-[A-Za-z0-9_.-]+\z/)
        raise UserError.new("#{label} must start with engine-run- and contain only letters, numbers, dot, underscore, or dash", 1)
      end
    end
  end
end
