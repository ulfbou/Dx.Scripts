#!/usr/bin/env bash
set -euo pipefail

# Level priorities (higher = more severe)
# error=40, warn=30, info=20, debug=10, trace=5
_log_level_num() {
  case "${1:-info}" in
    error) echo 40 ;;
    warn)  echo 30 ;;
    info)  echo 20 ;;
    debug) echo 10 ;;
    trace) echo 5  ;;
    *) echo 20 ;;
  esac
}

DX_LOG_FORMAT="human"
DX_LOG_LEVEL_NUM="$(_log_level_num info)"

# JSONL file sink (always-on to file for traceability)
LOG_FILE=""
log_set_file() { LOG_FILE="$1"; }

log_bootstrap_init() {
  local fmt="${1:-human}"
  local lvl="${2:-info}"
  DX_LOG_FORMAT="$fmt"
  DX_LOG_LEVEL_NUM="$(_log_level_num "$lvl")"
}

log_reconfigure() {
  local fmt="${1:-$DX_LOG_FORMAT}"
  local lvl="${2:-info}"
  DX_LOG_FORMAT="$fmt"
  DX_LOG_LEVEL_NUM="$(_log_level_num "$lvl")"
}

_log_should_emit() {
  local lvl="$1"
  local num="$(_log_level_num "$lvl")"
  [[ "$num" -ge "$DX_LOG_LEVEL_NUM" ]]
}

_log_now() { date +"%Y-%m-%dT%H:%M:%S%z"; }

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Emit to STDOUT (human)
_log_emit_human() {
  local lvl="$1" mod="$2" msg="$3"; shift 3
  local ts; ts="$(_log_now)"
  local code=""
  local kv=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      code=*) code="${1#code=}"; shift ;;
      *) kv+="$1 " ; shift ;;
    esac
  done
  [[ -n "$code" ]] && code=" $code"
  printf '[%s] %s %s%s %s\n' "$lvl" "$ts" "$mod" "$code" "$msg"
  [[ -n "$kv" ]] && printf '        %s\n' "$kv"
}

# Emit to STDOUT (json)
_log_emit_json() {
  local lvl="$1" mod="$2" msg="$3"; shift 3
  local ts; ts="$(_log_now)"
  local code=""
  local rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      code=*) code="${1#code=}"; shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  printf '{'
  printf '"ts":"%s","level":"%s","module":"%s","message":"%s"' "$(_json_escape "$ts")" "$lvl" "$(_json_escape "$mod")" "$(_json_escape "$msg")"
  [[ -n "$code" ]] && printf ',"code":"%s"' "$(_json_escape "$code")"
  for kv in "${rest[@]:-}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    printf ',"%s":"%s"' "$(_json_escape "$k")" "$(_json_escape "$v")"
  done
  printf '}\n'
}

# Mirror to LOG_FILE as JSONL (always)
_log_emit_to_file_jsonl() {
  local lvl="$1" mod="$2" msg="$3"; shift 3
  [[ -n "$LOG_FILE" ]] || return 0
  local ts; ts="$(_log_now)"
  {
    printf '{'
    printf '"ts":"%s","level":"%s","module":"%s","message":"%s"' "$(_json_escape "$ts")" "$lvl" "$(_json_escape "$mod")" "$(_json_escape "$msg")"
    while [[ $# -gt 0 ]]; do
      k="${1%%=*}"; v="${1#*=}"
      printf ',"%s":"%s"' "$(_json_escape "$k")" "$(_json_escape "$v")"
      shift
    done
    printf '}\n'
  } >> "$LOG_FILE"
}

_log_emit() {
  local lvl="$1" mod="$2" msg="$3"; shift 3
  _log_should_emit "$lvl" && {
    if [[ "$DX_LOG_FORMAT" == "json" ]]; then
      _log_emit_json "$lvl" "$mod" "$msg" "$@"
    else
      _log_emit_human "$lvl" "$mod" "$msg" "$@"
    fi
  }
  # Always mirror to JSONL file
  _log_emit_to_file_jsonl "$lvl" "$mod" "$msg" "$@"
}

log_error() { _log_emit error "${1:-dx}" "${2:-}" code="${3:-}" "${@:4}"; }
log_warn()  { _log_emit warn  "${1:-dx}" "${2:-}" "${@:3}"; }
log_info()  { _log_emit info  "${1:-dx}" "${2:-}" "${@:3}"; }
log_debug() { _log_emit debug "${1:-dx}" "${2:-}" "${@:3}"; }
log_trace() { _log_emit trace "${1:-dx}" "${2:-}" "${@:3}"; }
