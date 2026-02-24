#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LIB_DIR="$RUNTIME_DIR/lib"
CMD_DIR="$RUNTIME_DIR/commands"

. "$LIB_DIR/util.sh"
. "$LIB_DIR/errors.sh"
. "$LIB_DIR/logging.sh"
. "$LIB_DIR/fs.sh"
. "$LIB_DIR/scope.sh"
. "$LIB_DIR/config.sh"
. "$LIB_DIR/bundle.sh"

export DX_BOOT_LOG_FORMAT="${DX_BOOT_LOG_FORMAT:-human}"  # human|json
export DX_BOOT_LOG_LEVEL="${DX_BOOT_LOG_LEVEL:-info}"     # error|warn|info|debug|trace

GLOBAL_ARGS=()
CLI_LOG_FORMAT=""
CLI_LOG_LEVEL=""
STRICT_CONFIG="0"
SCOPE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-format) shift; CLI_LOG_FORMAT="${1:-}"; shift || true ;;
    --log-level)  shift; CLI_LOG_LEVEL="${1:-}";  shift || true ;;
    --strict-config) STRICT_CONFIG="1"; shift ;;
    --global) SCOPE_OVERRIDE="global"; shift ;;
    --local|--project) SCOPE_OVERRIDE="project"; shift ;;
    -h|--help) set -- help ;;
    init|env|pack|unpack|help) GLOBAL_ARGS+=("$1"); shift; break ;;
    *) break ;;
  esac
done

CMD="${GLOBAL_ARGS[0]:-help}"

log_bootstrap_init "$DX_BOOT_LOG_FORMAT" "$DX_BOOT_LOG_LEVEL"

# Scope + log file setup
scope_detect "$SCOPE_OVERRIDE" || die "DXSCOPE001" "Cannot determine requested scope"
log_debug "dx" "Scope detected" "scope=$(scope_name)" "root=$(scope_root)"

# Always-on JSONL under project .dx/logs or ~/.dxs/logs
log_dir="$(dx_log_dir)"
safe_mkdir "$log_dir"
log_set_file "$log_dir/dx-$(date +%Y%m%d).jsonl"
log_info "dx" "Logging file sink enabled" "logFile=$log_dir"

# Config resolution
export DX_CLI_LOG_FORMAT="${CLI_LOG_FORMAT:-}"
export DX_CLI_LOG_LEVEL="${CLI_LOG_LEVEL:-}"
export DX_CLI_STRICT_CONFIG="${STRICT_CONFIG}"

config_resolve || die "DXCFG004" "Configuration resolution failed"
log_reconfigure "$(config_get_effective_log_format)" "$(config_get_effective_log_level)"
log_trace "dx" "Config loaded" "strict=${STRICT_CONFIG}"

case "$CMD" in
  help)
    cat <<'H'
dx — DX-first prototype runtime 1.0.0

Usage:
  dx [--log-format human|json] [--log-level L] [--strict-config] [--global|--local] <command> [args...]

Commands:
  init     Initialize project/global state
  env      Show resolved environment (human or --json)
  pack     Pack a directory into a single .dxp artifact (prints only the path)
  unpack   Validate + apply a .dxp into a root (one step)

Examples:
  dx init
  dx env --json
  dx pack /path sh,txt
  dx unpack /c/tmp/mybundle.dxp --root /path --mode overwrite
H
    ;;
  init)   . "$CMD_DIR/init.sh";   dx_cmd_init "$@";   ;;
  env)    . "$CMD_DIR/env.sh";    dx_cmd_env "$@";    ;;
  pack)   . "$CMD_DIR/pack.sh";   dx_cmd_pack "$@";   ;;
  unpack) . "$CMD_DIR/unpack.sh"; dx_cmd_unpack "$@"; ;;
  *)      die "DXCORE001" "Unknown command: $CMD"     ;;
esac
