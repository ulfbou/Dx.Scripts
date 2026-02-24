#!/usr/bin/env bash
# Lists all NuGet packages and all versions from GitHub Packages.
# Git Bash note: endpoints MUST NOT start with a leading slash.
# Usage:
#   ./gh-list-nuget.sh [OWNER] [SCOPE] [FORMAT]
#     OWNER  - account/org (default: ulfbou)
#     SCOPE  - user|org (default: user)
#     FORMAT - table|csv|json (default: table)

set -euo pipefail

OWNER="${1:-ulfbou}"
SCOPE="${2:-user}"    # user|org
FORMAT="${3:-table}"  # table|csv|json
BASE_DIR="$(pwd)"

# IMPORTANT: no leading slash here
if [[ "$SCOPE" == "org" ]]; then
  BASE="orgs/${OWNER}"
else
  BASE="users/${OWNER}"
fi

packages=$(gh api --paginate -H "Accept: application/vnd.github+json" \
  "${BASE}/packages?package_type=nuget" \
  --jq '.[].name')

if [[ -z "${packages}" ]]; then
  echo "No NuGet packages found for $SCOPE '${OWNER}'."
  exit 0
fi

rows_tmp="$(mktemp)"
while IFS= read -r pkg; do
  gh api --paginate -H "Accept: application/vnd.github+json" \
    "${BASE}/packages/nuget/${pkg}/versions" \
    --jq '.[] | [.name, .created_at, .updated_at] | @tsv' \
    | sed "s/^/${pkg}\t/"
done <<< "$packages" > "$rows_tmp"

case "$FORMAT" in
  table)
    printf "Package\tVersion\tCreatedAt\tUpdatedAt\n"
    column -t -s $'\t' "$rows_tmp"
    ;;
  csv)
    out="$BASE_DIR/packages.csv"
    printf "package,version,created_at,updated_at\n" > "$out"
    sed 's/\t/,/g' "$rows_tmp" >> "$out"
    echo "Wrote $out"
    ;;
  json)
    awk -F'\t' 'BEGIN{print "["}
      {printf "%s{\"package\":\"%s\",\"version\":\"%s\",\"created_at\":\"%s\",\"updated_at\":\"%s\"}",
              (NR==1?"":","), $1,$2,$3,$4}
      END{print "]"}' "$rows_tmp"
    ;;
  *)
    echo "Unknown FORMAT '$FORMAT'. Use table|csv|json." >&2
    exit 1
    ;;
esac

rm -f "$rows_tmp"
