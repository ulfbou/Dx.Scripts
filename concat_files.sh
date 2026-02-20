#!/usr/bin/env bash
set -euo pipefail

# concat.sh (refactored to match apply-file-instructions.sh style)
# Concatenates files by extension under a root directory, writing results to an output file.

###############################################################################
# Argument validation
###############################################################################

if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
  cat <<'EOF'
Usage: ./concat.sh [ROOT_DIR] [EXTENSIONS] [OUTPUT_FILE]

Arguments:
  ROOT_DIR       Root directory to search (default: .)
  EXTENSIONS     Comma-separated file extensions, with or without leading dot.
                  Example: "cs,js"  or  ".py"
                  Default: cs
  OUTPUT_FILE    Output file to write concatenated results (default: all_files.txt)

Behavior:
  - Skips bin/, obj/, .venv/, .vs/, .vscode/
  - Skips generated files like *.g.cs or *.g.js
  - Handles filenames with spaces/newlines

Examples:
  ./concat.sh
  ./concat.sh ./src "cs,js" merged.txt
EOF
  exit 0
fi

###############################################################################
# Variable initialisation
###############################################################################

ROOT_DIR="${1:-.}"
EXTENSIONS_RAW="${2:-cs}"
OUTPUT_FILE="${3:-all_files.txt}"

# Normalize whitespace trimming
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

###############################################################################
# Extension parsing
###############################################################################

IFS=',' read -ra RAW_EXTS <<< "$EXTENSIONS_RAW"
EXTS=()

for e in "${RAW_EXTS[@]}"; do
  e="$(trim "$e")"
  [[ -z "$e" ]] && continue

  if [[ "$e" != .* ]]; then
    EXTS+=(".${e}")
  else
    EXTS+=("$e")
  fi
done

if [[ ${#EXTS[@]} -eq 0 ]]; then
  echo "No valid extensions provided." >&2
  exit 1
fi

###############################################################################
# Status output
###############################################################################

echo "Starting concatenation..."
echo "Root Directory: $ROOT_DIR"
echo "Extensions: ${EXTS[*]}"
echo "Output File: $OUTPUT_FILE"

# Clear output file
: > "$OUTPUT_FILE"

###############################################################################
# Build find command arguments
###############################################################################

FIND_ARGS=(
  "$ROOT_DIR"
  -type f

  # directory exclusions
  -not -path "*/bin/*"
  -not -path "*/obj/*"
  -not -path "*/.venv/*"
  -not -path "*/.vs/*"
  -not -path "*/.vscode/*"
)

# Skip generated files like *.g.cs
for ext in "${EXTS[@]}"; do
  FIND_ARGS+=(-not -name "*.g${ext}")
done

# Group the extension matches
FIND_ARGS+=("(")
first=true
for ext in "${EXTS[@]}"; do
  if $first; then
    FIND_ARGS+=(-name "*${ext}")
    first=false
  else
    FIND_ARGS+=(-o -name "*${ext}")
  fi
done
FIND_ARGS+=(")")

###############################################################################
# File processing loop (aligned with apply-file-instructions.sh style)
###############################################################################

while IFS= read -r -d '' file; do
  echo "Processing: $file"

  dir="$(dirname -- "$file")"
  base="$(basename -- "$file")"

  {
    printf "===== Folder: %s =====\n" "$dir"
    printf "===== File: %s =====\n" "$base"
    cat -- "$file"
    printf "\n"
  } >> "$OUTPUT_FILE"

done < <(find "${FIND_ARGS[@]}" -print0)

echo "Concatenation complete. Output written to $OUTPUT_FILE"
