# frozen_string_literal: true

module Aiweb
  class CodexCliBridge
    DEFAULT_ALLOWED_COMMANDS = %w[
      status runtime-plan scaffold-status intent init start interview run design-brief design-research
      design-system design-prompt design select-design ingest-reference scaffold setup build preview qa-playwright
      qa-screenshot qa-a11y qa-lighthouse visual-critique repair visual-polish workbench
      component-map visual-edit agent-run verify-loop github-sync deploy-plan deploy qa-checklist qa-report
      next-task advance rollback resolve-blocker snapshot supabase-secret-qa
    ].freeze

    UNSAFE_ARG_PATTERN = /(?:\A|=|[\x00\/\\])\.env(?:\.|\z|[\/\\])/.freeze
    BACKEND_CONTROLLED_ARG_PATTERN = /\A--(?:path(?:=|\z)|json\z|dry-run\z|approved\z)/.freeze
    COMMAND_TIMEOUT_SECONDS = 180

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
        "approved agent-run/setup/verify-loop execution requires a matching X-Aiweb-Approval-Token header or the API token when no separate approval token is configured",
        "agent-run maps to aiweb agent-run --agent codex|openmanus and keeps approval semantics",
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
      raise UserError.new("bridge deploy is dry-run only", 5) if command == "deploy" && !dry_run

      argv = [RbConfig.ruby, aiweb_bin, "--path", project_path, command]
      argv.concat(args)
      argv << "--approved" if %w[agent-run setup verify-loop].include?(command) && approved
      argv << "--dry-run" if dry_run
      argv << "--json"

      stdout, stderr, status = capture_argv(argv)
      parsed = parse_json(stdout)
      {
        "schema_version" => 1,
        "status" => status.success? ? "passed" : "failed",
        "exit_code" => status.exitstatus,
        "bridge" => metadata.merge(
          "project_path" => project_path,
          "command" => command,
          "args" => args,
          "dry_run" => dry_run,
          "approved" => approved,
          "argv" => argv
        ),
        "stdout_json" => parsed,
        "stdout" => parsed ? nil : stdout.to_s[0, 20_000],
        "stderr" => stderr.to_s[0, 20_000]
      }
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

    private

    def parse_json(stdout)
      JSON.parse(stdout)
    rescue JSON::ParserError
      nil
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
  end
end
