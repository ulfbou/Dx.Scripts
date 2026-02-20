#!/usr/bin/env bash
set -euo pipefail

# gh-branch-commits-compact.sh (v1.2)
# Default: repo;branch;committed_at;subject;author_name;author_email;commit_sha
# Sekundärt: --topology (relationsinfo), --message full (subject+body).
# Robust: använder fulla ref-namn för logg, fetch-retry, MSYS-guard, debug/tracing, verify.

# --- Windows/MSYS path-conversion guard ---
case "$(uname -s)" in
  MINGW*|MSYS*) export MSYS2_ARG_CONV_EXCL="*";;
esac

# --- Standard ---
REPO=""
INFER=false
OUT_FILE="commits.csv"
DELIM=";"               # Excel i sv_SE
SINCE=""
UNTIL=""
WORKDIR=""
KEEP_WORKDIR=false
BRANCH_REGEX=""
MESSAGE_MODE="subject"  # subject | full
TOPOLOGY=false
BOM=false               # skriv UTF-8 BOM
DATE_FORMAT="iso"       # iso | local-human
DEBUG=false             # extra logg + GIT_TRACE
VERIFY=false            # kör git show-ref och ev. fsck

usage() {
  cat <<EOF
Usage: $0 --repo <owner/name> [options]

Options:
  --repo <owner/name>    Källa repo (t.ex. ulfnewton/QuizBattle). Eller --infer.
  --infer                Härled repo från aktuell katalog (GitHub-klon).
  --out <file|- >        Output-CSV (default: commits.csv). '-' = stdout.
  --sep <char>           Separator (default: ';').
  --since <date>         Från och med (YYYY-MM-DD eller ISO8601).
  --until <date>         Till och med (YYYY-MM-DD eller ISO8601).
  --branches-regex <re>  Matcha branchnamn (ex: '^teaching/|^feature/').
  --message subject|full 'subject' (default) eller 'full' (subject+body i samma cell).
  --topology             Relationsfält (is_merge, parent_count, parent_shas, also_in_branches,
                         merge_guess_from, merge_guess_to).
  --bom                  Skriv UTF-8 BOM (om Excel kräver).
  --date-format iso|local-human
  --workdir <dir>        Arbetskatalog för mirror-klon.
  --keep-workdir         Behåll arbetskatalogen (felsök).
  --debug                Extra logg + GIT_TRACE*; behåller arbetskatalogen automatiskt.
  --verify               Sammanfattar refs och kör 'git fsck --full' (kan ta tid).
  -h, --help             Visa hjälp.
EOF
}

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --infer) INFER=true; shift ;;
    --out) OUT_FILE="$2"; shift 2 ;;
    --sep) DELIM="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    --branches-regex) BRANCH_REGEX="$2"; shift 2 ;;
    --message) MESSAGE_MODE="$2"; shift 2 ;;
    --topology) TOPOLOGY=true; shift ;;
    --bom) BOM=true; shift ;;
    --date-format) DATE_FORMAT="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --keep-workdir) KEEP_WORKDIR=true; shift ;;
    --debug) DEBUG=true; KEEP_WORKDIR=true; shift ;;
    --verify) VERIFY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Okänt argument: $1" >&2; usage; exit 1 ;;
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

debug() { $DEBUG && printf "[debug] %s\n" "$*" >&2; }

# Tracing för Git vid debug
if $DEBUG; then
  export GIT_TRACE=1 GIT_TRACE_PACKET=1 GIT_TRACE_PACK_ACCESS=1 GIT_TRACE_PERFORMANCE=1
  export GIT_CURL_VERBOSE=1
fi

# --- Repo-härledning ---
if $INFER && [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
[[ -z "$REPO" ]] && { echo "Ange --repo <owner/name> eller använd --infer." >&2; exit 1; }

# --- Repo-info (utan ledande slash i endpoint) ---
REPO_JSON="$(gh api "repos/${REPO}")"
SSH_URL="$(jq -r '.ssh_url' <<<"$REPO_JSON")"
FULL_NAME="$(jq -r '.full_name' <<<"$REPO_JSON")"
debug "FULL_NAME=$FULL_NAME"
debug "SSH_URL=$SSH_URL"

# --- Arbetskatalog ---
CLEANUP=true
if [[ -z "${WORKDIR}" ]]; then
  WORKDIR="$(mktemp -d -t gh-branch-commits.XXXXXX)"
else
  mkdir -p "$WORKDIR"
  CLEANUP=false
fi
$KEEP_WORKDIR && CLEANUP=false
cleanup() { $CLEANUP && { debug "Rensar arbetskatalog $WORKDIR"; rm -rf "$WORKDIR"; }; }
trap cleanup EXIT

# --- Klona som mirror/bare + fetch-retry ---
GITDIR="${WORKDIR}/$(basename "$REPO").git"

clone_or_update() {
  if [[ -d "$GITDIR" ]]; then
    debug "Uppdaterar befintlig mirror: $GITDIR"
  else
    debug "Klona mirror: $SSH_URL -> $GITDIR"
    git clone --mirror "$SSH_URL" "$GITDIR" -q
  fi

  # Säkerställ bred fetchspec i mirror (brukar redan finnas, men vi sätter ändå)
  git --git-dir="$GITDIR" config remote.origin.fetch "+refs/*:refs/*" || true

  local tries=0
  local ok=false
  while [[ $tries -lt 3 ]]; do
    tries=$((tries+1))
    debug "Fetch-försök $tries/3 (--all --tags --prune --force)"
    if git --git-dir="$GITDIR" fetch --all --tags --prune --force -q; then
      ok=true; break
    else
      sleep $((tries*2))
    fi
  done
  if ! $ok; then
    echo "[varning] fetch misslyckades efter 3 försök – fortsätter ändå." >&2
  fi
}

clone_or_update

# --- Verify (valfritt) ---
if $VERIFY; then
  debug "Räknar refs och kör fsck --full (kan ta tid)."
  heads=$(git --git-dir="$GITDIR" for-each-ref refs/heads --format='%(refname)' | wc -l | tr -d ' ')
  rems=$(git --git-dir="$GITDIR" for-each-ref refs/remotes --format='%(refname)' | wc -l | tr -d ' ')
  tags=$(git --git-dir="$GITDIR" for-each-ref refs/tags --format='%(refname)' | wc -l | tr -d ' ')
  printf "[verify] refs: heads=%s remotes=%s tags=%s\n" "$heads" "$rems" "$tags" >&2
  if ! git --git-dir="$GITDIR" fsck --full >&2; then
    echo "[varning] git fsck hittade problem." >&2
  fi
fi

# --- Branchlista: mappa kortnamn -> fullref (föredra remotes/origin/* vid krock) ---
declare -A REF_BY_SHORT
declare -A SOURCE_KIND  # heads|remotes

# heads först (så att remotes får skriva över senare)
while IFS= read -r line; do
  fullref="${line%% *}"; short="${line#* }"
  REF_BY_SHORT["$short"]="$fullref"
  SOURCE_KIND["$short"]="heads"
done < <(git --git-dir="$GITDIR" for-each-ref --format='%(refname) %(refname:short)' refs/heads)

# remotes/origin – ersätter ev. heads med samma kortnamn
while IFS= read -r line; do
  fullref="${line%% *}"; short="${line#* }"
  [[ "$short" == "HEAD" ]] && continue
  # Normalisera kortnamn: ta bort 'origin/' prefix i display, men fullref behålls
  short="${short#origin/}"
  REF_BY_SHORT["$short"]="$fullref"
  SOURCE_KIND["$short"]="remotes"
done < <(git --git-dir="$GITDIR" for-each-ref --format='%(refname) %(refname:short)' refs/remotes/origin)

# Filtrera regex och sortera kortnamn
mapfile -t SHORTS < <(printf "%s\n" "${!REF_BY_SHORT[@]}" | sort)
if [[ -n "$BRANCH_REGEX" ]]; then
  mapfile -t SHORTS < <(printf "%s\n" "${SHORTS[@]}" | grep -E "$BRANCH_REGEX" || true)
fi

if [[ ${#SHORTS[@]} -eq 0 ]]; then
  echo "Inga branches hittades i $FULL_NAME." >&2
  exit 0
fi

# --- CSV helpers ---
csv_escape() { local s="${1:-}"; s="${s//\"/\"\"}"; printf '"%s"' "$s"; }

write_header_default() {
  {
    csv_escape "repo"; printf "%s" "$DELIM"
    csv_escape "branch"; printf "%s" "$DELIM"
    csv_escape "committed_at"; printf "%s" "$DELIM"
    csv_escape "subject"; printf "%s" "$DELIM"
    csv_escape "author_name"; printf "%s" "$DELIM"
    csv_escape "author_email"; printf "%s" "$DELIM"
    csv_escape "commit_sha"
    $TOPOLOGY && printf "%s" "$DELIM" && csv_escape "is_merge" \
                     && printf "%s" "$DELIM" && csv_escape "parent_count" \
                     && printf "%s" "$DELIM" && csv_escape "parent_shas" \
                     && printf "%s" "$DELIM" && csv_escape "also_in_branches" \
                     && printf "%s" "$DELIM" && csv_escape "merge_guess_from" \
                     && printf "%s" "$DELIM" && csv_escape "merge_guess_to"
    printf "\n"
  } >> "$1"
}

write_row_default() {
  local out="$1" repo="$2" br="$3" committed="$4" subj="$5" an="$6" ae="$7" sha="$8"
  {
    csv_escape "$repo"; printf "%s" "$DELIM"
    csv_escape "$br"; printf "%s" "$DELIM"
    csv_escape "$committed"; printf "%s" "$DELIM"
    csv_escape "$subj"; printf "%s" "$DELIM"
    csv_escape "$an"; printf "%s" "$DELIM"
    csv_escape "$ae"; printf "%s" "$DELIM"
    csv_escape "$sha"
  } >> "$out"
}

append_topology_fields() {
  local out="$1" is_merge="$2" parent_count="$3" parent_shas="$4" also_in="$5" from="$6" to="$7"
  {
    printf "%s" "$DELIM"; csv_escape "$is_merge"
    printf "%s" "$DELIM"; csv_escape "$parent_count"
    printf "%s" "$DELIM"; csv_escape "$parent_shas"
    printf "%s" "$DELIM"; csv_escape "$also_in"
    printf "%s" "$DELIM"; csv_escape "$from"
    printf "%s" "$DELIM"; csv_escape "$to"
    printf "\n"
  } >> "$out"
}

# --- Output init (tempfil för att undvika låsningsproblem) ---
OUT_TO_STDOUT=false
if [[ "$OUT_FILE" == "-" ]]; then
  OUT_TO_STDOUT=true
  TMP_OUT="$(mktemp)"
else
  OUT_DIR="$(dirname -- "$OUT_FILE")"
  BASE_NAME="$(basename -- "$OUT_FILE")"
  mkdir -p "$OUT_DIR"
  TMP_OUT="$(mktemp -p "$OUT_DIR" ".tmp.${BASE_NAME}.XXXXXX")"
fi

# --- BOM ev. ---
$BOM && printf '\xEF\xBB\xBF' >> "$TMP_OUT"

# --- Header ---
write_header_default "$TMP_OUT"

# --- Datumformat ---
DATE_PRETTY="%cI"; DATE_ARGS=()
if [[ "$DATE_FORMAT" == "local-human" ]]; then
  DATE_PRETTY="%cd"; DATE_ARGS=(--date=iso-local)
fi

# --- Export per branch (äldst -> nyast) ---
for SHORT in "${SHORTS[@]}"; do
  FULLREF="${REF_BY_SHORT[$SHORT]}"

  # Verifiera att ref finns (undviker "fatal: bad object <branch>")
  if ! git --git-dir="$GITDIR" rev-parse --verify -q "$FULLREF" >/dev/null; then
    printf "[varning] hoppar branch '%s' – saknar objekt för %s\n" "$SHORT" "$FULLREF" >&2
    continue
  fi

  # Pretty-format: separera fält med 0x1f, records med 0x1e
  PRETTY="%H%x1f%P%x1f%aN%x1f%aE%x1f${DATE_PRETTY}%x1f%s%x1f%b%x1e"
  ARGS=(log "$FULLREF" "${DATE_ARGS[@]}" --reverse --no-decorate --pretty=format:${PRETTY})
  [[ -n "$SINCE" ]] && ARGS+=(--since="$SINCE")
  [[ -n "$UNTIL" ]] && ARGS+=(--until="$UNTIL")

  # Kör logg
  while IFS= read -r -d $'\x1e' REC; do
    [[ -z "$REC" ]] && continue
    IFS=$'\x1f' read -r SHA PARENTS AN AE CMTD SUBJECT BODY <<<"$REC"

    # Välj message enligt mode
    MSG="$SUBJECT"
    if [[ "$MESSAGE_MODE" == "full" && -n "$BODY" ]]; then
      MSG="${SUBJECT}"$'\n\n'"${BODY}"
    fi

    # Default-rad
    write_row_default "$TMP_OUT" "$FULL_NAME" "$SHORT" "$CMTD" "$MSG" "$AN" "$AE" "$SHA"

    if $TOPOLOGY; then
      parent_shas="$PARENTS"; parent_count=0
      if [[ -n "$PARENTS" ]]; then
        arr=($PARENTS); parent_count=${#arr[@]}
      fi
      is_merge="false"; [[ $parent_count -gt 1 ]] && is_merge="true"

      also_in="$(git --git-dir="$GITDIR" branch --contains "$SHA" --all 2>/dev/null \
        | sed -E 's/^[* ]+//' \
        | sed -E 's|^remotes/origin/||; s|^origin/||; s|^heads/||; s|^remotes/||' \
        | grep -v '^HEAD$' \
        | grep -v "^${SHORT}$" || true \
        | sort -u | paste -sd',' -)"

      from_guess=""; to_guess=""
      if printf '%s\n' "$SUBJECT" | grep -qiE '^merge '; then
        if [[ "$SUBJECT" =~ [Mm]erge\ branch\ \'([^\']+)\'\ into\ ([^[:space:]]+) ]]; then
          from_guess="${BASH_REMATCH[1]}"; to_guess="${BASH_REMATCH[2]}"
        elif [[ "$SUBJECT" =~ [Mm]erge\ pull\ request\ #[0-9]+\ from\ [^/]+/([^[:space:]]+) ]]; then
          from_guess="${BASH_REMATCH[1]}"
        elif [[ "$SUBJECT" =~ [Mm]erge\ remote-tracking\ branch\ \'origin/([^\']+)\'\ into\ ([^[:space:]]+) ]]; then
          from_guess="${BASH_REMATCH[1]}"; to_guess="${BASH_REMATCH[2]}"
        fi
      fi

      append_topology_fields "$TMP_OUT" "$is_merge" "$parent_count" "$parent_shas" "${also_in:-}" "${from_guess:-}" "${to_guess:-}"
    else
      printf "\n" >> "$TMP_OUT"
    fi
  done < <(git --git-dir="$GITDIR" "${ARGS[@]}" || true)
done

# --- Skriv ut/skriv färdigt ---
if $OUT_TO_STDOUT; then
  cat "$TMP_OUT"
  rm -f "$TMP_OUT"
else
  if mv -f "$TMP_OUT" "$OUT_FILE" 2>/dev/null; then
    echo "[info] CSV skriven till: $OUT_FILE"
  else
    echo "[varning] Kunde inte skriva till '$OUT_FILE' (låst av Excel?)."
    echo "[info] Din export finns här: $TMP_OUT"
    echo "[info] Stäng filen i Excel och byt namn:"
    echo "       mv '$TMP_OUT' '$OUT_FILE'"
  fi
fi

$KEEP_WORKDIR || { debug "Tar bort $WORKDIR"; rm -rf "$WORKDIR"; echo "[info] Arbetskatalog togs bort."; }
