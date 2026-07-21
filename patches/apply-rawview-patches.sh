#!/usr/bin/env bash
# Apply RawOS integration patches to a RawView source tree (idempotent).
#
# Usage: apply-rawview-patches.sh <rawview_src_dir> [anthropic_model]
#
# Changes:
#   1. rawview/config.py::_env_files() also reads /etc/rawview/rawview.env
#      (lowest priority) so RawOS can preset GHIDRA_INSTALL_DIR / JAVA_EXECUTABLE
#      / RAWVIEW_THEME system-wide.
#   2. Bump the stale default `anthropic_model` to a current model id.
#
# Uses Python for precise, idempotent edits rather than fragile line patches.
set -euo pipefail

SRC="${1:?usage: apply-rawview-patches.sh <rawview_src_dir> [anthropic_model]}"
MODEL="${2:-claude-opus-4-8}"
CONFIG="$SRC/rawview/config.py"

[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG not found" >&2; exit 1; }

RAWOS_MODEL="$MODEL" python3 - "$CONFIG" <<'PY'
import os, re, sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()
orig = src
model = os.environ["RAWOS_MODEL"]

# 1) Inject the system-wide env file as the lowest-priority source.
if "/etc/rawview/rawview.env" not in src:
    anchor = "    user = user_settings_env_path()\n"
    inject = (
        '    system = Path("/etc/rawview/rawview.env")  # RawOS system-wide defaults (lowest priority)\n'
        + anchor
    )
    if anchor not in src:
        sys.exit("PATCH FAIL: could not find `user = user_settings_env_path()` in _env_files()")
    src = src.replace(anchor, inject, 1)
    # Prepend `system` to the returned tuple (lowest priority = first).
    src = src.replace("return (user, repo_rawview, cwd)",
                      "return (system, user, repo_rawview, cwd)", 1)

# 2) Refresh the default Anthropic model id.
src = re.sub(r'(anthropic_model:\s*str\s*=\s*Field\(\s*default=")[^"]*(")',
             lambda m: m.group(1) + model + m.group(2), src, count=1)

if src != orig:
    open(path, "w", encoding="utf-8").write(src)
    print(f"[patch] updated {path}")
else:
    print(f"[patch] no changes (already patched): {path}")
PY
