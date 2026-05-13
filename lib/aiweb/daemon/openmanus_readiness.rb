# frozen_string_literal: true

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

      stdout, stderr, status = container_image_inspect(provider, image)
      if status&.success?
        {
          "provider" => provider,
          "status" => "ready",
          "executable_path" => executable,
          "image" => image,
          "image_present" => true,
          "inspect_stdout" => stdout.to_s[0, 300],
          "blocking_issues" => []
        }
      else
        {
          "provider" => provider,
          "status" => "missing_image",
          "executable_path" => executable,
          "image" => image,
          "image_present" => false,
          "inspect_stderr" => stderr.to_s[0, 300],
          "blocking_issues" => ["#{provider} image is missing locally: #{image}"]
        }
      end
    rescue Timeout::Error
      {
        "provider" => provider,
        "status" => "unavailable",
        "executable_path" => executable,
        "image" => image,
        "image_present" => false,
        "blocking_issues" => ["#{provider} image preflight timed out"]
      }
    rescue SystemCallError => e
      {
        "provider" => provider,
        "status" => "unavailable",
        "executable_path" => executable,
        "image" => image,
        "image_present" => false,
        "blocking_issues" => ["#{provider} image preflight failed: #{e.message}"]
      }
    end

    def container_image_inspect(provider, image)
      Timeout.timeout(2) do
        Open3.capture3(provider, "image", "inspect", image)
      end
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
