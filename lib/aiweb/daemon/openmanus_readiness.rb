# frozen_string_literal: true

require_relative "../runtime"

module Aiweb
  module OpenManusReadiness
    def openmanus_readiness_payload(check_image:)
      image = ENV.fetch("AIWEB_OPENMANUS_IMAGE", "").to_s.strip
      image = "openmanus:latest" if image.empty?
      providers = %w[docker podman].map { |provider| openmanus_provider_readiness(provider, image, check_image: check_image) }
      ready = providers.find { |provider| provider["status"] == "ready" }
      missing_runtime = providers.all? { |provider| provider["executable_path"].to_s.empty? }
      status = if ready
                 "ready"
               elsif missing_runtime
                 "missing_runtime"
               elsif check_image
                 "missing_image"
               else
                 "unchecked"
               end
      blockers = providers.flat_map { |provider| Array(provider["blocking_issues"]) }.uniq
      blockers = [] if ready
      {
        "schema_version" => 1,
        "status" => status,
        "image" => image,
        "check_image" => check_image,
        "providers" => providers,
        "selected_provider" => ready && ready["provider"],
        "blocking_issues" => blockers,
        "next_action" => openmanus_readiness_next_action(status, image)
      }
    end

    def openmanus_provider_readiness(provider, image, check_image:)
      executable = find_executable(provider)
      unless executable
        return {
          "provider" => provider,
          "status" => "missing_runtime",
          "executable_path" => nil,
          "image" => image,
          "image_present" => false,
          "blocking_issues" => ["#{provider} executable is missing from PATH"]
        }
      end

      unless check_image
        return {
          "provider" => provider,
          "status" => "unchecked",
          "executable_path" => executable,
          "image" => image,
          "image_present" => nil,
          "blocking_issues" => []
        }
      end

      result = container_image_inspect(executable, image)
      if result.status == "timeout"
        {
          "provider" => provider,
          "status" => "unavailable",
          "executable_path" => executable,
          "image" => image,
          "image_present" => false,
          "blocking_issues" => ["#{provider} image preflight timed out"]
        }
      elsif result.success?
        {
          "provider" => provider,
          "status" => "ready",
          "executable_path" => executable,
          "image" => image,
          "image_present" => true,
          "inspect_stdout" => result.stdout.to_s[0, 300],
          "blocking_issues" => []
        }
      else
        {
          "provider" => provider,
          "status" => "missing_image",
          "executable_path" => executable,
          "image" => image,
          "image_present" => false,
          "inspect_stderr" => result.stderr.to_s[0, 300],
          "blocking_issues" => ["#{provider} image is missing locally: #{image}"]
        }
      end
    rescue ArgumentError, SystemCallError => e
      {
        "provider" => provider,
        "status" => "unavailable",
        "executable_path" => executable,
        "image" => image,
        "image_present" => false,
        "blocking_issues" => ["#{provider} image preflight failed: #{e.message}"]
      }
    end

    def container_image_inspect(executable, image)
      Aiweb::Runtime::ProcessRunner.new.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: [executable, "image", "inspect", image],
          cwd: Dir.pwd,
          timeout: 2,
          max_output_bytes: 16_000,
          risk_class: "openmanus_readiness_image_inspect",
          description: "OpenManus local image inspect readiness probe"
        )
      )
    end

    def openmanus_readiness_next_action(status, image)
      case status
      when "ready"
        "start approved OpenManus engine-run jobs with --agent openmanus --sandbox docker|podman"
      when "missing_runtime"
        "install Docker or Podman locally, then prepare the #{image} image"
      when "missing_image"
        "build or pull the local #{image} image before approved OpenManus execution"
      else
        "call GET /api/engine/openmanus-readiness before enabling OpenManus run controls"
      end
    end

    def find_executable(name)
      paths = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      extensions = if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
                     ENV.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";")
                   else
                     [""]
                   end
      paths.each do |dir|
        extensions.each do |ext|
          candidate = File.join(dir, "#{name}#{ext}")
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
      end
      nil
    end
  end
end
