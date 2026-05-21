# frozen_string_literal: true

module Aiweb
  class CLI
    module DispatchAdapterHelpers
      private

      def call_project_adapter(method_name, kwargs)
        unless project.respond_to?(method_name)
          raise UserError.new("#{method_name.to_s.tr("_", "-")} is not available for this project adapter", EXIT_ADAPTER_UNAVAILABLE)
        end

        project.public_send(method_name, **adapter_supported_kwargs(project.method(method_name), kwargs))
      end

      def adapter_supported_kwargs(method, kwargs)
        keyword_params = method.parameters.select { |kind, _| %i[key keyreq].include?(kind) }.map(&:last)
        return kwargs if keyword_params.empty?

        kwargs.select { |key, _| keyword_params.include?(key) }
      end

      def normalized_deploy_target_option(value, required:, command:)
        text = value.to_s.strip
        if text.empty?
          raise UserError.new("#{command} requires --target cloudflare-pages or --target vercel", EXIT_VALIDATION_FAILED) if required
          return nil
        end
        unless %w[cloudflare-pages vercel].include?(text)
          raise UserError.new("#{command} target must be cloudflare-pages or vercel", EXIT_VALIDATION_FAILED)
        end

        text
      end

      def normalize_deploy_adapter_payload!(result, target)
        return result unless result.is_a?(Hash)
        return result if result["deploy"].is_a?(Hash)

        dry_run_payload = result["deploy_dry_run"]
        return result unless dry_run_payload.is_a?(Hash)

        result["deploy"] = dry_run_payload.merge(
          "status" => dry_run_payload["status"] || "planned",
          "dry_run" => dry_run_payload.key?("dry_run") ? dry_run_payload["dry_run"] : true,
          "target" => dry_run_payload["target"] || target
        )
        result
      end

      def unsafe_deploy_error?(error)
        error.message.match?(/unsafe external action|unsafe deploy|blocked/i)
      end

      def setup_approval_error?(error)
        error.message.match?(/approved|approval|unsafe|blocked/i)
      end

      def normalize_setup_payload!(result, approved:, dry_run:)
        return result unless result.is_a?(Hash) && result["setup"].is_a?(Hash)

        setup = result["setup"]
        setup["requires_approval"] = !approved unless setup.key?("requires_approval")
        setup["approved"] = approved unless setup.key?("approved")
        setup["dry_run"] = dry_run unless setup.key?("dry_run")
        result
      end

      def normalize_agent_run_payload!(result, task:, agent:, approved:, dry_run:)
        return result unless result.is_a?(Hash) && result["agent_run"].is_a?(Hash)

        agent_run = result["agent_run"]
        agent_run["task"] ||= task
        agent_run["agent"] ||= agent
        agent_run["approved"] = approved unless agent_run.key?("approved")
        agent_run["dry_run"] = dry_run unless agent_run.key?("dry_run")
        result
      end

      def unsafe_deploy_blocked_payload(target, message)
        {
          "schema_version" => 1,
          "current_phase" => nil,
          "action_taken" => "deploy blocked",
          "changed_files" => [],
          "blocking_issues" => ["unsafe deploy blocked: #{message}"],
          "missing_artifacts" => [],
          "deploy" => {
            "schema_version" => 1,
            "status" => "blocked",
            "dry_run" => false,
            "target" => target,
            "supported_targets" => %w[cloudflare-pages vercel],
            "guardrails" => ["no external deploy", "no provider CLI", "no network", "no build/preview/install", "no .env/.env.* access"],
            "blocking_issues" => ["unsafe deploy blocked: #{message}"]
          },
          "next_action" => "rerun as aiweb deploy --target cloudflare-pages|vercel --dry-run"
        }
      end

      def setup_approval_blocked_payload(message)
        {
          "schema_version" => 1,
          "current_phase" => nil,
          "action_taken" => "setup blocked",
          "changed_files" => [],
          "blocking_issues" => ["setup install approval required: #{message}"],
          "missing_artifacts" => [],
          "setup" => {
            "schema_version" => 1,
            "status" => "blocked",
            "dry_run" => false,
            "install" => true,
            "approved" => false,
            "planned_command" => "pnpm install",
            "planned_stdout_path" => ".ai-web/runs/setup-<timestamp>/stdout.log",
            "planned_stderr_path" => ".ai-web/runs/setup-<timestamp>/stderr.log",
            "planned_metadata_path" => ".ai-web/runs/setup-<timestamp>/setup.json",
            "guardrails" => ["matching dry-run approval_hash plus explicit approval required for lower-level real install", "--dry-run writes nothing", "no build/preview/QA/deploy", "no .env/.env.* reads or output"],
            "blocking_issues" => ["setup install approval required: #{message}"]
          },
          "next_action" => "rerun as aiweb setup --install --dry-run and review the approval_hash; real install is a lower-level ops action, not a friendly web-building runbook"
        }
      end
    end
  end
end
