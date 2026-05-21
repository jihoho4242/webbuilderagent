# frozen_string_literal: true

require "open3"
require "rbconfig"

module Aiweb
  module Runtime
    class ProcessRunner
      def capture(spec)
        stdout = ""
        stderr = ""
        status = nil
        begin
          Open3.popen3(
            EnvPolicy.clean_env(spec.env),
            *spec.argv,
            **spawn_options(spec.cwd)
          ) do |stdin, out, err, wait_thread|
            write_stdin(stdin, spec.stdin_data)
            stdout_thread = Thread.new { out.read.to_s rescue "" }
            stderr_thread = Thread.new { err.read.to_s rescue "" }
            if wait_thread.join(spec.timeout)
              status = wait_thread.value
              stdout = stdout_thread.value
              stderr = stderr_thread.value
            else
              cleanup_process(wait_thread.pid)
              stdout = safe_thread_value(stdout_thread)
              stderr = safe_thread_value(stderr_thread)
              return ToolResult.new(
                status: "timeout",
                stdout: truncate(EnvPolicy.redact(utf8_text(stdout)), spec.max_output_bytes),
                stderr: truncate(EnvPolicy.redact("#{utf8_text(stderr)}\ncommand timed out after #{spec.timeout}s"), spec.max_output_bytes),
                exit_code: nil,
                command: spec.command
              )
            end
          end
          ToolResult.new(
            status: status.success? ? "passed" : "failed",
            stdout: truncate(EnvPolicy.redact(utf8_text(stdout)), spec.max_output_bytes),
            stderr: truncate(EnvPolicy.redact(utf8_text(stderr)), spec.max_output_bytes),
            exit_code: status.exitstatus,
            command: spec.command
          )
        rescue SystemCallError, IOError => e
          ToolResult.new(
            status: "failed",
            stdout: truncate(EnvPolicy.redact(utf8_text(stdout)), spec.max_output_bytes),
            stderr: truncate(EnvPolicy.redact("#{utf8_text(stderr)}\n#{e.class}: #{e.message}"), spec.max_output_bytes),
            exit_code: nil,
            command: spec.command
          )
        end
      end

      private

      def utf8_text(value)
        text = value.to_s
        return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

        text = text.dup
        text = text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY || text.encoding == Encoding::ASCII_8BIT
        text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
      rescue EncodingError
        value.to_s.bytes.map { |byte| byte < 128 ? byte.chr : "�" }.join
      end

      def spawn_options(cwd)
        options = { chdir: cwd, unsetenv_others: true }
        options[:pgroup] = true unless windows?
        options
      end

      def cleanup_process(pid)
        return cleanup_windows_process(pid) if windows?

        Process.kill("TERM", -pid)
        sleep 0.1
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EINVAL
        nil
      end

      def cleanup_windows_process(pid)
        system("taskkill", "/PID", pid.to_s, "/T", "/F", out: File::NULL, err: File::NULL)
      rescue SystemCallError, IOError
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH, Errno::EINVAL
          nil
        end
      end

      def windows?
        RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
      end

      def write_stdin(stdin, data)
        stdin.write(data.to_s) unless data.nil?
      rescue IOError, SystemCallError
        nil
      ensure
        stdin.close unless stdin.closed?
      end

      def safe_thread_value(thread)
        return "" unless thread.join(0.2)

        thread.value.to_s
      rescue StandardError
        ""
      end

      def truncate(value, max)
        text = utf8_text(value)
        text.bytesize > max ? "#{utf8_text(text.byteslice(0, max))}\n[truncated]" : text
      end
    end
  end
end
