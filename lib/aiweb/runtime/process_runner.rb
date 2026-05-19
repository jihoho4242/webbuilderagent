# frozen_string_literal: true

require "open3"

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
            chdir: spec.cwd,
            unsetenv_others: true
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
                stdout: truncate(EnvPolicy.redact(stdout), spec.max_output_bytes),
                stderr: truncate(EnvPolicy.redact("#{stderr}\ncommand timed out after #{spec.timeout}s"), spec.max_output_bytes),
                exit_code: nil,
                command: spec.command
              )
            end
          end
          ToolResult.new(
            status: status.success? ? "passed" : "failed",
            stdout: truncate(EnvPolicy.redact(stdout), spec.max_output_bytes),
            stderr: truncate(EnvPolicy.redact(stderr), spec.max_output_bytes),
            exit_code: status.exitstatus,
            command: spec.command
          )
        rescue SystemCallError, IOError => e
          ToolResult.new(status: "failed", stdout: truncate(EnvPolicy.redact(stdout), spec.max_output_bytes), stderr: truncate(EnvPolicy.redact("#{stderr}\n#{e.class}: #{e.message}"), spec.max_output_bytes), exit_code: nil, command: spec.command)
        end
      end

      private

      def cleanup_process(pid)
        Process.kill("TERM", pid)
        sleep 0.1
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::EINVAL
        nil
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
        text = value.to_s
        text.bytesize > max ? text.byteslice(0, max).to_s + "\n[truncated]" : text
      end
    end
  end
end
