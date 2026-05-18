# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "shellwords"

module FakeAiwebCliRuntimeTooling
  def write_fake_verify_loop_tooling(root)
    FileUtils.mkdir_p(File.join(root, "node_modules", ".bin"))
    %w[playwright axe lighthouse].each do |name|
      write_fake_executable(File.join(root, "node_modules", ".bin"), name, "exit 0")
    end

    bin_dir = File.join(root, "fake-verify-loop-bin")
    FileUtils.mkdir_p(bin_dir)
    write_fake_executable(
      bin_dir,
      "pnpm",
      <<~'SH'
        case "$1" in
          build)
            mkdir -p dist
            printf '<h1>fake verify-loop build</h1>\n' > dist/index.html
            echo 'fake verify-loop build pass'
            exit "${BUILD_FAKE_EXIT_STATUS:-0}"
            ;;
          dev)
            echo 'fake verify-loop preview start'
            exit 0
            ;;
          exec)
            tool="$2"
            shift 2
            case "$tool" in
              playwright)
                subcommand="$1"
                if [ "$subcommand" = "test" ]; then
                  if [ "${PLAYWRIGHT_FAKE_STATUS:-passed}" = "failed" ]; then
                    echo '{"status":"failed","suites":[],"stats":{"unexpected":1}}'
                    echo 'fake verify-loop playwright failure' >&2
                    exit 1
                  fi
                  echo '{"status":"passed","suites":[],"stats":{"expected":1}}'
                  echo 'fake verify-loop playwright pass' >&2
                  exit 0
                fi
                if [ "$subcommand" = "screenshot" ]; then
                  wrote=0
                  for arg in "$@"; do
                    case "$arg" in
                      *.png)
                        mkdir -p "$(dirname "$arg")"
                        printf 'fake verify-loop screenshot for %s\n' "$arg" > "$arg"
                        wrote=1
                        ;;
                    esac
                  done
                  if [ "${QA_SCREENSHOT_FAKE_STATUS:-passed}" = "failed" ]; then
                    echo 'fake verify-loop screenshot failure' >&2
                    exit 1
                  fi
                  [ "$wrote" = 1 ] || { echo 'missing screenshot output' >&2; exit 64; }
                  echo 'fake verify-loop screenshot pass' >&2
                  exit 0
                fi
                ;;
              axe|lighthouse)
                status="${AIWEB_STATIC_QA_STATUS:-passed}"
                [ "$tool" = "axe" ] && status="${A11Y_FAKE_STATUS:-$status}"
                [ "$tool" = "lighthouse" ] && status="${LIGHTHOUSE_FAKE_STATUS:-$status}"
                for arg in "$@"; do
                  case "$arg" in
                    --output-path=*)
                      report="${arg#--output-path=}"
                      mkdir -p "$(dirname "$report")"
                      echo "{\"tool\":\"$tool\",\"status\":\"$status\"}" > "$report"
                      ;;
                  esac
                done
                if [ "$status" = "failed" ]; then
                  echo "{\"tool\":\"$tool\",\"status\":\"failed\"}"
                  echo "fake verify-loop $tool failure" >&2
                  exit 1
                fi
                echo "{\"tool\":\"$tool\",\"status\":\"passed\"}"
                echo "fake verify-loop $tool pass" >&2
                exit 0
                ;;
            esac
            ;;
        esac
        echo "unexpected fake verify-loop pnpm command: $*" >&2
        exit 64
      SH
    )
    codex_script = File.join(bin_dir, "codex-fake.rb")
    File.write(
      codex_script,
      <<~RUBY
        # frozen_string_literal: true

        require "fileutils"

        STDIN.read
        patch_path = #{File.join(root, "src/components/Hero.astro").inspect}
        marker_path = #{File.join(root, ".ai-web", "runs", "codex-runs.log").inspect}
        if File.file?(patch_path)
          File.open(patch_path, "a") { |file| file.write("\\n<!-- patched by fake verify-loop codex -->\\n") }
        end
        FileUtils.mkdir_p(File.dirname(marker_path))
        File.open(marker_path, "a") { |file| file.write("run\\n") }
        puts "fake verify-loop codex stdout"
        warn "fake verify-loop codex stderr"
      RUBY
    )
    if windows?
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{codex_script}\" %*\r\n")
    else
      wrapper = File.join(bin_dir, "codex")
      File.write(wrapper, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{codex_script.shellescape} \"$@\"\n")
      FileUtils.chmod("+x", wrapper)
    end
    bin_dir
  end
end
