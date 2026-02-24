#!/usr/bin/env bash
set -euo pipefail

_SCOPE="global"
_ROOT="$HOME/.dx"

scope_name() { printf '%s' "$_SCOPE"; }
scope_root() { printf '%s' "$_ROOT"; }

dx_config_home() { printf '%s/.config/dx' "$HOME"; }
dx_state_home()  { printf '%s/.dxs' "$HOME"; }
dx_log_dir() {
  if [[ "$_SCOPE" == "project" ]]; then
    printf '%s/logs' "$_ROOT"
  else
    printf '%s/logs' "$(dx_state_home)"
  fi
}

scope_detect() {
  local override="${1:-}"  # "global"|"project"|""

  if [[ "$override" == "global" ]]; then
    _SCOPE="global"; _ROOT="$HOME/.dx"; return 0
  elif [[ "$override" == "project" ]]; then
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
      _SCOPE="project"; _ROOT="$(git rev-parse --show-toplevel)/.dx"; return 0
    else
      return 1
    fi
  fi

  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    _SCOPE="project"; _ROOT="$(git rev-parse --show-toplevel)/.dx"
  else
    _SCOPE="global"; _ROOT="$HOME/.dx"
  fi
  return 0
}

scope_state_path() { joinpath "$_ROOT" "${1:-}"; }
scope_assert_local() { git rev-parse --show-toplevel >/dev/null 2>&1; }
scope_assert_global() { return 0; }
