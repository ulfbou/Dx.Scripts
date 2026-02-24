#!/usr/bin/env bash
set -euo pipefail

safe_mkdir() { [[ -d "$1" ]] || mkdir -p -- "$1"; }

append_unique_line() {
  local file="$1" line="$2"
  [[ -f "$file" ]] || { printf '%s\n' "$line" > "$file"; return 0; }
  grep -qxF -- "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

atomic_write() {
  local dst="$1"; shift
  local dir; dir="$(dirname -- "$dst")"
  safe_mkdir "$dir"
  local tmp; tmp="$(mktemp "${dir}/.dxwrite.XXXXXX")"
  printf '%s' "$*" > "$tmp"
  mv -f -- "$tmp" "$dst"
}
