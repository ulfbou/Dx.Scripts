# DX CLI — Usage Guide (Runtime v1.0.0)

> **Scope:** `dx` runtime and built‑in commands (`help`, `init`, `env`, `pack`, `unpack`) and expected behavior of the versioned shim.  
> **Audience:** Developers and CI using the DX Engine locally or on build agents.

***

## 0) Quick Start

```bash
# Show CLI help
dx help

# Initialize DX folders (auto-detects project/global scope)
dx init

# Print resolved environment (human / JSON)
dx env
dx env --json

# Pack files (by extensions) from a root folder into a single .dxp artifact
dx pack /path/to/root sh,md

# Unpack a .dxp artifact into a target root
dx unpack /c/tmp/mybundle.dxp --root /some/dir --mode overwrite
```

***

## 1) The Versioned Shim

Location:

    dx/core/runtime/v1.0.0/bin/dx

Behavior:

*   Computes `DX_ROOT` from its own location (four levels up to `dx/`).
*   Reads **`dx/VERSION`** (BOM/whitespace tolerant).
*   If empty, **auto-detects** exactly one subfolder under `dx/core/runtime/`.
*   Resolves runtime entry at:
        dx/core/runtime/<version>/dx.sh
*   Fails with clear messages if the version cannot be resolved or if `dx.sh` isn’t executable.

> This keeps each runtime **self‑contained** and enables future side‑by‑side runtime versions.

***

## 2) Top-level CLI: common flags & logging

All commands share a minimal set of top-level flags:

```bash
dx [--log-format human|json] [--log-level error|warn|info|debug|trace]
   [--strict-config]
   [--global | --local|--project]
   <command> [args...]
```

*   **`--log-format`**: console output (`human` or `json`). Logs are **always** mirrored to a **JSONL** file under the detected scope (see below).
*   **`--log-level`**: severity filter for console logs (file logs still capture everything the runtime emits).
*   **`--strict-config`**: enable strict configuration behavior (see §6 Configuration).
*   **`--global` / `--local|--project`**: force the scope (otherwise auto‑detected).

**Log file sink** (automatic):

*   Project scope ⇒ `./.dx/logs/dx-YYYYMMDD.jsonl`
*   Global scope  ⇒ `~/.dxs/logs/dx-YYYYMMDD.jsonl`

***

## 3) Scopes: project vs global

*   **Project scope** (auto‑detected if inside a Git repo):
        <repo>/.dx/
          logs/
          tmp/
          snapshots/
          modules/
          config
*   **Global scope**:
        ~/.dxs/
          logs/
        ~/.config/dx/
          config

Switch explicitly:

```bash
dx --global env
dx --local  env
```

***

## 4) Commands (built‑in)

### 4.1 `help`

Displays the top-level help and lists commands.

```bash
dx help
```

***

### 4.2 `init`

Initialize state and config for the active scope.

```bash
dx init [--global|--local]
```

What it does:

*   Creates missing scope directories (`.dx/`, `logs/`, `tmp/`, `snapshots/`, `modules/`).
*   Ensures **global config** at: `~/.config/dx/config` with a minimal TOML skeleton.
*   Ensures **project config** at: `<repo>/.dx/config` with `dx.schemaVersion`.
*   In project scope, adds `/.dx/` to the repo’s `.gitignore` (idempotent).

***

### 4.3 `env`

Show resolved environment state (after merging built‑ins + global/project config + environment + CLI overrides).

```bash
# Human format
dx env

# JSON format (for automation)
dx env --json
```

Typical output fields (JSON):

*   `"schemaVersion"`: `"1.0"`
*   `"resolved"`: effective config tree (see §6).
*   `"provenance"`: per‑key source (BUILTIN / ENV / CLI / FILE:...).
*   `"runtime"`: `{ "version": "1.0.0", "channel": "stable" }`
*   `"scope"` / `"scopeRoot"`: current scope & folder.

***

### 4.4 `pack`

Pack files from a root directory into one portable **DXP** bundle.

```bash
dx pack <root-dir> <ext1,ext2,...> [<out-file>] [--out <file>] [--out-dir <dir>] [--enc raw|b64]
```

*   **`root-dir`**: path to scan.
*   **`ext1,ext2,...`**: comma‑separated list of file extensions (case‑insensitive; dot optional).
*   **Output**:
    *   If `--out` / positional `<out-file>` is provided ⇒ write to it.
    *   Otherwise generate a name:
            <outDir>/dxpack.<basename(root)>.<exts>.dxp
        where `<outDir>` resolves from config `[pack].outDir` (defaults to `/c/tmp` on MSYS or `~/.dxs/out`).
*   **`--enc raw|b64`**:
    *   `raw`: embeds file bytes directly (fast).
    *   `b64`: embeds Base64 lines (robust across shells/systems).
        > For large text files on MSYS, prefer `b64` in CI tests to avoid `dd` edge‑cases during unpack.

**DXP format (simplified):**

    DXP1
    @schema=1
    @exts=sh,md
    @modeDefault=overwrite
    @deny=.dx,.git,bin,obj,node_modules,.vs,.vscode
    @count=33
    --FILES--
    F <relpath> <xflag> <sha256> <size> <enc>   # one per file
    <payload...>

**Return value**: prints **only the output path** on the last line (script‑friendly).  
Capture it reliably:

```bash
BUNDLE="$(dx pack . sh,md --enc b64 2>/dev/null | tail -n 1)"
```

***

### 4.5 `unpack`

Validate and restore a `.dxp` into a target root (one step).

```bash
dx unpack <bundle.dxp> --root <target-root> [--mode overwrite|skip|error]
```

*   Validates **header**, **per‑file meta**, **size**, and **sha256**.
*   Auto‑detects payload encoding (`raw` or `b64`; legacy entries without `enc` are treated as `b64`).
*   Safe paths only (no absolute, no traversal; blocks targets under `.dx/`).
*   Preserves file executability based on `xflag`.
*   **`--mode`**:
    *   `overwrite` (default)
    *   `skip` (don’t overwrite existing files)
    *   `error` (fail if a file exists)

Example:

```bash
dx unpack /c/tmp/dxpack.Dx.Scripts.sh-md.dxp --root /f/tmp/unpacked --mode overwrite
```

***

## 5) Deterministic Round‑Trip (recommended workflow)

Use `b64` when validating end‑to‑end integrity across environments:

```bash
# Pack
OUT="$(dx pack . sh,md --enc b64 2>/dev/null | tail -n 1)"

# Unpack to a temp directory
TEMP_ROOT="/f/tmp/dx-roundtrip"
rm -rf "$TEMP_ROOT" && mkdir -p "$TEMP_ROOT"
dx unpack "$OUT" --root "$TEMP_ROOT" --mode overwrite

# (Optional) Compare trees ignoring noise
diff -ru --exclude=".git" --exclude=".dx" --exclude="bin" --exclude="obj" --exclude="node_modules" . "$TEMP_ROOT" | head -200
```

> For CI, keep a **SHA‑256 verification** step (we added a `tests/roundtrip/test_pack_unpack.sh` blueprint during Phase 2.3). It proves every unpacked file exactly matches the bundle metadata.

***

## 6) Configuration Model

**Sources and precedence** (low → high):

1.  **Built‑in TOML** (runtime defaults)
2.  **Global config**: `~/.config/dx/config`
3.  **Project config**: `<repo>/.dx/config`
4.  **Environment** (whitelisted variables, parsed w/ strict types)
5.  **CLI** overrides

**Key sections** (examples):

```toml
[dx]
schemaVersion = "1.0"

[core]
runtimeChannel = "stable"   # informational today
logFormat      = "human"    # "human" | "json"
logLevel       = "info"     # error|warn|info|debug|trace
denyGithub     = true

[paths]
downloads = "C:/Users/<User>/Downloads"

[unpack]
maxFiles    = 50
maxFileKB   = 2560
allowBinary = false

[pack]
outDir = "/c/tmp"
```

**Environment variables** (examples):

*   `DX_LOG_FORMAT`, `DX_LOG_LEVEL`
*   `DX_DOWNLOADS`
*   `DX_UNPACK_MAX_FILES`, `DX_UNPACK_MAX_FILE_KB`, `DX_ALLOW_BINARY`

**CLI overrides** (highest):

*   `--log-format`, `--log-level`, `--strict-config`

**Strict mode** (`--strict-config`):

*   Turns invalid env values into errors (rather than warnings).
*   Honors optional “lock” semantics if present in future configs.

Use:

```bash
dx --strict-config env --json
```

***

## 7) Conventions & Safety

*   **Path safety**: Unpack forbids absolute paths, parent traversal, and `.dx/` targets.
*   **Binary guard**: Unpack can refuse files with NUL bytes unless `allowBinary` is set.
*   **Always‑on file logging**: JSONL trail under `logs/` for auditability.
*   **Idempotence**: `init` and pack/unpack flows are repeatable; `skip`/`error` give overwrite control.

***

## 8) Troubleshooting

### “Bundle not found”

You likely captured logs with the path when assigning `OUT`. Use:

```bash
OUT="$(dx pack . sh,md --enc b64 2>/dev/null | tail -n 1)"
```

### “Runtime entry not found/executable”

*   Verify `dx/VERSION` content (e.g., `v1.0.0`) and that:
        dx/core/runtime/v1.0.0/dx.sh
    exists and is executable (`git update-index --chmod=+x ...`).

### Large text becomes empty on unpack (MSYS raw mode)

*   Use `--enc b64` for cross‑shell determinism in tests/CI. Keep `raw` for fast local workflows if it’s reliable on your shell.

### No logs appearing

*   Check scope and ensure the logs directory is writable:
    *   Project: `./.dx/logs/`
    *   Global : `~/.dxs/logs/`

***

## 9) Examples (copy‑paste)

**Pack repository scripts & docs to a named file (b64):**

```bash
dx pack . sh,md --out /c/tmp/scripts-and-docs.dxp --enc b64
```

**Unpack with “skip” mode (never overwrite):**

```bash
dx unpack /c/tmp/scripts-and-docs.dxp --root /f/tmp/review --mode skip
```

**Machine‑readable environment (for CI):**

```bash
dx --log-format json env --json > .dx/logs/env.json
```

**Force global scope for a machine‑wide init:**

```bash
dx --global init
```

***

## 10) Glossary

*   **DXP**: Deterministic pack format produced by `dx pack`: header + metadata + payloads.
*   **Scope**: Context the runtime operates in (project vs global) controlling where logs and config live.
*   **Shim**: Version launcher script in `dx/core/runtime/<version>/bin/dx` that resolves `dx/VERSION` and execs the right runtime.

***

## 11) What’s Next (Phase 3 preview)

*   Generate a canonical **`dx.manifest.json`** and schema.
*   Add per‑module `module.json` metadata.
*   Auto‑produce `INDEX.md` from the manifest.
*   Wire the round‑trip test into CI.
