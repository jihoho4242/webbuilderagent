# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_resume_artifact_hash_blockers(context)
      checkpoint = context.fetch(:checkpoint)
      graph = checkpoint["run_graph"]
      hashes = checkpoint["artifact_hashes"]
      unless hashes.is_a?(Hash)
        return graph.is_a?(Hash) ? ["engine-run resume checkpoint is missing artifact hashes"] : []
      end
      if graph.is_a?(Hash) && hashes.empty?
        return ["engine-run resume checkpoint has no artifact hashes to validate"]
      end

      blockers = []
      expected_paths = graph.is_a?(Hash) ? engine_run_resume_artifact_hash_paths(context) : {}
      if graph.is_a?(Hash)
        required = engine_run_resume_required_artifact_hash_paths(context)
        unknown = hashes.keys.map(&:to_s) - expected_paths.keys
        unknown.each { |name| blockers << "engine-run resume checkpoint has unknown artifact hash for #{name}" }
        missing = required.keys.reject { |name| hashes.key?(name) }
        missing.each { |name| blockers << "engine-run resume checkpoint is missing required artifact hash for #{name}" }
        required.each do |name, expected_path|
          artifact = hashes[name]
          next unless artifact.is_a?(Hash)

          path = engine_run_normalize_artifact_hash_path(artifact["path"])
          unless path == expected_path
            blockers << "engine-run resume artifact hash path is invalid for #{name}: #{artifact["path"].to_s.empty? ? "(missing)" : artifact["path"]}"
          end
        end
      end

      hashes.each do |name, artifact|
        if graph.is_a?(Hash) && !expected_paths.key?(name.to_s)
          next
        end
        unless artifact.is_a?(Hash)
          blockers << "engine-run resume artifact hash is malformed for #{name}"
          next
        end
        path = artifact["path"].to_s
        expected = artifact["sha256"].to_s
        expected_bytes = artifact["bytes"]
        if path.empty? || expected.empty? || !expected_bytes.is_a?(Integer)
          blockers << "engine-run resume artifact hash is incomplete for #{name}"
          next
        end
        normalized_path = engine_run_normalize_artifact_hash_path(path)
        unless normalized_path
          blockers << "engine-run resume artifact hash path is invalid for #{name}: #{path}"
          next
        end
        expected_path = expected_paths[name.to_s]
        if graph.is_a?(Hash) && normalized_path != expected_path
          blockers << "engine-run resume artifact hash path is invalid for #{name}: #{path}"
          next
        end
        full = File.expand_path(normalized_path, root)
        unless engine_run_path_within_project_root?(full)
          blockers << "engine-run resume artifact hash path escapes project root for #{name}: #{path}"
          next
        end
        unless File.file?(full)
          blockers << "engine-run resume artifact is missing: #{normalized_path}"
          next
        end
        actual = "sha256:#{Digest::SHA256.file(full).hexdigest}"
        blockers << "engine-run resume artifact hash mismatch for #{normalized_path}" unless actual == expected
        if expected_bytes != File.size(full)
          blockers << "engine-run resume artifact byte size mismatch for #{normalized_path}"
        end
      end
      blockers
    rescue SystemCallError => e
      ["engine-run resume artifact hash validation failed: #{e.message}"]
    end

    def engine_run_resume_required_artifact_hash_paths(context)
      engine_run_resume_artifact_hash_paths(context).slice(
        "staged_manifest",
        "graph_execution_plan",
        "graph_scheduler_state",
        "opendesign_contract",
        "project_index",
        "run_memory",
        "authz_enforcement",
        "worker_adapter_registry",
        "sandbox_preflight"
      )
    end

    def engine_run_resume_artifact_hash_paths(context)
      run_dir = engine_run_normalize_artifact_hash_path(context.fetch(:run_dir))
      raise UserError.new("engine-run resume run directory is invalid", 5) unless run_dir

      artifact_path = lambda do |filename|
        [run_dir, "artifacts", filename].join("/")
      end
      qa_path = lambda do |filename|
        [run_dir, "qa", filename].join("/")
      end
      run_id = context.fetch(:run_id).to_s
      {
        "staged_manifest" => artifact_path.call("staged-manifest.json"),
        "graph_execution_plan" => artifact_path.call("graph-execution-plan.json"),
        "graph_scheduler_state" => artifact_path.call("graph-scheduler-state.json"),
        "opendesign_contract" => artifact_path.call("opendesign-contract.json"),
        "project_index" => artifact_path.call("project-index.json"),
        "run_memory" => artifact_path.call("run-memory.json"),
        "authz_enforcement" => artifact_path.call("authz-enforcement.json"),
        "worker_adapter_registry" => artifact_path.call("worker-adapter-registry.json"),
        "sandbox_preflight" => artifact_path.call("sandbox-preflight.json"),
        "supply_chain_gate" => artifact_path.call("supply-chain-gate.json"),
        "supply_chain_sbom" => artifact_path.call("sbom.json"),
        "supply_chain_audit" => artifact_path.call("package-audit.json"),
        "verification" => qa_path.call("verification.json"),
        "preview" => qa_path.call("preview.json"),
        "browser_evidence" => qa_path.call("screenshots.json"),
        "design_verdict" => qa_path.call("design-verdict.json"),
        "design_fidelity" => qa_path.call("design-fidelity.json"),
        "design_fixture" => qa_path.call("design-fixture.json"),
        "eval_benchmark" => qa_path.call("eval-benchmark.json"),
        "quarantine" => artifact_path.call("quarantine.json"),
        "diff" => [".ai-web", "diffs", "#{run_id}.patch"].join("/")
      }
    end

    def engine_run_normalize_artifact_hash_path(path)
      normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      return nil if normalized.empty?
      return nil if normalized.start_with?("/")
      return nil if normalized.match?(/\A[A-Za-z]:\//)

      parts = normalized.split("/")
      return nil if parts.any? { |part| part.empty? || part == "." || part == ".." }

      normalized
    end

    def engine_run_path_within_project_root?(path)
      expanded = File.expand_path(path)
      root_path = File.expand_path(root)
      comparison_expanded = windows? ? expanded.downcase : expanded
      comparison_root = windows? ? root_path.downcase : root_path
      comparison_expanded == comparison_root || comparison_expanded.start_with?(comparison_root + File::SEPARATOR)
    end
  end
end
