# frozen_string_literal: true

require "digest"
require_relative "run_state/event_log"

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_final_status(result, policy)
      return "cancelled" if result.fetch(:blocking_issues).any? { |issue| issue.to_s.match?(/cancellation requested/i) }
      return "quarantined" if policy["status"].to_s == "quarantined" || policy.fetch("blocking_issues").any? { |issue| issue.to_s.match?(/\Aquarantine:/i) }
      return "failed" unless result.fetch(:success)
      return "blocked" unless policy.fetch("blocking_issues").empty?
      return "waiting_approval" unless policy.fetch("approval_issues").empty?
      return "no_changes" if policy.fetch("safe_changes").empty?

      "passed"
    end

    def engine_run_checkpoint_next_step(status)
      case status
      when "passed", "no_changes" then "review_results"
      when "waiting_approval" then "review_approval_request"
      when "cancelled" then "engine-run --resume"
      when "quarantined" then "manual_quarantine_review"
      else "inspect_events"
      end
    end

    def engine_run_action_taken(status)
      case status
      when "passed" then "ran agentic engine"
      when "no_changes" then "engine run produced no source changes"
      when "waiting_approval" then "engine run waiting for elevated approval"
      when "cancelled" then "engine run cancelled"
      when "quarantined" then "engine run quarantined"
      when "blocked" then "engine run blocked"
      else "engine run failed"
      end
    end

    def engine_run_next_action(metadata)
      case metadata["status"]
      when "passed"
        "review #{metadata["metadata_path"]}, #{metadata["diff_path"]}, and the event timeline"
      when "waiting_approval"
        "review copy_back_policy approval_issues in #{metadata["metadata_path"]}; rerun only after granting the specific elevated capability"
      when "cancelled"
        "review #{metadata["checkpoint_path"]}, run aiweb engine-run --resume #{metadata["run_id"]} --dry-run to obtain the resume approval_hash, then rerun with --approval-hash HASH --approved"
      when "quarantined"
        "review redacted quarantine evidence at #{metadata["quarantine_path"]}; copy-back is blocked until manual release outside engine-run"
      else
        "inspect #{metadata["events_path"]} and #{metadata["metadata_path"]}, then rerun aiweb engine-run --dry-run"
      end
    end

    def engine_run_metadata(**attrs)
      run_id = attrs.fetch(:run_id)
      status = attrs.fetch(:status)
      mode = attrs.fetch(:mode)
      agent = attrs.fetch(:agent)
      sandbox = attrs.fetch(:sandbox)
      approved = attrs.fetch(:approved)
      dry_run = attrs.fetch(:dry_run)
      goal = attrs.fetch(:goal)
      capability = attrs.fetch(:capability)
      approval_hash = attrs.fetch(:approval_hash)
      paths = attrs.fetch(:paths)
      events = attrs.fetch(:events)
      checkpoint = attrs.fetch(:checkpoint)
      blocking_issues = attrs.fetch(:blocking_issues)
      started_at = attrs[:started_at]
      finished_at = attrs[:finished_at]
      exit_code = attrs[:exit_code]
      staged_manifest_path = attrs[:staged_manifest_path]
      diff_path = attrs[:diff_path]
      stdout_log = attrs[:stdout_log]
      stderr_log = attrs[:stderr_log]
      verification_path = attrs[:verification_path]
      preview_path = attrs[:preview_path]
      screenshot_evidence_path = attrs[:screenshot_evidence_path]
      design_verdict_path = attrs[:design_verdict_path]
      design_fidelity_path = attrs[:design_fidelity_path]
      design_fixture_path = attrs[:design_fixture_path]
      eval_benchmark_path = attrs[:eval_benchmark_path]
      supply_chain_gate_path = attrs[:supply_chain_gate_path]
      opendesign_contract_path = attrs[:opendesign_contract_path]
      project_index_path = attrs[:project_index_path]
      run_memory_path = attrs[:run_memory_path]
      authz_enforcement_path = attrs[:authz_enforcement_path]
      worker_adapter_registry_path = attrs[:worker_adapter_registry_path]
      graph_execution_plan_path = attrs[:graph_execution_plan_path]
      graph_scheduler_state_path = attrs[:graph_scheduler_state_path]
      sandbox_preflight_path = attrs[:sandbox_preflight_path]
      quarantine_path = attrs[:quarantine_path]
      agent_result_path = attrs[:agent_result_path]
      run_graph = attrs[:run_graph]
      graph_execution_plan = attrs[:graph_execution_plan]
      graph_scheduler_state = attrs[:graph_scheduler_state]
      tool_broker = attrs[:tool_broker]
      sandbox_preflight = attrs[:sandbox_preflight]
      copy_back_policy = attrs[:copy_back_policy]
      verification = attrs[:verification]
      preview = attrs[:preview]
      screenshot_evidence = attrs[:screenshot_evidence]
      design_verdict = attrs[:design_verdict]
      design_fidelity = attrs[:design_fidelity]
      design_fixture = attrs[:design_fixture]
      eval_benchmark = attrs[:eval_benchmark]
      supply_chain_gate = attrs[:supply_chain_gate]
      quarantine = attrs[:quarantine]
      opendesign_contract = attrs[:opendesign_contract]
      project_index = attrs[:project_index]
      run_memory = attrs[:run_memory]
      authz_enforcement = attrs[:authz_enforcement]
      worker_adapter_registry = attrs[:worker_adapter_registry]
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "mode" => mode,
        "agent" => agent,
        "sandbox" => sandbox,
        "approved" => approved,
        "dry_run" => dry_run,
        "goal" => goal,
        "capability" => capability,
        "approval_hash" => approval_hash,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "run_dir" => relative(paths.fetch(:run_dir)),
        "metadata_path" => relative(paths.fetch(:metadata_path)),
        "events_path" => relative(paths.fetch(:events_path)),
        "approval_path" => relative(paths.fetch(:approval_path)),
        "checkpoint_path" => relative(paths.fetch(:checkpoint_path)),
        "workspace_path" => relative(paths.fetch(:workspace_dir)),
        "staged_manifest_path" => staged_manifest_path,
        "opendesign_contract_path" => opendesign_contract_path,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "diff_path" => diff_path,
        "worker_adapter_contract_path" => relative(paths.fetch(:worker_adapter_contract_path)),
        "authz_enforcement_path" => authz_enforcement_path,
        "worker_adapter_registry_path" => worker_adapter_registry_path,
        "graph_execution_plan_path" => graph_execution_plan_path,
        "graph_scheduler_state_path" => graph_scheduler_state_path,
        "agent_result_path" => agent_result_path,
        "verification_path" => verification_path,
        "preview_path" => preview_path,
        "screenshot_evidence_path" => screenshot_evidence_path,
        "design_verdict_path" => design_verdict_path,
        "design_fidelity_path" => design_fidelity_path,
        "design_fixture_path" => design_fixture_path,
        "eval_benchmark_path" => eval_benchmark_path,
        "supply_chain_gate_path" => supply_chain_gate_path,
        "sandbox_preflight_path" => sandbox_preflight_path,
        "project_index_path" => project_index_path,
        "quarantine_path" => quarantine_path,
        "events" => events,
        "checkpoint" => checkpoint,
        "run_graph" => run_graph,
        "graph_execution_plan" => graph_execution_plan,
        "graph_scheduler_state" => graph_scheduler_state,
        "tool_broker" => tool_broker,
        "authz_contract" => engine_run_authz_contract,
        "retention_redaction_policy" => engine_run_retention_redaction_policy,
        "sandbox_preflight" => sandbox_preflight,
        "project_index" => project_index,
        "run_memory_path" => run_memory_path,
        "run_memory" => run_memory,
        "authz_enforcement" => authz_enforcement,
        "worker_adapter_registry" => worker_adapter_registry,
        "opendesign_contract" => opendesign_contract,
        "copy_back_policy" => copy_back_policy,
        "verification" => verification,
        "preview" => preview,
        "screenshot_evidence" => screenshot_evidence,
        "design_verdict" => design_verdict,
        "design_fidelity" => design_fidelity,
        "design_fixture" => design_fixture,
        "eval_benchmark" => eval_benchmark,
        "supply_chain_gate" => supply_chain_gate,
        "quarantine" => quarantine,
        "blocking_issues" => blocking_issues,
        "guardrails" => [
          "host project is not writable by the agent process",
          "sandbox workspace is staged with .env, credentials, provider auth, and generated bulk directories excluded",
          "network/install/deploy/provider CLI/git push require elevated approval",
          "copy-back requires denylist, secret, binary, and writable-envelope validation",
          "web Workbench is not required for engine-run"
        ]
      }.compact
    end

    def engine_run_payload(state:, metadata:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["engine_run"] = metadata
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["blocking_issues"] = (payload["blocking_issues"] + Array(metadata["blocking_issues"])).uniq
      payload["next_action"] = next_action
      payload
    end

    def engine_run_job_record(run_id:, status:, started_at:, finished_at:, events_path:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "kind" => "engine-run",
        "status" => status,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "events_path" => relative(events_path),
        "updated_at" => now
      }
    end

    def engine_run_command_descriptor(agent, mode, sandbox, max_cycles, resume = nil)
      command = ["aiweb", "engine-run", "--agent", agent, "--mode", mode, "--max-cycles", max_cycles.to_s]
      command.concat(["--sandbox", sandbox]) if engine_run_container_worker_agent?(agent) && !sandbox.to_s.empty?
      command.concat(["--resume", resume]) unless resume.to_s.strip.empty?
      command << "--approved"
      command
    end

    def engine_run_sandbox_suffix(agent, sandbox)
      engine_run_container_worker_agent?(agent) && !sandbox.to_s.empty? ? " --sandbox #{sandbox}" : ""
    end

    def engine_run_resume_checkpoint(run_id)
      safe = validate_run_id!(run_id)
      path = File.join(run_lifecycle_run_dir(safe), "checkpoint.json")
      read_json_file(path)
    rescue UserError
      nil
    end

    def engine_run_resume_context(run_id)
      return nil if run_id.to_s.strip.empty?

      safe = validate_run_id!(run_id)
      run_dir = run_lifecycle_run_dir(safe)
      checkpoint_path = File.join(run_dir, "checkpoint.json")
      checkpoint = read_json_file(checkpoint_path)
      return nil unless checkpoint

      metadata = read_json_file(File.join(run_dir, "engine-run.json")) || {}
      manifest_path = File.join(".ai-web", "runs", safe, "artifacts", "staged-manifest.json")
      metadata_manifest_path = metadata["staged_manifest_path"].to_s
      manifest_path = metadata_manifest_path if checkpoint["run_graph"].nil? && !metadata_manifest_path.empty?
      manifest_abs = File.expand_path(manifest_path, root)
      manifest = read_json_file(manifest_abs)
      workspace_rel = checkpoint["workspace_path"].to_s.empty? ? metadata["workspace_path"].to_s : checkpoint["workspace_path"].to_s
      workspace_dir = File.expand_path(workspace_rel, root)
      {
        run_id: safe,
        run_dir: relative(run_dir),
        checkpoint_path: relative(checkpoint_path),
        checkpoint: checkpoint,
        metadata: metadata,
        manifest_path: relative(manifest_abs),
        manifest: manifest,
        workspace_dir: workspace_dir
      }
    rescue UserError
      nil
    end

    def engine_run_resume_blockers(context)
      blockers = []
      workspace_dir = context.fetch(:workspace_dir)
      unless workspace_dir.start_with?(File.expand_path(root) + File::SEPARATOR)
        blockers << "engine-run resume workspace is outside the project root"
      end
      blockers << "engine-run resume workspace is missing: #{relative(workspace_dir)}" unless Dir.exist?(workspace_dir)
      blockers << "engine-run resume staged manifest is missing or unreadable: #{context.fetch(:manifest_path)}" unless context[:manifest].is_a?(Hash)
      blockers.concat(engine_run_resume_artifact_hash_blockers(context))
      blockers.concat(engine_run_resume_graph_artifact_binding_blockers(context))
      blockers.concat(engine_run_resume_graph_cursor_blockers(context))
      blockers
    end

    def engine_run_resume_graph_artifact_binding_blockers(context)
      checkpoint = context.fetch(:checkpoint)
      graph = checkpoint["run_graph"]
      cursor = checkpoint["run_graph_cursor"]
      hashes = checkpoint["artifact_hashes"]
      return [] unless graph.is_a?(Hash) && cursor.is_a?(Hash) && hashes.is_a?(Hash)

      expected_paths = engine_run_resume_artifact_hash_paths(context)
      plan_path = expected_paths["graph_execution_plan"]
      state_path = expected_paths["graph_scheduler_state"]
      plan = read_json_file(File.expand_path(plan_path, root))
      scheduler_state = read_json_file(File.expand_path(state_path, root))
      blockers = []
      blockers << "engine-run resume hashed graph execution plan is missing or unreadable" unless plan.is_a?(Hash)
      blockers << "engine-run resume hashed graph scheduler state is missing or unreadable" unless scheduler_state.is_a?(Hash)
      return blockers unless plan.is_a?(Hash) && scheduler_state.is_a?(Hash)

      checkpoint_run_id = checkpoint["run_id"].to_s
      blockers << "engine-run resume graph execution plan run_id does not match checkpoint" unless plan["run_id"].to_s == checkpoint_run_id
      blockers << "engine-run resume graph scheduler state run_id does not match checkpoint" unless scheduler_state["run_id"].to_s == checkpoint_run_id
      unless scheduler_state["graph_execution_plan_ref"].to_s == plan_path
        blockers << "engine-run resume graph scheduler state does not reference the hashed graph execution plan"
      end
      unless scheduler_state["cursor"] == cursor
        blockers << "engine-run resume checkpoint graph cursor does not match hashed graph scheduler state cursor"
      end

      executor = graph["executor_contract"].to_h
      node_order = Array(executor["node_order"]).map(&:to_s)
      unless Array(plan["node_order"]).map(&:to_s) == node_order
        blockers << "engine-run resume graph execution plan node order does not match checkpoint graph"
      end
      unless plan["executor_type"].to_s == executor["executor_type"].to_s
        blockers << "engine-run resume graph execution plan executor type does not match checkpoint graph"
      end
      derived_from_checkpoint = Aiweb::GraphSchedulerRuntime.start_node(node_order, cursor)
      derived_from_scheduler_state = Aiweb::GraphSchedulerRuntime.start_node(Array(scheduler_state["node_order"]).map(&:to_s), scheduler_state["cursor"])
      unless derived_from_checkpoint == derived_from_scheduler_state
        blockers << "engine-run resume start node derivation does not match hashed graph scheduler state"
      end

      graph_nodes = Array(graph["nodes"]).select { |node| node.is_a?(Hash) }
      scheduler_nodes_by_id = Array(scheduler_state["nodes"]).select { |node| node.is_a?(Hash) }.to_h { |node| [node["node_id"].to_s, node] }
      invocations_by_id = Array(plan["node_invocations"]).select { |node| node.is_a?(Hash) }.to_h { |node| [node["node_id"].to_s, node] }
      graph_nodes.each do |node|
        node_id = node["node_id"].to_s
        scheduler_node = scheduler_nodes_by_id[node_id]
        invocation = invocations_by_id[node_id]
        unless scheduler_node
          blockers << "engine-run resume hashed graph scheduler state is missing node #{node_id}"
          next
        end
        unless invocation
          blockers << "engine-run resume hashed graph execution plan is missing node #{node_id}"
          next
        end
        if scheduler_node["state"].to_s != node["state"].to_s || scheduler_node["attempt"].to_i != node["attempt"].to_i
          blockers << "engine-run resume checkpoint graph node #{node_id} does not match hashed graph scheduler state"
        end
        if invocation["handler"].to_s != node.dig("executor", "handler").to_s ||
           invocation["side_effect_boundary"].to_s != node["side_effect_boundary"].to_s ||
           invocation["tool_broker_required"] != (node.dig("executor", "tool_broker_required") == true)
          blockers << "engine-run resume checkpoint graph node #{node_id} does not match hashed graph execution plan"
        end
      end
      blockers.uniq
    rescue SystemCallError, JSON::ParserError => e
      ["engine-run resume graph artifact binding validation failed: #{e.message}"]
    end

    def engine_run_resume_graph_cursor_blockers(context)
      checkpoint = context.fetch(:checkpoint)
      graph = checkpoint["run_graph"]
      cursor = checkpoint["run_graph_cursor"]
      blockers = []
      blockers << "engine-run resume checkpoint is missing run graph" unless graph.is_a?(Hash)
      blockers << "engine-run resume checkpoint is missing run graph cursor" unless cursor.is_a?(Hash)
      return blockers unless graph.is_a?(Hash) && cursor.is_a?(Hash)

      if !graph["run_id"].to_s.empty? && graph["run_id"].to_s != checkpoint["run_id"].to_s
        blockers << "engine-run resume run graph run_id does not match checkpoint"
      end

      node_id = cursor["node_id"].to_s
      cursor_state = cursor["state"].to_s
      cursor_attempt = cursor["attempt"]
      nodes = Array(graph["nodes"])
      node = nodes.find { |candidate| candidate.is_a?(Hash) && candidate["node_id"].to_s == node_id }
      blockers << "engine-run resume graph cursor points at unknown node: #{node_id.empty? ? "(missing)" : node_id}" unless node
      return blockers unless node

      node_state = node["state"].to_s
      blockers << "engine-run resume graph cursor has invalid state: #{cursor_state.empty? ? "(missing)" : cursor_state}" unless %w[pending running passed failed skipped blocked waiting_approval quarantined no_changes].include?(cursor_state)
      unless engine_run_resume_graph_cursor_state_compatible?(cursor_state, node_state)
        blockers << "engine-run resume graph cursor state #{cursor_state} does not match node #{node_id} state #{node_state}"
      end
      unless cursor_attempt.is_a?(Integer) && cursor_attempt >= 0
        blockers << "engine-run resume graph cursor attempt is invalid"
      end
      if cursor_attempt.is_a?(Integer) && node["attempt"].is_a?(Integer) && cursor_attempt < node["attempt"]
        blockers << "engine-run resume graph cursor attempt is behind node attempt"
      end
      blockers.concat(engine_run_resume_graph_executor_blockers(graph, nodes))
      blockers
    end

    def engine_run_resume_graph_executor_blockers(graph, nodes)
      blockers = []
      executor = graph["executor_contract"]
      blockers << "engine-run resume checkpoint is missing run graph executor contract" unless executor.is_a?(Hash)
      return blockers unless executor.is_a?(Hash)

      blockers << "engine-run resume graph executor type is invalid" unless executor["executor_type"].to_s == "sequential_durable_node_executor"
      node_ids = nodes.map { |candidate| candidate.is_a?(Hash) ? candidate["node_id"].to_s : "" }.reject(&:empty?)
      unless Array(executor["node_order"]).map(&:to_s) == node_ids
        blockers << "engine-run resume graph executor node order does not match graph nodes"
      end

      nodes.each do |node|
        next unless node.is_a?(Hash)

        node_id = node["node_id"].to_s
        node_executor = node["executor"]
        node_replay = node["replay_policy"]
        unless node_executor.is_a?(Hash)
          blockers << "engine-run resume graph node #{node_id} is missing executor"
          next
        end
        blockers << "engine-run resume graph node #{node_id} executor id is invalid" unless node_executor["executor_id"].to_s == "engine_run.#{node_id}"
        blockers << "engine-run resume graph node #{node_id} handler is missing" if node_executor["handler"].to_s.strip.empty?
        blockers << "engine-run resume graph node #{node_id} executor boundary mismatch" unless node_executor["side_effect_boundary"].to_s == node["side_effect_boundary"].to_s
        boundary_requires_broker = node["side_effect_boundary"].to_s != "none"
        if boundary_requires_broker && node_executor["tool_broker_required"] != true
          blockers << "engine-run resume graph node #{node_id} side effect is not gated by tool broker"
        end
        blockers << "engine-run resume graph node #{node_id} is missing replay policy" unless node_replay.is_a?(Hash)
        if node_replay.is_a?(Hash) && node_replay["requires_artifact_hash_validation"] != true
          blockers << "engine-run resume graph node #{node_id} replay policy does not require artifact hash validation"
        end
      end

      blockers
    end

    def engine_run_resume_graph_cursor_state_compatible?(cursor_state, node_state)
      return true if cursor_state == node_state
      return true if cursor_state == "blocked" && %w[failed blocked].include?(node_state)
      return true if cursor_state == "quarantined" && node_state == "blocked"
      return true if cursor_state == "no_changes" && node_state == "passed"

      false
    end

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
