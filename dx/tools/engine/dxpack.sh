#!/usr/bin/env bash
set -euo pipefail

# dxpack.sh
# Packs source files into an *instruction file* that undxpack.sh can replay.
# Each file becomes a block:
#   // === BEGIN FILE: {ROOT}/relative/path ===
#   <content>
#   // === END FILE: {ROOT}/relative/path ===
#
# UX-first CLI:
# - Named flags: --root/-r, --ext/-e, --output/-o, --dry-run, --strict, --verbose/-v, --help/-h, /?
# - Heuristics: fix mixed/ambiguous positionals (unless --strict or PACK_FILES_STRICT=1).
# - Flexible ext separators: comma, semicolon, or whitespace.

# Exit codes:
#   0  OK (or help shown)
#   2  Invalid/too many/conflicting arguments
#   3  Output file not writable / cannot be created
#   4  No valid extensions provided
#   5  No files matched
#   6  Root directory does not exist or is not a directory

ROOT_DIR="."
EXTENSIONS_RAW="cs"
OUTPUT_FILE="instructions.txt"
VERBOSE=false
DRY_RUN=false
STRICT="${PACK_FILES_STRICT:-0}"

note() { printf 'NOTE: %s\n' "$*" >&2; }
err()  { printf 'Error: %s\n' "$*" >&2; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

is_ext_list_token() {
  local t="$(trim "$1")"
  [[ "$t" =~ ^[[:space:]]*\.?[A-Za-z0-9_+-]+([,;[:space:]]+\.?[A-Za-z0-9_+-]+)*[[:space:]]*$ ]]
}
is_outfile_token() {
  local t="$1"
  [[ "$t" == *"/"* || "$t" == *"\\"* || "$t" =~ \.(txt|list|instructions|instr|out|pack)$ ]]
}
is_dir_token() {
  local t="$1"
  if [[ -d "$t" ]]; then return 0; fi
  [[ "$t" == */ || "$t" == *\\ ]]
}

print_usage() {
  cat <<'EOF'
Usage:
  ./dxpack.sh [ROOT_DIR] [EXTENSIONS] [OUTPUT_FILE] [--dry-run] [--strict] [-v|--verbose] [-h|--help]

Arguments (positional OR via flags):
  ROOT_DIR       Root directory to search (default: .)
  EXTENSIONS     File extensions (comma/semicolon/space-separated; with or without leading dot).
                 Example: cs,js   or   .py .sh   (default: cs)
  OUTPUT_FILE    Output instruction file (default: instructions.txt)

Options:
  -r, --root <dir>       Set root directory (overrides positional).
  -e, --ext <list>       Set extensions (overrides positional).
  -o, --output <file>    Set output file (overrides positional).
  --dry-run              Print matched files (deterministic order), do not write.
  --strict               Disable heuristics; require canonical positional order.
  -v, --verbose          Verbose output (per-file "Processing:" lines; overwrite notice).
  -h, --help, /?         Show this help and exit 0.

Behavior:
  - Excludes typical build/IDE folders: bin/, obj/, .venv/, .vs/, .vscode/
  - Skips generated artifacts like *.g.<ext>
  - Excludes editor/OS artifacts: .#*, *~, .*.swp/.swo, .DS_Store
  - Null-safe traversal and deterministic ordering
EOF
}

if [[ $# -eq 0 ]]; then print_usage; exit 0; fi

POSITIONALS=()
SET_ROOT=false; SET_EXT=false; SET_OUT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|"/?") print_usage; exit 0 ;;
    -v|--verbose)   VERBOSE=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --strict)       STRICT=1; shift ;;
    -r|--root)      ROOT_DIR="$2"; SET_ROOT=true; shift 2 ;;
    -e|--ext|--extensions) EXTENSIONS_RAW="$2"; SET_EXT=true; shift 2 ;;
    -o|--out|--output) OUTPUT_FILE="$2"; SET_OUT=true; shift 2 ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONALS+=("$1"); shift; done; break ;;
    -*) err "Unknown option: $1"; echo "Try: ./dxpack.sh --help" >&2; exit 2 ;;
    *) POSITIONALS+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONALS[@]} -gt 3 ]]; then
  err "Too many positional arguments. Expected at most: ROOT_DIR [EXTENSIONS] [OUTPUT_FILE]"
  exit 2
fi

assign_from_positionals() {
  local a b c; a="${POSITIONALS[0]:-}"; b="${POSITIONALS[1]:-}"; c="${POSITIONALS[2]:-}"
  if [[ "$STRICT" == "1" ]]; then
    [[ -n "$a" ]] && ROOT_DIR="$a"
    [[ -n "$b" ]] && EXTENSIONS_RAW="$b"
    [[ -n "$c" ]] && OUTPUT_FILE="$c"
    return
  fi
  case ${#POSITIONALS[@]} in
    1)
      if   is_dir_token "$a"; then ROOT_DIR="$a"; note "Interpreting '$a' as ROOT_DIR"
      elif is_ext_list_token "$a"; then EXTENSIONS_RAW="$a"; note "Interpreting '$a' as EXTENSIONS"
      elif is_outfile_token "$a"; then OUTPUT_FILE="$a"; note "Interpreting '$a' as OUTPUT_FILE"
      else ROOT_DIR="$a"; note "Assuming '$a' is ROOT_DIR (use -e/-o for EXTENSIONS/OUTPUT)"; fi
      ;;
    2)
      local k1 k2
      if   is_dir_token "$a"; then k1="dir"
      elif is_ext_list_token "$a"; then k1="ext"
      elif is_outfile_token "$a"; then k1="out"
      else k1="unknown"; fi
      if   is_dir_token "$b"; then k2="dir"
      elif is_ext_list_token "$b"; then k2="ext"
      elif is_outfile_token "$b"; then k2="out"
      else k2="unknown"; fi
      if   [[ $k1 == dir && $k2 == ext ]]; then ROOT_DIR="$a"; EXTENSIONS_RAW="$b"; note "Interpreting '$a' as ROOT_DIR and '$b' as EXTENSIONS"
      elif [[ $k1 == dir && $k2 == out ]]; then ROOT_DIR="$a"; OUTPUT_FILE="$b"; note "Interpreting '$a' as ROOT_DIR and '$b' as OUTPUT_FILE"
      elif [[ $k1 == ext && $k2 == out ]]; then EXTENSIONS_RAW="$a"; OUTPUT_FILE="$b"; note "Interpreting '$a' as EXTENSIONS and '$b' as OUTPUT_FILE"
      elif [[ $k1 == out && $k2 == dir ]]; then OUTPUT_FILE="$a"; ROOT_DIR="$b"; note "Interpreting '$a' as OUTPUT_FILE and '$b' as ROOT_DIR"
      elif [[ $k1 == ext && $k2 == dir ]]; then EXTENSIONS_RAW="$a"; ROOT_DIR="$b"; note "Interpreting '$a' as EXTENSIONS and '$b' as ROOT_DIR"
      elif [[ $k1 == out && $k2 == ext ]]; then OUTPUT_FILE="$a"; EXTENSIONS_RAW="$b"; note "Interpreting '$a' as OUTPUT_FILE and '$b' as EXTENSIONS"
      else ROOT_DIR="$a"; EXTENSIONS_RAW="$b"; note "Assuming canonical order: ROOT_DIR='$a', EXTENSIONS='$b'"; fi
      ;;
    3)
      local arr=("$a" "$b" "$c") i tdir="" text="" tout=""
      for i in 0 1 2; do [[ -z "$tdir" ]] && is_dir_token "${arr[$i]}" && { tdir="${arr[$i]}"; continue; } done
      for i in 0 1 2; do [[ -z "$text" ]] && is_ext_list_token "${arr[$i]}" && { text="${arr[$i]}"; continue; } done
      for i in 0 1 2; do [[ -z "$tout" ]] && is_outfile_token "${arr[$i]}" && { tout="${arr[$i]}"; continue; } done
      if [[ -n "$tdir" && -n "$text" && -n "$tout" ]]; then
        ROOT_DIR="$tdir"; EXTENSIONS_RAW="$text"; OUTPUT_FILE="$tout"
        note "Interpreting positionals as: ROOT_DIR='$tdir', EXTENSIONS='$text', OUTPUT_FILE='$tout'"
      else
        ROOT_DIR="$a"; EXTENSIONS_RAW="$b"; OUTPUT_FILE="$c"
        note "Assuming canonical order: ROOT_DIR='$a', EXTENSIONS='$b', OUTPUT_FILE='$c'"
      fi
      ;;
  esac
}
assign_from_positionals

$SET_ROOT && note "Flag overrides ROOT_DIR → $ROOT_DIR"
$SET_EXT  && note "Flag overrides EXTENSIONS → $EXTENSIONS_RAW"
$SET_OUT  && note "Flag overrides OUTPUT_FILE → $OUTPUT_FILE"

if [[ ! -d "$ROOT_DIR" ]]; then err "Root directory does not exist or is not a directory: $ROOT_DIR"; exit 6; fi

EXTS=()
# shellcheck disable=SC2206
TOKS=($(printf '%s' "$EXTENSIONS_RAW" | tr ',;' '  '))
for e in "${TOKS[@]}"; do
  e="$(trim "$e")"; [[ -z "$e" ]] && continue
  [[ "$e" == .* ]] && EXTS+=("$e") || EXTS+=(".${e}")
done
if [[ ${#EXTS[@]} -eq 0 ]]; then err "No valid extensions provided: $EXTENSIONS_RAW"; exit 4; fi

OUT_DIR="."
if [[ "$OUTPUT_FILE" == */* || "$OUTPUT_FILE" == *\\* ]]; then
  OUT_DIR="${OUTPUT_FILE%/*}"
  [[ -z "$OUT_DIR" || "$OUT_DIR" == "$OUTPUT_FILE" ]] && OUT_DIR="."
fi
[[ -d "$OUT_DIR" ]] || mkdir -p -- "$OUT_DIR" 2>/dev/null || true
if [[ ! -d "$OUT_DIR" || ! -w "$OUT_DIR" ]]; then err "Cannot write output in: $OUT_DIR"; exit 3; fi

if [[ -s "$OUTPUT_FILE" && "$VERBOSE" == true ]]; then
  echo "WARNING: Overwriting existing file: $OUTPUT_FILE"
fi

FIND_ARGS=(
  "$ROOT_DIR"
  -type f
  -not -path "*/bin/*"
  -not -path "*/obj/*"
  -not -path "*/.venv/*"
  -not -path "*/.vs/*"
  -not -path "*/.vscode/*"
  # editor/OS junk to exclude:
  -not -name ".#*"
  -not -name "*~"
  -not -name ".*.swp" -not -name ".*.swo"
  -not -name ".DS_Store"
)

for ext in "${EXTS[@]}"; do
  FIND_ARGS+=(-not -name "*.g${ext}")
done

FIND_ARGS+=("(")
first=true
for ext in "${EXTS[@]}"; do
  if $first; then FIND_ARGS+=(-name "*${ext}"); first=false
  else FIND_ARGS+=(-o -name "*${ext}")
  fi
done
FIND_ARGS+=(")")

# shellcheck disable=SC2207
mapfile -d '' -t FILES < <(find "${FIND_ARGS[@]}" -print0 | LC_ALL=C sort -z)

echo "Starting packing..."
echo "Root Directory: $ROOT_DIR"
echo "Extensions: ${EXTS[*]}"
echo "Output File: $OUTPUT_FILE"
echo "Files matched: ${#FILES[@]}"

if [[ ${#FILES[@]} -eq 0 ]]; then err "No files matched."; exit 5; fi

if $DRY_RUN; then
  printf '%s\n' "${FILES[@]}"
  echo "Dry run: no instruction file was written."
  exit 0
fi

: > "$OUTPUT_FILE"
ROOT_CANON="${ROOT_DIR%/}"

for file in "${FILES[@]}"; do
  [[ "$VERBOSE" == true ]] && echo "Processing: $file"
  rel="$file"
  if [[ "$rel" == "$ROOT_CANON/"* ]]; then
    rel="${rel#"$ROOT_CANON/"}"
  fi
  {
    printf '// === BEGIN FILE: {ROOT}/%s ===\n' "$rel"
    cat -- "$file"
    printf '\n// === END FILE: {ROOT}/%s ===\n\n' "$rel"
  } >> "$OUTPUT_FILE"
done

echo "Packing complete. Instruction file written to: $OUTPUT_FILE"
