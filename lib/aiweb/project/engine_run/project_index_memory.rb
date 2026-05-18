# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_project_index(manifest)
      files = manifest.fetch("files", {})
      package_scripts = engine_run_package_scripts(files)
      {
        "schema_version" => 1,
        "status" => "ready",
        "generated_at" => now,
        "source" => "staged_manifest_repo_index",
        "manifest_file_count" => files.length,
        "retrieval" => {
          "strategy" => "repo_index_json_rg_compatible",
          "dependency_free" => true,
          "worker_context_ref" => "_aiweb/project-index.json"
        },
        "routes" => engine_run_index_group(files, %r{\A(?:src/)?(?:pages/.+\.(?:astro|js|jsx|ts|tsx|vue|svelte)|app/.+(?:page|route)\.(?:js|jsx|ts|tsx))\z}, "route"),
        "components" => engine_run_component_index(files),
        "styles" => engine_run_index_group(files, %r{\A(?:(?:src/)?styles/.+|app/.+\.css|src/app/.+\.css|.+(?:global|style|theme|tailwind).*\.(?:css|scss|sass)|(?:astro|vite|tailwind)\.config\.(?:js|mjs|cjs|ts))\z}, "style"),
        "data_contracts" => engine_run_index_group(files, %r{\A(?:(?:src/)?content/.+|(?:src/)?data/.+|schemas?/.+|prisma/schema\.prisma|supabase/.+|\.ai-web/component-map\.json|.+(?:schema|contract|model|type).*\.(?:json|ts|tsx|js|rb))\z}, "data_contract"),
        "auth_surface" => engine_run_index_group(files, %r{(?:auth|login|signup|middleware|session|supabase|clerk|nextauth|oauth)}i, "auth"),
        "env_surface" => {
          "content_read" => false,
          "policy" => "names_only_no_env_values",
          "files" => Dir.glob(File.join(root, ".env*")).select { |path| File.file?(path) }.map { |path| relative(path) }.sort
        },
        "package_scripts" => package_scripts,
        "test_commands" => package_scripts.select { |name, _command| name.match?(/\b(?:test|check|lint|type|build|preview|dev)\b/i) },
        "authz_context" => {
          "local_project_scope" => true,
          "saas_claims_required_before_remote_exposure" => %w[tenant_id project_id user_id]
        }
      }
    end

    def engine_run_package_scripts(files)
      return {} unless files.key?("package.json")

      parsed = JSON.parse(File.read(File.join(root, "package.json"), 128 * 1024))
      parsed.fetch("scripts", {}).to_h.transform_values(&:to_s).sort.to_h
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def engine_run_index_group(files, pattern, kind)
      items = files.keys.grep(pattern).sort.first(200).map do |path|
        engine_run_index_item(path, files.fetch(path), kind)
      end
      { "status" => items.empty? ? "empty" : "ready", "items" => items }
    end

    def engine_run_component_index(files)
      declared = engine_run_component_map_targets
      discovered = engine_run_index_group(files, %r{\A(?:src/)?components/.+\.(?:astro|js|jsx|ts|tsx|vue|svelte)\z}, "component").fetch("items")
      {
        "status" => (declared.empty? && discovered.empty?) ? "empty" : "ready",
        "declared" => declared,
        "items" => (discovered + declared.filter_map do |target|
          path = target["source_path"].to_s
          next if path.empty? || !files.key?(path)

          engine_run_index_item(path, files.fetch(path), "component").merge("data_aiweb_id" => target["data_aiweb_id"])
        end).uniq { |entry| [entry["path"], entry["data_aiweb_id"]] }.first(200)
      }
    end

    def engine_run_component_map_targets
      path = File.join(root, ".ai-web", "component-map.json")
      parsed = File.file?(path) ? JSON.parse(File.read(path, 256 * 1024)) : {}
      Array(parsed["components"]).filter_map do |component|
        next unless component.is_a?(Hash)

        source_path = component["source_path"].to_s
        next if source_path.empty?

        {
          "data_aiweb_id" => component["data_aiweb_id"].to_s,
          "source_path" => source_path,
          "editable" => component["editable"] == true
        }
      end
    rescue JSON::ParserError, SystemCallError
      []
    end

    def engine_run_index_item(path, metadata, kind)
      digest = metadata["sha256"].to_s
      digest = "sha256:#{digest}" unless digest.empty? || digest.start_with?("sha256:")
      {
        "path" => path,
        "kind" => kind,
        "sha256" => digest,
        "bytes" => metadata["bytes"]
      }.compact
    end

    def engine_run_write_workspace_project_index(workspace_dir, project_index)
      path = File.join(workspace_dir, "_aiweb", "project-index.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(project_index))
      path
    end

    def engine_run_memory_index(run_id:, goal:, project_index:, opendesign_contract:, paths:)
      route_records = Array(project_index.dig("routes", "items")).first(20).map do |item|
        engine_run_memory_record("route", item["path"], item.slice("path", "kind", "source_path"))
      end
      component_records = Array(project_index.dig("components", "items")).first(40).map do |item|
        engine_run_memory_record("component", item["path"], item.slice("path", "data_aiweb_id", "source_path", "editable"))
      end
      script_records = project_index.fetch("package_scripts", {}).to_h.first(20).map do |name, command|
        engine_run_memory_record("package_script", name, { "name" => name, "command" => command })
      end
      design_records = [
        engine_run_memory_record(
          "design_contract",
          opendesign_contract.to_h["selected_candidate"] || "opendesign_contract",
          {
            "status" => opendesign_contract.to_h["status"],
            "selected_candidate" => opendesign_contract.to_h["selected_candidate"],
            "contract_hash" => opendesign_contract.to_h["contract_hash"],
            "selected_candidate_sha256" => opendesign_contract.to_h["selected_candidate_sha256"]
          }
        )
      ]
      memory_records = (design_records + route_records + component_records + script_records).compact
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "recorded_at" => now,
        "goal" => goal,
        "status" => "ready",
        "retrieval_strategy" => "bounded_lexical_cards",
        "rag_status" => "not_configured",
        "rag_gap" => "No embedding store or LlamaIndex pipeline is configured; this artifact provides deterministic retrieval cards for the current run only.",
        "memory_records" => memory_records,
        "memory_record_count" => memory_records.length,
        "evidence_refs" => {
          "project_index_path" => relative(paths.fetch(:project_index_path)),
          "opendesign_contract_path" => relative(paths.fetch(:opendesign_contract_path)),
          "run_memory_path" => relative(paths.fetch(:run_memory_path))
        },
        "worker_handoff" => {
          "workspace_path" => "_aiweb/run-memory.json",
          "allowed_use" => "read-only retrieval context for the selected worker adapter",
          "must_not_contain" => %w[raw_env secret_values provider_tokens]
        }
      }
    end

    def engine_run_memory_record(kind, key, payload)
      key_text = key.to_s
      return nil if key_text.empty?

      body = payload.to_h.compact
      {
        "id" => "mem-#{Digest::SHA256.hexdigest([kind, key_text, JSON.generate(body)].join("\0"))[0, 16]}",
        "kind" => kind,
        "key" => key_text,
        "summary" => body.map { |field, value| "#{field}=#{value}" }.join("; ")[0, 500],
        "payload" => body
      }
    end

    def engine_run_write_workspace_run_memory(workspace_dir, run_memory)
      path = File.join(workspace_dir, "_aiweb", "run-memory.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(run_memory))
      path
    end

    def engine_run_write_workspace_worker_adapter_contract(workspace_dir, contract)
      path = File.join(workspace_dir, "_aiweb", "worker-adapter-contract.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(contract))
      path
    end

    def engine_run_write_workspace_worker_adapter_registry(workspace_dir, registry)
      path = File.join(workspace_dir, "_aiweb", "worker-adapter-registry.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(registry))
      path
    end

  end
end
