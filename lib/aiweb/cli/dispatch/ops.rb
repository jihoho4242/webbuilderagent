# frozen_string_literal: true

module Aiweb
  class CLI
    module Dispatch
      private

    def dispatch_github_sync(opts)
      remote = opts[:remote].to_s.strip.empty? ? nil : opts[:remote].to_s.strip
      branch = opts[:branch].to_s.strip.empty? ? nil : opts[:branch].to_s.strip
      kwargs = { dry_run: @dry_run, remote: remote, branch: branch }.compact
      call_project_adapter(:github_sync, kwargs)
    end

    def dispatch_deploy_plan(opts)
      target = normalized_deploy_target_option(opts[:target], required: false, command: "deploy-plan")
      kwargs = { dry_run: @dry_run, target: target }.compact
      call_project_adapter(:deploy_plan, kwargs)
    end

    def dispatch_deploy(opts)
      target = normalized_deploy_target_option(opts[:target], required: true, command: "deploy")
      call_project_adapter(:deploy, { target: target, approved: !!opts[:approved], force: !!opts[:force], dry_run: @dry_run }).tap do |result|
        normalize_deploy_adapter_payload!(result, target)
      end
    rescue UserError => e
      raise unless unsafe_deploy_error?(e)

      unsafe_deploy_blocked_payload(target, e.message)
    end

    def dispatch_setup_command
      opts = parse_options do |o, options|
        o.on("--install") { options[:install] = true }
        o.on("--approval-hash HASH") { |v| options[:approval_hash] = v }
        o.on("--approval-request HASH") { |v| options[:approval_hash] = v }
        o.on("--approved") { options[:approved] = true }
        o.on("--allow-lifecycle-scripts") { options[:allow_lifecycle_scripts] = true }
        o.on("--audit-exception PATH") { |v| options[:audit_exception_path] = v }
      end
      unless @argv.empty?
        raise UserError.new("setup does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end
      unless opts[:install]
        raise UserError.new("setup requires --install", EXIT_VALIDATION_FAILED)
      end

      dispatch_setup(opts)
    end

    def dispatch_setup(opts)
      call_project_adapter(:setup, { install: true, approved: !!opts[:approved], approval_hash: opts[:approval_hash], dry_run: @dry_run, audit_exception_path: opts[:audit_exception_path], allow_lifecycle_scripts: !!opts[:allow_lifecycle_scripts] }).tap do |result|
        normalize_setup_payload!(result, approved: !!opts[:approved], dry_run: @dry_run)
      end
    rescue UserError => e
      raise unless setup_approval_error?(e)

      setup_approval_blocked_payload(e.message)
    end
    end
  end
end
