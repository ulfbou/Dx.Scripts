#!/usr/bin/env bash
set -euo pipefail

# dx runtime entry — parses top-level flags, resolves scope + config, initializes logging, dispatches commands.

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="$RUNTIME_DIR/lib"
CMD_DIR="$RUNTIME_DIR/commands"

# shellcheck source=lib/*.sh
. "$LIB_DIR/util.sh"
. "$LIB_DIR/errors.sh"
. "$LIB_DIR/logging.sh"
. "$LIB_DIR/fs.sh"
. "$LIB_DIR/scope.sh"
. "$LIB_DIR/config.sh"

# --- Defaults for bootstrap logging (reconfigured after config resolve) ---
export DX_BOOT_LOG_FORMAT="${DX_BOOT_LOG_FORMAT:-human}"  # human|json
export DX_BOOT_LOG_LEVEL="${DX_BOOT_LOG_LEVEL:-info}"     # error|warn|info|debug|trace

# --- Parse top-level CLI (common flags + command) ---
GLOBAL_ARGS=()
CLI_LOG_FORMAT=""
CLI_LOG_LEVEL=""
STRICT_CONFIG="0"
SCOPE_OVERRIDE=""  # "global"|"project"|""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-format) shift; CLI_LOG_FORMAT="${1:-}"; shift || true ;;
    --log-level) shift;  CLI_LOG_LEVEL="${1:-}";  shift || true ;;
    --strict-config) STRICT_CONFIG="1"; shift ;;
    --global) SCOPE_OVERRIDE="global"; shift ;;
    --local|--project) SCOPE_OVERRIDE="project"; shift ;;
    -h|--help) set -- help ;;
    init|env|help) GLOBAL_ARGS+=("$1"); shift; break ;;
    *) break ;;
  esac
done

CMD="${GLOBAL_ARGS[0]:-help}"

# --- Bootstrap logging (before config) ---
log_bootstrap_init "$DX_BOOT_LOG_FORMAT" "$DX_BOOT_LOG_LEVEL"

# --- Scope detection ---
scope_detect "$SCOPE_OVERRIDE" || die "DXSCOPE001" "Cannot determine requested scope"
log_debug "dx" "Scope detected" "scope=$(scope_name)" "root=$(scope_root)"

log_dir="$(dx_log_dir)"
safe_mkdir "$log_dir"
# daily JSONL file
log_set_file "$log_dir/dx-$(date +%Y%m%d).jsonl"
log_info "dx" "Logging enabled" "file=$log_dir"

# --- Config resolution
export DX_CLI_LOG_FORMAT="${CLI_LOG_FORMAT:-}"
export DX_CLI_LOG_LEVEL="${CLI_LOG_LEVEL:-}"
export DX_CLI_STRICT_CONFIG="${STRICT_CONFIG}"

if ! js="$(_config_py)"; then
  ec=$?
  case "$ec" in 42) die "DXCORE003" "Missing Python 3.11+ tomllib" ;; 20|21|22|23|24) exit "$ec" ;; *) die "DXCFG004" "Configuration resolution failed" ;; esac
fi

config_resolve || die "DXCFG004" "Configuration resolution failed"
# Reconfigure logger to effective settings
log_reconfigure "$(config_get_effective_log_format)" "$(config_get_effective_log_level)"

log_trace "dx" "Config loaded" "source=resolver" "strict=${STRICT_CONFIG}"

# --- Dispatch ---
case "$CMD" in
  help)
    cat <<'H'
dx — prototype runtime v1.0.0

Usage:
  dx [--log-format human|json] [--log-level L] [--strict-config] [--global|--local] <command> [args...]

Commands:
  init         Initialize scope state structure (global/project)
  env          Print resolved environment (human or --json)
  help         Show this help

Examples:
  dx init
  dx init --global
  dx env
  dx env --json

H
    ;;

  init)
    . "$CMD_DIR/init.sh"
    dx_cmd_init "$@"
    ;;

  env)
    . "$CMD_DIR/env.sh"
    dx_cmd_env "$@"
    ;;

  *)
    die "DXCORE001" "Unknown command: $CMD"
    ;;
esac
