# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "shellwords"

module FakeCodexTooling
  def write_fake_codex_tooling(root, prompt_path: nil, patch_path: nil, marker_path: nil, stdout_text: "fake codex stdout", stderr_text: "fake codex stderr", exit_status: 0)
    bin_dir = File.join(root, "fake-agent-bin")
    FileUtils.mkdir_p(bin_dir)
    script = File.join(bin_dir, "codex-fake.rb")
    File.write(
      script,
      <<~RUBY
        # frozen_string_literal: true

        require "fileutils"

        input = STDIN.read
        prompt_path = #{prompt_path.inspect}
        patch_path = #{patch_path.inspect}
        marker_path = #{marker_path.inspect}

        unless prompt_path.to_s.empty?
          FileUtils.mkdir_p(File.dirname(prompt_path))
          File.write(prompt_path, input)
        end

        if !patch_path.to_s.empty? && File.file?(patch_path)
          File.open(patch_path, "a") { |file| file.write("\\n<!-- patched by fake codex -->\\n") }
        end

        unless marker_path.to_s.empty?
          FileUtils.mkdir_p(File.dirname(marker_path))
          FileUtils.touch(marker_path)
        end

        puts #{stdout_text.inspect}
        warn #{stderr_text.inspect}
        exit #{exit_status.to_i}
      RUBY
    )
    if windows?
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
    else
      wrapper = File.join(bin_dir, "codex")
      File.write(wrapper, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{script.shellescape} \"$@\"\n")
      FileUtils.chmod("+x", wrapper)
    end
    bin_dir
  end

  def write_fake_codex_env_guard_tooling(root)
    bin_dir = File.join(root, "fake-codex-env-guard-bin")
    FileUtils.mkdir_p(bin_dir)
    if windows?
      script = File.join(bin_dir, "codex-env-guard-fake.rb")
      File.write(
        script,
        <<~'RUBY'
          # frozen_string_literal: true
          STDIN.read
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_CODEX_SECRET].include?(key) }
            warn "secret environment leaked to codex"
            exit 81
          end
          path = File.join("src", "components", "Hero.astro")
          File.open(path, "a") { |file| file.write("\n<!-- patched by env guard codex -->\n") } if File.file?(path)
          puts "fake env guard codex stdout"
        RUBY
      )
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
    else
      script = File.join(bin_dir, "codex")
      File.write(
        script,
        <<~'SH'
          #!/bin/sh
          cat >/dev/null
          if env | grep -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY|FAKE_CODEX_SECRET' >/dev/null; then
            echo "secret environment leaked to codex" >&2
            exit 81
          fi
          if [ -f src/components/Hero.astro ]; then
            printf '\n<!-- patched by env guard codex -->\n' >> src/components/Hero.astro
          fi
          echo "fake env guard codex stdout"
        SH
      )
      FileUtils.chmod("+x", script)
    end
    bin_dir
  end

end
