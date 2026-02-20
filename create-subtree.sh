#!/bin/bash

# Usage: ./create-subtree.sh <repo-name> <destination-path> [branch]
# Example: ./create-subtree.sh Zentient.DependencyInjection configuration/dependency-injection master

OWNER="ulfbou"
REPO_NAME="$1"
DEST_PATH="$2"
BRANCH="${3:-main}"  # Defaults to 'main' if not provided
REPO_URL="https://github.com/$OWNER/$REPO_NAME.git"

# Validate input
if [[ -z "$REPO_NAME" || -z "$DEST_PATH" ]]; then
  echo "❌ Usage: $0 <repo-name> <destination-path> [branch]"
  exit 1
fi

# Check if repo exists
if gh repo view "$OWNER/$REPO_NAME" &>/dev/null; then
  echo "✅ Repository '$OWNER/$REPO_NAME' exists."
else
  echo "🚀 Creating repository '$OWNER/$REPO_NAME'..."
  gh repo create "$OWNER/$REPO_NAME" --public --description "$REPO_NAME subtree" --add-readme
  echo "🎉 Repository created: $REPO_URL"
fi

# Ensure working tree is clean
if ! git diff-index --quiet HEAD --; then
  echo "❌ Working tree has uncommitted changes. Please commit or stash before proceeding."
  exit 1
fi

# Add subtree
echo "🌱 Adding subtree '$REPO_NAME' from branch '$BRANCH' to '$DEST_PATH'..."
git subtree add --prefix="$DEST_PATH" "$REPO_URL" "$BRANCH" --squash

echo "✅ Subtree '$REPO_NAME' added under ./$DEST_PATH from branch '$BRANCH'"
