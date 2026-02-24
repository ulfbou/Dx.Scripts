#!/usr/bin/env bash
set -euo pipefail

has_cmd() { command -v "$1" >/dev/null 2>&1; }

abspath() {
  local p="${1:-.}"
  if [[ -d "$p" ]]; then (cd "$p" && pwd -P)
  else (cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")")
  fi
}

joinpath() {
  local a="${1%/}"; local b="${2#/}"
  printf '%s/%s' "$a" "$b"
}
