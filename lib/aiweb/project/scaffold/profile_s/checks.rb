# frozen_string_literal: true

module Aiweb
  class Project
    module Scaffold
      module ProfileS
        private

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
      end
    end
  end
end
