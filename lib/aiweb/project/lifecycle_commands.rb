# frozen_string_literal: true

require "fileutils"

module Aiweb
  module ProjectLifecycleCommands
    def init(profile: nil, dry_run: false)
      changes = []
      payload = nil
      selected_profile = nil
      selected_profile_data = nil
      if profile
        selected_profile, selected_profile_data = Profiles.fetch!(profile)
      end
      mutation(dry_run: dry_run) do
        timestamp = now
        planned_dirs.each do |dir|
          changes << create_dir(dir, dry_run)
        end

        copy_core_templates(dry_run, changes)

        state = load_state_if_present || load_template_yaml("state.yaml")
        state["project"]["id"] = default_project_id if blank?(state.dig("project", "id"))
        state["project"]["name"] = File.basename(root) if blank?(state.dig("project", "name"))
        state["project"]["created_at"] = timestamp if blank?(state.dig("project", "created_at"))
        state["project"]["updated_at"] = timestamp
        ensure_defaults!(state)

        if selected_profile
          state["implementation"]["stack_profile"] = selected_profile
          state["implementation"]["scaffold_target"] = selected_profile_data[:scaffold_target]
          changes << write_file(File.join(aiweb_dir, "stack.md"), stack_markdown(selected_profile, selected_profile_data), dry_run)
          changes << write_file(File.join(aiweb_dir, "deploy.md"), deploy_markdown(selected_profile, selected_profile_data), dry_run)
        end

        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = selected_profile ? "initialized profile #{selected_profile}" : "initialized director workspace"
      end
      payload
    end

    def status
      assert_initialized!
      state = load_state
      refreshed = refresh_state!(state)
      payload = status_hash(state: refreshed, changed_files: [])
      validation_errors = validate_state_shape(refreshed)
      unless validation_errors.empty?
        payload["validation_errors"] = validation_errors
        payload["blocking_issues"] = (payload["blocking_issues"] + validation_errors.map { |error| "state validation failed: #{error}" }).uniq
        payload["next_action"] = "repair .ai-web/state.yaml then rerun aiweb status"
      end
      payload
    end

    def start(idea:, profile: nil, advance: true, dry_run: false)
      idea = idea.to_s.strip
      raise UserError.new("start requires --idea", 1) if idea.empty?

      route = IntentRouter.route(idea)
      selected_profile = profile.to_s.strip.empty? ? route.fetch("recommended_profile") : profile.to_s.strip
      Profiles.fetch!(selected_profile)

      if dry_run
        return {
          "schema_version" => 1,
          "current_phase" => nil,
          "action_taken" => "planned director start",
          "changed_files" => [],
          "blocking_issues" => [],
          "missing_artifacts" => [],
          "start_steps" => start_steps(selected_profile, advance),
          "next_action" => "would create #{root}, initialize profile #{selected_profile}, draft interview artifacts#{advance ? ", then advance to phase-0.25" : ""}",
        }
      end

      FileUtils.mkdir_p(root)
      init_payload = init(profile: selected_profile, dry_run: false)
      interview_payload = interview(idea: idea, dry_run: false)
      final_payload = advance ? self.advance(dry_run: false) : status
      final_payload = final_payload.merge(
        "action_taken" => advance ? "started director workspace and advanced to quality gate" : "started director workspace",
        "changed_files" => compact_changes([
          init_payload["changed_files"],
          interview_payload["changed_files"],
          final_payload["changed_files"],
        ]),
        "start_steps" => start_steps(selected_profile, advance),
        "next_action" => start_next_action(advance, final_payload)
      )
      final_payload
    end

    def interview(idea:, dry_run: false)
      assert_initialized!
      idea = idea.to_s.strip
      idea = "TODO: describe the website idea" if idea.empty?
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        intent = classify_intent(idea)
        changes << write_yaml(File.join(aiweb_dir, "intent.yaml"), intent, dry_run)
        changes << write_file(File.join(aiweb_dir, "first-view-contract.md"), first_view_contract_markdown(intent, idea), dry_run)
        changes << write_file(File.join(aiweb_dir, "project.md"), project_markdown(idea, state, intent), dry_run)
        changes << write_file(File.join(aiweb_dir, "product.md"), product_markdown(idea, intent), dry_run)
        changes << write_file(File.join(aiweb_dir, "brand.md"), brand_markdown(idea), dry_run)
        changes << write_file(File.join(aiweb_dir, "content.md"), content_markdown(idea, intent), dry_run)
        changes << write_design_brief_if_needed(intent: intent, dry_run: dry_run, force: false)
        changes << write_design_system_if_needed(intent: intent, dry_run: dry_run, force: false)
        mark_artifacts_from_files!(state)
        add_decision!(state, "interview_draft", "Generated #{intent["archetype"]} interview artifacts from idea: #{idea}")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "generated interview drafts"
      end
      payload
    end

  end
end
