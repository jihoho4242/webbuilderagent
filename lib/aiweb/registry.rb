# frozen_string_literal: true

require "json"
require "yaml"

module Aiweb
  class Registry
    REGISTRIES = {
      "design-systems" => {
        label: "Design systems",
        singular: "design system",
        directory: "design-systems"
      },
      "skills" => {
        label: "Skills",
        singular: "skill",
        directory: "skills"
      },
      "craft" => {
        label: "Craft",
        singular: "craft item",
        directory: "craft"
      }
    }.freeze

    METADATA_FILENAMES = %w[
      aiweb.json registry.json metadata.json manifest.json index.json
      skill.json design-system.json craft.json
      DESIGN.md design.md SKILL.md skill.md
      aiweb.yaml aiweb.yml registry.yaml registry.yml metadata.yaml metadata.yml manifest.yaml manifest.yml index.yaml index.yml
      README.md readme.md index.md
    ].freeze

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
    end

    def list(name)
      config = REGISTRIES.fetch(name)
      directory = config.fetch(:directory)
      absolute_directory = File.join(root, directory)
      validation_errors = []
      warnings = []
      entries = Dir.exist?(absolute_directory) ? scan_entries(absolute_directory, validation_errors, warnings) : []

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "listed #{directory}",
        "changed_files" => [],
        "blocking_issues" => validation_errors.map { |error| "registry metadata validation failed: #{error}" },
        "validation_errors" => validation_errors,
        "warnings" => warnings,
        "missing_artifacts" => Dir.exist?(absolute_directory) ? [] : [directory],
        "next_action" => entries.empty? ? "add entries under #{directory}/" : "select an entry from #{directory}/",
        "registry" => {
          "name" => name,
          "label" => config.fetch(:label),
          "singular" => config.fetch(:singular),
          "directory" => directory,
          "path" => relative_path(absolute_directory),
          "exists" => Dir.exist?(absolute_directory),
          "count" => entries.length,
          "items" => entries
        }
      }
    end

    private

    def scan_entries(directory, validation_errors, warnings)
      Dir.children(directory).reject { |name| name.start_with?(".") }.map do |name|
        absolute_path = File.join(directory, name)
        next unless File.directory?(absolute_path) || File.file?(absolute_path)

        entry_for(absolute_path, validation_errors, warnings)
      end.compact.sort_by { |entry| [entry["id"].to_s.downcase, entry["path"].to_s.downcase] }
    end

    def entry_for(absolute_path, validation_errors, warnings)
      metadata_path = metadata_path_for(absolute_path)
      metadata = metadata_path ? read_metadata(metadata_path, validation_errors, warnings) : {}
      fallback_id = File.directory?(absolute_path) ? File.basename(absolute_path) : File.basename(absolute_path, File.extname(absolute_path))
      id = present_string(metadata["id"]) || slug(fallback_id)
      title = present_string(metadata["title"]) || present_string(metadata["name"]) || titleize(fallback_id)

      {
        "id" => id,
        "title" => title,
        "description" => present_string(metadata["description"]) || present_string(metadata["summary"]),
        "path" => relative_path(absolute_path),
        "kind" => File.directory?(absolute_path) ? "directory" : "file",
        "metadata_path" => metadata_path && relative_path(metadata_path)
      }.compact
    end

    def metadata_path_for(absolute_path)
      if File.directory?(absolute_path)
        METADATA_FILENAMES.map { |name| File.join(absolute_path, name) }.find { |path| File.file?(path) }
      elsif metadata_file?(absolute_path)
        absolute_path
      end
    end

    def metadata_file?(path)
      %w[.json .yaml .yml .md .markdown].include?(File.extname(path).downcase)
    end

    def read_metadata(path, validation_errors, warnings)
      case File.extname(path).downcase
      when ".json"
        parse_structured_metadata(path, validation_errors, warnings) do |content|
          JSON.parse(content)
        rescue JSON::ParserError => e
          raise MetadataParseError, "invalid JSON: #{e.message}"
        end
      when ".yaml", ".yml"
        parse_structured_metadata(path, validation_errors, warnings) do |content|
          YAML.safe_load(content, permitted_classes: [], aliases: false)
        rescue Psych::Exception => e
          raise MetadataParseError, "invalid YAML: #{e.message}"
        end
      when ".md", ".markdown"
        markdown_metadata(path, validation_errors, warnings)
      else
        {}
      end
    end

    class MetadataParseError < StandardError; end

    def parse_structured_metadata(path, validation_errors, warnings)
      data = yield(File.read(path))
      return stringify_keys(data) if data.is_a?(Hash)

      record_metadata_problem(path, validation_errors, warnings, "metadata must be a mapping/object")
      {}
    rescue MetadataParseError, SystemCallError => e
      record_metadata_problem(path, validation_errors, warnings, e.message)
      {}
    end

    def markdown_metadata(path, validation_errors, warnings)
      lines = File.readlines(path, chomp: true)
      heading = lines.find { |line| line.match?(/\A#\s+\S/) }
      paragraph = lines.find do |line|
        stripped = line.strip
        !stripped.empty? && !stripped.start_with?("#")
      end
      {
        "title" => heading&.sub(/\A#\s+/, "")&.strip,
        "description" => paragraph&.strip
      }.compact
    rescue SystemCallError => e
      record_metadata_problem(path, validation_errors, warnings, e.message)
      {}
    end

    def record_metadata_problem(path, validation_errors, warnings, message)
      relative = relative_path(path)
      validation_errors << "#{relative}: #{message}"
      warnings << "using path-derived registry fields for #{relative} because metadata could not be loaded"
    end

    def stringify_keys(hash)
      hash.each_with_object({}) do |(key, value), memo|
        memo[key.to_s] = value
      end
    end

    def present_string(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def titleize(value)
      value.to_s.tr("_-", " ").split.map(&:capitalize).join(" ")
    end

    def slug(value)
      slugged = value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      slugged.empty? ? value.to_s.strip : slugged
    end

    def relative_path(path)
      expanded = File.expand_path(path)
      prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      return "." if expanded == root
      return expanded.delete_prefix(prefix) if expanded.start_with?(prefix)

      expanded
    end
  end
end
