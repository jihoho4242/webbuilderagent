# frozen_string_literal: true

require "shellwords"

module Aiweb
  module ProjectEngineRunGeneratedSources
    def engine_run_tool_broker_shim_source(tool_name, config)
      <<~SH
        #!/bin/sh
        set -eu
        TOOL_NAME=#{Shellwords.escape(tool_name)}
        RISK_CLASS=#{Shellwords.escape(config.fetch("risk"))}
        BLOCK_MODE=#{Shellwords.escape(config.fetch("mode"))}
        BLOCK_REASON=#{Shellwords.escape(config.fetch("reason"))}
        EVENT_PATH="${AIWEB_TOOL_BROKER_EVENTS_PATH:-/workspace/_aiweb/tool-broker-events.jsonl}"
        REAL_PATH="${AIWEB_TOOL_BROKER_REAL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
        SHIM_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

        aiweb_block() {
          mkdir -p "$(dirname -- "$EVENT_PATH")"
          ARG_COUNT=$#
          printf '{"schema_version":1,"type":"tool.blocked","tool_name":"%s","risk_class":"%s","reason":"%s","args_redacted":true,"arg_count":%s}\\n' "$TOOL_NAME" "$RISK_CLASS" "$BLOCK_REASON" "$ARG_COUNT" >> "$EVENT_PATH"
          printf 'AIWEB_TOOL_BROKER_BLOCKED %s: %s\\n' "$RISK_CLASS" "$BLOCK_REASON" >&2
          exit 126
        }

        aiweb_delegate() {
          OLD_IFS=$IFS
          IFS=:
          for dir in $REAL_PATH; do
            IFS=$OLD_IFS
            [ -n "$dir" ] || continue
            [ "$dir" = "$SHIM_DIR" ] && continue
            if [ -x "$dir/$TOOL_NAME" ]; then
              exec "$dir/$TOOL_NAME" "$@"
            fi
            IFS=:
          done
          IFS=$OLD_IFS
          printf 'AIWEB_TOOL_BROKER_REAL_COMMAND_MISSING %s\\n' "$TOOL_NAME" >&2
          exit 127
        }

        aiweb_first_subcommand() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --)
                shift
                break
                ;;
              --prefix|--workspace|--filter|--cwd|--cache|--userconfig|--registry|-C|-w)
                shift
                [ "$#" -gt 0 ] && shift
                continue
                ;;
              --prefix=*|--workspace=*|--filter=*|--cwd=*|--cache=*|--userconfig=*|--registry=*|-C=*|-w=*)
                shift
                continue
                ;;
              -c)
                shift
                if [ "$TOOL_NAME" = "git" ]; then
                  [ "$#" -gt 0 ] && shift
                fi
                continue
                ;;
              -*)
                shift
                continue
                ;;
              *)
                printf '%s' "$1"
                return 0
                ;;
            esac
          done
          [ "$#" -gt 0 ] && printf '%s' "$1"
        }

        aiweb_contains_package_install() {
          for arg in "$@"; do
            case "$arg" in
              add|install|i|ci|update|upgrade|up) return 0 ;;
            esac
          done
          return 1
        }

        aiweb_contains_git_push() {
          for arg in "$@"; do
            [ "$arg" = "push" ] && return 0
          done
          return 1
        }

        case "$BLOCK_MODE" in
          always_block)
            aiweb_block "$@"
            ;;
          package_manager)
            if aiweb_contains_package_install "$@"; then
              aiweb_block "$@"
            fi
            aiweb_delegate "$@"
            ;;
          git)
            if aiweb_contains_git_push "$@"; then
              aiweb_block "$@"
            fi
            aiweb_delegate "$@"
            ;;
          *)
            aiweb_block "$@"
            ;;
        esac
      SH
    end
  end
end
