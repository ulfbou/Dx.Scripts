#!/usr/bin/env bash
set -euo pipefail

dx_cmd_init() {
  local force_global=0 force_local=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --global) force_global=1; shift ;;
      --local|--project) force_local=1; shift ;;
      -h|--help)
        cat <<'H'
dx init — initialize state for current scope

Usage:
  dx init [--global|--local]
H
        return 0 ;;
      *) break ;;
    esac
  done

  if (( force_global && force_local )); then
    die "DXCORE001" "Mutually exclusive flags: --global and --local"
  fi

  local override=""
  (( force_global )) && override="global"
  (( force_local ))  && override="project"
  scope_detect "$override" || die "DXSCOPE001" "Cannot initialize: not in a git repo for --local"

  local root; root="$(scope_root)"

  for d in "" "logs" "tmp" "snapshots" "modules"; do
    safe_mkdir "$root/$d" || die "DXSCOPE002" "Cannot create directory: $root/$d"
  done

  # Ensure global config + fallback state homes
  local ghome; ghome="$(dx_config_home)"
  local shome; shome="$(dx_state_home)"
  safe_mkdir "$ghome" "$shome" "$shome/logs"

  # Global TOML config with [dx] and [pack] outDir if missing
  local global_cfg="$ghome/config"
  if [[ ! -f "$global_cfg" ]]; then
    cat > "$global_cfg" <<'T'
[dx]
schemaVersion = "1.0"

[pack]
outDir = "/c/tmp"
T
  else
    # Ensure [dx] and [pack].outDir exist
    if ! grep -q '^\[dx\]' "$global_cfg"; then
      printf '\n[dx]\nschemaVersion = "1.0"\n' >> "$global_cfg"
    fi
    if ! grep -q '^\[pack\]' "$global_cfg"; then
      printf '\n[pack]\noutDir = "/c/tmp"\n' >> "$global_cfg"
    elif ! grep -q '^outDir *= ' <(awk '/^\[pack\]/{f=1;next}/^\[/{f=0}f{print}' "$global_cfg"); then
      # Add outDir under [pack]
      awk '1; /^\[pack\]$/ && !x{print "outDir = \"/c/tmp\""; x=1}' "$global_cfg" > "$global_cfg.tmp" && mv -f "$global_cfg.tmp" "$global_cfg"
    fi
  fi

  # Project .dx/config TOML stub
  local pcfg="$root/config"
  if [[ ! -f "$pcfg" ]]; then
    cat > "$pcfg" <<'T'
[dx]
schemaVersion = "1.0"
T
  fi

  if [[ "$(scope_name)" == "project" ]]; then
    local repo_root; repo_root="$(git rev-parse --show-toplevel)"
    append_unique_line "$repo_root/.gitignore" ".dx/"
  fi

  log_info "init" "Initialized $(scope_name) scope at $root"
  log_info "init" "Global config: $(dx_config_home)/config"
  log_info "init" "Fallback state: $(dx_state_home)"
}
