#!/usr/bin/env bash
set -euo pipefail

# Config:  DXCFG001..DXCFG005
# Scope:   DXSCOPE001..DXSCOPE003
# Core:    DXCORE001..DXCORE003 (003 = missing dependency)

_error_exit_code() {
  local code="${1:-}"
  case "$code" in
    DXCFG001) echo 20 ;;
    DXCFG002) echo 21 ;;
    DXCFG003) echo 22 ;;
    DXCFG004) echo 23 ;;
    DXCFG005) echo 24 ;;
    DXSCOPE001) echo 30 ;;
    DXSCOPE002) echo 31 ;;
    DXSCOPE003) echo 32 ;;
    DXCORE001) echo 40 ;;
    DXCORE002) echo 41 ;;
    DXCORE003) echo 42 ;;
    *) echo 1 ;;
  esac
}

die() {
  local code="${1:-DXCORE001}"; shift || true
  local msg="${1:-fatal error}"
  log_error "dx" "$msg" "code=$code"
  exit "$(_error_exit_code "$code")"
}
