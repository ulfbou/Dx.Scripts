#!/usr/bin/env bash
set -euo pipefail

# Round-trip verification for DX Engine pack/unpack
# - Uses --enc b64 to be shell/OS-agnostic (avoids MSYS raw+dd edge cases)
# - Verifies each file’s SHA-256 against the bundle metadata (strong proof)

ROOT="${1:-.}"
EXTS="${2:-sh,md}"
ENC="${3:-b64}"          # default to b64 for determinism across environments
WORKDIR="$(mktemp -d -t dx.roundtrip.XXXXXX)"

cleanup() {
  [[ -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "[rt] root: ${ROOT}"
echo "[rt] exts: ${EXTS}"
echo "[rt] enc:  ${ENC}"
echo "[rt] work: ${WORKDIR}"

BUNDLE="$(dx pack "$ROOT" "$EXTS" --enc "$ENC" 2>/dev/null | tail -n 1)"
[[ -f "$BUNDLE" ]] || { echo "[rt][ERR] No bundle produced"; exit 1; }
echo "[rt] bundle: $BUNDLE"

OUT="$WORKDIR/unpacked"
mkdir -p "$OUT"
dx unpack "$BUNDLE" --root "$OUT" --mode overwrite >/dev/null

# Parse bundle metadata lines: F <rel> <xflag> <sha> <size> <enc?>
# Then verify each unpacked file’s sha256
FAIL=0
while IFS= read -r line; do
  # Skip until metadata section starts
  [[ "$line" == "--FILES--" ]] && break
done < "$BUNDLE"

# Process metadata lines
exec 3<"$BUNDLE"
# Seek to first metadata row (after --FILES--)
while IFS= read -r meta <&3; do
  [[ "$meta" == "--FILES--" ]] && break
done

while IFS= read -r meta <&3; do
  # Stop on first non-meta line
  [[ "$meta" =~ ^F\  ]] || continue
  # shellcheck disable=SC2206
  TOKS=($meta)  # F rel xflag sha size [enc]
  rel="${TOKS[1]}"
  exp_sha="${TOKS[3]}"

  target="$OUT/$rel"
  if [[ ! -f "$target" ]]; then
    echo "[rt][MISS] $rel"
    FAIL=1
    continue
  fi

  # Compute sha256 of unpacked file
  if command -v sha256sum >/dev/null 2>&1; then
    act_sha="$(sha256sum "$target" | awk '{print $1}')"
  else
    act_sha="$(shasum -a 256 "$target" | awk '{print $1}')"
  fi

  if [[ "$act_sha" != "$exp_sha" ]]; then
    echo "[rt][SHA MISMATCH] $rel"
    echo "  expected: $exp_sha"
    echo "  actual:   $act_sha"
    FAIL=1
  fi
done

if [[ "$FAIL" -eq 0 ]]; then
  echo "[rt] OK: all files verified."
else
  echo "[rt] FAIL: verification errors."
  exit 2
fi

# Optional: a short human diff (best-effort)
echo
echo "[rt] Short diff (ignoring .git/.dx/bin/obj/node_modules), first 200 lines:"
diff -ru \
  --exclude=".git" \
  --exclude=".dx" \
  --exclude="bin" \
  --exclude="obj" \
  --exclude="node_modules" \
  "$ROOT" "$OUT" | head -200 || true
