# frozen_string_literal: true

module Aiweb
  class Project
    module Scaffold
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

    def scaffold_profile_d_metadata(files, state, profile_data)
      selected = selected_candidate_id
      {
        "schema_version" => 1,
        "profile" => "D",
        "framework" => "Astro",
        "package_manager" => "pnpm",
        "dev_command" => "pnpm dev",
        "build_command" => "pnpm build",
        "scaffold_target" => profile_data.fetch(:scaffold_target),
        "selected_candidate" => selected,
        "selected_candidate_path" => selected ? ".ai-web/design-candidates/#{selected}.html" : nil,
        "design_source" => File.exist?(File.join(aiweb_dir, "DESIGN.md")) ? ".ai-web/DESIGN.md" : nil,
        "design_brief_source" => File.exist?(File.join(aiweb_dir, "design-brief.md")) ? ".ai-web/design-brief.md" : nil,
        "created_at" => now,
        "metadata_path" => SCAFFOLD_PROFILE_D_METADATA_PATH,
        "files" => files.keys.map do |relative_path|
          {
            "path" => relative_path,
            "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path))
          }
        end
      }
    end

    def scaffold_profile_d_files(state)
      context = scaffold_context(state)
      {
        "package.json" => package_json_profile_d(context),
        "astro.config.mjs" => astro_config_profile_d,
        "tailwind.config.mjs" => tailwind_config_profile_d,
        "src/styles/global.css" => global_css_profile_d,
        "src/content/site.json" => JSON.pretty_generate(site_content_profile_d(context)) + "\n",
        "src/components/Hero.astro" => hero_component_profile_d,
        "src/components/SectionCard.astro" => section_card_component_profile_d,
        "src/pages/index.astro" => index_page_profile_d(context),
        "public/.gitkeep" => ""
      }
    end


    def scaffold_profile_s_metadata(files, profile_data)
      {
        "schema_version" => 1,
        "profile" => "S",
        "framework" => "Next.js",
        "framework_detail" => "Next.js App Router + Supabase SSR",
        "package_manager" => "pnpm",
        "dev_command" => "pnpm dev",
        "build_command" => "pnpm build",
        "scaffold_target" => profile_data.fetch(:scaffold_target),
        "metadata_path" => SCAFFOLD_PROFILE_S_METADATA_PATH,
        "secret_qa_path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH,
        "local_verify_path" => SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH,
        "local_only" => true,
        "external_actions_allowed" => false,
        "env_template_path" => "supabase/env.example.template",
        "env_dotfile_created" => false,
        "supabase_public_env" => %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY],
        "guardrails" => [
          "no external Supabase project creation",
          "no deploy/external hosting",
          "no .env or .env.* files"
        ],
        "created_at" => now,
        "files" => files.keys.map do |relative_path|
          {
            "path" => relative_path,
            "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path))
          }
        end
      }
    end

    def scaffold_profile_s_files(state)
      context = scaffold_context(state)
      {
        "package.json" => package_json_profile_s(context),
        "next.config.mjs" => next_config_profile_s,
        "tsconfig.json" => tsconfig_profile_s,
        "src/app/layout.tsx" => layout_tsx_profile_s(context),
        "src/app/page.tsx" => page_tsx_profile_s(context),
        "src/app/globals.css" => globals_css_profile_s,
        "src/lib/supabase/client.ts" => supabase_client_ts_profile_s,
        "src/lib/supabase/server.ts" => supabase_server_ts_profile_s,
        "supabase/migrations/0001_initial_schema.sql" => supabase_initial_schema_profile_s,
        "supabase/rls-draft.md" => supabase_rls_draft_profile_s,
        "supabase/storage.md" => supabase_storage_profile_s,
        "supabase/env.example.template" => supabase_env_template_profile_s
      }
    end

    def supabase_secret_qa_scan_files
      SCAFFOLD_PROFILE_S_REQUIRED_FILES.each_with_object({}) do |relative_path, memo|
        next if relative_path == SCAFFOLD_PROFILE_S_SECRET_QA_PATH
        next if unsafe_env_path?(relative_path)

        path = File.join(root, relative_path)
        memo[relative_path] = File.read(path) if File.file?(path)
      end
    end

    def supabase_local_verify_scan_files
      SCAFFOLD_PROFILE_S_REQUIRED_FILES.each_with_object({}) do |relative_path, memo|
        next if unsafe_env_path?(relative_path)

        path = File.join(root, relative_path)
        memo[relative_path] = File.read(path) if File.file?(path)
      end
    end

    def scaffold_profile_s_secret_qa(files)
      scanned = files.keys.reject { |path| unsafe_env_path?(path) }.sort
      findings = scanned.flat_map do |relative_path|
        body = files.fetch(relative_path)
        PROFILE_S_SECRET_EXPOSURE_PATTERNS.each_with_object([]) do |pattern, memo|
          next unless body.match?(pattern)

          memo << { "path" => relative_path, "pattern" => pattern.source }
        end
      end
      {
        "schema_version" => 1,
        "status" => findings.empty? ? "passed" : "failed",
        "created_at" => now,
        "scanned_paths" => scanned,
        "read_dot_env" => false,
        "scan" => {
          "mode" => "generated-safe-files-only",
          "excluded_patterns" => [".env", ".env.*"],
          "scanned_files" => scanned,
          "env_files_read" => false,
          "source_contents_embedded" => false
        },
        "files" => scanned.map { |relative_path| { "path" => relative_path, "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path)) } },
        "findings" => findings
      }
    end

    def scaffold_profile_s_local_verify(files)
      scanned = files.keys.reject { |path| unsafe_env_path?(path) }.sort
      required_paths = SCAFFOLD_PROFILE_S_REQUIRED_FILES
      missing_paths = required_paths.reject { |path| files.key?(path) }
      checks = {
        "required_files" => supabase_local_required_files_check(missing_paths),
        "safe_env_template" => supabase_local_env_template_check(files["supabase/env.example.template"]),
        "ssr_stubs" => supabase_local_ssr_stubs_check(files),
        "migrations_rls" => supabase_local_migrations_check(files["supabase/migrations/0001_initial_schema.sql"]),
        "storage_docs" => supabase_local_storage_docs_check(files["supabase/storage.md"]),
        "metadata" => supabase_local_metadata_check(files[SCAFFOLD_PROFILE_S_METADATA_PATH]),
        "secret_qa" => supabase_local_secret_qa_check(files[SCAFFOLD_PROFILE_S_SECRET_QA_PATH]),
        "external_actions" => supabase_local_external_actions_check(files)
      }
      findings = checks.flat_map { |name, check| Array(check["findings"]).map { |finding| finding.merge("check" => name) } }
      {
        "schema_version" => 1,
        "status" => findings.empty? ? "passed" : "failed",
        "created_at" => now,
        "local_only" => true,
        "external_actions_performed" => false,
        "provider_cli_invoked" => false,
        "read_dot_env" => false,
        "scanned_paths" => scanned,
        "required_paths" => required_paths,
        "checks" => checks,
        "files" => scanned.map { |relative_path| { "path" => relative_path, "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path)) } },
        "findings" => findings
      }
    end

    def supabase_local_required_files_check(missing_paths)
      findings = missing_paths.map { |path| { "path" => path, "message" => "required Profile S file is missing" } }
      { "status" => findings.empty? ? "passed" : "failed", "missing_paths" => missing_paths, "findings" => findings }
    end

    def supabase_local_env_template_check(body)
      findings = []
      if body.to_s.empty?
        findings << { "path" => "supabase/env.example.template", "message" => "safe Supabase env template is missing" }
      else
        findings << { "path" => "supabase/env.example.template", "message" => "NEXT_PUBLIC_SUPABASE_URL placeholder is missing" } unless body.match?(/NEXT_PUBLIC_SUPABASE_URL=/)
        findings << { "path" => "supabase/env.example.template", "message" => "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY placeholder is missing" } unless body.match?(/NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=/)
        PROFILE_S_SECRET_EXPOSURE_PATTERNS.each do |pattern|
          findings << { "path" => "supabase/env.example.template", "message" => "unsafe secret placeholder pattern found", "pattern" => pattern.source } if body.match?(pattern)
        end
      end
      { "status" => findings.empty? ? "passed" : "failed", "allowed_public_env" => %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY], "dot_env_created" => false, "findings" => findings }
    end

    def supabase_local_ssr_stubs_check(files)
      client = files["src/lib/supabase/client.ts"].to_s
      server = files["src/lib/supabase/server.ts"].to_s
      findings = []
      findings << { "path" => "src/lib/supabase/client.ts", "message" => "browser Supabase SSR client stub is missing createBrowserClient" } unless client.match?(/createBrowserClient/)
      findings << { "path" => "src/lib/supabase/server.ts", "message" => "server Supabase SSR client stub is missing createServerClient" } unless server.match?(/createServerClient/)
      findings << { "path" => "src/lib/supabase/server.ts", "message" => "server Supabase SSR client stub is missing cookies integration" } unless server.match?(/cookies/)
      %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY].each do |key|
        findings << { "path" => "src/lib/supabase/client.ts", "message" => "#{key} is missing from browser client stub" } unless client.include?(key)
        findings << { "path" => "src/lib/supabase/server.ts", "message" => "#{key} is missing from server client stub" } unless server.include?(key)
      end
      { "status" => findings.empty? ? "passed" : "failed", "client_path" => "src/lib/supabase/client.ts", "server_path" => "src/lib/supabase/server.ts", "findings" => findings }
    end

    def supabase_local_migrations_check(body)
      findings = []
      text = body.to_s
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing enable row level security" } unless text.match?(/enable row level security/i)
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing create policy statements" } unless text.match?(/create policy/i)
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing auth.uid ownership guard" } unless text.match?(/auth\.uid\(\)/i)
      { "status" => findings.empty? ? "passed" : "failed", "path" => "supabase/migrations/0001_initial_schema.sql", "findings" => findings }
    end

    def supabase_local_storage_docs_check(body)
      findings = []
      text = body.to_s
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc is missing" } if text.empty?
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc must describe storage options" } unless text.match?(/storage|bucket/i)
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc must retain external-action guardrails" } unless text.match?(/does not run Supabase CLI commands|no buckets are created/i)
      { "status" => findings.empty? ? "passed" : "failed", "path" => "supabase/storage.md", "findings" => findings }
    end

    def supabase_local_metadata_check(body)
      findings = []
      metadata = body.to_s.empty? ? nil : JSON.parse(body)
      unless metadata.is_a?(Hash)
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "Profile S metadata is missing or malformed" }
      else
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata profile must be S" } unless metadata["profile"] == "S"
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata must stay local-only" } unless metadata["local_only"] == true
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata must disallow external actions" } unless metadata["external_actions_allowed"] == false
      end
      { "status" => findings.empty? ? "passed" : "failed", "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "findings" => findings }
    rescue JSON::ParserError
      { "status" => "failed", "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "findings" => [{ "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "Profile S metadata is malformed" }] }
    end

    def supabase_local_secret_qa_check(body)
      findings = []
      qa = body.to_s.empty? ? nil : JSON.parse(body)
      unless qa.is_a?(Hash)
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA artifact is missing or malformed" }
      else
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA must pass before local verification passes" } unless qa["status"] == "passed"
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA must not read dot-env files" } unless qa["read_dot_env"] == false
      end
      { "status" => findings.empty? ? "passed" : "failed", "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "findings" => findings }
    rescue JSON::ParserError
      { "status" => "failed", "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "findings" => [{ "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA artifact is malformed" }] }
    end

    def supabase_local_external_actions_check(files)
      patterns = {
        "supabase_provider_cli" => /supabase\s+(login|link|projects\s+create|init|start|db\s+push)/i,
        "deploy_cli" => /\b(vercel|netlify|cloudflare)\s+deploy\b/i,
        "network_curl" => /\bcurl\s+https?:\/\//i
      }
      findings = files.reject { |path, _| path.start_with?(".ai-web/qa/") }.flat_map do |relative_path, body|
        patterns.each_with_object([]) do |(name, pattern), memo|
          memo << { "path" => relative_path, "message" => "external action command pattern found", "pattern" => name } if body.to_s.match?(pattern)
        end
      end
      { "status" => findings.empty? ? "passed" : "failed", "performed" => false, "network" => false, "provider_cli" => false, "findings" => findings }
    end

    def unsafe_env_path?(relative_path)
      Aiweb::Runtime::PathPolicy.unsafe_env_path?(relative_path)
    end

    def secret_looking_path?(relative_path)
      Aiweb::Runtime::PathPolicy.secret_looking_path?(relative_path)
    end

    def package_json_profile_s(context)
      JSON.pretty_generate(
        "name" => npm_package_name(context.fetch(:project_id).empty? ? context.fetch(:project_name) : context.fetch(:project_id)),
        "version" => "0.1.0",
        "private" => true,
        "type" => "module",
        "scripts" => {
          "dev" => "next dev",
          "build" => "next build",
          "start" => "next start"
        },
        "dependencies" => {
          "@supabase/ssr" => "latest",
          "@supabase/supabase-js" => "latest",
          "next" => "latest",
          "react" => "latest",
          "react-dom" => "latest"
        },
        "devDependencies" => {
          "@types/node" => "latest",
          "@types/react" => "latest",
          "@types/react-dom" => "latest",
          "typescript" => "latest"
        }
      ) + "\n"
    end

    def next_config_profile_s
      <<~JS
        /** @type {import('next').NextConfig} */
        const nextConfig = {};

        export default nextConfig;
      JS
    end

    def tsconfig_profile_s
      JSON.pretty_generate(
        "compilerOptions" => {
          "target" => "ES2017",
          "lib" => %w[dom dom.iterable esnext],
          "allowJs" => true,
          "skipLibCheck" => true,
          "strict" => true,
          "noEmit" => true,
          "esModuleInterop" => true,
          "module" => "esnext",
          "moduleResolution" => "bundler",
          "resolveJsonModule" => true,
          "isolatedModules" => true,
          "jsx" => "preserve",
          "incremental" => true,
          "plugins" => [{ "name" => "next" }],
          "paths" => { "@/*" => ["./src/*"] }
        },
        "include" => ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
        "exclude" => ["node_modules"]
      ) + "\n"
    end

    def layout_tsx_profile_s(context)
      title = context.fetch(:title).to_s.empty? ? context.fetch(:project_name) : context.fetch(:title)
      <<~TSX
        import type { Metadata } from 'next';
        import './globals.css';

        export const metadata: Metadata = {
          title: #{title.inspect},
          description: #{context.fetch(:description).inspect},
        };

        export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
          return (
            <html lang="ko">
              <body>{children}</body>
            </html>
          );
        }
      TSX
    end

    def page_tsx_profile_s(context)
      title = context.fetch(:title).to_s.empty? ? context.fetch(:project_name) : context.fetch(:title)
      <<~TSX
        import { createClient } from '@/lib/supabase/server';

        export default async function Home() {
          const supabase = await createClient();
          const { data: profileRows } = await supabase.from('profiles').select('id, display_name').limit(3);

          return (
            <main className="mx-auto flex min-h-screen max-w-5xl flex-col gap-8 px-6 py-16">
              <section className="rounded-3xl border border-slate-200 bg-white p-8 shadow-sm">
                <p className="text-sm font-semibold uppercase tracking-[0.24em] text-emerald-700">AI Web Director Profile S</p>
                <h1 className="mt-4 text-4xl font-bold tracking-tight text-slate-950">#{CGI.escapeHTML(title)}</h1>
                <p className="mt-4 max-w-2xl text-lg leading-8 text-slate-700">#{CGI.escapeHTML(context.fetch(:description))}</p>
              </section>

              <section className="rounded-3xl border border-dashed border-emerald-300 bg-emerald-50 p-6">
                <h2 className="text-2xl font-bold text-slate-950">Local Supabase planning stub</h2>
                <p className="mt-3 text-slate-700">
                  This scaffold uses safe public browser env names only and does not create or read dot-env files.
                </p>
                <pre className="mt-4 overflow-auto rounded-2xl bg-slate-950 p-4 text-sm text-emerald-100">
                  {JSON.stringify(profileRows ?? [], null, 2)}
                </pre>
              </section>
            </main>
          );
        }
      TSX
    end

    def globals_css_profile_s
      <<~CSS
        :root {
          color: #0f172a;
          background: #f8fafc;
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }

        * {
          box-sizing: border-box;
        }

        body {
          margin: 0;
          min-width: 320px;
        }
      CSS
    end

    def supabase_client_ts_profile_s
      <<~TS
        import { createBrowserClient } from '@supabase/ssr';

        export function createClient() {
          return createBrowserClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL!,
            process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
          );
        }
      TS
    end

    def supabase_server_ts_profile_s
      <<~TS
        import { createServerClient } from '@supabase/ssr';
        import { cookies } from 'next/headers';

        export async function createClient() {
          const cookieStore = await cookies();

          return createServerClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL!,
            process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
            {
              cookies: {
                getAll() {
                  return cookieStore.getAll();
                },
                setAll(cookiesToSet) {
                  try {
                    cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
                  } catch {
                    // Server Components cannot set cookies. Middleware should refresh sessions when needed.
                  }
                },
              },
            },
          );
        }
      TS
    end

    def supabase_initial_schema_profile_s
      <<~SQL
        -- Profile S draft migration for local planning only.
        -- Review with a database owner before applying to any external Supabase project.

        create table if not exists public.profiles (
          id uuid primary key references auth.users(id) on delete cascade,
          display_name text,
          created_at timestamptz not null default now(),
          updated_at timestamptz not null default now()
        );

        alter table public.profiles enable row level security;

        create policy "profiles are viewable by owner"
          on public.profiles for select
          using (auth.uid() = id);

        create policy "profiles are insertable by owner"
          on public.profiles for insert
          with check (auth.uid() = id);

        create policy "profiles are updatable by owner"
          on public.profiles for update
          using (auth.uid() = id)
          with check (auth.uid() = id);
      SQL
    end

    def supabase_rls_draft_profile_s
      <<~MD
        # Supabase RLS Draft — Profile S

        Status: draft for local planning only.

        ## Policies
        - `profiles`: owner-only select/insert/update using `auth.uid() = id`.
        - Add table-specific policies before connecting real product data.

        ## Guardrails
        - Do not apply this draft to a hosted Supabase project without review.
        - Keep service-role credentials out of generated app files and browser code.
        - Public browser variables are limited to `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`.
      MD
    end

    def supabase_storage_profile_s
      <<~MD
        # Supabase Storage Options — Profile S

        Status: planning notes only; no buckets are created by this scaffold.

        ## Option A: private user uploads
        - Bucket: `user-uploads`.
        - Access: authenticated owner read/write policies.
        - Use signed URLs for temporary sharing.

        ## Option B: public marketing assets
        - Bucket: `public-assets`.
        - Access: public read, restricted write.
        - Prefer static `public/` files until product scope needs runtime uploads.

        ## External-action guardrail
        This scaffold does not run Supabase CLI commands, create buckets, or contact external APIs.
      MD
    end

    def supabase_env_template_profile_s
      <<~TXT
        # Copy these keys into your local untracked environment file when you are ready.
        # This is intentionally not named .env.example because Profile S must not create dot-env files.
        NEXT_PUBLIC_SUPABASE_URL=https://your-project-ref.supabase.co
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
      TXT
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

    def package_json_profile_d(context)
      JSON.pretty_generate(
        "name" => npm_package_name(context.fetch(:project_id).empty? ? context.fetch(:project_name) : context.fetch(:project_id)),
        "version" => "0.1.0",
        "private" => true,
        "type" => "module",
        "scripts" => {
          "dev" => "astro dev",
          "build" => "astro build",
          "preview" => "astro preview"
        },
        "dependencies" => {
          "@astrojs/mdx" => "latest",
          "@astrojs/sitemap" => "latest",
          "astro" => "latest",
          "tailwindcss" => "latest",
          "@tailwindcss/vite" => "latest"
        }
      ) + "\n"
    end

    def astro_config_profile_d
      <<~JS
        import { defineConfig } from 'astro/config';
        import mdx from '@astrojs/mdx';
        import sitemap from '@astrojs/sitemap';
        import tailwindcss from '@tailwindcss/vite';

        export default defineConfig({
          integrations: [mdx(), sitemap()],
          vite: {
            plugins: [tailwindcss()]
          }
        });
      JS
    end

    def tailwind_config_profile_d
      <<~JS
        export default {
          content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
          theme: {
            extend: {
              colors: {
                ink: '#111827',
                paper: '#fffaf3',
                accent: '#2563eb'
              }
            }
          }
        };
      JS
    end

    def global_css_profile_d
      <<~CSS
        @import "tailwindcss";

        :root {
          color: #111827;
          background: #fffaf3;
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }

        body {
          margin: 0;
          min-width: 320px;
        }

        a {
          color: inherit;
        }
      CSS
    end

    def site_content_profile_d(context)
      {
        "schema_version" => 1,
        "title" => context.fetch(:title),
        "description" => context.fetch(:description),
        "archetype" => context.fetch(:archetype),
        "primary_interaction" => context.fetch(:primary_interaction),
        "must_have_first_view" => context.fetch(:must_have_first_view),
        "must_not_have" => context.fetch(:must_not_have),
        "selected_candidate" => context.fetch(:selected_candidate),
        "selected_candidate_path" => context.fetch(:selected_candidate_path),
        "design_brief_excerpt" => context.fetch(:design_brief_excerpt),
        "design_system_excerpt" => context.fetch(:design_system_excerpt),
        "content_policy" => "Use only source-backed proof. Do not add fake testimonials, fake logos, fake customer counts, or fake metrics."
      }
    end

    def hero_component_profile_d
      <<~ASTRO
        ---
        const { title, description, primaryInteraction, selectedCandidate } = Astro.props;
        ---

        <section class="mx-auto grid max-w-6xl gap-8 px-6 py-20 md:grid-cols-[1.2fr_0.8fr] md:items-center" data-aiweb-id="page.home.hero">
          <div data-aiweb-id="component.hero.copy">
            <p class="mb-3 text-sm font-semibold uppercase tracking-[0.24em] text-blue-700">AI Web Director Profile D</p>
            <h1 class="text-4xl font-bold tracking-tight text-slate-950 md:text-6xl">{title}</h1>
            <p class="mt-5 max-w-2xl text-lg leading-8 text-slate-700">{description}</p>
            <div class="mt-8 rounded-2xl border border-slate-200 bg-white/80 p-5 shadow-sm" data-aiweb-id="component.hero.primary-interaction">
              <p class="text-sm font-semibold text-slate-500">Primary first-view interaction</p>
              <p class="mt-2 text-xl font-semibold text-slate-950">{primaryInteraction || 'TODO: confirm from .ai-web/first-view-contract.md'}</p>
            </div>
          </div>
          <aside class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm" data-aiweb-id="component.hero.design-reference">
            <p class="text-sm font-semibold text-slate-500">Design reference</p>
            <p class="mt-2 text-2xl font-bold text-slate-950">{selectedCandidate || 'No selected candidate yet'}</p>
            <p class="mt-3 text-sm leading-6 text-slate-600">Generated from Director artifacts. Keep DESIGN.md authoritative and replace placeholders only with source-backed content.</p>
          </aside>
        </section>
      ASTRO
    end

    def section_card_component_profile_d
      <<~ASTRO
        ---
        const { title, items = [], aiwebId = 'component.section-card' } = Astro.props;
        ---

        <section class="mx-auto max-w-6xl px-6 py-10" data-aiweb-id={aiwebId}>
          <div class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 class="text-2xl font-bold text-slate-950">{title}</h2>
            <ul class="mt-5 grid gap-3 text-slate-700 md:grid-cols-2">
              {items.map((item) => <li class="rounded-2xl bg-slate-50 p-4" data-aiweb-id={`${aiwebId}.item`}>{item}</li>)}
            </ul>
          </div>
        </section>
      ASTRO
    end

    def index_page_profile_d(context)
      <<~ASTRO
        ---
        import '../styles/global.css';
        import site from '../content/site.json';
        import Hero from '../components/Hero.astro';
        import SectionCard from '../components/SectionCard.astro';

        const title = site.title || #{context.fetch(:project_name).inspect};
        const description = site.description || 'Static site scaffold generated from AI Web Director artifacts.';
        ---

        <html lang="ko" data-aiweb-id="document.home">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <meta name="description" content={description} />
            <title>{title}</title>
          </head>
          <body class="bg-[var(--color-paper,#fffaf3)]">
            <main data-aiweb-id="page.home">
              <Hero
                title={title}
                description={description}
                primaryInteraction={site.primary_interaction}
                selectedCandidate={site.selected_candidate}
              />
              <SectionCard title="First-view obligations" items={site.must_have_first_view || []} aiwebId="page.home.first-view-obligations" />
              <SectionCard title="Forbidden or excluded patterns" items={site.must_not_have || []} aiwebId="page.home.must-not-have" />
              <section class="mx-auto max-w-6xl px-6 py-10" data-aiweb-id="page.home.source-notes">
                <div class="rounded-3xl border border-dashed border-slate-300 bg-white/70 p-6">
                  <h2 class="text-2xl font-bold text-slate-950">Source notes</h2>
                  <p class="mt-4 text-sm leading-6 text-slate-600">Selected candidate: {site.selected_candidate || 'none'}</p>
                  <p class="mt-2 text-sm leading-6 text-slate-600">Policy: {site.content_policy}</p>
                </div>
              </section>
            </main>
          </body>
        </html>
      ASTRO
    end

    end
  end
end
