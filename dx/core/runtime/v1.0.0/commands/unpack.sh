#!/usr/bin/env bash
set -euo pipefail

dx_cmd_unpack() {
  if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'H'
dx unpack — validate + restore a .dxp pack into a target root (one step)

Usage:
  dx unpack <bundle.dxp> --root <target-root> [--mode overwrite|skip|error]

Defaults:
  --mode overwrite

Behavior:
  - Validates header + per-file meta; auto-detects payload encoding:
      * 'raw'  → read exactly <size> bytes after the meta line, then consume one newline separator
      * 'b64'  → read next line; base64-decode
      * legacy (no 'enc' field) → treated as 'b64'
  - Path safety (no absolute, no traversal, no .dx targets)
  - sha256 + size verified per file
  - Preserves exec bit (xflag)
H
    return 0
  fi

  local bundle="${1:-}"; shift || true
  local root="" mode="overwrite"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root|-r) shift; root="${1:-}"; shift || true ;;
      --mode|-m) shift; mode="${1:-}"; shift || true ;;
      *) die "DXCORE001" "Unknown option to dx unpack: $1" ;;
    esac
  done

  [[ -f "$bundle" ]] || die "DXCORE001" "Bundle not found"
  [[ -n "$root"   ]] || die "DXCORE001" "Missing --root <target-root>"
  root="$(cd "$root" 2>/dev/null && pwd -P)" || die "DXCORE001" "Target root not found"
  case "$mode" in overwrite|skip|error) ;; *) die "DXCORE001" "Invalid mode: $mode" ;; esac

  log_info "unpack" "unpack_start" bundle="$bundle" root="$root" mode="$mode"

  # Header (CRLF tolerant)
  IFS= read -r line1 < "$bundle" || die "DXCORE001" "Empty bundle"
  line1="${line1%$'\r'}"
  [[ "$line1" == "DXP1" ]] || die "DXCORE001" "Unsupported bundle header (expected DXP1)"
  local schema; schema="$(grep -m1 '^@schema=' "$bundle" | head -n1 | cut -d= -f2- || true)"
  schema="${schema%$'\r'}"
  [[ "$schema" == "1" ]] || die "DXCORE001" "Unsupported schema: ${schema:-<missing>}"

  # Helpers
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/bundle.sh"

  local tmpdir; tmpdir="$(mktemp -d)"
  local decoded_list="$tmpdir/decoded.list"
  : > "$decoded_list"
  local started=0

  exec 3< "$bundle"
  while IFS= read -r line <&3; do
    line="${line%$'\r'}"
    if (( ! started )); then
      [[ "$line" == "--FILES--" ]] && { started=1; continue; }
      continue
    fi

    # Meta line + encoding
    local meta="$line"
    # shellcheck disable=SC2086
    set -- $meta
    [[ "${1:-}" == "F" ]] || die "DXCORE001" "Malformed bundle entry: $meta"
    local rel="${2:-}" xflag="${3:-}" sha_exp="${4:-}" size_exp="${5:-}" enc="${6:-}"
    [[ -n "$rel" && -n "$xflag" && -n "$sha_exp" && -n "$size_exp" ]] || die "DXCORE001" "Malformed entry (missing fields): $meta"

    # Default legacy → b64
    if [[ -z "$enc" ]]; then enc="b64"; fi
    case "$enc" in raw|b64) ;; *) die "DXCORE001" "Unsupported encoding: $enc" ;; esac

    validate_relpath_segments "$rel" || die "DXCORE001" "Illegal path in bundle: $rel"
    case "$rel" in .dx/*) die "DXCORE001" "Bundle targets .dx/, denied: $rel" ;; esac

    local tmpf; tmpf="$(mktemp "$tmpdir/.file.XXXXXX")"

    if [[ "$enc" == "raw" ]]; then
      # Read exactly <size_exp> bytes from fd 3 into tmpf
      # Consume a single trailing newline separator written by the packer.
      dd bs=1 count="$size_exp" of="$tmpf" 2>/dev/null <&3 || die "DXCORE001" "Raw copy failed: $rel"
      # Eat one line break (LF or CRLF) if present
      IFS= read -r _sep <&3 || true
    else
      local b64=""
      IFS= read -r b64 <&3 || die "DXCORE001" "Malformed bundle: missing base64 line"
      b64="${b64%$'\r'}"
      printf '%s' "$b64" | dx_b64_dec > "$tmpf" || die "DXCORE001" "Base64 decode failed: $rel"
    fi

    local size_act; size_act="$(wc -c < "$tmpf" | tr -d ' ')"
    [[ "$size_act" == "$size_exp" ]] || die "DXCORE001" "Size mismatch (corrupt): $rel"

    local sha_act; sha_act="$(sha256_file "$tmpf")"
    [[ "$sha_act" == "$sha_exp" ]] || die "DXCORE001" "Hash mismatch (corrupt): $rel"

    printf '%s\t%s\t%s\n' "$rel" "$xflag" "$tmpf" >> "$decoded_list"
  done
  exec 3<&-

  # Apply
  local created=0 overwritten=0 skipped=0
  while IFS=$'\t' read -r rel xflag tmpf; do
    dst="$root/$rel"
    dir="$(dirname -- "$dst")"
    mkdir -p -- "$dir"

    if [[ -e "$dst" ]]; then
      case "$mode" in
        overwrite) cat "$tmpf" | atomic_write "$dst"; overwritten=$((overwritten+1)) ;;
        skip)      skipped=$((skipped+1)); continue ;;
        error)     die "DXCORE001" "Refusing to overwrite existing file: $rel" ;;
      esac
    else
      cat "$tmpf" | atomic_write "$dst"; created=$((created+1))
    fi

    [[ "$xflag" == "1" ]] && chmod +x -- "$dst" 2>/dev/null || true
  done < "$decoded_list"

  log_info "unpack" "unpack_done" created="$created" overwritten="$overwritten" skipped="$skipped"
  echo "OK: unpacked created=$created overwritten=$overwritten skipped=$skipped"
}
