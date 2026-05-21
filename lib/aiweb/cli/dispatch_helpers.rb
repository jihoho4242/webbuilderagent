# frozen_string_literal: true

require "optparse"

require_relative "../runtime/path_policy"

module Aiweb
  class CLI
    module DispatchHelpers
      private

    def reject_extra_args!(command)
      return if @argv.empty?

      raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
    end

    def dispatch_registry(command)
      subcommand = @argv.shift || "list"
      unless subcommand == "list"
        raise UserError.new("unknown #{command} command #{subcommand.inspect}; expected list", EXIT_VALIDATION_FAILED)
      end

      parse_options
      unless @argv.empty?
        raise UserError.new("#{command} list does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end

      registry.list(command)
    end

    def parse_options
      options = {}
      parser = OptionParser.new do |o|
        yield(o, options) if block_given?
      end
      parser.parse!(@argv)
      options
    end

    def parse_positive_integer(value, option)
      text = value.to_s
      unless text.match?(/\A[1-9]\d*\z/)
        raise UserError.new("#{option} must be a positive integer", EXIT_VALIDATION_FAILED)
      end

      text.to_i
    end

    def relative_path(path)
      path = File.expand_path(path.to_s)
      root_prefix = @root.end_with?(File::SEPARATOR) ? @root : "#{@root}#{File::SEPARATOR}"
      return path.sub(root_prefix, "") if path.start_with?(root_prefix)

      path.sub(/\A#{Regexp.escape(@root)}\/?/, "")
    end

    def unsafe_env_path?(path)
      value = path.to_s.strip
      return false if value.empty? || value == "latest"

      Aiweb::Runtime::PathPolicy.unsafe_env_path?(value)
    end

    def parse_browser_qa_options(command)
      opts = parse_options do |o, options|
        o.on("--url URL") { |v| options[:url] = v }
        o.on("--task-id ID") { |v| options[:task_id] = v }
        o.on("--force") { options[:force] = true }
      end
      unless @argv.empty?
        raise UserError.new("#{command} does not accept extra positional arguments: #{@argv.join(", ")}", EXIT_VALIDATION_FAILED)
      end
      opts
    end
    end
  end
end
