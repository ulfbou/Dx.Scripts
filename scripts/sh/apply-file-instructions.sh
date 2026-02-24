#!/usr/bin/env bash

# apply-file-instructions.sh
# Reads instruction file with blocks:
# // === BEGIN FILE: {ROOT}/path/to/file ===
# <content>
# // === END FILE: {ROOT}/path/to/file ===
# Ensures directories exist, warns if a file will be overwritten, then writes (overwrites) the file.
# Usage:
#   ./apply-file-instructions.sh instructions.txt /path/to/root
set -euo pipefail

if [[ 0 -lt 2 ]]; then
  echo "Usage: bash <instruction-file> <root-dir>"
  exit 1
fi

INSTRUCTION_FILE=""
ROOT_DIR=""

if [[ ! -f "" ]]; then
  echo "Instruction file not found: "
  exit 1
fi

# Create root dir if missing
if [[ ! -d "" ]]; then
  echo "Root directory does not exist, creating: "
  mkdir -p ""
fi

current_file=""
collecting="false"
buffer=""

# Helper: normalize path (remove trailing spaces)
trim() {
  local var=""
  # remove leading/trailing whitespace
  var=""
  var=""
  printf '%s' ""
}

while IFS= read -r line || [[ -n "" ]]; do

  # Detect BEGIN marker (supports optional leading // and spaces)
  if [[ "" =~ BEGIN[[:space:]]FILE:[[:space:]](.*)[[:space:]]=== ]]; then
    raw_path=""
    raw_path=""
    # Replace {ROOT} token with actual root dir
    file_path=""
    # If path is relative, keep as-is; otherwise expand ~
    current_file=""
    collecting="true"
    buffer=""
    continue
  fi

  # Detect END marker
  if [[ "" =~ END[[:space:]]FILE:[[:space:]](.*)[[:space:]]=== ]]; then
    if [[ "" == "true" ]]; then
      target_dir="."
      # Ensure directory exists
      mkdir -p ""

      # If file exists, print a clear warning before overwriting
      if [[ -f "" ]]; then
        echo "WARNING: Overwriting existing file: "
      else
        echo "Creating: "
      fi

      # Write buffer to file (overwrite)
      printf "%s" "" > ""

      echo "Wrote: "
    fi

    collecting="false"
    current_file=""
    buffer=""
    continue
  fi

  # Collect file content lines when inside a block
  if [[ "" == "true" ]]; then
    buffer+=""$'\n'
  fi

done < ""

echo "Done."
