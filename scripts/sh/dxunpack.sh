#!/usr/bin/env bash
set -euo pipefail

# dxunpack.sh — sandbox-first, two-pass unpack for instruction files
# Strict markers (must match entire line exactly):
#   // === BEGIN FILE: {ROOT}/relative/path ===
#   // === END FILE: {ROOT}/relative/path ===
#
# BEGIN is only recognized when NOT collecting.
# While collecting, END must match the current file path or it is treated as literal content.
# Denied files always print reasons (no extra flags).
# If no blocks are parsed, we print DEBUG diagnostics immediately.

INSTRUCTION_FILE=""
ROOT_DIR=".dx/sandbox"
MODE="overwrite"           # overwrite|skip|error
DRY_RUN=false
VERBOSE=false
STRICT="${UNPACK_FILES_STRICT:-0}"
APPLY=false
ANALYZE_ONLY=false
VERIFY=false

# Ceilings (env tunables)
UNPACK_MAX_FILES="${UNPACK_MAX_FILES:-50}"
UNPACK_MAX_FILE_KB="${UNPACK_MAX_FILE_KB:-2560}" # ~2.5 MiB per file
ALLOW_BINARY="${ALLOW_BINARY:-0}"                # 0 = deny NUL; 1 = allow

note(){ printf 'NOTE: %s\n' "$*" >&2; }
err(){  printf 'Error: %s\n' "$*" >&2; }

print_usage(){
  cat <<'H'
Usage:
  ./scripts/dxunpack.sh [INSTRUCTION_FILE] [ROOT_DIR]
      [-i|--input <file|->] [-r|--root <dir>] [--apply]
      [--mode <overwrite|skip|error>] [--verify]
      [--dry-run] [--analyze-only] [--strict] [-v|--verbose] [-h|--help]
H
}

# ---- CLI ----
POSITIONALS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|"/?") print_usage; exit 0 ;;
    -v|--verbose)   VERBOSE=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;            # keep dry-run independent
    --analyze-only) ANALYZE_ONLY=true; shift ;;
    --strict)       STRICT=1; shift ;;
    --apply)        APPLY=true; shift ;;
    --verify)       VERIFY=true; shift ;;
    --mode)
      [[ $# -ge 2 ]] || { err "Missing value for --mode"; exit 2; }
      MODE="$2"; shift 2
      case "$MODE" in overwrite|skip|error) ;; *) err "Invalid --mode: $MODE"; exit 2 ;; esac
      ;;
    -i|--input)
      [[ $# -ge 2 ]] || { err "Missing value for $1"; exit 2; }
      INSTRUCTION_FILE="$2"; shift 2 ;;
    -r|--root)
      [[ $# -ge 2 ]] || { err "Missing value for $1"; exit 2; }
      ROOT_DIR="$2"; shift 2 ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONALS+=("$1"); shift; done; break ;;
    -*) err "Unknown option: $1"; echo "Try: --help" >&2; exit 2 ;;
    *) POSITIONALS+=("$1"); shift ;;
  esac
done

# Positionals fallback (kept from original UX)
if [[ ${#POSITIONALS[@]} -gt 2 ]]; then err "Too many positional arguments"; exit 2; fi
if [[ "$STRICT" == "1" ]]; then
  [[ -n "${POSITIONALS[0]:-}" ]] && INSTRUCTION_FILE="${POSITIONALS[0]}"
  [[ -n "${POSITIONALS[1]:-}" ]] && ROOT_DIR="${POSITIONALS[1]}"
else
  a="${POSITIONALS[0]:-}"; b="${POSITIONALS[1]:-}"
  if [[ -n "$a" ]]; then
    if [[ "$a" == "-" || -f "$a" ]]; then INSTRUCTION_FILE="$a"; note "Interpreting '$a' as INSTRUCTION_FILE"
    elif [[ -d "$a" || "$a" == */ || "$a" == *\\ ]]; then ROOT_DIR="$a"; note "Interpreting '$a' as ROOT_DIR"
    fi
  fi
  if [[ -n "$b" ]]; then
    if [[ "$b" == "-" || -f "$b" ]]; then INSTRUCTION_FILE="$b"; note "Interpreting '$b' as INSTRUCTION_FILE"
    elif [[ -d "$b" || "$b" == */ || "$b" == *\\ ]]; then ROOT_DIR="$b"; note "Interpreting '$b' as ROOT_DIR"
    fi
  fi
fi

# DO NOT override ROOT_DIR on --apply. Honor the user-provided -r/ROOT always.

# Resolve input
if [[ -z "$INSTRUCTION_FILE" ]]; then
  if [[ -f "instructions.txt" ]]; then INSTRUCTION_FILE="instructions.txt"; note "Using default INSTRUCTION_FILE: instructions.txt"
  elif [[ ! -t 0 ]]; then INSTRUCTION_FILE="-"; note "Reading INSTRUCTION_FILE from stdin (-)"
  else print_usage; exit 0; fi
fi

if [[ "$INSTRUCTION_FILE" != '-' ]]; then
  [[ -r "$INSTRUCTION_FILE" && -f "$INSTRUCTION_FILE" ]] || { err "Instruction file not found or unreadable: $INSTRUCTION_FILE"; exit 3; }
  IN_STREAM="$INSTRUCTION_FILE"
else
  IN_STREAM="/dev/stdin"
  [[ -t 0 ]] && { err "No input on stdin; provide a file or pipe data"; exit 2; }
fi

# Prepare ROOT_DIR
if [[ -z "${ROOT_DIR:-}" ]]; then err "Missing ROOT_DIR (-r)"; exit 2; fi
if [[ ! -d "$ROOT_DIR" ]]; then
  $VERBOSE && echo "Root directory does not exist, creating: $ROOT_DIR"
  mkdir -p -- "$ROOT_DIR" 2>/dev/null || { err "Cannot create ROOT_DIR: $ROOT_DIR"; exit 6; }
fi
abs_root="$(cd "$ROOT_DIR" 2>/dev/null && pwd -P || true)"
[[ -n "$abs_root" && -d "$abs_root" ]] || { err "Invalid ROOT_DIR (cannot resolve): $ROOT_DIR"; exit 6; }

echo "Starting unpack..."
echo "Instruction file: $INSTRUCTION_FILE"
echo "Root Directory:   $abs_root"
echo "Mode:             $MODE"
$DRY_RUN && echo "Dry run:          yes"

# ---------- Strict markers with escaped braces ----------
BEGIN_RE='^// === BEGIN FILE: \{ROOT\}/(.+) ===$'
END_RE='^// === END FILE: \{ROOT\}/(.+) ===$'

# Quick deny list
deny_match(){
  case "$1" in
    .git|.git/*|node_modules/*|bin/*|obj/*|.vs/*|.vscode/*) return 0;;
    .github/*)  [[ "${DX_DENY_GITHUB:-1}" = "1" ]] && return 0 || return 1;;
    *) return 1;;
  esac
}

# Robust NUL detection for Git Bash/MSYS: scan first 4KiB hex and look for ' 00 '
contains_nul(){ LC_ALL=C od -An -tx1 -N 4096 -- "$1" 2>/dev/null | grep -qi ' 00 '; }

# Safe relpath guard: reject empty, absolute, or traversal
invalid_relpath(){
  local p="$1"
  [[ -z "$p" || "$p" == /* || "$p" == *"/../"* || "$p" == "../"* || "$p" == *"/.." || "$p" == ".." ]]
}

# --- Self-protection: prevent overwriting the instruction file itself
SELF_REL=""
if [[ "$INSTRUCTION_FILE" != "-" ]]; then
  abs_instr="$(cd "$(dirname -- "$INSTRUCTION_FILE")" 2>/dev/null && pwd -P)/$(basename -- "$INSTRUCTION_FILE")"
  case "$abs_instr" in
    "$abs_root"/*)
      SELF_REL="${abs_instr#$abs_root/}"
      note "Self-protection enabled: will not overwrite instructions file: {ROOT}/$SELF_REL"
      ;;
  esac
fi

# State (add deterministic bookkeeping for verify/apply)
collecting=false; current_rel=""; buffer=""
# per-file staging
declare -A REL_TO_TMP=()   # rel -> temp file path
declare -A REL_SEEN=()     # rel -> count
ACCEPTED_BLOCKS=()         # rel paths accepted
DENIED_REPORT=()           # "rel<TAB>reason"
BLOCKS=0; DENIED=0; CREATED=0; OVERWRITTEN=0; SKIPPED=0

# ---- PASS 1: Parse & classify ----
# shellcheck disable=SC2162
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  line="${line%$'\r'}"

  if ! $collecting && [[ "$line" =~ $BEGIN_RE ]]; then
    current_rel="${BASH_REMATCH[1]}"

    if invalid_relpath "$current_rel"; then
      err "Invalid path in BEGIN: {ROOT}/$current_rel"; exit 4
    fi
    # duplicate detection
    if [[ -n "${REL_SEEN[$current_rel]:-}" ]]; then
      REL_SEEN[$current_rel]=$(( REL_SEEN[$current_rel] + 1 ))
      DENIED_REPORT+=("$current_rel\tduplicate block")
      DENIED=$((DENIED+1))
      # remain collecting; ignore this block's body safely
      collecting=true; buffer=""; current_rel="__DENY_DUP__"
      continue
    fi
    REL_SEEN[$current_rel]=1
    collecting=true; buffer=""
    $VERBOSE && echo "BEGIN {ROOT}/$current_rel"
    continue
  fi

  if $collecting && [[ "$line" =~ $END_RE ]]; then
    end_rel="${BASH_REMATCH[1]}"
    if [[ "$end_rel" != "$current_rel" ]]; then
      # treat unmatched END as literal content
      buffer+="${line}"$'\n'
      continue
    fi

    # finalize this block (unless it was a denied-dup collector)
    if [[ "$current_rel" != "__DENY_DUP__" ]]; then
      target_abs="$abs_root/$current_rel"
      case "$target_abs" in "$abs_root"/*) ;; *) err "Illegal path (escapes ROOT_DIR): $target_abs"; exit 4 ;; esac

      tmpbuf="$(mktemp)" || { err "mktemp failed"; exit 7; }
      printf "%s" "$buffer" > "$tmpbuf" || { err "Write failed: $tmpbuf"; rm -f -- "$tmpbuf" 2>/dev/null || true; exit 7; }
      size=$(wc -c < "$tmpbuf" | tr -d ' ')

      if (( size > UNPACK_MAX_FILE_KB*1024 )); then
        DENIED_REPORT+=("$current_rel\tsize>max(${size}B)"); rm -f -- "$tmpbuf"; DENIED=$((DENIED+1))
      elif deny_match "$current_rel"; then
        DENIED_REPORT+=("$current_rel\tdenyPaths"); rm -f -- "$tmpbuf"; DENIED=$((DENIED+1))
      elif [[ "$ALLOW_BINARY" != "1" ]] && contains_nul "$tmpbuf"; then
        if $VERBOSE; then
          echo "DEBUG(binary): first 64 bytes of content:" >&2
          LC_ALL=C od -An -tx1 -N 64 -- "$tmpbuf" >&2 || true
        fi
        DENIED_REPORT+=("$current_rel\tbinary-nul"); rm -f -- "$tmpbuf"; DENIED=$((DENIED+1))
      # Self-overwrite protection: deny if block targets the instruction file itself
      elif [[ -n "$SELF_REL" && "$current_rel" == "$SELF_REL" ]]; then
        DENIED_REPORT+=("$current_rel\tself-overwrite")
        rm -f -- "$tmpbuf"
        DENIED=$((DENIED+1))
        $VERBOSE && echo "DENY(self) {ROOT}/$current_rel"
      else
        REL_TO_TMP["$current_rel"]="$tmpbuf"
        ACCEPTED_BLOCKS+=("$current_rel")
        $VERBOSE && echo "READY {ROOT}/$current_rel size=$size"
        # leave tmp for Pass 2; do not remove
      fi
    fi

    collecting=false; current_rel=""; buffer=""; BLOCKS=$((BLOCKS+1))
    continue
  fi

  $collecting && buffer+="${line}"$'\n'
done < "$IN_STREAM"

# DEBUG: if no blocks recognized, print actionable diagnostics
if (( BLOCKS == 0 )); then
  printf '%s\n' "DEBUG: No blocks parsed. Checking for marker lines and hidden characters..." >&2
  head -n 3 "$INSTRUCTION_FILE" 2>/dev/null | od -An -tx1 >&2 || true
  printf '%s\n' "DEBUG: BEGIN matches (first 5):" >&2
  (grep -nE '^// === BEGIN FILE: \{ROOT\}/.+ ===$' "$INSTRUCTION_FILE" || true) | head -n 5 >&2
  printf '%s\n' "DEBUG: END   matches (first 5):" >&2
  (grep -nE '^// === END FILE: \{ROOT\}/.+ ===$' "$INSTRUCTION_FILE" || true) | head -n 5 >&2
fi

# Unterminated block (strict fails, non-strict discards)
if $collecting; then
  if [[ "$current_rel" != "__DENY_DUP__" ]]; then
    if [[ "$STRICT" == "1" ]]; then err "Malformed: reached EOF before END for {ROOT}/$current_rel"; exit 4
    else note "Discarding unterminated block: {ROOT}/$current_rel"
    fi
  fi
fi

# Ceiling on number of files
if (( BLOCKS > UNPACK_MAX_FILES )); then err "File count exceeds max ($BLOCKS>$UNPACK_MAX_FILES)"; exit 5; fi

# Print denials, if any (immediately helpful)
if (( DENIED > 0 )); then
  echo "Denied details:"
  for row in "${DENIED_REPORT[@]}"; do
    printf '  - %s  (%s)\n' "${row%%$'\t'*}" "${row#*$'\t'}"
  done
fi

# Analyze-only → report and exit
if $ANALYZE_ONLY; then
  total_bytes=0
  for rel in "${ACCEPTED_BLOCKS[@]}"; do
    f="${REL_TO_TMP[$rel]}"; sz=$(wc -c < "$f" | tr -d ' '); total_bytes=$((total_bytes + sz))
  done
  echo "Analyze-only: blocks=$BLOCKS accepted=${#ACCEPTED_BLOCKS[@]} denied=$DENIED bytes=$total_bytes"
  for rel in "${ACCEPTED_BLOCKS[@]}"; do printf '  %s\n' "$rel"; done
  exit 0
fi

# Optional verify gate (true verify: compare sandbox vs ROOT files)
if $VERIFY; then
  status=0
  for rel in "${ACCEPTED_BLOCKS[@]}"; do
    src="${REL_TO_TMP[$rel]}"
    dst="$abs_root/$rel"
    if [[ ! -f "$dst" ]]; then
      printf 'MISSING: %s\n' "$rel"; status=3; continue
    fi
    if cmp -s -- "$src" "$dst"; then
      printf 'OK: %s\n' "$rel"
    else
      printf 'MISMATCH: %s\n' "$rel"; status=3
    fi
  done
  exit $status
fi

# ---- PASS 2: Apply (write defensively) ----
for rel in "${ACCEPTED_BLOCKS[@]}"; do
  src="${REL_TO_TMP[$rel]}"
  dst="$abs_root/$rel"
  tdir="$(dirname -- "$dst")"
  mkdir -p -- "$tdir" || { err "Cannot create dir: $tdir"; exit 7; }

  canon="$(cd "$tdir" 2>/dev/null && pwd -P || true)"
  case "$canon" in "$abs_root"|"$abs_root"/*) ;; *) err "Illegal path after canonicalization: $dst"; exit 4 ;; esac

  if [[ -f "$dst" ]]; then
    case "$MODE" in
      overwrite)
        if $DRY_RUN; then printf 'OVERWRITE: %s\n' "$rel"
        else mv -f -- "$src" "$dst"; OVERWRITTEN=$((OVERWRITTEN+1)); fi
        ;;
      skip)
        $DRY_RUN && printf 'SKIP (exists): %s\n' "$rel" || true
        SKIPPED=$((SKIPPED+1))
        ;;
      error)
        err "Refusing to overwrite existing file: $rel"; exit 5
        ;;
    esac
  else
    if $DRY_RUN; then printf 'WRITE: %s\n' "$rel"
    else mv -f -- "$src" "$dst"; CREATED=$((CREATED+1)); fi
  fi
done

echo "Unpack complete. Blocks=$BLOCKS Created=$CREATED Overwritten=$OVERWRITTEN Skipped=$SKIPPED Denied=$DENIED"
