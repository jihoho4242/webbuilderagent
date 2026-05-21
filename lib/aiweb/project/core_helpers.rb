# frozen_string_literal: true

require "fileutils"
require "yaml"
require_relative "../errors"

module Aiweb
  module ProjectCoreHelpers
    private

    def planned_dirs
      [
        aiweb_dir,
        File.join(aiweb_dir, "gates"),
        File.join(aiweb_dir, "design-candidates"),
        File.join(aiweb_dir, "qa"),
        File.join(aiweb_dir, "qa", "results"),
        File.join(aiweb_dir, "tasks"),
        File.join(aiweb_dir, "snapshots")
      ]
    end

    def copy_core_templates(dry_run, changes)
      template_map = {
        "quality.yaml" => File.join(aiweb_dir, "quality.yaml"),
        "state.schema.json" => File.join(aiweb_dir, "state.schema.json"),
        "quality.schema.json" => File.join(aiweb_dir, "quality.schema.json"),
        "qa-result.schema.json" => File.join(aiweb_dir, "qa", "qa-result.schema.json"),
        "intent.schema.json" => File.join(aiweb_dir, "intent.schema.json"),
        "intent.yaml" => File.join(aiweb_dir, "intent.yaml"),
        "first-view-contract.md" => File.join(aiweb_dir, "first-view-contract.md"),
        "project.md" => File.join(aiweb_dir, "project.md"),
        "product.md" => File.join(aiweb_dir, "product.md"),
        "brand.md" => File.join(aiweb_dir, "brand.md"),
        "content.md" => File.join(aiweb_dir, "content.md"),
        "ia.md" => File.join(aiweb_dir, "ia.md"),
        "data.md" => File.join(aiweb_dir, "data.md"),
        "security.md" => File.join(aiweb_dir, "security.md"),
        "design-brief.md" => File.join(aiweb_dir, "design-brief.md"),
        "deploy.md" => File.join(aiweb_dir, "deploy.md"),
        "post-launch-backlog.md" => File.join(aiweb_dir, "post-launch-backlog.md"),
        "final-qa-report.md" => File.join(aiweb_dir, "qa", "final-report.md"),
        "DESIGN.md" => File.join(aiweb_dir, "DESIGN.md"),
        "AGENTS.md" => File.join(root, "AGENTS.md")
      }
      template_map.each do |src, dest|
        changes << copy_template(src, dest, dry_run) unless File.exist?(dest)
      end
      root_design = File.join(root, "DESIGN.md")
      changes << copy_template("DESIGN.md", root_design, dry_run) unless File.exist?(root_design)
      changes << write_file(File.join(aiweb_dir, "gates", "gate-1a-scope-quality-stack.md"), gate_markdown("Gate 1A — Scope / Quality / Stack", ["Release scope", "Quality contract", "Stack profile"], "pending"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-1a-scope-quality-stack.md"))
      changes << write_file(File.join(aiweb_dir, "gates", "gate-1b-product-content-ia-data-security.md"), gate_markdown("Gate 1B — Product / Content / IA / Data / Security", ["Product", "Brand/content", "IA", "Data/security"], "pending"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-1b-product-content-ia-data-security.md"))
      changes << write_file(File.join(aiweb_dir, "gates", "gate-2-design.md"), gate_markdown("Gate 2 — Design", ["Design candidates", "Comparison", "Selected design"], "pending"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-2-design.md"))
      changes << write_file(File.join(aiweb_dir, "gates", "gate-3-golden-flow.md"), gate_markdown("Gate 3 — Golden Flow", ["Golden page", "Golden flow QA"], "pending"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-3-golden-flow.md"))
      changes << copy_template("gate-4-predeploy.md", File.join(aiweb_dir, "gates", "gate-4-predeploy.md"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-4-predeploy.md"))
    end

    def copy_template(name, dest, dry_run)
      src = File.join(templates_dir, name)
      raise UserError.new("missing template #{src}", 10) unless File.exist?(src)
      write_file(dest, File.read(src), dry_run)
    end

    def load_template_yaml(name)
      YAML.load_file(File.join(templates_dir, name))
    end

    def load_state_if_present
      File.exist?(state_path) ? YAML.load_file(state_path) : nil
    end

    def assert_initialized!
      raise UserError.new("not initialized; run aiweb init first", 1) unless initialized?
    end

    def phase_guard!(state, command, allowed_phases, force)
      return if force
      current = state.dig("phase", "current")
      return if allowed_phases.include?(current)

      raise UserError.new(
        "#{command} requires current phase #{allowed_phases.join(" or ")}; current phase is #{current.inspect}. Use --force only for manual repair/override.",
        2
      )
    end

    def mutation(dry_run:)
      if dry_run
        yield
        return
      end
      FileUtils.mkdir_p(aiweb_dir)
      lock = File.join(aiweb_dir, ".lock")
      lock_acquired = false
      begin
        File.open(lock, File::WRONLY | File::CREAT | File::EXCL) do |file|
          lock_acquired = true
          file.write("pid=#{Process.pid}\ncreated_at=#{now}\n")
        end
        yield
      rescue Errno::EEXIST
        raise UserError.new("state lock exists: #{lock}. If this is stale, remove it only after confirming no aiweb command is running.", 1)
      ensure
        FileUtils.rm_f(lock) if lock_acquired
      end
    end

  end
end
