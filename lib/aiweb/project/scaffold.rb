# frozen_string_literal: true

require_relative "scaffold/profile_d"
require_relative "scaffold/profile_s"

module Aiweb
  class Project
    module Scaffold
      include ProfileD
      include ProfileS
    def scaffold(profile: "D", dry_run: false, force: false)
      assert_initialized!
      selected_profile, profile_data = Profiles.fetch!(profile)
      return scaffold_profile_s(profile_data, dry_run: dry_run, force: force) if selected_profile == "S"

      unless selected_profile == "D"
        raise UserError.new("scaffold currently supports --profile D or --profile S; received #{profile.inspect}", 1)
      end

      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        ensure_scaffold_state_defaults!(state)
        validate_scaffold_design_gate!(state)
        files = scaffold_profile_d_files(state)
        scaffold_metadata_path = File.join(aiweb_dir, "scaffold-profile-D.json")
        conflicts = scaffold_conflicts(files, force: force)
        preflight_scaffold_targets!(files, metadata_path: scaffold_metadata_path, force: force, profile: "D")

        unless conflicts.empty?
          raise UserError.new(
            "scaffold profile D found existing files that differ and were preserved: #{conflicts.join(", ")}. No scaffold files were written. Rerun aiweb scaffold --profile D --force to overwrite regular scaffold files after reviewing those files.",
            1
          )
        end

        files.each do |relative_path, content|
          path = File.join(root, relative_path)
          next if File.exist?(path) && File.read(path) == content

          changes << write_file(path, content, dry_run)
        end

        metadata = scaffold_profile_d_metadata(files, state, profile_data)
        changes << write_json(scaffold_metadata_path, metadata, dry_run)
        apply_scaffold_state!(state, metadata)
        add_decision!(state, "scaffold_profile_d", "Generated Profile D Astro-style static app skeleton from .ai-web/DESIGN.md and selected candidate context")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)

        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = force ? "regenerated scaffold profile D" : "generated scaffold profile D"
        payload["scaffold"] = metadata.reject { |key, _| key == "files" }
        payload["next_action"] = "review generated Astro-style files; do not run package install until implementation approval"
      end
      payload
    end


    def scaffold_profile_s(profile_data, dry_run:, force:)
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        ensure_scaffold_state_defaults!(state)
        files = scaffold_profile_s_files(state)
        scaffold_metadata_path = File.join(aiweb_dir, "scaffold-profile-S.json")
        secret_qa_path = File.join(aiweb_dir, "qa", "supabase-secret-qa.json")
        local_verify_path = File.join(aiweb_dir, "qa", "supabase-local-verify.json")
        conflicts = scaffold_conflicts(files, force: force)
        preflight_scaffold_targets!(files, metadata_path: scaffold_metadata_path, force: force, profile: "S")
        preflight_scaffold_targets!({}, metadata_path: secret_qa_path, force: force, profile: "S")
        preflight_scaffold_targets!({}, metadata_path: local_verify_path, force: force, profile: "S")

        unless conflicts.empty?
          raise UserError.new(
            "scaffold profile S found existing files that differ and were preserved: #{conflicts.join(", ")}. No scaffold files were written. Rerun aiweb scaffold --profile S --force to overwrite regular scaffold files after reviewing those files.",
            1
          )
        end

        files.each do |relative_path, content|
          path = File.join(root, relative_path)
          next if File.exist?(path) && File.read(path) == content

          changes << write_file(path, content, dry_run)
        end

        metadata = scaffold_profile_s_metadata(files, profile_data)
        changes << write_json(scaffold_metadata_path, metadata, dry_run)
        scaffold_files_with_metadata = files.merge(SCAFFOLD_PROFILE_S_METADATA_PATH => JSON.pretty_generate(metadata) + "\n")
        secret_qa = scaffold_profile_s_secret_qa(scaffold_files_with_metadata)
        changes << write_json(secret_qa_path, secret_qa, dry_run)
        local_verify = scaffold_profile_s_local_verify(scaffold_files_with_metadata.merge(SCAFFOLD_PROFILE_S_SECRET_QA_PATH => JSON.pretty_generate(secret_qa) + "\n"))
        changes << write_json(local_verify_path, local_verify, dry_run)
        apply_scaffold_state!(state, metadata)
        state["qa"] ||= {}
        state["qa"]["supabase_secret_qa"] = SCAFFOLD_PROFILE_S_SECRET_QA_PATH
        state["qa"]["supabase_local_verify"] = SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH
        add_decision!(state, "scaffold_profile_s", "Generated local-only Profile S Next.js + Supabase scaffold with safe non-dot env template, secret QA artifact, and local Supabase verification")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)

        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = force ? "regenerated scaffold profile S" : "generated scaffold profile S"
        payload["scaffold"] = metadata.reject { |key, _| key == "files" }
        payload["secret_qa"] = secret_qa.reject { |key, _| key == "files" }
        payload["supabase_local_verify"] = local_verify.reject { |key, _| key == "files" }
        payload["next_action"] = "review generated local-only Next.js/Supabase files and .ai-web/qa/supabase-local-verify.json; copy supabase/env.example.template manually into an untracked local env file only when ready"
      end
      payload
    end

    def supabase_secret_qa(dry_run: false, force: false)
      assert_initialized!
      state = load_state
      files = supabase_secret_qa_scan_files
      artifact_path = File.join(root, SCAFFOLD_PROFILE_S_SECRET_QA_PATH)
      qa = scaffold_profile_s_secret_qa(files)
      qa["artifact_path"] = SCAFFOLD_PROFILE_S_SECRET_QA_PATH
      qa["profile"] = "S"
      planned_changes = [SCAFFOLD_PROFILE_S_SECRET_QA_PATH]

      if dry_run
        payload = status_hash(state: state, changed_files: [])
        payload["action_taken"] = "planned Supabase secret QA"
        payload["planned_changes"] = planned_changes
        payload["supabase_secret_qa"] = qa.merge("dry_run" => true)
        payload["next_action"] = "rerun supabase_secret_qa without dry_run to write #{SCAFFOLD_PROFILE_S_SECRET_QA_PATH}"
        return payload
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        existing_conflict = File.file?(artifact_path) && !force && JSON.parse(File.read(artifact_path)).is_a?(Hash) == false
        raise UserError.new("Supabase secret QA artifact is malformed; review #{SCAFFOLD_PROFILE_S_SECRET_QA_PATH} or rerun with force", 1) if existing_conflict

        changes << write_json(artifact_path, qa, false)
        state["qa"] ||= {}
        state["qa"]["supabase_secret_qa"] = SCAFFOLD_PROFILE_S_SECRET_QA_PATH
        add_decision!(state, "supabase_secret_qa", "Scanned generated Profile S safe files without reading dot-env paths")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "recorded Supabase secret QA"
        payload["supabase_secret_qa"] = qa
        payload["next_action"] = qa["status"] == "passed" ? "keep dot-env files local and untracked" : "review Profile S generated safe files for credential exposure patterns"
      end
      payload
    rescue JSON::ParserError
      raise UserError.new("Supabase secret QA artifact is malformed; review #{SCAFFOLD_PROFILE_S_SECRET_QA_PATH} or rerun with force", 1)
    end

    def supabase_local_verify(dry_run: false, force: false)
      assert_initialized!
      state = load_state
      files = supabase_local_verify_scan_files
      artifact_path = File.join(root, SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH)
      verify = scaffold_profile_s_local_verify(files)
      verify["artifact_path"] = SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH
      verify["profile"] = "S"
      planned_changes = [SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH]

      if dry_run
        payload = status_hash(state: state, changed_files: [])
        payload["action_taken"] = "planned Supabase local verification"
        payload["planned_changes"] = planned_changes
        payload["supabase_local_verify"] = verify.merge("dry_run" => true)
        payload["next_action"] = "rerun supabase-local-verify without --dry-run to write #{SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH}"
        return payload
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        existing_conflict = File.file?(artifact_path) && !force && JSON.parse(File.read(artifact_path)).is_a?(Hash) == false
        raise UserError.new("Supabase local verification artifact is malformed; review #{SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH} or rerun with force", 1) if existing_conflict

        changes << write_json(artifact_path, verify, false)
        state["qa"] ||= {}
        state["qa"]["supabase_local_verify"] = SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH
        add_decision!(state, "supabase_local_verify", "Verified generated Profile S files locally without reading dot-env paths or contacting Supabase")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "recorded Supabase local verification"
        payload["supabase_local_verify"] = verify
        payload["next_action"] = verify["status"] == "passed" ? "run aiweb setup --install --dry-run only after reviewing generated Profile S files" : "repair generated Profile S safe files, then rerun aiweb supabase-local-verify"
      end
      payload
    rescue JSON::ParserError
      raise UserError.new("Supabase local verification artifact is malformed; review #{SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH} or rerun with force", 1)
    end



      private

    def ensure_scaffold_state_defaults!(state)
      ensure_implementation_state_defaults!(state)
      state["implementation"]["scaffold_created"] = false if state["implementation"]["scaffold_created"].nil?
      state["implementation"]["scaffold_profile"] ||= nil
      state["implementation"]["scaffold_framework"] ||= nil
      state["implementation"]["scaffold_package_manager"] ||= nil
      state["implementation"]["scaffold_dev_command"] ||= nil
      state["implementation"]["scaffold_build_command"] ||= nil
      state["implementation"]["scaffold_metadata_path"] ||= nil
      state["implementation"]["latest_agent_run"] ||= nil
      state["implementation"]["last_diff"] ||= nil
      state
    end

    def apply_scaffold_state!(state, metadata)
      ensure_scaffold_state_defaults!(state)
      state["implementation"]["stack_profile"] = metadata.fetch("profile")
      state["implementation"]["scaffold_target"] = metadata.fetch("scaffold_target")
      state["implementation"]["scaffold_created"] = true
      state["implementation"]["scaffold_profile"] = metadata.fetch("profile")
      state["implementation"]["scaffold_framework"] = metadata.fetch("framework")
      state["implementation"]["scaffold_package_manager"] = metadata.fetch("package_manager")
      state["implementation"]["scaffold_dev_command"] = metadata.fetch("dev_command")
      state["implementation"]["scaffold_build_command"] = metadata.fetch("build_command")
      state["implementation"]["scaffold_metadata_path"] = metadata.fetch("metadata_path")
      state
    end

    def validate_scaffold_design_gate!(state)
      design_path = File.join(aiweb_dir, "DESIGN.md")
      if !File.file?(design_path) || stub_file?(design_path)
        raise UserError.new("scaffold profile D requires substantive .ai-web/DESIGN.md; run aiweb design-system resolve or provide a completed design source of truth before scaffold", 1)
      end

      selected = state.dig("design_candidates", "selected_candidate").to_s.strip
      if selected.empty?
        raise UserError.new("scaffold profile D requires design_candidates.selected_candidate; run aiweb design --candidates 3 then aiweb select-design candidate-01|candidate-02|candidate-03 before scaffold", 1)
      end

      selected_path = selected_candidate_artifact_path(state, selected)
      unless selected_path && File.file?(selected_path)
        relative_selected_path = selected_path ? relative(selected_path) : ".ai-web/design-candidates/#{selected}.html"
        raise UserError.new("scaffold profile D requires selected candidate artifact #{relative_selected_path}; rerun aiweb design --candidates 3 then aiweb select-design #{selected} before scaffold", 1)
      end
    end

    def selected_candidate_artifact_path(state, selected)
      ref = Array(state.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == selected }
      candidates = []
      candidates << File.join(root, ref["path"].to_s) if ref && !ref["path"].to_s.strip.empty?
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.html")
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.md")
      candidates.find { |path| File.file?(path) } || candidates.first
    end

    def preflight_scaffold_targets!(files, metadata_path:, force:, profile: "D")
      conflicts = scaffold_target_type_conflicts(files.keys + [relative(metadata_path)])
      return if conflicts.empty?

      raise UserError.new("scaffold profile #{profile} cannot write because directories conflict with required scaffold files: #{conflicts.join(", ")}. Remove or rename those directories before rerunning; --force only overwrites regular files and wrote no scaffold files.", 1)
    end

    def scaffold_target_type_conflicts(relative_paths)
      conflicts = []
      relative_paths.each do |relative_path|
        parts = relative_path.split(File::SEPARATOR)
        parts.each_index do |index|
          partial = File.join(root, *parts[0..index])
          next unless File.exist?(partial)

          if index == parts.length - 1
            conflicts << "#{relative_path} (directory exists where file is needed)" if File.directory?(partial)
          elsif !File.directory?(partial)
            conflicts << "#{parts[0..index].join(File::SEPARATOR)} (file exists where directory is needed for #{relative_path})"
            break
          end
        end
      end
      conflicts.uniq
    end

    def scaffold_conflicts(files, force:)
      return [] if force

      files.each_with_object([]) do |(relative_path, content), conflicts|
        path = File.join(root, relative_path)
        next unless File.file?(path)
        next if File.read(path) == content

        conflicts << relative_path
      end
    end

    def scaffold_context(state)
      intent = load_intent_artifact
      selected = selected_candidate_id
      {
        project_name: state.dig("project", "name").to_s.empty? ? File.basename(root) : state.dig("project", "name"),
        project_id: state.dig("project", "id").to_s.empty? ? default_project_id : state.dig("project", "id"),
        title: scaffold_title_from_artifacts(state, intent),
        description: scaffold_description_from_artifacts(intent),
        archetype: intent["archetype"].to_s,
        primary_interaction: intent["primary_interaction"].to_s,
        must_have_first_view: Array(intent["must_have_first_view"]),
        must_not_have: Array(intent["must_not_have"]),
        design_brief_excerpt: scaffold_excerpt(File.join(aiweb_dir, "design-brief.md")),
        design_system_excerpt: scaffold_excerpt(File.join(aiweb_dir, "DESIGN.md")),
        selected_candidate: selected,
        selected_candidate_path: selected ? ".ai-web/design-candidates/#{selected}.html" : nil
      }
    end

    def scaffold_title_from_artifacts(state, intent)
      project_path = File.join(aiweb_dir, "project.md")
      if File.exist?(project_path)
        idea_line = File.read(project_path).lines.each_cons(2).find { |a, _b| a.strip == "## Idea" }
        title = idea_line&.last.to_s.strip
        return title unless title.empty? || title.start_with?("TODO")
      end
      concept = intent["original_intent"].to_s.strip
      return concept unless concept.empty?

      state.dig("project", "name").to_s
    end

    def scaffold_description_from_artifacts(intent)
      primary = intent["primary_interaction"].to_s.strip
      archetype = intent["archetype"].to_s.strip
      if primary.empty? && archetype.empty?
        "Source-backed static site scaffold generated by AI Web Director."
      else
        "A #{archetype.empty? ? "static" : archetype} web foundation centered on #{primary.empty? ? "the approved first-view contract" : primary}."
      end
    end

    def scaffold_excerpt(path, max_lines = 18)
      return "" unless File.exist?(path)

      File.read(path).lines.map(&:rstrip).reject(&:empty?).first(max_lines).join("\n")
    end

    def npm_package_name(value)
      ascii = value.to_s.downcase.gsub(/[^a-z0-9._-]+/, "-").gsub(/^-+|-+$/, "")
      ascii = "aiweb-site" if ascii.empty? || ascii.start_with?(".", "_")
      ascii
    end


    end
  end
end
