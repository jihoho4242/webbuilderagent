# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "shellwords"

module FakeAiwebCliRuntimeTooling
  def write_fake_engine_codex_tooling(root, patch_path: "src/components/Hero.astro", secret_path: nil, patch_text: "<!-- patched by fake engine codex -->", stdout_text: "fake engine codex stdout", exit_status: 0)
    bin_dir = File.join(root, "fake-engine-bin")
    FileUtils.mkdir_p(bin_dir)
    if windows?
      script = File.join(bin_dir, "codex-engine-fake.rb")
      File.write(
        script,
        <<~RUBY
          # frozen_string_literal: true
          STDIN.read
          path = #{patch_path.inspect}
          if path && !path.empty? && File.file?(path)
            File.open(path, "a") { |file| file.write("\\n" + #{patch_text.inspect} + "\\n") }
          end
          secret_path = #{secret_path.inspect}
          File.write(secret_path, "SECRET=engine-run-created-env\\n") if secret_path && !secret_path.empty?
          puts #{stdout_text.inspect}
          warn "fake engine codex stderr"
          exit #{exit_status.to_i}
        RUBY
      )
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
    else
      script = File.join(bin_dir, "codex")
      File.write(
        script,
        <<~SH
          #!/bin/sh
          cat >/dev/null
          if [ -n #{patch_path.shellescape} ] && [ -f #{patch_path.shellescape} ]; then
            printf '\\n%s\\n' #{patch_text.shellescape} >> #{patch_path.shellescape}
          fi
          if [ -n #{secret_path.to_s.shellescape} ]; then
            printf 'SECRET=engine-run-created-env\\n' > #{secret_path.to_s.shellescape}
          fi
          echo #{stdout_text.shellescape}
          echo "fake engine codex stderr" >&2
          exit #{exit_status.to_i}
        SH
      )
      FileUtils.chmod("+x", script)
    end
    bin_dir
  end

  def write_fake_engine_repair_tooling(root)
    bin_dir = File.join(root, "fake-engine-repair-bin")
    FileUtils.mkdir_p(bin_dir)
    if windows?
      codex_script = File.join(bin_dir, "codex-repair-fake.rb")
      File.write(
        codex_script,
        <<~'RUBY'
          # frozen_string_literal: true
          STDIN.read
          marker = File.file?(File.join("_aiweb", "repair-observation.json")) ? "<!-- fixed after qa -->" : "<!-- needs repair -->"
          File.open(File.join("src", "components", "Hero.astro"), "a") { |file| file.write("\n#{marker}\n") }
          puts "fake repair codex stdout"
        RUBY
      )
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{codex_script}\" %*\r\n")
      npm_script = File.join(bin_dir, "npm-repair-fake.rb")
      File.write(
        npm_script,
        <<~'RUBY'
          # frozen_string_literal: true
          unless ARGV == ["run", "build"]
            warn "unexpected npm command: #{ARGV.join(" ")}"
            exit 64
          end
          body = File.file?(File.join("src", "components", "Hero.astro")) ? File.read(File.join("src", "components", "Hero.astro")) : ""
          if body.include?("fixed after qa")
            puts "fake build passed"
            exit 0
          end
          warn "fake build failed"
          exit 7
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      codex_script = File.join(bin_dir, "codex")
      File.write(
        codex_script,
        <<~'SH'
          #!/bin/sh
          cat >/dev/null
          if [ -f _aiweb/repair-observation.json ]; then
            printf '\n<!-- fixed after qa -->\n' >> src/components/Hero.astro
          else
            printf '\n<!-- needs repair -->\n' >> src/components/Hero.astro
          fi
          echo "fake repair codex stdout"
        SH
      )
      FileUtils.chmod("+x", codex_script)
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~'SH'
          #!/bin/sh
          if [ "$1 $2" != "run build" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          if grep -q "fixed after qa" src/components/Hero.astro; then
            echo "fake build passed"
            exit 0
          fi
          echo "fake build failed" >&2
          exit 7
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    bin_dir
  end

  def write_fake_engine_verification_guard_tooling(root)
    bin_dir = write_fake_engine_codex_tooling(root)
    if windows?
      npm_script = File.join(bin_dir, "npm-guard-fake.rb")
      File.write(
        npm_script,
        <<~'RUBY'
          # frozen_string_literal: true
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_ENGINE_SECRET].include?(key) }
            warn "secret environment leaked to verification"
            exit 81
          end
          unless ARGV == ["run", "build"]
            warn "unexpected npm command: #{ARGV.join(" ")}"
            exit 64
          end
          puts "fake clean verification"
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~'SH'
          #!/bin/sh
          if env | grep -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY|FAKE_ENGINE_SECRET' >/dev/null; then
            echo "secret environment leaked to verification" >&2
            exit 81
          fi
          if [ "$1 $2" != "run build" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          echo "fake clean verification"
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    bin_dir
  end

  def write_fake_engine_openmanus_repair_tooling(root, agent_result_payload_after_repair: nil)
    bin_dir = write_fake_openmanus_tooling(root, repair_mode: true, agent_result_payload_after_repair: agent_result_payload_after_repair)
    if windows?
      npm_script = File.join(bin_dir, "npm-repair-fake.rb")
      File.write(
        npm_script,
        <<~'RUBY'
          # frozen_string_literal: true
          unless ARGV == ["run", "build"]
            warn "unexpected npm command: #{ARGV.join(" ")}"
            exit 64
          end
          body = File.file?(File.join("src", "components", "Hero.astro")) ? File.read(File.join("src", "components", "Hero.astro")) : ""
          if body.include?("fixed after qa")
            puts "fake build passed"
            exit 0
          end
          warn "fake build failed"
          exit 7
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~'SH'
          #!/bin/sh
          if [ "$1 $2" != "run build" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          if grep -q "fixed after qa" src/components/Hero.astro; then
            echo "fake build passed"
            exit 0
          fi
          echo "fake build failed" >&2
          exit 7
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    bin_dir
  end

  def write_fake_engine_openmanus_verification_guard_tooling(root)
    bin_dir = write_fake_openmanus_tooling(root)
    if windows?
      npm_script = File.join(bin_dir, "npm-guard-fake.rb")
      File.write(
        npm_script,
        <<~'RUBY'
          # frozen_string_literal: true
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_ENGINE_SECRET].include?(key) }
            warn "secret environment leaked to verification"
            exit 81
          end
          unless ARGV == ["run", "build"]
            warn "unexpected npm command: #{ARGV.join(" ")}"
            exit 64
          end
          puts "fake clean verification"
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~'SH'
          #!/bin/sh
          if env | grep -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY|FAKE_ENGINE_SECRET' >/dev/null; then
            echo "secret environment leaked to verification" >&2
            exit 81
          fi
          if [ "$1 $2" != "run build" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          echo "fake clean verification"
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    bin_dir
  end

  def write_fake_engine_openmanus_preview_tooling(root, preview_exit_status: 0, **fake_options)
    bin_dir = write_fake_openmanus_tooling(root, **fake_options)
    if windows?
      npm_script = File.join(bin_dir, "npm-preview-fake.rb")
      File.write(
        npm_script,
        <<~RUBY
          # frozen_string_literal: true
          unless ARGV == ["run", "dev"]
            warn "unexpected npm command: \#{ARGV.join(" ")}"
            exit 64
          end
          if #{preview_exit_status.to_i} != 0
            warn "fake preview failed"
            exit #{preview_exit_status.to_i}
          end
          puts "Local: http://127.0.0.1:4321/"
          exit 0
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~SH
          #!/bin/sh
          if [ "$1 $2" != "run dev" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          if [ #{preview_exit_status.to_i} -ne 0 ]; then
            echo "fake preview failed" >&2
            exit #{preview_exit_status.to_i}
          fi
          echo "Local: http://127.0.0.1:4321/"
          exit 0
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    write_fake_engine_browser_observe_tooling(bin_dir)
    bin_dir
  end

  def write_fake_engine_browser_observe_tooling(bin_dir)
    script = File.join(bin_dir, "node-browser-observe-fake.rb")
    File.write(
      script,
      <<~'RUBY'
        # frozen_string_literal: true

        require "fileutils"
        require "json"
        require "zlib"

        def png_chunk(type, data)
          [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
        end

        def write_fake_png(path, width, height)
          width = width.to_i
          height = height.to_i
          row = "\x00".b + ("\xF4\xF4\xF4".b * width)
          raw = row * height
          png = "\x89PNG\r\n\x1A\n".b +
            png_chunk("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")) +
            png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
            png_chunk("IEND", "".b)
          File.binwrite(path, png)
        end

        unless ARGV[0].to_s.tr("\\", "/") == "_aiweb/browser-observe.js"
          warn "unexpected node command: #{ARGV.join(" ")}"
          exit 64
        end

        url, viewport, width, height, screenshot_path, evidence_path = ARGV[1, 6]
        FileUtils.mkdir_p(File.dirname(screenshot_path))
        FileUtils.mkdir_p(File.dirname(evidence_path))
        if ENV["BROWSER_OBSERVE_FAKE_STATUS"] == "failed" || File.file?(File.join(".ai-web", "fail-browser-observe"))
          File.write(evidence_path, JSON.pretty_generate(
            "schema_version" => 1,
            "status" => "failed",
            "viewport" => viewport,
            "width" => width.to_i,
            "height" => height.to_i,
            "url" => url,
            "blocking_issues" => ["fake browser observation failed"]
          ))
          warn "fake browser observe failure"
          exit 1
        end
        if ENV["BROWSER_OBSERVE_FAKE_INVALID_PNG"] == "1" || File.file?(File.join(".ai-web", "fake-browser-invalid-png"))
          File.write(screenshot_path, "fake browser screenshot for #{viewport} #{url}\n")
        else
          write_fake_png(screenshot_path, width, height)
        end
        console_errors = if ENV["BROWSER_OBSERVE_FAKE_CONSOLE_ERROR"] == "1" || File.file?(File.join(".ai-web", "fake-browser-console-error"))
          [{ "type" => "error", "text" => "fake console error", "location" => { "url" => url, "lineNumber" => 1, "columnNumber" => 1 } }]
        else
          []
        end
        network_errors = if ENV["BROWSER_OBSERVE_FAKE_NETWORK_ERROR"] == "1" || File.file?(File.join(".ai-web", "fake-browser-network-error"))
          [{ "url" => "#{url}missing.js", "method" => "GET", "resource_type" => "script", "status" => 500 }]
        else
          []
        end
        external_request_blocked = ENV["BROWSER_OBSERVE_FAKE_EXTERNAL_REQUEST_BLOCKED"] == "1" || File.file?(File.join(".ai-web", "fake-browser-external-request-blocked"))
        external_requests_blocked = external_request_blocked ? [
          { "url" => "https://example.test/asset.js", "method" => "GET", "resource_type" => "script", "is_navigation_request" => false, "failure" => "non_local_request_blocked" }
        ] : []
        network_errors.concat(external_requests_blocked)
        action_recovery_failed = ENV["BROWSER_OBSERVE_FAKE_ACTION_RECOVERY_FAIL"] == "1" || File.file?(File.join(".ai-web", "fake-browser-action-recovery-fail"))
        action_recovery_status = (action_recovery_failed || external_request_blocked) ? "failed" : "captured"
        action_recovery_blockers = []
        action_recovery_blockers << "fake action recovery failed" if action_recovery_failed
        action_recovery_blockers << "1 non-local browser request(s) were blocked" if external_request_blocked
        action_recovery = {
          "schema_version" => 1,
          "status" => action_recovery_status,
          "required" => true,
          "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
          "viewport" => viewport,
          "url" => url,
          "actionable_target_count" => 1,
          "actions" => [
            {
              "index" => 0,
              "status" => action_recovery_status,
              "selector" => "[data-aiweb-id=\"component.hero.copy\"]",
              "text_role" => "section",
              "actions" => [
                { "name" => "scroll_into_view", "status" => "passed" },
                { "name" => "hover", "status" => "passed" },
                { "name" => "focus", "status" => "passed" }
              ],
              "recovery" => [{ "name" => "escape", "status" => "passed" }]
            }
          ],
          "recovery_steps" => [{ "action" => "restore_preview_url", "status" => action_recovery_failed ? "failed" : "passed", "from" => url, "to" => url }],
          "external_requests_blocked" => external_requests_blocked,
          "unsafe_navigation_policy_enforced" => true,
          "unsafe_navigation_blocked" => external_request_blocked,
          "blocking_issues" => action_recovery_blockers
        }
        evidence = {
          "schema_version" => 1,
          "status" => "captured",
          "capture_mode" => "playwright_browser",
          "viewport" => viewport,
          "width" => width.to_i,
          "height" => height.to_i,
          "url" => url,
          "screenshot" => {
            "path" => screenshot_path,
            "capture_mode" => "playwright_browser"
          },
          "console_errors" => console_errors,
          "network_errors" => network_errors,
          "dom_snapshot" => {
            "schema_version" => 1,
            "status" => "captured",
            "capture_mode" => "playwright_browser",
            "route" => "/",
            "viewport" => viewport,
            "selectors" => [
              {
                "selector" => "[data-aiweb-id=\"component.hero.copy\"]",
                "data_aiweb_id" => "component.hero.copy",
                "text_role" => "section",
                "computed_styles" => { "font_size" => "16px", "line_height" => "24px" },
                "bounding_box" => { "x" => 0, "y" => 0, "width" => width.to_i, "height" => 120 }
              }
            ],
            "required_fields" => %w[route viewport selector data_aiweb_id text_role computed_styles bounding_box]
          },
          "a11y_report" => {
            "schema_version" => 1,
            "status" => "captured",
            "capture_mode" => "playwright_accessibility_tree",
            "required_checks" => %w[contrast keyboard_focus aria_labels landmarks touch_targets],
            "accessibility_tree_present" => true,
            "findings" => []
          },
          "computed_style_summary" => {
            "schema_version" => 1,
            "status" => "captured",
            "capture_mode" => "playwright_computed_style",
            "required_properties" => %w[font-family font-size font-weight line-height color background-color margin padding gap display grid flex overflow],
            "sampled_count" => 1
          },
          "interaction_states" => %w[default hover focus-visible active disabled loading empty error success].map do |state|
            {
              "state" => state,
              "status" => %w[disabled loading empty error success].include?(state) ? "not_applicable" : "captured",
              "evidence" => state == "default" ? [screenshot_path] : []
            }
          end,
          "keyboard_focus_traversal" => {
            "schema_version" => 1,
            "status" => "captured",
            "required" => true,
            "steps" => [{ "selector" => "[data-aiweb-id=\"component.hero.copy\"]", "text_role" => "section" }]
          },
          "action_recovery" => action_recovery,
          "blocking_issues" => []
        }
        File.write(evidence_path, JSON.pretty_generate(evidence))
        if ENV["BROWSER_OBSERVE_FAKE_EXIT_AFTER_EVIDENCE"] == "1" || File.file?(File.join(".ai-web", "fake-browser-exit-after-evidence"))
          warn "fake browser observe wrote evidence then failed"
          exit 1
        end
        warn "fake browser observe pass"
        exit 0
      RUBY
    )
    FileUtils.chmod("+x", script)
    if windows?
      File.write(File.join(bin_dir, "node.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
    else
      File.write(File.join(bin_dir, "node"), "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{script.shellescape} \"$@\"\n")
      FileUtils.chmod("+x", File.join(bin_dir, "node"))
    end
  end
end
