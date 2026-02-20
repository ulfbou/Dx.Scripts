#!/bin/bash

# Usage: ./manage_sln_projects.sh add|remove

ACTION="$1"

if [[ "$ACTION" != "add" && "$ACTION" != "remove" ]]; then
  echo "Usage: $0 add|remove"
  exit 1
fi

# Find all .sln files
find . -type f -name "*.sln" | while read -r SLN_PATH; do
  SLN_DIR=$(dirname "$SLN_PATH")

  echo "Processing solution: $SLN_PATH"

  # Find all .csproj files under the solution directory
  find "$SLN_DIR" -type f -name "*.csproj" | while read -r CSPROJ_PATH; do
    echo "  $ACTION project: $CSPROJ_PATH"
    dotnet sln "$SLN_PATH" "$ACTION" "$CSPROJ_PATH"
  done
done
