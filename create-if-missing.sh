#!/bin/bash

# Usage: ./create-if-missing.sh Zentient.MyNewRepo "Optional description here"

# GitHub username or org
OWNER="ulfbou"

# Repo name from first argument
REPO_NAME="$1"

# Optional description
DESCRIPTION="${2:-"$REPO_NAME repository"}"

# Check if repo exists
if gh repo view "$OWNER/$REPO_NAME" &>/dev/null; then
  echo "✅ Repository '$OWNER/$REPO_NAME' already exists."
else
  echo "🚀 Creating repository '$OWNER/$REPO_NAME'..."
  gh repo create "$OWNER/$REPO_NAME" --public --description "$DESCRIPTION" --add-readme
  echo "🎉 Repository created: https://github.com/$OWNER/$REPO_NAME"
fi
