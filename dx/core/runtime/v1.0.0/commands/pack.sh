#!/usr/bin/env bash
set -euo pipefail

dx_cmd_pack() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'H'
dx pack — produce one reproducible .dxp file from a root directory

Usage:
  dx pack <root-dir> <ext1,ext2,...> [<out-file>] [--out <file>] [--out-dir <dir>] [--enc raw|b64]

Notes:
  - Default output directory comes from [pack].outDir (global or project config)
  - Default excludes: .dx/**, .git/**, bin/**, obj/**, node_modules/**, .vs/**, .vscode/**
  - Default encoding: raw (no base64). The per-file meta line includes 'raw' or 'b64'.
  - Backward compatibility: unpack treats entries with no 'enc' token as 'b64' (legacy).

Output:
  - Prints ONLY the output .dxp path to stdout (scriptable)
  - Logs details to .dx/logs or ~/.dxs/logs
H
    return 0
  fi

  local root="${1:-}"; local exts_csv="${2:-}"
  shift 2 || true

  # Optional 3rd positional OUT file
  local out_pos=""
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    out_pos="$1"; shift
  fi

  local out="" out_dir="" enc_mode="raw"   # <— default raw
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) shift; out="${1:-}"; shift || true ;;
      --out-dir) shift; out_dir="${1:-}"; shift || true ;;
      --enc) shift; enc_mode="${1:-raw}"; shift || true ;;
      *) die "DXCORE001" "Unknown option to dx pack: $1" ;;
    esac
  done

  case "$enc_mode" in raw|b64) ;; *) die "DXCORE001" "Invalid --enc (use raw|b64)" ;; esac

  [[ -n "$root" && -n "$exts_csv" ]] || die "DXCORE001" "Usage: dx pack <root-dir> <ext1,ext2,...> [<out-file>] [--out <file>] [--out-dir <dir>] [--enc raw|b64]"
  root="$(cd "$root" 2>/dev/null && pwd -P)" || die "DXCORE001" "Root dir not found"

  IFS=',' read -r -a exts <<< "$exts_csv"
  declare -A extset=()
  for e in "${exts[@]}"; do e="${e,,}"; e="${e#.}"; [[ -n "$e" ]] && extset["$e"]=1; done
  [[ ${#extset[@]} -gt 0 ]] || die "DXCORE001" "No valid extensions"

  # Output selection ( --out > positional > generated )
  local destdir
  if [[ -n "$out" ]]; then
    destdir="$(dirname -- "$out")"
    mkdir -p -- "$destdir"
  elif [[ -n "$out_pos" ]]; then
    out="$out_pos"
    destdir="$(dirname -- "$out")"
    mkdir -p -- "$destdir"
  else
    if [[ -n "$out_dir" ]]; then
      destdir="$out_dir"
    else
      if command -v config_get_pack_outdir >/dev/null 2>&1; then
        destdir="$(config_get_pack_outdir)"
      else
        destdir="/c/tmp"
      fi
    fi
    mkdir -p -- "$destdir"
    local base; base="$(basename -- "$root")"
    local normexts; normexts="$(printf '%s' "$exts_csv" | tr '[:upper:]' '[:lower:]' | tr ',' '-' | tr -d ' ')"
    out="$destdir/dxpack.${base}.${normexts}.dxp"
  fi

  log_info "pack" "pack_start" root="$root" exts="$exts_csv" out="$out" enc="$enc_mode"

  local tmp_list; tmp_list="$(mktemp)"
  while IFS= read -r -d '' f; do
    case "$f" in
      *"/.git/"*|*"/.dx/"*|*"/bin/"*|*"/obj/"*|*"/node_modules/"*|*"/.vs/"*|*"/.vscode/"*) continue ;;
    esac
    local b; b="$(basename -- "$f")"
    local ext="${b##*.}"; ext="${ext,,}"
    [[ -n "${extset[$ext]:-}" ]] || continue
    printf '%s\n' "$f" >> "$tmp_list"
  done < <(find "$root" -type f -print0)

  LC_ALL=C sort -u "$tmp_list" -o "$tmp_list"
  local count; count="$(wc -l < "$tmp_list" | tr -d ' ')"
  log_info "pack" "pack_scan" files="$count"

  local tmp_out; tmp_out="$(mktemp "$(dirname -- "$out")/.dxp.XXXXXX")"

  {
    echo "DXP1"
    echo "@schema=1"
    # echo "@root=${root}"   # omit to avoid leaking abs paths in v0
    echo "@exts=${exts_csv}"
    echo "@modeDefault=overwrite"
    echo "@deny=.dx,.git,bin,obj,node_modules,.vs,.vscode"
    echo "@count=${count}"
    echo "--FILES--"
  } > "$tmp_out"

  # Helpers
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/bundle.sh"

  while IFS= read -r abs; do
    rel="${abs#$root/}"
    validate_relpath_segments "$rel" || die "DXCORE001" "Invalid relpath during pack: $rel"
    xflag=0; [[ -x "$abs" ]] && xflag=1
    size="$(wc -c < "$abs" | tr -d ' ')"
    sha="$(sha256_file "$abs")"

    if [[ "$enc_mode" == "raw" ]]; then
      printf 'F %s %s %s %s raw\n' "$rel" "$xflag" "$sha" "$size" >> "$tmp_out"
      # Write raw bytes then a single newline as a separator
      cat -- "$abs" >> "$tmp_out"
      printf '\n' >> "$tmp_out"
    else
      b64="$(dx_b64_enc < "$abs")"
      printf 'F %s %s %s %s b64\n' "$rel" "$xflag" "$sha" "$size" >> "$tmp_out"
      printf '%s\n' "$b64" >> "$tmp_out"
    fi
  done < "$tmp_list"

  mv -f -- "$tmp_out" "$out"
  log_info "pack" "pack_done" out="$out" files="$count" enc="$enc_mode"
  printf '%s\n' "$out"
}
