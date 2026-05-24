# frozen_string_literal: true

require_relative "resume_validation/artifact_hashes"

module Aiweb
  module ProjectEngineRun
    private

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
  end
end
