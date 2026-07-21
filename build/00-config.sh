#!/usr/bin/env bash
# RawOS build configuration - sourced by every build script and chroot hook.
# Override any value from the environment, e.g.:  RAWOS_VERSION=0.2.0 make iso
set -euo pipefail

# ── Identity ────────────────────────────────────────────────────────────────
export RAWOS_NAME="RawOS"
export RAWOS_ID="rawos"
export RAWOS_VERSION="${RAWOS_VERSION:-0.1.0}"
export RAWOS_CODENAME="${RAWOS_CODENAME:-Ghostwire}"
export RAWOS_HOME_URL="https://github.com/codeminute-the-dev/RawView"
export RAWOS_DISCORD_URL="https://discord.gg/aHRjNzhNgk"

# ── Base distro ─────────────────────────────────────────────────────────────
export UBUNTU_SUITE="${UBUNTU_SUITE:-noble}"          # Ubuntu 24.04 LTS
export ARCH="${ARCH:-amd64}"
export UBUNTU_MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"

# ── Bundled component versions (pinned) ─────────────────────────────────────
export GHIDRA_VERSION="${GHIDRA_VERSION:-12.0.4}"
export GHIDRA_BUILD_DATE="${GHIDRA_BUILD_DATE:-20260303}"   # part of the release asset name
export TEMURIN_MAJOR="${TEMURIN_MAJOR:-21}"
# Canonical RawView version RawOS ships (see plan note about version drift).
export RAWVIEW_VERSION="${RAWVIEW_VERSION:-1.2.4}"
export RAWVIEW_ANTHROPIC_MODEL="${RAWVIEW_ANTHROPIC_MODEL:-claude-opus-4-8}"

# ── Theme / branding ────────────────────────────────────────────────────────
export RAWOS_THEME="tokyo_night"
# Tokyo Night core palette (used to generate GRUB/Plymouth/terminal themes).
export TN_BG="#1a1b26"
export TN_BG_DARK="#16161e"
export TN_FG="#c0caf5"
export TN_ACCENT="#7aa2f7"   # blue
export TN_ACCENT2="#bb9af7"  # purple
export TN_GREEN="#9ece6a"
export TN_RED="#f7768e"

# ── Filesystem paths inside the target (chroot) ─────────────────────────────
export TARGET_GHIDRA_DIR="/opt/ghidra"
export TARGET_JDK_DIR="/opt/jdk"
export TARGET_RAWVIEW_ENV="/etc/rawview/rawview.env"

# ── Host build paths ────────────────────────────────────────────────────────
# RAWOS_ROOT resolves to the repo root regardless of where a script is invoked.
export RAWOS_ROOT="${RAWOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export WORK_DIR="${WORK_DIR:-$RAWOS_ROOT/work}"        # chroot + staging (large, gitignored)
export CHROOT_DIR="${CHROOT_DIR:-$WORK_DIR/chroot}"
export IMAGE_DIR="${IMAGE_DIR:-$WORK_DIR/image}"       # ISO staging tree
export OUT_DIR="${OUT_DIR:-$RAWOS_ROOT/out}"           # final artifacts
export CACHE_DIR="${CACHE_DIR:-$RAWOS_ROOT/.cache}"    # downloaded tarballs (Ghidra/JDK/etc.)

# Where RawView source lives. Prefer the vendored submodule; fall back to the
# sibling working copy on this machine so local builds work out of the box.
if [ -d "$RAWOS_ROOT/vendor/RawView/rawview" ]; then
    export RAWVIEW_SRC="$RAWOS_ROOT/vendor/RawView"
else
    export RAWVIEW_SRC="${RAWVIEW_SRC:-/home/codeminute/RawView}"
fi

export ISO_LABEL="RAWOS_${RAWOS_VERSION//./_}"
export ISO_FILENAME="${RAWOS_ID}-${RAWOS_VERSION}-${ARCH}-live.iso"

# ── Helpers ─────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[RawOS]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[RawOS warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[RawOS error]\033[0m %s\n' "$*" >&2; exit 1; }
