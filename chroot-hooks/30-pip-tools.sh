#!/usr/bin/env bash
# Runs INSIDE the chroot. Installs Python RE tooling into a dedicated venv at
# /opt/rawos-venv and links the CLIs onto PATH. Kept out of the system python
# to avoid clashing with apt-managed python packages (PEP 668).
set -euo pipefail
source /rawos-build/chroot.env
log() { printf '\033[1;34m[30-pip]\033[0m %s\n' "$*"; }

VENV="/opt/rawos-venv"
log "Creating $VENV ..."
python3 -m venv "$VENV"
"$VENV/bin/pip" install --no-cache-dir --upgrade pip wheel setuptools

# keystone-engine wheels can be flaky per-arch; keep it best-effort.
# NOTE: no `fakenet-ng` here - the PyPI package by that name is an empty 0.0.1
# stub, not Mandiant's FakeNet-NG. INetSim (apt) is the shipped fake-network tool.
PY_TOOLS=(
    pwntools
    frida-tools
    volatility3
    yara-python
    keystone-engine
    ropgadget
    unicorn
    capstone
)
log "Installing: ${PY_TOOLS[*]}"
for t in "${PY_TOOLS[@]}"; do
    "$VENV/bin/pip" install --no-cache-dir "$t" || printf '\033[1;33m[30-pip] WARN: %s failed\033[0m\n' "$t"
done

# Expose the venv CLIs system-wide without activating the venv.
log "Linking venv CLIs into /usr/local/bin ..."
for bin in fakenet pwn ROPgadget vol frida frida-trace; do
    [ -x "$VENV/bin/$bin" ] && ln -sf "$VENV/bin/$bin" "/usr/local/bin/$bin"
done

log "pip tools done."
