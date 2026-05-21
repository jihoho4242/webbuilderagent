# frozen_string_literal: true

module Aiweb
  class CLI
    module Dispatch
      private

    def dispatch_start
      opts = parse_options do |o, options|
        o.on("--path PATH") { |v| options[:path] = v }
        o.on("--profile PROFILE") { |v| options[:profile] = v }
        o.on("--idea IDEA") { |v| options[:idea] = v }
        o.on("--no-advance") { options[:advance] = false }
      end
      opts[:idea] ||= @argv.join(" ")
      target_root = opts[:path].to_s.strip.empty? ? @root : File.expand_path(opts[:path])
      Project.new(target_root).start(idea: opts[:idea], profile: opts[:profile], advance: opts.fetch(:advance, true), dry_run: @dry_run)
    end

    def dispatch_run_status
      opts = parse_options do |o, options|
        o.on("--run-id ID") { |v| options[:run_id] = v }
      end
      reject_extra_args!("run-status")
      project.run_status(run_id: opts[:run_id])
    end

    def dispatch_run_timeline(command)
      opts = parse_options do |o, options|
        o.on("--limit N") { |v| options[:limit] = parse_positive_integer(v, "--limit") }
      end
      reject_extra_args!(command)
      project.run_timeline(limit: opts[:limit] || 20)
    end

    def dispatch_observability_summary(command)
      opts = parse_options do |o, options|
        o.on("--limit N") { |v| options[:limit] = parse_positive_integer(v, "--limit") }
      end
      reject_extra_args!(command)
      project.observability_summary(limit: opts[:limit] || 20)
    end

    def dispatch_run_cancel
      opts = parse_options do |o, options|
        o.on("--run-id ID") { |v| options[:run_id] = v }
        o.on("--force") { options[:force] = true }
      end
      reject_extra_args!("run-cancel")
      project.run_cancel(run_id: opts[:run_id] || "active", force: opts[:force], dry_run: @dry_run)
    end

    def dispatch_run_resume
      opts = parse_options do |o, options|
        o.on("--run-id ID") { |v| options[:run_id] = v }
      end
      reject_extra_args!("run-resume")
      project.run_resume(run_id: opts[:run_id] || "latest", dry_run: @dry_run)
    end

    def dispatch_verify_loop
      opts = parse_options do |o, options|
        o.on("--max-cycles N") { |v| options[:max_cycles] = parse_positive_integer(v, "--max-cycles") }
        o.on("--agent AGENT") { |v| options[:agent] = v }
        o.on("--sandbox SANDBOX") { |v| options[:sandbox] = v }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approved") { options[:approved] = true }
        o.on("--force") { options[:force] = true }
      end
      reject_extra_args!("verify-loop")
      project.verify_loop(max_cycles: opts[:max_cycles] || 3, agent: opts[:agent], sandbox: opts[:sandbox], approved: !!opts[:approved], approval_hash: opts[:approval_hash], force: opts[:force], dry_run: @dry_run)
    end

    def dispatch_intent
      subcommand = @argv.shift || "route"
      unless subcommand == "route"
        raise UserError.new("unknown intent command #{subcommand.inspect}; expected route", EXIT_VALIDATION_FAILED)
      end

      opts = parse_options do |o, options|
        o.on("--idea IDEA") { |v| options[:idea] = v }
      end
      if opts[:idea] && !@argv.empty?
        raise UserError.new("intent route does not accept extra positional arguments when --idea is provided: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end
      idea = opts[:idea] || @argv.join(" ")
      idea = IntentRouter.normalize_idea(idea)
      raise UserError.new("intent route requires --idea or a positional idea", EXIT_VALIDATION_FAILED) if idea.empty?

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "routed intent",
        "changed_files" => [],
        "blocking_issues" => [],
        "missing_artifacts" => [],
        "intent" => IntentRouter.route(idea),
        "next_action" => "use recommended_skill and recommended_design_system when drafting implementation artifacts"
      }
    end

    def dispatch_design_system
      subcommand = @argv.shift || "resolve"
      unless subcommand == "resolve"
        raise UserError.new("unknown design-system command #{subcommand.inspect}; expected resolve", EXIT_VALIDATION_FAILED)
      end

      opts = parse_options do |o, options|
        o.on("--force") { options[:force] = true }
      end
      unless @argv.empty?
        raise UserError.new("design-system resolve does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      project.design_system_resolve(dry_run: @dry_run, force: opts[:force])
    end

    def dispatch_runtime_execution(command)
      case command
      when "build"
        parse_options
        reject_extra_args!(command)
        project.build(dry_run: @dry_run)
      when "preview"
        opts = parse_options do |o, options|
          o.on("--stop") { options[:stop] = true }
        end
        reject_extra_args!(command)
        project.preview(dry_run: @dry_run, stop: opts[:stop])
      when "qa-playwright", "browser-qa"
        opts = parse_browser_qa_options(command)
        project.qa_playwright(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-screenshot", "screenshot-qa"
        opts = parse_browser_qa_options(command)
        project.qa_screenshot(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-a11y", "a11y-qa"
        opts = parse_browser_qa_options(command)
        project.qa_a11y(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      when "qa-lighthouse", "lighthouse-qa"
        opts = parse_browser_qa_options(command)
        project.qa_lighthouse(url: opts[:url], task_id: opts[:task_id], force: opts[:force], dry_run: @dry_run)
      end
    end
    end
  end
end
