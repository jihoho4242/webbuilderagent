# frozen_string_literal: true

require "json"
require "optparse"
require "stringio"

require_relative "registry"

module Aiweb
  class CLI
    EXIT_SUCCESS = 0
    EXIT_VALIDATION_FAILED = 1
    EXIT_PHASE_BLOCKED = 2
    EXIT_BUDGET_BLOCKED = 3
    EXIT_ADAPTER_UNAVAILABLE = 4
    EXIT_UNSAFE_EXTERNAL_ACTION = 5
    EXIT_INTERNAL_ERROR = 10

    MUTATION_COMMANDS = %w[start init interview run ingest-design next-task qa-checklist qa-report advance rollback resolve-blocker snapshot design-prompt].freeze
    REGISTRY_COMMANDS = %w[design-systems skills craft].freeze

    def initialize(argv, root)
      @argv = argv.dup
      @root = root
      @json = false
      @dry_run = false
    end

    def run
      parse_global_flags!
      command = @argv.shift || "help"
      if @dry_run && !MUTATION_COMMANDS.include?(command)
        return emit_error("--dry-run is only supported for mutation commands", EXIT_VALIDATION_FAILED)
      end

      result = dispatch(command)
      result["dry_run"] = @dry_run if @dry_run
      emit_result(result)
      exit_code_for(command, result)
    rescue UserError => e
      emit_error(e.message, e.exit_code)
    rescue OptionParser::ParseError, ArgumentError => e
      emit_error(e.message, EXIT_VALIDATION_FAILED)
    rescue StandardError => e
      emit_error("#{e.class}: #{e.message}", EXIT_INTERNAL_ERROR)
    end

    private

    def project
      @project ||= Project.new(@root)
    end

    def registry
      @registry ||= Registry.new(@root)
    end

    def parse_global_flags!
      kept = []
      until @argv.empty?
        arg = @argv.shift
        case arg
        when "--json"
          @json = true
        when "--dry-run"
          @dry_run = true
        when "--path"
          value = @argv.shift
          raise OptionParser::MissingArgument, "--path" if value.to_s.empty?

          @root = File.expand_path(value)
        when /\A--path=(.+)\z/
          @root = File.expand_path($1)
        else
          kept << arg
        end
      end
      @argv = kept
    end

    def dispatch(command)
      case command
      when "help", "--help", "-h"
        help_payload
      when "version", "--version"
        base_payload("version", "aiweb #{Aiweb::VERSION}")
      when "start"
        opts = parse_options do |o, options|
          o.on("--path PATH") { |v| options[:path] = v }
          o.on("--profile PROFILE") { |v| options[:profile] = v }
          o.on("--idea IDEA") { |v| options[:idea] = v }
          o.on("--no-advance") { options[:advance] = false }
        end
        opts[:idea] ||= @argv.join(" ")
        target_root = opts[:path].to_s.strip.empty? ? @root : File.expand_path(opts[:path])
        Project.new(target_root).start(idea: opts[:idea], profile: opts[:profile] || "D", advance: opts.fetch(:advance, true), dry_run: @dry_run)
      when "init"
        opts = parse_options do |o, options|
          o.on("--profile PROFILE") { |v| options[:profile] = v }
        end
        project.init(profile: opts[:profile], dry_run: @dry_run)
      when "status"
        project.status
      when *REGISTRY_COMMANDS
        dispatch_registry(command)
      when "interview"
        opts = parse_options do |o, options|
          o.on("--idea IDEA") { |v| options[:idea] = v }
        end
        opts[:idea] ||= @argv.join(" ")
        project.interview(idea: opts[:idea], dry_run: @dry_run)
      when "run"
        project.run(dry_run: @dry_run)
      when "design-prompt"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        project.design_prompt(dry_run: @dry_run, force: opts[:force])
      when "ingest-design"
        opts = parse_options do |o, options|
          o.on("--id ID") { |v| options[:id] = v }
          o.on("--title TITLE") { |v| options[:title] = v }
          o.on("--source SOURCE") { |v| options[:source] = v }
          o.on("--notes NOTES") { |v| options[:notes] = v }
          o.on("--selected") { options[:selected] = true }
          o.on("--force") { options[:force] = true }
        end
        project.ingest_design(id: opts[:id], title: opts[:title], source: opts[:source], notes: opts[:notes], selected: opts[:selected], dry_run: @dry_run, force: opts[:force])
      when "next-task"
        opts = parse_options do |o, options|
          o.on("--type TYPE") { |v| options[:type] = v }
          o.on("--force") { options[:force] = true }
        end
        project.next_task(type: opts[:type], dry_run: @dry_run, force: opts[:force])
      when "qa-checklist"
        opts = parse_options do |o, options|
          o.on("--force") { options[:force] = true }
        end
        project.qa_checklist(dry_run: @dry_run, force: opts[:force])
      when "qa-report"
        opts = parse_options do |o, options|
          o.on("--from PATH") { |v| options[:from] = v }
          o.on("--status STATUS") { |v| options[:status] = v }
          o.on("--task-id ID") { |v| options[:task_id] = v }
          o.on("--duration-minutes N") { |v| options[:duration_minutes] = v.to_f }
          o.on("--timed-out") { options[:timed_out] = true }
          o.on("--force") { options[:force] = true }
        end
        project.qa_report(status: opts[:status] || "passed", task_id: opts[:task_id], duration_minutes: opts[:duration_minutes], timed_out: opts[:timed_out], from: opts[:from], dry_run: @dry_run, force: opts[:force])
      when "advance"
        project.advance(dry_run: @dry_run)
      when "rollback"
        opts = parse_options do |o, options|
          o.on("--to PHASE") { |v| options[:to] = v }
          o.on("--failure CODE") { |v| options[:failure] = v }
          o.on("--reason REASON") { |v| options[:reason] = v }
        end
        if opts[:to].to_s.empty? && opts[:failure].to_s.empty?
          raise UserError.new("rollback requires --to or --failure", EXIT_VALIDATION_FAILED)
        end
        project.rollback(to: opts[:to], failure: opts[:failure], reason: opts[:reason], dry_run: @dry_run)
      when "resolve-blocker"
        opts = parse_options do |o, options|
          o.on("--reason REASON") { |v| options[:reason] = v }
        end
        project.resolve_blocker(reason: opts[:reason], dry_run: @dry_run)
      when "snapshot"
        opts = parse_options do |o, options|
          o.on("--reason REASON") { |v| options[:reason] = v }
        end
        project.snapshot(reason: opts[:reason], dry_run: @dry_run)
      else
        raise UserError.new("unknown command #{command.inspect}; run aiweb help", EXIT_VALIDATION_FAILED)
      end
    end

    def dispatch_registry(command)
      subcommand = @argv.shift || "list"
      unless subcommand == "list"
        raise UserError.new("unknown #{command} command #{subcommand.inspect}; expected list", EXIT_VALIDATION_FAILED)
      end

      parse_options
      unless @argv.empty?
        raise UserError.new("#{command} list does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      registry.list(command)
    end

    def parse_options
      options = {}
      parser = OptionParser.new do |o|
        yield(o, options) if block_given?
      end
      parser.parse!(@argv)
      options
    end

    def help_payload
      base_payload("help", <<~HELP)
        aiweb — AI Web Director CLI

        Commands:
          start [--path PATH] --idea "..." [--profile A|B|C|D] [--no-advance]
          init [--profile A|B|C|D]
          status
          interview --idea "..."
          run
          design-prompt [--force]
          ingest-design [--id ID] [--title TITLE] [--source SOURCE] [--notes NOTES] [--selected] [--force]
          next-task [--type TYPE] [--force]
          qa-checklist [--force]
          qa-report [--from PATH] [--status passed|failed|blocked] [--duration-minutes N] [--timed-out] [--force]
          advance
          rollback [--to PHASE] [--failure CODE] [--reason "..."]
          resolve-blocker --reason "..."
          snapshot [--reason "..."]
          design-systems list
          skills list
          craft list

        Global flags:
          --json       machine-readable output
          --dry-run    plan mutation without writing files
          --path PATH  run against a project directory

        Phase-sensitive commands are guarded:
          design-prompt: phase-3 or phase-3.5
          ingest-design: phase-3.5
          next-task: phase-6 through phase-11
          qa-checklist: phase-7 through phase-11
          qa-report: phase-7 through phase-11
        Use --force only for manual repair/override.
      HELP
    end

    def base_payload(action, message)
      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => action,
        "changed_files" => [],
        "blocking_issues" => [],
        "missing_artifacts" => [],
        "next_action" => message
      }
    end

    def emit_result(result)
      if @json
        puts JSON.pretty_generate(result)
      else
        puts human_result(result)
      end
    end

    def emit_error(message, code)
      payload = {
        "schema_version" => 1,
        "status" => "error",
        "error" => { "code" => code, "message" => message },
        "blocking_issues" => [message],
        "next_action" => "fix the reported issue and rerun the command"
      }
      if @json
        puts JSON.pretty_generate(payload)
      else
        warn "Error: #{message}"
        warn "Next command: #{payload["next_action"]}"
      end
      code
    end

    def human_result(result)
      return human_registry_result(result) if result["registry"]

      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = result["blocking_issues"] || []
      [
        "Current phase: #{result["current_phase"] || "n/a"}",
        "Action taken: #{result["action_taken"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_registry_result(result)
      registry_payload = result.fetch("registry")
      items = registry_payload.fetch("items")
      lines = ["#{registry_payload.fetch("label")} (#{registry_payload.fetch("count")})"]
      unless registry_payload.fetch("exists")
        lines << "Directory not found: #{registry_payload.fetch("directory")}/"
      end
      if items.empty?
        lines << "No #{registry_payload.fetch("singular")} entries found."
      else
        items.each do |item|
          description = item["description"].to_s.empty? ? "" : " — #{item["description"]}"
          lines << "- #{item["id"]}: #{item["title"]} (#{item["path"]})#{description}"
        end
      end
      validation_errors = result["validation_errors"] || []
      warnings = result["warnings"] || []
      lines << "Validation errors: #{validation_errors.join("; ")}" unless validation_errors.empty?
      lines << "Warnings: #{warnings.join("; ")}" unless warnings.empty?
      lines.join("\n")
    end

    def exit_code_for(command, result)
      return EXIT_VALIDATION_FAILED if result["validation_errors"] && !result["validation_errors"].empty?
      return EXIT_SUCCESS if REGISTRY_COMMANDS.include?(command)
      return EXIT_SUCCESS if %w[help version status start init interview run design-prompt ingest-design next-task qa-checklist qa-report rollback resolve-blocker snapshot].include?(command)
      if command == "advance" && result["action_taken"] == "advance blocked"
        issue = result["blocking_issues"].join(" ")
        return EXIT_BUDGET_BLOCKED if issue =~ /budget|candidate cap|design generation cap/i
        return EXIT_PHASE_BLOCKED
      end
      EXIT_SUCCESS
    end
  end
end
