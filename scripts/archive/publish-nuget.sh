#!/usr/bin/env bash
# Publish one or all NuGet packages using PWD as base.
# PackageVersion-first: we set /p:PackageVersion if provided; we never set Version.
#
# Usage:
#   ./publish-nuget.sh -o ulfbou -p src/Dx.Domain/Dx.Domain.csproj
#   ./publish-nuget.sh -o ulfbou -p Dx.Domain
#   ./publish-nuget.sh -o ulfbou --all
#   ./publish-nuget.sh -o ulfbou --all --search-path src
#   ./publish-nuget.sh -o ulfbou -p Dx.Domain -pv 0.1.0-alpha.3
#
# Env:
#   GH_PACKAGES_PAT (or GITHUB_TOKEN / NUGET_AUTH_TOKEN) must have write:packages (+ repo if private)

set -euo pipefail

OWNER=""
PROJECT=""
ALL=false
CONFIG="Release"
PKG_VERSION=""   # <-- PackageVersion override
DRYRUN=false
SEARCH_PATH="."   # relative to PWD

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--owner) OWNER="$2"; shift 2;;
    -p|--project) PROJECT="$2"; shift 2;;
    --all) ALL=true; shift;;
    -c|--configuration) CONFIG="$2"; shift 2;;
    -v|--version) echo "Use --package-version (or -pv). --version is deprecated."; exit 2;;
    -pv|--package-version) PKG_VERSION="$2"; shift 2;;
    --dry-run) DRYRUN=true; shift;;
    --search-path) SEARCH_PATH="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "${OWNER}" ]]; then
  echo "Missing --owner"; exit 1
fi

BASE_DIR="$(pwd)"
SEARCH_ROOT="${BASE_DIR}/${SEARCH_PATH}"

if [[ ! -d "$SEARCH_ROOT" ]]; then
  echo "Search path '${SEARCH_PATH}' does not exist under '${BASE_DIR}'." >&2
  exit 1
fi

TOKEN="${GH_PACKAGES_PAT:-${GITHUB_TOKEN:-${NUGET_AUTH_TOKEN:-}}}"
if [[ -z "${TOKEN}" ]]; then
  echo "Set GH_PACKAGES_PAT (or GITHUB_TOKEN/NUGET_AUTH_TOKEN) with write:packages (+ repo if needed)." >&2
  exit 1
fi

SOURCE="https://nuget.pkg.github.com/${OWNER}/index.json"
ARTIFACTS="${BASE_DIR}/.nupkgs"; mkdir -p "$ARTIFACTS"

resolve_project() {
  local p="$1"
  # Absolute/relative file path?
  if [[ -f "$p" ]]; then realpath "$p"; return; fi
  # Try ./<search-path>/src/<name>/<name>.csproj
  local cand="${SEARCH_ROOT}/src/${p}/${p}.csproj"
  if [[ -f "$cand" ]]; then echo "$cand"; return; fi
  # Fallback: search recursively from SEARCH_ROOT
  local found
  found="$(find "$SEARCH_ROOT" -type f -name "${p}.csproj" | head -n 1 || true)"
  if [[ -n "$found" ]]; then echo "$found"; return; fi
  echo "Could not resolve project '${p}' under search-root '${SEARCH_ROOT}'." >&2
  exit 1
}

pack_and_push() {
  local proj="$1"
  echo "Packing $proj ..."
  local args=(pack "$proj" -c "$CONFIG" -o "$ARTIFACTS" /p:ContinuousIntegrationBuild=true)
  [[ -n "$PKG_VERSION" ]] && args+=("/p:PackageVersion=$PKG_VERSION")
  dotnet "${args[@]}"

  shopt -s nullglob
  for nupkg in "$ARTIFACTS"/*.nupkg; do
    [[ "$nupkg" == *".symbols.nupkg" ]] && continue
    if $DRYRUN; then
      echo "Dry-run: would push $(basename "$nupkg")"
    else
      echo "Pushing $(basename "$nupkg") to $SOURCE ..."
      dotnet nuget push "$nupkg" -s "$SOURCE" -k "$TOKEN" --skip-duplicate
    fi
  done
}

if $ALL; then
  mapfile -t projects < <(find "$SEARCH_ROOT" -type f -name '*.csproj')
  if [[ ${#projects[@]} -eq 0 ]]; then
    echo "No .csproj found under '${SEARCH_ROOT}'." >&2
    exit 1
  fi
  for p in "${projects[@]}"; do pack_and_push "$p"; done
elif [[ -n "$PROJECT" ]]; then
  proj_path="$(resolve_project "$PROJECT")"
  pack_and_push "$proj_path"
else
  echo "Specify --project <path|name> or --all (optionally with --search-path <dir>)." >&2
  exit 1
fi
