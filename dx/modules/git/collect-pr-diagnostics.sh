#!/usr/bin/env bash
# collect-pr-diagnostics.sh
# DX-first PR diagnostics bundle collector for AI analysis.
# Requires: git, gh, dotnet
# Optional: tar (usually available), gzip
#
# Usage examples:
#   ./collect-pr-diagnostics.sh --pr 123
#   ./collect-pr-diagnostics.sh --pr 123 --solution MyApp.sln --binlog
#   ./collect-pr-diagnostics.sh --pr 123 --no-test
#   ./collect-pr-diagnostics.sh --pr 123 --configuration Release --framework net8.0
#
# Output:
#   ./pr-diagnostics-<repo>-pr-<n>-<timestamp>.tar.gz

set -euo pipefail

#######################################
# Pretty logging
#######################################
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; DIM=$'\e[2m'; RST=$'\e[0m'

log()  { echo "${BLU}==>${RST} $*"; }
ok()   { echo "${GRN}OK:${RST} $*"; }
warn() { echo "${YLW}WARN:${RST} $*" >&2; }
err()  { echo "${RED}ERR:${RST} $*" >&2; }

die() { err "$*"; exit 1; }

#######################################
# Defaults
#######################################
PR_NUMBER=""
SOLUTION_PATH=""
CONFIGURATION="Debug"
FRAMEWORK=""
RUNTIME=""
NO_BUILD=0
NO_TEST=0
NO_RESTORE=0
NO_WORKFLOW_LOGS=0
DO_BINLOG=0
DO_FORMAT=0
DO_PACKAGES=1
DO_VULNS=1
REDACT=1
EXTRA_CONTEXT=""
OUT_DIR=""
KEEP_DIR=0
MAX_LOG_BYTES=$((25 * 1024 * 1024))   # cap huge logs at ~25MB per file

#######################################
# Helpers
#######################################
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

now_stamp() {
  date +"%Y%m%d-%H%M%S"
}

repo_slug() {
  # Try gh first; fallback to parsing git remote
  if gh repo view --json nameWithOwner -q .nameWithOwner >/dev/null 2>&1; then
    gh repo view --json nameWithOwner -q .nameWithOwner
    return
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "${url}" ]] || { echo "unknown/unknown"; return; }
  url="${url%.git}"
  # handle https://github.com/owner/repo or git@github.com:owner/repo
  if [[ "$url" =~ github\.com[:/]{1}([^/]+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    echo "unknown/unknown"
  fi
}

mkdirp() { mkdir -p "$1"; }

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf "%s\n" "$*" > "$path"
}

run_capture() {
  # run_capture <outfile> <command...>
  local outfile="$1"; shift
  mkdir -p "$(dirname "$outfile")"
  {
    echo "# Command: $*"
    echo "# Timestamp: $(date -Iseconds)"
    echo
    "$@"
  } > "$outfile" 2>&1 || {
    warn "Command failed (captured to $outfile): $*"
    return 1
  }
}

truncate_if_huge() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local size
  size=$(wc -c <"$f" | tr -d ' ')
  if (( size > MAX_LOG_BYTES )); then
    warn "Truncating huge file: $f ($(printf "%'.0f" "$size") bytes)"
    # Keep head+tail, preserve usefulness
    local head_bytes=$((MAX_LOG_BYTES / 2))
    local tail_bytes=$((MAX_LOG_BYTES / 2))
    local tmp="${f}.tmp"
    {
      echo "### TRUNCATED: file exceeded ${MAX_LOG_BYTES} bytes ###"
      echo "### HEAD (${head_bytes} bytes) ###"
      head -c "$head_bytes" "$f"
      echo
      echo "### TAIL (${tail_bytes} bytes) ###"
      tail -c "$tail_bytes" "$f"
    } > "$tmp"
    mv "$tmp" "$f"
  fi
}

redact_inplace() {
  # Best-effort redaction. Not perfect; still review before sharing.
  # Redacts common tokens/secrets patterns in text files.
  local f="$1"
  [[ -f "$f" ]] || return 0

  # Only attempt on "likely text" extensions to avoid corrupting binaries
  case "$f" in
    *.json|*.txt|*.log|*.md|*.yml|*.yaml|*.xml|*.config|*.ini|*.props|*.targets|*.trx|*.csproj|*.sln)
      ;;
    *)
      return 0
      ;;
  esac

  # GitHub tokens: ghp_, gho_, ghs_, ghu_, github_pat_
  # Azure DevOps PATs and generic bearer tokens patterns are harder; keep conservative.
  # Connection strings: Password=..., Pwd=..., SharedAccessKey=...
  sed -i.bak -E \
    -e 's/(gh[pous]_[A-Za-z0-9_]{20,})/[REDACTED_GH_TOKEN]/g' \
    -e 's/(github_pat_[A-Za-z0-9_]{20,})/[REDACTED_GH_PAT]/g' \
    -e 's/((Password|Pwd)=)[^;"]+/\1[REDACTED]/gi' \
    -e 's/((SharedAccessKey|AccountKey)=)[^;"]+/\1[REDACTED]/gi' \
    -e 's/((Authorization: Bearer )[^[:space:]]+)/Authorization: Bearer [REDACTED]/gi' \
    "$f" 2>/dev/null || true
  rm -f "${f}.bak" 2>/dev/null || true
}

redact_tree() {
  local dir="$1"
  [[ $REDACT -eq 1 ]] || return 0
  log "Redacting common secrets patterns (best-effort)…"
  # Avoid scanning huge binaries: only common text extensions
  while IFS= read -r -d '' file; do
    redact_inplace "$file"
  done < <(find "$dir" -type f \( \
      -name "*.json" -o -name "*.txt" -o -name "*.log" -o -name "*.md" -o \
      -name "*.yml" -o -name "*.yaml" -o -name "*.xml" -o -name "*.config" -o \
      -name "*.ini" -o -name "*.props" -o -name "*.targets" -o -name "*.trx" -o \
      -name "*.csproj" -o -name "*.sln" \
    \) -print0 2>/dev/null)
}

gh_auth_check() {
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
}

detect_solution() {
  # If --solution not provided, try to find one.
  [[ -n "$SOLUTION_PATH" ]] && return 0

  local sln
  sln="$(find . -maxdepth 2 -name "*.sln" -print -quit 2>/dev/null || true)"
  if [[ -n "$sln" ]]; then
    SOLUTION_PATH="${sln#./}"
    warn "Auto-detected solution: $SOLUTION_PATH (override with --solution)"
  else
    warn "No .sln found. dotnet commands will run in repo root unless you provide --solution."
  fi
}

dotnet_args_common() {
  local args=()
  args+=( "-c" "$CONFIGURATION" )
  [[ -n "$FRAMEWORK" ]] && args+=( "-f" "$FRAMEWORK" )
  [[ -n "$RUNTIME" ]] && args+=( "-r" "$RUNTIME" )
  printf "%q " "${args[@]}"
}

#######################################
# Parse arguments
#######################################
usage() {
  cat <<'EOF'
collect-pr-diagnostics.sh --pr <number> [options]

Options:
  --pr <n>                 PR number (required)
  --solution <path.sln>    Path to solution (auto-detects if omitted)
  --configuration <cfg>    Debug (default) / Release
  --framework <tfm>        e.g. net8.0 (optional)
  --runtime <rid>          e.g. win-x64, linux-x64 (optional)

  --no-restore             Skip dotnet restore
  --no-build               Skip dotnet build
  --no-test                Skip dotnet test
  --binlog                 Produce MSBuild binary logs for restore/build/test
  --format                 Run dotnet format --verify-no-changes (best-effort)

  --no-workflow-logs       Skip downloading workflow run logs (can be large/slow)
  --no-redact              Do not redact secrets patterns (NOT recommended)
  --keep-dir               Do not delete the output folder after creating archive
  --context "<text>"       Add extra context text (quoted) for AI

Examples:
  ./collect-pr-diagnostics.sh --pr 123
  ./collect-pr-diagnostics.sh --pr 123 --solution src/MyApp.sln --binlog --configuration Release
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR_NUMBER="${2:-}"; shift 2;;
    --solution) SOLUTION_PATH="${2:-}"; shift 2;;
    --configuration) CONFIGURATION="${2:-}"; shift 2;;
    --framework) FRAMEWORK="${2:-}"; shift 2;;
    --runtime) RUNTIME="${2:-}"; shift 2;;

    --no-restore) NO_RESTORE=1; shift;;
    --no-build) NO_BUILD=1; shift;;
    --no-test) NO_TEST=1; shift;;
    --binlog) DO_BINLOG=1; shift;;
    --format) DO_FORMAT=1; shift;;

    --no-workflow-logs) NO_WORKFLOW_LOGS=1; shift;;
    --no-redact) REDACT=0; shift;;
    --keep-dir) KEEP_DIR=1; shift;;
    --context) EXTRA_CONTEXT="${2:-}"; shift 2;;

    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1 (use --help)";;
  esac
done

[[ -n "$PR_NUMBER" ]] || { usage; die "--pr is required"; }

#######################################
# Preconditions
#######################################
need_cmd git
need_cmd gh
need_cmd dotnet
gh_auth_check

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run this in a git repo."
detect_solution

#######################################
# Create output directories
#######################################
REPO="$(repo_slug)"
REPO_SAFE="${REPO//\//-}"
STAMP="$(now_stamp)"
OUT_DIR="pr-diagnostics-${REPO_SAFE}-pr-${PR_NUMBER}-${STAMP}"
mkdirp "$OUT_DIR"

# Structured subfolders
mkdirp "$OUT_DIR/00-meta"
mkdirp "$OUT_DIR/01-pr"
mkdirp "$OUT_DIR/02-git"
mkdirp "$OUT_DIR/03-dotnet/env"
mkdirp "$OUT_DIR/03-dotnet/restore"
mkdirp "$OUT_DIR/03-dotnet/build"
mkdirp "$OUT_DIR/03-dotnet/test"
mkdirp "$OUT_DIR/03-dotnet/packages"
mkdirp "$OUT_DIR/04-workflows"
mkdirp "$OUT_DIR/05-ai"

log "Output folder: $OUT_DIR"

#######################################
# Capture high-level manifest
#######################################
write_file "$OUT_DIR/00-meta/manifest.txt" \
  "repo: $REPO" \
  "pr: $PR_NUMBER" \
  "timestamp: $(date -Iseconds)" \
  "configuration: $CONFIGURATION" \
  "framework: ${FRAMEWORK:-<none>}" \
  "runtime: ${RUNTIME:-<none>}" \
  "solution: ${SOLUTION_PATH:-<auto/none>}" \
  "options: NO_RESTORE=$NO_RESTORE NO_BUILD=$NO_BUILD NO_TEST=$NO_TEST BINLOG=$DO_BINLOG FORMAT=$DO_FORMAT NO_WORKFLOW_LOGS=$NO_WORKFLOW_LOGS REDACT=$REDACT" \
  ""

#######################################
# 1) GitHub PR data
#######################################
log "Collecting PR metadata/diff/comments/checks…"

# PR view JSON
run_capture "$OUT_DIR/01-pr/pr.json" \
  gh pr view "$PR_NUMBER" --repo "$REPO" --json \
  number,title,body,state,isDraft,createdAt,updatedAt,mergedAt,mergeable,mergeStateStatus,additions,deletions,changedFiles,baseRefName,headRefName,baseRefOid,headRefOid,author,assignees,labels,milestone,reviewDecision,comments,reviews,files,commits,url

# Human-friendly summary
run_capture "$OUT_DIR/01-pr/pr.txt" \
  gh pr view "$PR_NUMBER" --repo "$REPO"

# Diff & patch
run_capture "$OUT_DIR/01-pr/pr.diff" \
  gh pr diff "$PR_NUMBER" --repo "$REPO"

run_capture "$OUT_DIR/01-pr/pr.patch" \
  gh pr diff "$PR_NUMBER" --repo "$REPO" --patch

# Checks rollup (human)
run_capture "$OUT_DIR/01-pr/checks.txt" \
  gh pr checks "$PR_NUMBER" --repo "$REPO"

# Reviews list
run_capture "$OUT_DIR/01-pr/reviews.json" \
  gh pr view "$PR_NUMBER" --repo "$REPO" --json reviews

# Comments list (issue + review comments)
run_capture "$OUT_DIR/01-pr/comments.json" \
  gh pr view "$PR_NUMBER" --repo "$REPO" --json comments

# PR timeline events (API): helpful for CI failures, label changes, etc.
# Note: uses GitHub REST "issues timeline" (preview header); gh handles auth.
run_capture "$OUT_DIR/01-pr/timeline.json" \
  gh api -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/issues/${PR_NUMBER}/timeline?per_page=100"

# File list (simple)
run_capture "$OUT_DIR/01-pr/files.txt" \
  gh pr view "$PR_NUMBER" --repo "$REPO" --json files -q '.files[].path'

# Commits (simple)
run_capture "$OUT_DIR/01-pr/commits.txt" \
  gh pr view "$PR_NUMBER" --repo "$REPO" --json commits -q '.commits[].oid + " " + .commits[].messageHeadline' || true

#######################################
# 2) Workflow runs and logs (best-effort)
#######################################
if [[ $NO_WORKFLOW_LOGS -eq 0 ]]; then
  log "Collecting workflow runs for PR head branch (best-effort)…"
  # Derive head branch from pr.json without jq: use gh --json query to extract
  HEAD_REF="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName -q '.headRefName' 2>/dev/null || true)"
  BASE_REF="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json baseRefName -q '.baseRefName' 2>/dev/null || true)"
  write_file "$OUT_DIR/04-workflows/refs.txt" "headRef: $HEAD_REF" "baseRef: $BASE_REF"

  # List recent runs for the branch; capture JSON + table
  run_capture "$OUT_DIR/04-workflows/runs.txt" \
    gh run list --repo "$REPO" --branch "$HEAD_REF" --limit 20

  run_capture "$OUT_DIR/04-workflows/runs.json" \
    gh run list --repo "$REPO" --branch "$HEAD_REF" --limit 50 --json \
    databaseId,displayTitle,event,headBranch,headSha,status,conclusion,createdAt,updatedAt,url,workflowName

  # Attempt to download logs for the most recent failed run (or most recent run)
  RUN_ID="$(gh run list --repo "$REPO" --branch "$HEAD_REF" --limit 10 --json databaseId,conclusion,status \
           -q '([.[] | select(.conclusion=="failure" or .conclusion=="cancelled")] | .[0].databaseId) // .[0].databaseId' 2>/dev/null || true)"

  if [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]]; then
    log "Downloading workflow run logs for run id: $RUN_ID"
    mkdirp "$OUT_DIR/04-workflows/run-${RUN_ID}"
    # gh run download supports artifacts; logs via `gh run view --log` and `--log-failed`
    run_capture "$OUT_DIR/04-workflows/run-${RUN_ID}/run.txt" \
      gh run view "$RUN_ID" --repo "$REPO"
    run_capture "$OUT_DIR/04-workflows/run-${RUN_ID}/log-failed.txt" \
      gh run view "$RUN_ID" --repo "$REPO" --log-failed
    run_capture "$OUT_DIR/04-workflows/run-${RUN_ID}/log.txt" \
      gh run view "$RUN_ID" --repo "$REPO" --log

    # Attempt artifacts download (if any)
    ( cd "$OUT_DIR/04-workflows/run-${RUN_ID}" && \
      gh run download "$RUN_ID" --repo "$REPO" ) >/dev/null 2>&1 || warn "No artifacts downloaded (none found or download failed)."

    truncate_if_huge "$OUT_DIR/04-workflows/run-${RUN_ID}/log.txt"
    truncate_if_huge "$OUT_DIR/04-workflows/run-${RUN_ID}/log-failed.txt"
  else
    warn "Could not determine a workflow run id for branch '$HEAD_REF'. Skipping run logs."
  fi
else
  warn "Skipping workflow logs (--no-workflow-logs)."
fi

#######################################
# 3) Local git repo diagnostics
#######################################
log "Collecting local git diagnostics…"

run_capture "$OUT_DIR/02-git/status.txt" git status --porcelain=v1 -b
run_capture "$OUT_DIR/02-git/remotes.txt" git remote -v
run_capture "$OUT_DIR/02-git/branches.txt" git branch -avv
run_capture "$OUT_DIR/02-git/tags.txt" git tag --list --sort=-creatordate | head -n 200
run_capture "$OUT_DIR/02-git/submodules.txt" git submodule status --recursive || true
run_capture "$OUT_DIR/02-git/config.txt" git config --list --show-origin

# Capture recent history around head
run_capture "$OUT_DIR/02-git/log-head-100.txt" git log -n 100 --decorate --oneline --graph

# Capture file tree overview (top-level)
run_capture "$OUT_DIR/02-git/ls-top.txt" bash -lc 'ls -la'

# Capture any repo-level config that influences build
for f in global.json NuGet.config Directory.Build.props Directory.Build.targets Directory.Packages.props; do
  if [[ -f "$f" ]]; then
    mkdirp "$OUT_DIR/03-dotnet/env/repo-config"
    cp -f "$f" "$OUT_DIR/03-dotnet/env/repo-config/$f"
  fi
done

#######################################
# 4) .NET environment diagnostics
#######################################
log "Collecting .NET environment diagnostics…"

run_capture "$OUT_DIR/03-dotnet/env/dotnet-info.txt" dotnet --info
run_capture "$OUT_DIR/03-dotnet/env/dotnet-sdks.txt" dotnet --list-sdks
run_capture "$OUT_DIR/03-dotnet/env/dotnet-runtimes.txt" dotnet --list-runtimes
run_capture "$OUT_DIR/03-dotnet/env/dotnet-workloads.txt" dotnet workload list || true

# Environment variables (filtered)
# Note: We intentionally avoid dumping everything to reduce secrets exposure.
run_capture "$OUT_DIR/03-dotnet/env/env-filtered.txt" bash -lc 'env | sort | egrep -i "^(DOTNET|NUGET|MSBUILD|GITHUB|CI|TF_BUILD|BUILD_|AGENT_|RUNNER_|PATH=)" || true'

#######################################
# 5) .NET solution/project diagnostics
#######################################
TARGET="${SOLUTION_PATH:-.}"
COMMON_ARGS=()
COMMON_ARGS+=( -c "$CONFIGURATION" )
[[ -n "$FRAMEWORK" ]] && COMMON_ARGS+=( -f "$FRAMEWORK" )
[[ -n "$RUNTIME" ]] && COMMON_ARGS+=( -r "$RUNTIME" )

# Restore
if [[ $NO_RESTORE -eq 0 ]]; then
  log "dotnet restore…"
  if [[ $DO_BINLOG -eq 1 ]]; then
    run_capture "$OUT_DIR/03-dotnet/restore/restore.txt" dotnet restore "$TARGET" \
      /bl:"$OUT_DIR/03-dotnet/restore/restore.binlog"
  else
    run_capture "$OUT_DIR/03-dotnet/restore/restore.txt" dotnet restore "$TARGET"
  fi
else
  warn "Skipping restore (--no-restore)."
fi

# Build
if [[ $NO_BUILD -eq 0 ]]; then
  log "dotnet build…"
  if [[ $DO_BINLOG -eq 1 ]]; then
    run_capture "$OUT_DIR/03-dotnet/build/build.txt" dotnet build "$TARGET" "${COMMON_ARGS[@]}" \
      /bl:"$OUT_DIR/03-dotnet/build/build.binlog" \
      /v:normal
  else
    run_capture "$OUT_DIR/03-dotnet/build/build.txt" dotnet build "$TARGET" "${COMMON_ARGS[@]}" /v:normal
  fi
else
  warn "Skipping build (--no-build)."
fi

# Test
if [[ $NO_TEST -eq 0 ]]; then
  log "dotnet test…"
  mkdirp "$OUT_DIR/03-dotnet/test/results"
  # We output TRX + blame + diag logs for maximum debuggability
  TEST_LOGGER="trx;LogFileName=test-results.trx"
  if [[ $DO_BINLOG -eq 1 ]]; then
    run_capture "$OUT_DIR/03-dotnet/test/test.txt" dotnet test "$TARGET" "${COMMON_ARGS[@]}" --no-build \
      --logger "$TEST_LOGGER" \
      --results-directory "$OUT_DIR/03-dotnet/test/results" \
      --blame \
      --diag "$OUT_DIR/03-dotnet/test/test-diag.log" \
      /bl:"$OUT_DIR/03-dotnet/test/test.binlog"
  else
    run_capture "$OUT_DIR/03-dotnet/test/test.txt" dotnet test "$TARGET" "${COMMON_ARGS[@]}" --no-build \
      --logger "$TEST_LOGGER" \
      --results-directory "$OUT_DIR/03-dotnet/test/results" \
      --blame \
      --diag "$OUT_DIR/03-dotnet/test/test-diag.log"
  fi
  truncate_if_huge "$OUT_DIR/03-dotnet/test/test-diag.log"
else
  warn "Skipping test (--no-test)."
fi

# dotnet format (verify only)
if [[ $DO_FORMAT -eq 1 ]]; then
  log "dotnet format --verify-no-changes (best-effort)…"
  run_capture "$OUT_DIR/03-dotnet/build/dotnet-format.txt" dotnet format "$TARGET" --verify-no-changes || true
fi

# Packages
if [[ $DO_PACKAGES -eq 1 ]]; then
  log "Collecting package inventory…"
  run_capture "$OUT_DIR/03-dotnet/packages/list-package.txt" dotnet list "$TARGET" package --include-transitive || true
  run_capture "$OUT_DIR/03-dotnet/packages/list-outdated.txt" dotnet list "$TARGET" package --outdated || true
fi
if [[ $DO_VULNS -eq 1 ]]; then
  run_capture "$OUT_DIR/03-dotnet/packages/list-vulnerable.txt" dotnet list "$TARGET" package --vulnerable || true
fi

#######################################
# 6) AI-first context synthesis
#######################################
log "Generating AI context prompt…"

PR_URL="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json url -q '.url' 2>/dev/null || true)"
PR_TITLE="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title -q '.title' 2>/dev/null || true)"
PR_HEAD_SHA="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefOid -q '.headRefOid' 2>/dev/null || true)"
PR_BASE_SHA="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json baseRefOid -q '.baseRefOid' 2>/dev/null || true)"

cat > "$OUT_DIR/05-ai/AI_PROMPT.md" <<EOF
# AI Analysis Packet (PR Diagnostics)

## Goal
You are an expert .NET + GitHub Actions + C# reviewer. Analyze this diagnostic bundle and propose:
1) Root cause(s)
2) Minimal fix
3) Safer long-term fix
4) Verification steps (local + CI)
5) Any PR feedback on design, reliability, performance, or security

## PR
- Repo: ${REPO}
- PR: #${PR_NUMBER}
- Title: ${PR_TITLE}
- URL: ${PR_URL}
- Base SHA: ${PR_BASE_SHA}
- Head SHA: ${PR_HEAD_SHA}

## What you have
- PR metadata: \`01-pr/pr.json\`
- Diff: \`01-pr/pr.diff\` and \`01-pr/pr.patch\`
- Checks: \`01-pr/checks.txt\`
- Workflow runs/logs: \`04-workflows/\`
- Git state: \`02-git/\`
- .NET env: \`03-dotnet/env/\`
- Restore/build/test outputs: \`03-dotnet/\`
- Package reports: \`03-dotnet/packages/\`

## Analysis Checklist (do these)
- Identify failing checks and correlate to workflow logs
- Spot compilation errors, analyzer warnings, test failures
- Compare PR diff to failure points (files/modules)
- Check SDK/workload mismatch, global.json, NuGet sources
- Look for flaky tests: blame/diag logs, timeouts, platform-specific issues
- Suggest the smallest code/config change to fix CI and keep intent

## Output format (required)
- Summary (1 paragraph)
- Evidence (bullet list with file paths + relevant lines)
- Fix plan (step-by-step)
- Code changes (file + snippet)
- Commands to verify (copy/paste)
EOF

if [[ -n "$EXTRA_CONTEXT" ]]; then
  echo -e "\n## Extra context from user\n${EXTRA_CONTEXT}\n" >> "$OUT_DIR/05-ai/AI_PROMPT.md"
fi

#######################################
# 7) Redaction + truncation pass
#######################################
log "Post-processing output (truncate huge logs + optional redaction)…"
# Truncate any big plain logs we generated
while IFS= read -r -d '' f; do
  truncate_if_huge "$f"
done < <(find "$OUT_DIR" -type f \( -name "*.log" -o -name "*.txt" \) -print0 2>/dev/null)

redact_tree "$OUT_DIR"

#######################################
# 8) Bundle into archive
#######################################
ARCHIVE="${OUT_DIR}.tar.gz"
log "Creating archive: $ARCHIVE"
tar -czf "$ARCHIVE" "$OUT_DIR"

ok "Archive created: $ARCHIVE"
ok "AI prompt: $OUT_DIR/05-ai/AI_PROMPT.md"

if [[ $KEEP_DIR -eq 0 ]]; then
  log "Cleaning up folder (use --keep-dir to keep it)…"
  rm -rf "$OUT_DIR"
  ok "Kept only archive: $ARCHIVE"
else
  ok "Kept folder: $OUT_DIR"
fi

cat <<EOF

Next steps:
1) Upload the archive to your AI assistant.
2) Start with: 05-ai/AI_PROMPT.md
3) If CI failed, point the AI to: 04-workflows/*/log-failed.txt and 01-pr/checks.txt

Security note:
- Best-effort redaction is enabled by default, but REVIEW before sharing.
- Use --no-redact only if you're confident the bundle contains no secrets.

EOF
