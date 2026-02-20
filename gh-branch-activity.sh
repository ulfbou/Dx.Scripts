#!/usr/bin/env bash
set -euo pipefail

# gh-branch-activity.sh (v2)
# Skannar dina GitHub-repos och alla branches för aktivitetsperioder.
# Output: CSV/SCV med header-rad och valfri separator (default ';').

# --- Standardinställningar ---
OUT_FILE="branch-activity.csv"
NAME_REGEX=""
INCLUDE_FORKS=false
INCLUDE_ARCHIVED=false
SCOPE="me"              # me | owner:<user> | org:<org>
MODE="full"             # full | fast
SINCE=""                # YYYY-MM-DD
WORKDIR=""              # tillfällig arbetskatalog; auto om tom
KEEP_WORKDIR=false      # behåll klonerna (mirror) efter körning
DELIM=";"               # CSV-separator: använd ';' för Excel i sv_SE

# --- Hjälp ---
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --out <file>           Sökväg till CSV (default: branch-activity.csv)
  --name-regex <regex>   Endast repos vars namn matchar regex
  --include-forks        Ta med forkade repos
  --include-archived     Ta med arkiverade repos
  --scope me             (default) /user/repos affiliation=owner,collaborator,organization_member
  --scope owner:<user>   Begränsa till specifik användare
  --scope org:<org>      Begränsa till specifik org
  --mode full|fast       full = exakta first/last; fast = uppskattar "first"
  --since YYYY-MM-DD     Begränsa analysen tidsmässigt
  --workdir <dir>        Arbetskatalog för mirror-kloner
  --keep-workdir         Behåll arbetskatalogen efter körning
  --sep <char>           Separator för CSV (default: ';')
  -h, --help             Visa hjälp

Exempel:
  $0 --out activity.csv
  $0 --sep ';' --out excel-friendly.csv
  $0 --scope owner:ulfnewton --since 2025-08-01
EOF
}

# --- Argumentparsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_FILE="$2"; shift 2 ;;
    --name-regex) NAME_REGEX="$2"; shift 2 ;;
    --include-forks) INCLUDE_FORKS=true; shift ;;
    --include-archived) INCLUDE_ARCHIVED=true; shift ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --keep-workdir) KEEP_WORKDIR=true; shift ;;
    --sep) DELIM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Okänt argument: $1"; usage; exit 1 ;;
  esac
done

# --- Beroenden ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Saknar beroende: $1" >&2; exit 1; }; }
need gh
need git
need jq

if ! gh auth status >/dev/null 2>&1; then
  echo "Du verkar inte vara inloggad i gh. Kör: gh auth login" >&2
  exit 1
fi

# --- Arbetskatalog ---
CLEANUP=true
if [[ -z "${WORKDIR}" ]]; then
  WORKDIR="$(mktemp -d -t gh-branch-activity.XXXXXX)"
else
  mkdir -p "$WORKDIR"
  CLEANUP=false
fi
if $KEEP_WORKDIR; then CLEANUP=false; fi
cleanup() { if $CLEANUP; then rm -rf "$WORKDIR"; fi; }
trap cleanup EXIT

# --- CSV/SCV-hjälp ---
csv_escape() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}
csv_header() {
  printf "%s\n" "$(IFS="$DELIM"; echo \
"repo${DELIM}branch${DELIM}first_commit${DELIM}last_commit${DELIM}commit_count${DELIM}active_months${DELIM}default_branch${DELIM}archived${DELIM}private${DELIM}fork${DELIM}html_url")"
}

# Skriv header EN gång
: > "$OUT_FILE"
csv_header >> "$OUT_FILE"

info()  { printf "[info] %s\n" "$*" >&2; }
warn()  { printf "[varning] %s\n" "$*" >&2; }

# --- Hämta repos ---
fetch_repos() {
  case "$SCOPE" in
    me)
      gh api --paginate '/user/repos?per_page=100&affiliation=owner,collaborator,organization_member'
      ;;
    owner:*)
      local user="${SCOPE#owner:}"
      gh api --paginate "/users/${user}/repos?per_page=100&type=all&sort=updated"
      ;;
    org:*)
      local org="${SCOPE#org:}"
      gh api --paginate "/orgs/${org}/repos?per_page=100&type=all&sort=updated"
      ;;
    *)
      echo "Ogiltig --scope: $SCOPE" >&2; exit 1 ;;
  esac
}

# --- Filtrera repos ---
filter_repos() {
  local jq_filter='.[] | {
    full_name: .full_name,
    name: .name,
    private: .private,
    archived: .archived,
    fork: .fork,
    default_branch: .default_branch,
    ssh_url: .ssh_url,
    html_url: .html_url
  }'

  if [[ -n "$NAME_REGEX" ]]; then
    jq_filter="${jq_filter} | select(.name | test(\"$NAME_REGEX\"))"
  fi
  if ! $INCLUDE_FORKS; then
    jq_filter="${jq_filter} | select(.fork == false)"
  fi
  if ! $INCLUDE_ARCHIVED; then
    jq_filter="${jq_filter} | select(.archived == false)"
  fi

  jq -r "[ ${jq_filter} ]"
}

# --- Mirror-klon & uppdatering ---
ensure_mirror_clone() {
  local ssh_url="$1"
  local dest="$2"
  if [[ -d "$dest" ]]; then
    # Mest kompatibel uppdatering över Git-versioner
    git --git-dir="$dest" fetch --all --prune -q || true
    return
  fi
  # Klona med git direkt (undviker ev. gh-CLI-flaggningsskillnader)
  git clone --mirror "$ssh_url" "$dest" -q
  # Direkt fetch för säkerhets skull
  git --git-dir="$dest" fetch --all --prune -q || true
}

# --- Analysfunktioner ---
analyze_branch_full() {
  local gitdir="$1"
  local branch="$2"
  local first last count months

  if [[ -n "$SINCE" ]]; then
    first="$(git --git-dir="$gitdir" log "$branch" --since="$SINCE" --format=%cI --reverse | head -n1 || true)"
    last="$(git --git-dir="$gitdir" log "$branch" --since="$SINCE" -1 --format=%cI || true)"
    count="$(git --git-dir="$gitdir" rev-list --count --since="$SINCE" "$branch" || echo 0)"
    months="$(git --git-dir="$gitdir" log "$branch" --since="$SINCE" --format=%cI | cut -c1-7 | sort -u | paste -sd' ' - || true)"
  else
    first="$(git --git-dir="$gitdir" log "$branch" --format=%cI --reverse | head -n1 || true)"
    last="$(git --git-dir="$gitdir" log "$branch" -1 --format=%cI || true)"
    count="$(git --git-dir="$gitdir" rev-list --count "$branch" || echo 0)"
    months="$(git --git-dir="$gitdir" log "$branch" --format=%cI | cut -c1-7 | sort -u | paste -sd' ' - || true)"
  fi

  echo "$first|$last|${count:-0}|$months"
}

analyze_branch_fast() {
  local gitdir="$1"
  local branch="$2"
  local last count months first

  if [[ -n "$SINCE" ]]; then
    last="$(git --git-dir="$gitdir" log "$branch" --since="$SINCE" -1 --format=%cI || true)"
    count="$(git --git-dir="$gitdir" rev-list --count --since="$SINCE" "$branch" || echo 0)"
    months="$(git --git-dir="$gitdir" log "$branch" --since="$SINCE" --format=%cI | cut -c1-7 | sort -u | paste -sd' ' - || true)"
  else
    last="$(git --git-dir="$gitdir" log "$branch" -1 --format=%cI || true)"
    count="$(git --git-dir="$gitdir" rev-list --count "$branch" || echo 0)"
    months="$(git --git-dir="$gitdir" log "$branch" --format=%cI | cut -c1-7 | sort -u | paste -sd' ' - || true)"
  fi

  if [[ -n "$months" ]]; then
    local first_month
    first_month="$(tr ' ' '\n' <<<"$months" | head -n1)"
    first="${first_month}-01T00:00:00Z"
  else
    first=""
  fi
  echo "$first|$last|${count:-0}|$months"
}

# --- Körning ---
REPOS_JSON="$(fetch_repos)"
FILTERED="$(printf '%s' "$REPOS_JSON" | filter_repos)"

REPO_COUNT="$(printf '%s' "$FILTERED" | jq 'length')"
info "Hittade $REPO_COUNT repos i scope '$SCOPE' (efter filter)."

printf '%s' "$FILTERED" | jq -c '.[]' | while read -r repo; do
  full_name="$(jq -r '.full_name' <<<"$repo")"
  name="$(jq -r '.name' <<<"$repo")"
  private="$(jq -r '.private' <<<"$repo")"
  archived="$(jq -r '.archived' <<<"$repo")"
  fork="$(jq -r '.fork' <<<"$repo")"
  default_branch="$(jq -r '.default_branch' <<<"$repo")"
  html_url="$(jq -r '.html_url' <<<"$repo")"
  ssh_url="$(jq -r '.ssh_url' <<<"$repo")"

  safe_dir="${name//[^A-Za-z0-9._-]/_}.git"
  gitdir="${WORKDIR}/${safe_dir}"

  info "Repo: $full_name (archived=${archived}, private=${private}, fork=${fork})"
  ensure_mirror_clone "$ssh_url" "$gitdir"

  # Samla alla branch-namn: både refs/heads/* och refs/remotes/origin/*
  mapfile -t branches < <(
    {
      git --git-dir="$gitdir" for-each-ref --format='%(refname:short)' refs/heads;
      git --git-dir="$gitdir" for-each-ref --format='%(refname:short)' refs/remotes/origin;
    } 2>/dev/null | sed -E 's|^origin/||' | grep -v '^HEAD$' | sort -u
  )

  if [[ ${#branches[@]} -eq 0 ]]; then
    warn "Inga branches i $full_name – hoppar vidare."
    continue
  fi

  for br in "${branches[@]}"; do
    local_result=""
    if [[ "$MODE" == "full" ]]; then
      local_result="$(analyze_branch_full "$gitdir" "$br")"
    else
      local_result="$(analyze_branch_fast "$gitdir" "$br")"
    fi
    IFS='|' read -r first_commit last_commit commit_count months <<<"$local_result"

    # Skriv rad
    {
      csv_escape "$full_name"; printf "%s" "$DELIM"
      csv_escape "$br"; printf "%s" "$DELIM"
      csv_escape "${first_commit:-}"; printf "%s" "$DELIM"
      csv_escape "${last_commit:-}"; printf "%s" "$DELIM"
      csv_escape "${commit_count:-0}"; printf "%s" "$DELIM"
      csv_escape "${months:-}"; printf "%s" "$DELIM"
      csv_escape "$default_branch"; printf "%s" "$DELIM"
      csv_escape "$archived"; printf "%s" "$DELIM"
      csv_escape "$private"; printf "%s" "$DELIM"
      csv_escape "$fork"; printf "%s" "$DELIM"
      csv_escape "$html_url"; printf "\n"
    } >> "$OUT_FILE"
  done
done

info "Klart. CSV skriven till: $OUT_FILE"
if ! $KEEP_WORKDIR; then
  info "Arbetskatalog togs bort: $WORKDIR"
else
  info "Arbetskatalog behålls: $WORKDIR"
fi
