#!/usr/bin/env bash
set -euo pipefail

now_utc_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    echo "DXCORE003: sha256 tool missing (sha256sum/shasum)" >&2
    return 1
  fi
}

dx_b64_enc() {
  if base64 --help 2>/dev/null | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}
dx_b64_dec() {
  if base64 --help 2>/dev/null | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -d
  fi
}

# Strict relpath validation by segments:
# - no empty
# - no absolute
# - no backslashes
# - no '..' segment
validate_relpath_segments() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" != /* ]] || return 1
  [[ "$p" != *"\\"* ]] || return 1
  IFS='/' read -r -a segs <<< "$p"
  for s in "${segs[@]}"; do
    [[ "$s" == ".." || "$s" == "" ]] && return 1
  done
  return 0
}
