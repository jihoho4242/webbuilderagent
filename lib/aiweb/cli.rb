# frozen_string_literal: true

require "json"
require "optparse"
require "stringio"

require_relative "errors"
require_relative "project"
require_relative "registry"
require_relative "intent_router"
require_relative "cli/dispatch"
require_relative "cli/output"
require_relative "cli/exit_codes"

module Aiweb
  class CLI
    EXIT_SUCCESS = 0
    EXIT_VALIDATION_FAILED = 1
    EXIT_PHASE_BLOCKED = 2
    EXIT_BUDGET_BLOCKED = 3
    EXIT_ADAPTER_UNAVAILABLE = 4
    EXIT_UNSAFE_EXTERNAL_ACTION = 5
    EXIT_INTERNAL_ERROR = 10

    MUTATION_COMMANDS = %w[start init interview run run-cancel run-resume engine-run engine-scheduler mcp-broker agent-run verify-loop eval-baseline human-baseline ingest-reference ingest-design next-task qa-checklist qa-report repair advance rollback resolve-blocker snapshot design-brief design-research design-system design-prompt design select-design scaffold setup build preview qa-playwright browser-qa qa-screenshot screenshot-qa qa-a11y a11y-qa qa-lighthouse lighthouse-qa visual-critique visual-polish workbench component-map visual-edit supabase-secret-qa supabase-local-verify github-sync deploy-plan deploy daemon backend].freeze
    RUNTIME_PLAN_COMMANDS = %w[runtime-plan scaffold-status].freeze
    REGISTRY_COMMANDS = %w[design-systems skills craft].freeze
    WEBBUILDER_COMMANDS = %w[
      help --help -h version --version
      start init status runtime-plan scaffold-status setup build preview interview run run-status run-timeline timeline observability-summary summary run-cancel run-resume design-brief design-system design-prompt design select-design scaffold supabase-secret-qa supabase-local-verify ingest-design next-task
      engine-run engine-scheduler mcp-broker agent-run verify-loop eval-baseline human-baseline qa-checklist qa-report repair qa-playwright qa-screenshot qa-a11y qa-lighthouse visual-critique visual-polish advance rollback resolve-blocker snapshot
      workbench component-map visual-edit github-sync deploy-plan deploy design-systems skills craft intent
    ].freeze

    include Dispatch
    include Output
    include ExitCodes

    def initialize(argv, root)
      @argv = argv.dup
      @root = root
      @json = false
      @dry_run = false
    end

    def run
      parse_global_flags!
      if unsafe_env_path?(@root)
        return emit_error("unsafe project path blocked: .env/.env.* paths are not allowed", EXIT_UNSAFE_EXTERNAL_ACTION)
      end

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
          if command_local_path_option?(kept)
            kept << arg
            kept << value
            next
          end
          raise UserError.new("unsafe --path target blocked: .env/.env.* paths are not allowed", EXIT_UNSAFE_EXTERNAL_ACTION) if unsafe_env_path?(value)

          @root = File.expand_path(value)
        when /\A--path=(.+)\z/
          if command_local_path_option?(kept)
            kept << arg
            next
          end
          raise UserError.new("unsafe --path target blocked: .env/.env.* paths are not allowed", EXIT_UNSAFE_EXTERNAL_ACTION) if unsafe_env_path?($1)

          @root = File.expand_path($1)
        else
          kept << arg
        end
      end
      @argv = kept
    end

    def command_local_path_option?(kept_args)
      %w[eval-baseline human-baseline].include?(kept_args.first)
    end

  end
end
