#!/usr/bin/env bash
set -euo pipefail
bash "$(dirname "$0")/test_pack_unpack.sh" . sh,md b64
