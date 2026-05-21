# frozen_string_literal: true

require "digest"
require "rbconfig"
require "shellwords"

module Aiweb
  module ProjectWorkbench
    private

    def workbench_serve_host(host)
      value = host.to_s.strip
      value.empty? ? "127.0.0.1" : value
    end

    def workbench_serve_port(port)
      value = port.to_i
      value.positive? ? value : 17342
    end

    def workbench_serve_allowed_host?(host)
      %w[localhost 127.0.0.1].include?(host.to_s)
    end

    def workbench_serve_command(host, port)
      [RbConfig.ruby, "-run", "-e", "httpd", File.join(root, ".ai-web", "workbench"), "-b", host.to_s, "-p", port.to_i.to_s]
    end

    def workbench_serve_approval_capability(state:, host:, port:, url:, paths:)
      {
        "schema_version" => 1,
        "capability" => "aiweb.workbench.serve.v1",
        "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash,
        "policy_kernel_version" => Aiweb::Tools::DecisionPacket::POLICY_KERNEL_VERSION,
        "risk_class" => "workbench_local_server",
        "host" => host,
        "port" => port,
        "url" => url,
        "local_only" => true,
        "command" => workbench_serve_command(host, port),
        "cwd" => root,
        "state_sha256" => File.file?(state_path) ? Digest::SHA256.file(state_path).hexdigest : nil,
        "workbench_paths" => paths,
        "workbench_artifact_fingerprints" => workbench_artifact_fingerprints(paths),
        "serve_boundary" => {
          "requires_dry_run_review" => true,
          "requires_matching_approval_hash" => true,
          "allowed_hosts" => %w[localhost 127.0.0.1],
          "writes_under" => %w[.ai-web/workbench .ai-web/runs/workbench-serve-*],
          "forbidden" => %w[workbench_control_execution install build preview qa deploy provider_cli external_network env_read state_mutation]
        },
        "state_present" => state.is_a?(Hash)
      }
    end

    def workbench_artifact_fingerprints(paths)
      paths.to_h.transform_values do |relative_path|
        path = File.join(root, relative_path.to_s)
        if File.file?(path)
          {
            "present" => true,
            "bytes" => File.size(path),
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        else
          { "present" => false }
        end
      end
    end

    def workbench_serve_approval_hash(capability)
      Digest::SHA256.hexdigest(JSON.generate(capability))
    end

    def workbench_serve_approval_blockers(approved:, supplied_hash:, expected_hash:)
      return ["workbench --serve requires --approved and --approval-hash HASH for real local serving"] unless approved
      return ["--approval-hash is required for real workbench serve"] if supplied_hash.to_s.empty?
      return ["workbench serve approval hash does not match the current serve capability envelope"] unless supplied_hash == expected_hash

      []
    end

    def workbench_serve_approved_command(approval_hash, host:, port:)
      parts = ["aiweb", "workbench", "--serve", "--host", host.to_s, "--port", port.to_i.to_s, "--approval-hash", approval_hash.to_s, "--approved"]
      Shellwords.join(parts)
    end

    def workbench_serve_metadata(run_id:, status:, host:, port:, url:, command:, pid:, started_at:, finished_at:, stdout_log:, stderr_log:, metadata_path:, workbench_paths:, dry_run:, approved:, approval_hash: nil, supplied_approval_hash: nil, capability: nil, blocking_issues:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "host" => host,
        "port" => port,
        "url" => url,
        "local_only" => true,
        "command" => command,
        "cwd" => root,
        "pid" => pid,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "metadata_path" => metadata_path,
        "workbench_paths" => workbench_paths,
        "dry_run" => dry_run,
        "approved" => approved,
        "approval_hash" => approval_hash,
        "supplied_approval_hash" => supplied_approval_hash,
        "capability" => capability,
        "blocking_issues" => blocking_issues
      }
    end

    def workbench_serve_summary(metadata)
      return nil unless metadata

      metadata.slice("status", "host", "port", "url", "local_only", "pid", "metadata_path", "stdout_log", "stderr_log", "approved", "approval_hash", "supplied_approval_hash", "dry_run", "blocking_issues")
    end

    def running_workbench_serve_metadata
      workbench_serve_metadata_files.reverse_each do |path|
        metadata = read_workbench_serve_metadata(path)
        next unless metadata
        next unless metadata["status"] == "running"
        next unless live_process?(metadata["pid"].to_i)

        metadata["metadata_path"] ||= relative(path)
        return metadata
      end
      nil
    end

    def workbench_serve_metadata_files
      Dir.glob(File.join(aiweb_dir, "runs", "workbench-serve-*", "workbench-serve.json")).sort
    end

    def read_workbench_serve_metadata(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end
end
