# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "shellwords"

module FakeRuntimeTooling
  def write_fake_openmanus_tooling(root, exit_status: 0, patch_workspace: true, mutate_root_path: nil, patch_path: File.join("src", "components", "Hero.astro"), patch_text: "<!-- patched by fake openmanus -->", stdout_text: "fake openmanus stdout", secret_path: nil, repair_mode: false, repair_first_text: "<!-- needs repair -->", repair_fixed_text: "<!-- fixed after qa -->", overwrite_workspace: false, include_podman: true, broker_blocked_action: nil, broker_args_text: nil, agent_result_payload: nil, agent_result_payload_after_repair: nil)
    bin_dir = File.join(root, "fake-openmanus-bin")
    FileUtils.mkdir_p(bin_dir)
    docker_script = File.join(bin_dir, "docker-openmanus-fake.rb")
    File.write(
      docker_script,
      <<~RUBY
        # frozen_string_literal: true
        require "fileutils"
        require "json"

        CONTAINER_MAP_PATH = File.join(File.dirname(__FILE__), "fake-runtime-containers.json")

        def option_value(argv, flag)
          index = argv.index(flag)
          return argv[index + 1].to_s if index && index + 1 < argv.length

          prefix = flag + "="
          argv.find { |value| value.start_with?(prefix) }.to_s.delete_prefix(prefix)
        end

        def option_values(argv, flag)
          values = []
          argv.each_with_index do |value, index|
            values << argv[index + 1].to_s if value == flag && index + 1 < argv.length
            values << value.delete_prefix(flag + "=") if value.start_with?(flag + "=")
          end
          values
        end

        def container_env(argv)
          option_values(argv, "-e").each_with_object({}) do |entry, memo|
            key, value = entry.split("=", 2)
            memo[key] = value.nil? ? ENV[key].to_s : value
          end
        end

        def workspace_path(host_workspace, container_path)
          text = container_path.to_s
          return text unless text.start_with?("/workspace/")

          File.join(host_workspace, text.delete_prefix("/workspace/"))
        end

        def read_container_map
          return {} unless File.file?(CONTAINER_MAP_PATH)

          JSON.parse(File.read(CONTAINER_MAP_PATH))
        rescue JSON::ParserError
          {}
        end

        def write_container_map(container_id, host_workspace)
          map = read_container_map
          map[container_id] = host_workspace
          File.write(CONTAINER_MAP_PATH, JSON.pretty_generate(map))
        end

        if ARGV[0] == "image" && ARGV[1] == "inspect"
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_OPENMANUS_SECRET].include?(key) }
            warn "secret environment leaked to docker image inspect"
            exit 82
          end
          if ENV["FAKE_OPENMANUS_IMAGE_MISSING"] == "1" || ARGV[2].to_s.include?("missing")
            warn "fake image missing"
            exit 1
          end
          if File.file?(File.join(Dir.pwd, ".ai-web", "empty-image-inspect"))
            exit 0
          end
          if File.file?(File.join(Dir.pwd, ".ai-web", "malformed-image-inspect"))
            puts "not-json"
            exit 0
          end
          image = ARGV[2].to_s
          image = "openmanus:latest" if image.empty?
          puts [{
            "Id" => "sha256:" + "a" * 64,
            "RepoDigests" => [image.sub(/:.*/, "") + "@sha256:" + "b" * 64],
            "Created" => "2026-05-14T00:00:00Z",
            "Architecture" => "amd64",
            "Os" => "linux"
          }].to_json
          exit 0
        end

        if ARGV[0] == "info"
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_OPENMANUS_SECRET].include?(key) }
            warn "secret environment leaked to docker info"
            exit 82
          end
          puts({
            "ServerVersion" => "fake-docker-26.0",
            "Driver" => "overlay2",
            "CgroupDriver" => "cgroupfs",
            "SecurityOptions" => ["name=seccomp,profile=default", "name=rootless"]
          }.to_json)
          exit 0
        end

        if ARGV[0] == "inspect"
          container_id = ARGV[1].to_s
          unsafe_inspect = ENV["FAKE_OPENMANUS_UNSAFE_INSPECT"] == "1" || File.file?(File.join(Dir.pwd, ".ai-web", "unsafe-runtime-inspect"))
          workspace_source = read_container_map[container_id].to_s
          workspace_source = "fake-wrong-workspace" if File.file?(File.join(Dir.pwd, ".ai-web", "unsafe-runtime-inspect-source"))
          workspace_source = "fake-workspace" if workspace_source.empty?
          puts [{
            "Id" => container_id.empty? ? "fake-runtime-container-missing" : container_id,
            "Name" => "/\#{container_id}",
            "Image" => "sha256:" + "a" * 64,
            "Config" => {
              "User" => option_value(ARGV, "--user").empty? ? "1000:1000" : option_value(ARGV, "--user")
            },
            "HostConfig" => {
              "NetworkMode" => unsafe_inspect ? "bridge" : "none",
              "ReadonlyRootfs" => true,
              "CapDrop" => ["ALL"],
              "SecurityOpt" => ["no-new-privileges"],
              "UsernsMode" => "",
              "PidsLimit" => 512,
              "Memory" => 2147483648,
              "NanoCpus" => 2000000000
            },
            "State" => {
              "Status" => "exited",
              "ExitCode" => 0,
              "OOMKilled" => false
            },
            "AppArmorProfile" => "docker-default",
            "ProcessLabel" => "system_u:system_r:container_t:s0:c1,c2",
            "Mounts" => [
              {
                "Type" => "bind",
                "Source" => workspace_source,
                "Destination" => "/workspace",
                "Mode" => "rw",
                "RW" => true
              }
            ]
          }].to_json
          exit 0
        end

        if ARGV[0] == "rm"
          exit 0
        end

        unless ARGV[0] == "run"
          warn "expected docker run"
          exit 64
        end
        if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_OPENMANUS_SECRET].include?(key) }
          warn "secret environment leaked to docker"
          exit 81
        end
        env = container_env(ARGV)
        unless env["AIWEB_NETWORK_ALLOWED"] == "0"
          warn "network guard missing"
          exit 82
        end
        unless env["AIWEB_MCP_ALLOWED"] == "0"
          warn "mcp guard missing"
          exit 83
        end
        unless env["AIWEB_ENV_ACCESS_ALLOWED"] == "0"
          warn "env guard missing"
          exit 84
        end
        unless option_value(ARGV, "--network") == "none"
          warn "network none missing"
          exit 85
        end
        mount = option_values(ARGV, "-v").find { |value| value.end_with?(":/workspace:rw") }.to_s
        host_workspace = mount.sub(%r{:/workspace:rw\\z}, "")
        if host_workspace.empty? || !Dir.exist?(host_workspace)
          warn "workspace mount missing"
          exit 86
        end
        cidfile = option_value(ARGV, "--cidfile")
        unless cidfile.empty?
          FileUtils.mkdir_p(File.dirname(cidfile))
          fake_container_id = "fake-runtime-container-\#{File.basename(host_workspace)}"
          File.write(cidfile, fake_container_id + "\n")
          write_container_map(fake_container_id, host_workspace)
        end

        STDIN.read
        configured_images = [ENV["AIWEB_OPENMANUS_IMAGE"].to_s, ENV["AIWEB_OPENHANDS_IMAGE"].to_s, ENV["AIWEB_LANGGRAPH_IMAGE"].to_s, ENV["AIWEB_OPENAI_AGENTS_IMAGE"].to_s, "openmanus:latest", "openhands:latest", "langgraph:latest", "openai-agents:latest"].reject(&:empty?)
        image_index = configured_images.filter_map { |image| ARGV.index(image) }.min
        container_command = image_index ? ARGV[(image_index + 1)..] : []
        tool_exit_status = nil
        Dir.chdir(host_workspace) do
          if env["AIWEB_ENGINE_RUN_TOOL"] == "sandbox_preflight_probe"
            if File.file?(File.join(".ai-web", "fail-sandbox-preflight-command"))
              warn "fake sandbox preflight command failed"
              tool_exit_status = 77
            elsif File.file?(File.join(".ai-web", "malformed-sandbox-preflight-probe"))
              puts "not-json"
              tool_exit_status = 0
            else
              probe_status = File.file?(File.join(".ai-web", "fail-sandbox-preflight-probe")) ? "failed" : "passed"
              puts({
                "schema_version" => 1,
                "status" => probe_status,
                "container_id" => probe_status == "passed" ? "fake-container-\#{File.basename(host_workspace)}" : nil,
                "effective_user" => {
                  "uid" => probe_status == "passed" ? 1000 : nil,
                  "gid" => 1000,
                  "name" => "aiweb"
                },
                "cwd" => "/workspace",
                "home" => env["HOME"],
                "env_guards" => {
                  "AIWEB_NETWORK_ALLOWED" => env["AIWEB_NETWORK_ALLOWED"],
                  "AIWEB_MCP_ALLOWED" => env["AIWEB_MCP_ALLOWED"],
                  "AIWEB_ENV_ACCESS_ALLOWED" => env["AIWEB_ENV_ACCESS_ALLOWED"],
                  "AIWEB_ENGINE_RUN_TOOL" => env["AIWEB_ENGINE_RUN_TOOL"]
                },
                "workspace_writable" => true,
                "root_filesystem_write_blocked" => true,
                "security_attestation" => {
                  "status" => probe_status,
                  "source" => "/proc/self/status",
                  "no_new_privs" => "1",
                  "no_new_privs_enabled" => true,
                  "seccomp" => "2",
                  "seccomp_filtering" => true,
                  "seccomp_filters" => "1",
                  "cap_eff" => "0000000000000000",
                  "cap_eff_zero" => true,
                  "cap_prm" => "0000000000000000",
                  "cap_bnd" => "0000000000000000"
                },
                "cgroup" => {
                  "source" => "/proc/self/cgroup",
                  "lines" => ["0::/fake-aiweb"]
                },
                "mountinfo_excerpt" => {
                  "source" => "/proc/self/mountinfo",
                  "lines" => ["1 0 0:1 / /workspace rw - overlay overlay rw"]
                },
                "egress_denial_probe" => {
                  "status" => probe_status,
                  "method" => "fake_inside_container_no_network_probe",
                  "target" => "93.184.216.34:80",
                  "observed" => probe_status == "passed" ? "connection_denied" : "unexpected_connect"
                }
              }.to_json)
              tool_exit_status = 0
            end
          elsif container_command.empty? || %w[openmanus openhands].include?(container_command.first.to_s) || container_command.join(" ").include?("langgraph-worker.py") || container_command.join(" ").include?("openai-agents-worker.py")
            puts #{stdout_text.inspect}
            warn "fake openmanus stderr"
            broker_blocked_action = #{broker_blocked_action.inspect}
            unless broker_blocked_action.to_s.empty?
              event_path = workspace_path(host_workspace, env["AIWEB_TOOL_BROKER_EVENTS_PATH"].to_s)
              FileUtils.mkdir_p(File.dirname(event_path)) unless event_path.empty?
              File.open(event_path, "a") do |file|
                file.puts({
                  "schema_version" => 1,
                  "type" => "tool.blocked",
                  "tool_name" => broker_blocked_action == "package_install" ? "npm" : broker_blocked_action,
                  "risk_class" => broker_blocked_action,
                  "reason" => "fake staged tool broker blocked " + broker_blocked_action,
                  "args_text" => #{broker_args_text.inspect} || (broker_blocked_action == "package_install" ? "install left-pad" : broker_blocked_action)
                }.to_json)
              end
              warn "AIWEB_TOOL_BROKER_BLOCKED " + broker_blocked_action
            end
            if #{patch_workspace ? "true" : "false"}
              path = #{patch_path.inspect}
              marker = if #{repair_mode ? "true" : "false"}
                         File.file?(File.join("_aiweb", "repair-observation.json")) ? #{repair_fixed_text.inspect} : #{repair_first_text.inspect}
                       else
                         #{patch_text.inspect}
                       end
              if File.file?(path)
                if #{overwrite_workspace ? "true" : "false"}
                  File.write(path, marker)
                else
                  File.open(path, "a") { |file| file.write("\\n" + marker + "\\n") }
                end
              end
            end
            secret_path = #{secret_path.inspect}
            File.write(secret_path, "SECRET=engine-run-created-env\\n") if secret_path && !secret_path.empty?
            result_env_path = env["AIWEB_OPENMANUS_RESULT_PATH"].to_s
            result_env_path = env["AIWEB_OPENHANDS_RESULT_PATH"].to_s if result_env_path.empty?
            result_env_path = env["AIWEB_LANGGRAPH_RESULT_PATH"].to_s if result_env_path.empty?
            result_env_path = env["AIWEB_OPENAI_AGENTS_RESULT_PATH"].to_s if result_env_path.empty?
            result_env_path = env["AIWEB_ENGINE_RUN_RESULT_PATH"].to_s if result_env_path.empty?
            result_path = workspace_path(host_workspace, result_env_path)
            FileUtils.mkdir_p(File.dirname(result_path)) unless result_path.empty?
            configured_result = #{agent_result_payload.nil? ? "nil" : JSON.generate(agent_result_payload).inspect}
            configured_result_after_repair = #{agent_result_payload_after_repair.nil? ? "nil" : JSON.generate(agent_result_payload_after_repair).inspect}
            if configured_result_after_repair && File.file?(File.join(host_workspace, "_aiweb", "repair-observation.json"))
              configured_result = configured_result_after_repair
            end
            File.write(result_path, configured_result || "{\\"schema_version\\":1,\\"status\\":\\"patched\\",\\"sandbox_mode\\":\\"docker\\"}\\n") unless result_path.empty?
          else
            system(*container_command)
            tool_exit_status = $?.exitstatus
          end
        end
        exit tool_exit_status if tool_exit_status
        root_mutation_path = #{mutate_root_path.inspect}
        if root_mutation_path && !root_mutation_path.empty?
          File.open(root_mutation_path, "a") { |file| file.write("\\n<!-- root mutation by fake openmanus -->\\n") }
        end
        exit #{exit_status.to_i}
      RUBY
    )
    if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
      File.write(File.join(bin_dir, "docker.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{docker_script}\" %*\r\n")
      File.write(File.join(bin_dir, "podman.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{docker_script}\" %*\r\n") if include_podman
    else
      File.write(File.join(bin_dir, "docker"), "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{docker_script.shellescape} \"$@\"\n")
      FileUtils.chmod("+x", File.join(bin_dir, "docker"))
      if include_podman
        File.write(File.join(bin_dir, "podman"), "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{docker_script.shellescape} \"$@\"\n")
        FileUtils.chmod("+x", File.join(bin_dir, "podman"))
      end
    end

    if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
      script = File.join(bin_dir, "openmanus-fake.rb")
      File.write(
        script,
        <<~RUBY
          # frozen_string_literal: true
          STDIN.read
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_OPENMANUS_SECRET].include?(key) }
            warn "secret environment leaked to openmanus"
            exit 81
          end
          unless ENV["AIWEB_NETWORK_ALLOWED"] == "0"
            warn "network guard missing"
            exit 82
          end
          unless ENV["AIWEB_MCP_ALLOWED"] == "0"
            warn "mcp guard missing"
            exit 83
          end
          unless ENV["AIWEB_ENV_ACCESS_ALLOWED"] == "0"
            warn "env guard missing"
            exit 84
          end
          puts #{stdout_text.inspect}
          warn "fake openmanus stderr"
          if #{patch_workspace ? "true" : "false"}
            path = #{patch_path.inspect}
            marker = if #{repair_mode ? "true" : "false"}
                       File.file?(File.join("_aiweb", "repair-observation.json")) ? #{repair_fixed_text.inspect} : #{repair_first_text.inspect}
                     else
                       #{patch_text.inspect}
                     end
            if File.file?(path)
              if #{overwrite_workspace ? "true" : "false"}
                File.write(path, marker)
              else
                File.open(path, "a") { |file| file.write("\\n" + marker + "\\n") }
              end
            end
          end
          secret_path = #{secret_path.inspect}
          File.write(secret_path, "SECRET=engine-run-created-env\\n") if secret_path && !secret_path.empty?
          root_mutation_path = #{mutate_root_path.inspect}
          if root_mutation_path && !root_mutation_path.empty?
            File.open(root_mutation_path, "a") { |file| file.write("\\n<!-- root mutation by fake openmanus -->\\n") }
          end
          result_path = ENV["AIWEB_OPENMANUS_RESULT_PATH"].to_s
          File.write(result_path, "{\\"schema_version\\":1,\\"status\\":\\"patched\\"}\\n") unless result_path.empty?
          exit #{exit_status.to_i}
        RUBY
      )
      File.write(File.join(bin_dir, "openmanus.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
      return bin_dir
    end

    workspace_patch =
      if patch_workspace
        shell_patch_text = repair_mode ? "" : patch_text.shellescape
        <<~SH
          if [ -f #{patch_path.shellescape} ]; then
            if [ #{repair_mode ? "1" : "0"} -eq 1 ] && [ -f _aiweb/repair-observation.json ]; then
              #{overwrite_workspace ? "printf '%s\\n' #{repair_fixed_text.shellescape} > #{patch_path.shellescape}" : "printf '\\n%s\\n' #{repair_fixed_text.shellescape} >> #{patch_path.shellescape}"}
            elif [ #{repair_mode ? "1" : "0"} -eq 1 ]; then
              #{overwrite_workspace ? "printf '%s\\n' #{repair_first_text.shellescape} > #{patch_path.shellescape}" : "printf '\\n%s\\n' #{repair_first_text.shellescape} >> #{patch_path.shellescape}"}
            else
              #{overwrite_workspace ? "printf '%s\\n' #{shell_patch_text} > #{patch_path.shellescape}" : "printf '\\n%s\\n' #{shell_patch_text} >> #{patch_path.shellescape}"}
            fi
          fi
        SH
      else
        ":"
      end
    root_mutation = mutate_root_path ? "printf '\\n<!-- root mutation by fake openmanus -->\\n' >> #{mutate_root_path.shellescape}" : ":"
    secret_write = secret_path.to_s.empty? ? ":" : "printf 'SECRET=engine-run-created-env\\n' > #{secret_path.to_s.shellescape}"
    write_fake_executable(
      bin_dir,
      "openmanus",
      <<~SH
        cat >/dev/null
        if env | grep -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY|FAKE_OPENMANUS_SECRET' >/dev/null; then
          echo 'secret environment leaked to openmanus' >&2
          exit 81
        fi
        [ "$AIWEB_NETWORK_ALLOWED" = "0" ] || { echo 'network guard missing' >&2; exit 82; }
        [ "$AIWEB_MCP_ALLOWED" = "0" ] || { echo 'mcp guard missing' >&2; exit 83; }
        [ "$AIWEB_ENV_ACCESS_ALLOWED" = "0" ] || { echo 'env guard missing' >&2; exit 84; }
        echo #{stdout_text.shellescape}
        echo 'fake openmanus stderr' >&2
        #{workspace_patch}
        #{secret_write}
        #{root_mutation}
        if [ -n "$AIWEB_OPENMANUS_RESULT_PATH" ]; then
          printf '{"schema_version":1,"status":"patched"}\\n' > "$AIWEB_OPENMANUS_RESULT_PATH"
        fi
        exit #{exit_status.to_i}
      SH
    )
    bin_dir
  end
end
