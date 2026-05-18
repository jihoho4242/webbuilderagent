# frozen_string_literal: true

require_relative "preview_browser/preview_process"
require_relative "preview_browser/screenshot_capture"
require_relative "preview_browser/browser_actions"

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_browser_observer_script_source
      File.read(File.expand_path("../browser_observer_script.js", __dir__))
    end

    def engine_run_write_browser_observer_script(workspace_dir)
      path = File.join(workspace_dir, "_aiweb", "browser-observe.js")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, engine_run_browser_observer_script_source)
      path
    end

  end
end
