# frozen_string_literal: true

require "digest"
require "fileutils"
require "find"
require "json"

module Aiweb
  module ProjectEngineRun
    def engine_run_stage_workspace(workspace_dir, events_path:, events:)
      raise UserError.new("engine-run workspace already exists and will not be reused: #{relative(workspace_dir)}", 5) if File.exist?(workspace_dir) || File.symlink?(workspace_dir)

      base_dir = File.dirname(workspace_dir)
      FileUtils.mkdir_p(base_dir)
      Dir.mkdir(workspace_dir)
      manifest = {
        "schema_version" => 1,
        "workspace_root" => relative(workspace_dir),
        "created_at" => now,
        "files" => {},
        "excluded" => []
      }
      engine_run_event(events_path, events, "preflight.started", "staging filtered project workspace")

      Find.find(root) do |path|
        rel = relative(path).tr("\\", "/")
        next if rel.empty? || rel == "."

        if File.directory?(path)
          if engine_run_stage_excluded?(rel)
            manifest["excluded"] << rel
            Find.prune
          end
          next
        end

        if engine_run_stage_excluded?(rel) || engine_run_secret_surface_path?(rel) || File.symlink?(path)
          manifest["excluded"] << rel
          next
        end
        if File.file?(path) && File.lstat(path).nlink.to_i > 1
          manifest["excluded"] << rel
          next
        end
        next unless File.file?(path)

        target = File.join(workspace_dir, rel)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(path, target)
        manifest["files"][rel] = {
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "bytes" => File.size(path)
        }
      end
      engine_run_event(events_path, events, "preflight.finished", "staged filtered project workspace", file_count: manifest.fetch("files").length, excluded_count: manifest.fetch("excluded").length)
      { manifest: manifest }
    rescue SystemCallError => e
      raise UserError.new("engine-run staging failed: #{e.message}", 1)
    end

    def engine_run_prepare_workspace_tool_broker(workspace_dir)
      bin_dir = File.join(workspace_dir, "_aiweb", "tool-broker-bin")
      events_path = engine_run_tool_broker_events_path(workspace_dir)
      FileUtils.mkdir_p(bin_dir)
      FileUtils.mkdir_p(File.dirname(events_path))
      engine_run_tool_broker_blocking_shims.each do |name, config|
        path = File.join(bin_dir, name)
        File.write(path, engine_run_tool_broker_shim_source(name, config))
        FileUtils.chmod("+x", path)
      end
      { bin_dir: bin_dir, events_path: events_path }
    end

    def engine_run_tool_broker_events_path(workspace_dir)
      File.join(workspace_dir, "_aiweb", "tool-broker-events.jsonl")
    end

    def engine_run_tool_broker_blocking_shims
      {
        "npm" => { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" },
        "pnpm" => { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" },
        "yarn" => { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" },
        "bun" => { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" },
        "curl" => { "risk" => "external_network", "mode" => "always_block", "reason" => "External network access requires explicit approval" },
        "wget" => { "risk" => "external_network", "mode" => "always_block", "reason" => "External network access requires explicit approval" },
        "git" => { "risk" => "git_push", "mode" => "git", "reason" => "git push requires explicit approval" },
        "vercel" => { "risk" => "deploy", "mode" => "always_block", "reason" => "Deploy/provider CLI execution requires explicit approval" },
        "netlify" => { "risk" => "deploy", "mode" => "always_block", "reason" => "Deploy/provider CLI execution requires explicit approval" },
        "wrangler" => { "risk" => "deploy", "mode" => "always_block", "reason" => "Deploy/provider CLI execution requires explicit approval" },
        "cloudflare" => { "risk" => "deploy", "mode" => "always_block", "reason" => "Deploy/provider CLI execution requires explicit approval" },
        "env" => { "risk" => "env_read", "mode" => "always_block", "reason" => "Raw environment reads require explicit approval" },
        "printenv" => { "risk" => "env_read", "mode" => "always_block", "reason" => "Raw environment reads require explicit approval" }
      }
    end

    def engine_run_tool_broker_event_count(workspace_dir)
      engine_run_workspace_tool_broker_events(workspace_dir).length
    end

    def engine_run_workspace_tool_broker_events(workspace_dir)
      path = engine_run_tool_broker_events_path(workspace_dir)
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        parsed = JSON.parse(line)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
    end

    def engine_run_emit_workspace_tool_broker_events(workspace_dir, events_path, events, cycle:, offset:)
      engine_run_workspace_tool_broker_events(workspace_dir).drop(offset.to_i).each do |event|
        engine_run_event(events_path, events, "tool.blocked", "tool broker blocked prohibited staged action", event.merge("cycle" => cycle))
      end
    end

    def engine_run_stage_excluded?(relative_path)
      normalized = relative_path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      ENGINE_RUN_STAGE_EXCLUDES.any? do |entry|
        normalized == entry || normalized.start_with?("#{entry}/")
      end
    end

    def engine_run_secret_surface_path?(relative_path)
      secret_surface_path?(relative_path)
    end
  end
end
