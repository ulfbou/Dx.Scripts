#!/usr/bin/env bash
set -euo pipefail

_json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r\n'/$'\n'}"
  s="${s//$'\r'/\\n}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

dx_cmd_env() {
  local out_json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) out_json=1; shift ;;
      -h|--help)
        cat <<'H'
dx env — print resolved environment

Usage:
  dx env [--json]
H
        return 0 ;;
      *) break ;;
    esac
  done

  if (( out_json )); then
    local snap; snap="$(config_snapshot_json)"
    local body; body="${snap#\{}"
    printf '{'
    printf '"scope":"%s","scopeRoot":"%s",' "$(_json_escape "$(scope_name)")" "$(_json_escape "$(scope_root)")"
    printf '%s\n' "$body"
    return 0
  fi

  log_info "env" "Scope: $(scope_name)"
  log_info "env" "Scope root: $(scope_root)"
  log_info "env" "Runtime: 1.0.0"
  log_info "env" "Log format: $(config_get_effective_log_format)"
  log_info "env" "Log level:  $(config_get_effective_log_level)"
}
