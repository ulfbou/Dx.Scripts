#!/bin/bash

# Usage: ./create-subtree.sh Zentient.MySubRepo "Subtree description" destination-folder

# GitHub username or org
OWNER="ulfbou"

# Arguments
REPO_NAME="$1"
DESCRIPTION="${2:-"$REPO_NAME subtree"}"
DEST_FOLDER="$3"

# Validate input
if [[ -z "$REPO_NAME" || -z "$DEST_FOLDER" ]]; then
  echo "❌ Usage: $0 <repo-name> \"description\" <destination-folder>"
  exit 1
fi

REPO_PATH="$OWNER/$REPO_NAME"
REPO_URL="https://github.com/$REPO_PATH.git"

# Check if repo exists
if gh repo view "$REPO_PATH" &>/dev/null; then
  echo "✅ Repository '$REPO_PATH' already exists."
else
  echo "🚀 Creating repository '$REPO_PATH'..."
  gh repo create "$REPO_PATH" --public --description "$DESCRIPTION" --add-readme
  echo "🎉 Repository created: $REPO_URL"
fi

# Check for clean working tree
if ! git diff-index --quiet HEAD --; then
  echo "❌ Cannot add subtree: working tree has uncommitted changes."
  echo "💡 Tip: Commit or stash your changes before running this script."
  exit 1
fi

# Add subtree
echo "🌱 Adding subtree '$REPO_NAME' to '$DEST_FOLDER'..."
git subtree add --prefix="$DEST_FOLDER" "$REPO_URL" main --squash

echo "✅ Subtree '$REPO_NAME' added under ./$DEST_FOLDER"
