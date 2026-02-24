#!/usr/bin/env bash
set -euo pipefail

DX_CONFIG_JSON=""

_dx_find_python() {
  if [[ -n "${DX_PYTHON:-}" ]]; then
    if "$DX_PYTHON" - <<'PY' >/dev/null 2>&1
import tomllib
PY
    then echo "$DX_PYTHON"; return 0; fi
  fi
  local cand
  for cand in python3 python "py -3"; do
    if [[ "$cand" == "py -3" ]]; then
      if command -v py >/dev/null 2>&1 && py -3 - <<'PY' >/dev/null 2>&1
import tomllib
PY
      then echo "py -3"; return 0; fi
      continue
    fi
    if command -v "$cand" >/dev/null 2>&1 && "$cand" - <<'PY' >/dev/null 2>&1
import tomllib
PY
    then echo "$cand"; return 0; fi
  done
  return 1
}

_config_builtin_toml() {
  cat <<'TOML'
[dx]
schemaVersion = "1.0"

[core]
runtimeChannel = "stable"
logFormat = "human"
logLevel  = "info"
denyGithub = true

[paths]
downloads = ""

[unpack]
maxFiles   = 50
maxFileKB  = 2560
allowBinary = false

[merge]
# arrays = { "modules.enabled" = "uniqueAppend" }

[modules]
enabled = []

# v0: allow pack settings here (unknown keys are tolerated)
[pack]
outDir = "/c/tmp"
TOML
}

_config_py() {
  local _py
  if ! _py="$(_dx_find_python)"; then
    echo "DXCORE003: Python 3.11+ with tomllib required (set DX_PYTHON to explicit interpreter)" >&2
    return 42
  fi

  "$_py" - <<'PY' || exit $?
import os, sys, json, pathlib

try:
    import tomllib
except Exception:
    print("DXCORE003: tomllib unavailable", file=sys.stderr)
    sys.exit(42)

def load_toml(path):
    if not path or not pathlib.Path(path).is_file():
        return {}
    with open(path, "rb") as f:
        return tomllib.load(f)

def set_prov(prov, path, source_label, origin, value):
    prov[path] = {"source": source_label, "origin": origin, "value": value}

def deep_merge(dst, src, prov, src_label, origin_prefix=None, table_replace_key="_replace", array_strategies=None, path=""):
    for k, v in (src or {}).items():
        full = f"{path}.{k}" if path else k
        origin = f"{origin_prefix or src_label}"
        if isinstance(v, dict):
            if v.get(table_replace_key) is True:
                dst[k] = {kk:vv for kk,vv in v.items() if kk != table_replace_key}
                set_prov(prov, full, src_label, origin, dst[k])
                continue
            if k not in dst or not isinstance(dst[k], dict):
                dst[k] = {}
            deep_merge(dst[k], v, prov, src_label, origin_prefix, table_replace_key, array_strategies, full)
        elif isinstance(v, list):
            strat = "replace"
            if array_strategies and full in array_strategies:
                strat = array_strategies[full]
                if strat not in ("replace","append","uniqueAppend"):
                    print("DXCFG005: invalid array strategy for " + full, file=sys.stderr)
                    sys.exit(24)
            if strat == "replace" or k not in dst or not isinstance(dst.get(k), list):
                dst[k] = v[:]
            elif strat == "append":
                dst[k] = dst[k] + v
            else:
                seen = set(dst[k])
                for item in v:
                    if item not in seen:
                        dst[k].append(item)
                        seen.add(item)
            set_prov(prov, full, src_label, origin, dst[k])
        else:
            dst[k] = v
            set_prov(prov, full, src_label, origin, v)
    return dst

def flatten_array_strategies(cfg):
    arrays = {}
    merge = cfg.get("merge", {})
    if isinstance(merge, dict):
        arr = merge.get("arrays", {})
        if isinstance(arr, dict):
            for k,v in arr.items():
                arrays[str(k)] = str(v)
    return arrays

def value_at(cfg, path):
    cur = cfg
    for p in path.split("."):
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur

def contains_key(cfg, path):
    cur = cfg
    for p in path.split("."):
        if not isinstance(cur, dict) or p not in cur:
            return False
        cur = cur[p]
    return True

def parse_bool(name, raw, strict):
    v = str(raw).lower()
    if v in ("true","1"):  return True
    if v in ("false","0"): return False
    if strict:
        print(f"DXCFG002: invalid env value for {name}='{raw}'", file=sys.stderr); sys.exit(21)
    print(f"warning: invalid env value for {name}='{raw}', ignoring", file=sys.stderr)
    return None

def parse_int(name, raw, strict):
    try:
        return int(str(raw).strip())
    except Exception:
        if strict:
            print(f"DXCFG002: invalid env value for {name}='{raw}'", file=sys.stderr); sys.exit(21)
        print(f"warning: invalid env value for {name}='{raw}', ignoring", file=sys.stderr)
        return None

home = os.path.expanduser("~")
global_config = os.path.join(home, ".config", "dx", "config")  # NEW home
scope_root = os.environ.get("DX_SCOPE_ROOT","")
proj_config = os.path.join(scope_root, "config") if scope_root else None

cfg = {}
prov = {}

# builtins
cfg = deep_merge({}, tomllib.loads(os.environ["DX_BUILTIN_TOML"]), prov, "BUILTIN")

# global
g_cfg = load_toml(global_config)
g_arrays = flatten_array_strategies(g_cfg)
cfg = deep_merge(cfg, g_cfg, prov, f"GLOBAL({global_config})", origin_prefix=f"FILE:{global_config}", array_strategies=g_arrays)

# locks (optional per earlier spec)
locks = set()
lock_advisory = False
dx_lock = (g_cfg.get("dx") or {}).get("lock") if isinstance(g_cfg.get("dx"), dict) else {}
if isinstance(dx_lock, dict):
    if isinstance(dx_lock.get("keys"), list):
        locks = set(str(x) for x in dx_lock["keys"])
    lock_advisory = bool(dx_lock.get("advisory", False))

# project
p_cfg = load_toml(proj_config)
p_arrays = flatten_array_strategies(p_cfg) or g_arrays
cfg = deep_merge(cfg, p_cfg, prov, f"PROJECT({proj_config})", origin_prefix=f"FILE:{proj_config}", array_strategies=p_arrays)

# strict mode aggregation
strict = os.environ.get("DX_CLI_STRICT_CONFIG","0") == "1" or bool((g_cfg.get("dx",{}).get("config",{}) or {}).get("strict", False)) or bool((p_cfg.get("dx",{}).get("config",{}) or {}).get("strict", False))

# ENV (whitelist, strict types per spec)
env_map = {}
if (v:=os.environ.get("DX_LOG_FORMAT")): env_map.setdefault("core",{})["logFormat"]=v
if (v:=os.environ.get("DX_LOG_LEVEL")):  env_map.setdefault("core",{})["logLevel"]=v
if (v:=os.environ.get("DX_DENY_GITHUB")):
    vb = parse_bool("DX_DENY_GITHUB", v, strict)
    if vb is not None: env_map.setdefault("core",{})["denyGithub"]=vb
if (v:=os.environ.get("DX_DOWNLOADS")): env_map.setdefault("paths",{})["downloads"]=v
if (v:=os.environ.get("DX_UNPACK_MAX_FILES")):
    vi = parse_int("DX_UNPACK_MAX_FILES", v, strict)
    if vi is not None: env_map.setdefault("unpack",{})["maxFiles"]=vi
if (v:=os.environ.get("DX_UNPACK_MAX_FILE_KB")):
    vi = parse_int("DX_UNPACK_MAX_FILE_KB", v, strict)
    if vi is not None: env_map.setdefault("unpack",{})["maxFileKB"]=vi
if (v:=os.environ.get("DX_ALLOW_BINARY")):
    vb = parse_bool("DX_ALLOW_BINARY", v, strict)
    if vb is not None: env_map.setdefault("unpack",{})["allowBinary"]=vb

cfg = deep_merge(cfg, env_map, prov, "ENV", origin_prefix="ENV")

# CLI (highest)
cli_map = {}
if os.environ.get("DX_CLI_LOG_FORMAT"): cli_map.setdefault("core",{})["logFormat"]=os.environ["DX_CLI_LOG_FORMAT"]
if os.environ.get("DX_CLI_LOG_LEVEL"):  cli_map.setdefault("core",{})["logLevel"]=os.environ["DX_CLI_LOG_LEVEL"]
cfg = deep_merge(cfg, cli_map, prov, "CLI", origin_prefix="CLI")

# lock enforcement baseline
lower = {}
lower = deep_merge(lower, tomllib.loads(os.environ["DX_BUILTIN_TOML"]), {}, "LOWER")
lower = deep_merge(lower, g_cfg, {}, "LOWER", array_strategies=g_arrays)

viol = []
for lk in locks:
    if contains_key(p_cfg, lk) and value_at(cfg, lk) != value_at(lower, lk):
        viol.append(lk)
if viol and not lock_advisory:
    print("DXCFG001: locked key override attempted: " + ", ".join(viol), file=sys.stderr)
    sys.exit(20)
elif viol and lock_advisory:
    print("warning: advisory locks violated: " + ", ".join(viol), file=sys.stderr)

# schemaVersion
sv = value_at(cfg, "dx.schemaVersion") or "1.0"
if sv != "1.0":
    print("DXCFG004: schemaVersion mismatch", file=sys.stderr)
    sys.exit(23)

out = {
  "schemaVersion":"1.0",
  "resolved": cfg,
  "provenance": prov,
  "runtime": {"version":"1.0.0","channel": (cfg.get("core",{}) or {}).get("runtimeChannel","stable")}
}
print(json.dumps(out, separators=(",",":")))
PY
}

config_resolve() {
  local builtin; builtin="$(_config_builtin_toml)"
  export DX_BUILTIN_TOML="$builtin"
  export DX_SCOPE_ROOT="$(scope_root)"

  local js
  if ! js="$(_config_py)"; then
    ec=$?
    case "$ec" in
      42) die "DXCORE003" "Missing Python 3.11+ tomllib" ;;
      20|21|22|23|24) exit "$ec" ;;
      *)  die "DXCFG004" "Configuration resolution failed" ;;
    esac
  fi

  DX_CONFIG_JSON="$js"
  return 0
}

config_get_effective_log_format() {
  local s; s="$(printf '%s' "$DX_CONFIG_JSON")"
  local val; val="$(printf '%s' "$s" | sed -n 's/.*"core":{[^}]*"logFormat":"\([^"]*\)".*/\1/p' | head -n1)"
  printf '%s' "${val:-human}"
}

config_get_effective_log_level() {
  local s; s="$(printf '%s' "$DX_CONFIG_JSON")"
  local val; val="$(printf '%s' "$s" | sed -n 's/.*"core":{[^}]*"logLevel":"\([^"]*\)".*/\1/p' | head -n1)"
  printf '%s' "${val:-info}"
}

# Getter for pack.outDir (TOML: [pack] outDir="..."), fallback: /c/tmp then ~/.dxs/out
config_get_pack_outdir() {
  local s; s="$(printf '%s' "$DX_CONFIG_JSON")"
  local val; val="$(printf '%s' "$s" | sed -n 's/.*"pack":{[^}]*"outDir":"\([^"]*\)".*/\1/p' | head -n1)"
  if [[ -n "${val:-}" ]]; then printf '%s' "$val"; return 0; fi
  if [[ -d "/c/tmp" || "${MSYSTEM:-}" =~ MINGW|MSYS ]]; then printf '/c/tmp'; return 0; fi
  printf '%s/out' "$(printf '%s' "$HOME/.dxs")"
}

config_snapshot_json() { printf '%s' "$DX_CONFIG_JSON"; }
