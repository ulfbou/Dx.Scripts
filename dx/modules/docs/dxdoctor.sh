#!/usr/bin/env bash
set -euo pipefail

EXPECT_ROOT="/f/repos/scripts"
EXPECT_SCRIPTS="/f/repos/scripts/scripts"
EXPECT_DL="/c/users/uffe/downloads"

ok(){   printf '[OK] %s\n' "$1"; }
warn(){ printf '[WARN] %s\n' "$1"; }
ko(){   printf '[FAIL] %s\n' "$1"; }
hr(){   printf '%s\n' '------------------------------'; }

STATUS=0

hr
printf 'Dx Doctor %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hr

DXU_PATH="$(command -v dxunpack.sh 2>/dev/null || true)"
DXP_PATH="$(command -v dxpack.sh 2>/dev/null || true)"

[[ -n "$DXU_PATH" ]] && ok "dxunpack.sh: $DXU_PATH" || { ko 'dxunpack.sh not found on PATH'; STATUS=1; }
[[ -n "$DXP_PATH" ]] && ok "dxpack.sh:   $DXP_PATH" || { ko 'dxpack.sh not found on PATH'; STATUS=1; }

if [[ -n "$DXU_PATH" ]]; then
  "$DXU_PATH" --help 2>/dev/null | grep -q -- "--apply"        && ok "supports --apply"        || { ko 'no --apply'; STATUS=1; }
  "$DXU_PATH" --help 2>/dev/null | grep -q -- "--analyze-only" && ok "supports --analyze-only" || { ko 'no --analyze-only'; STATUS=1; }
  "$DXU_PATH" --help 2>/dev/null | grep -q -- "--verify"       && ok "supports --verify"       || warn 'no --verify (optional)'
fi

ALT_NEW="$EXPECT_SCRIPTS/dxunpack.sh"
if [[ -n "$DXU_PATH" && -f "$ALT_NEW" && "$DXU_PATH" != "$ALT_NEW" ]]; then
  warn "Newer dxunpack.sh found at $ALT_NEW. To replace PATH copy:"
  printf '  %s\n' "cp -f '$ALT_NEW' '$DXU_PATH' && chmod +x '$DXU_PATH'"
fi

hr
printf 'Tools (non-blocking)\n'
hr
have(){ command -v "$1" >/dev/null 2>&1 && echo present || echo missing; }
if command -v sha256sum >/dev/null 2>&1; then sha_tool='sha256sum (present)'; elif command -v shasum >/dev/null 2>&1; then sha_tool='shasum -a 256 (present)'; else sha_tool='(missing)'; fi
printf '%-10s %s\n' 'sha256' "$sha_tool"
printf '%-10s %s\n' 'jq'       "$(have jq)"
printf '%-10s %s\n' 'gh'       "$(have gh)"
printf '%-10s %s\n' 'git'      "$(have git)"
printf '%-10s %s\n' 'dotnet'   "$(have dotnet)"

hr
printf 'Directories\n'
hr
[[ -d "$EXPECT_ROOT"   ]] && ok "exists: $EXPECT_ROOT"   || { ko "missing: $EXPECT_ROOT"; STATUS=1; }
[[ -d "$EXPECT_SCRIPTS" ]] && ok "exists: $EXPECT_SCRIPTS" || { ko "missing: $EXPECT_SCRIPTS"; STATUS=1; }
[[ -d "$EXPECT_DL"     ]] && ok "exists: $EXPECT_DL"     || { ko "missing: $EXPECT_DL"; STATUS=1; }

hr
printf 'PATH entries (grep: scripts)\n'
hr
printf '%s\n' "$PATH" | tr ':' '\n' | grep -i scripts || true

hr
[[ $STATUS -eq 0 ]] && ok 'Doctor checks passed' || ko 'Doctor found issues'
exit $STATUS
