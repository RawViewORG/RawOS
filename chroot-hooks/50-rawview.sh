#!/usr/bin/env bash
# Runs INSIDE the chroot. Applies RawOS patches to the RawView source, builds it
# from source (reusing RawView's own build-deb.sh), installs the .deb, and writes
# the system-wide /etc/rawview/rawview.env so Ghidra/JDK/theme are preconfigured.
set -euo pipefail
source /rawos-build/chroot.env
log()  { printf '\033[1;34m[50-rawview]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[50-rawview] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SRC="$RAWVIEW_SRC_IN_CHROOT"
[ -f "$SRC/pyproject.toml" ] || die "RawView source not found at $SRC"

export DEBIAN_FRONTEND=noninteractive
export JAVA_HOME="$TARGET_JDK_DIR"
export PATH="$TARGET_JDK_DIR/bin:$PATH"
export GHIDRA_INSTALL_DIR="$TARGET_GHIDRA_DIR"

log "Applying RawOS integration patches to RawView source..."
bash /rawos-build/patches/apply-rawview-patches.sh "$SRC" "$RAWVIEW_ANTHROPIC_MODEL"

log "Creating build venv and installing RawView + build deps..."
BUILD_VENV="/tmp/rawview-build-venv"
python3 -m venv "$BUILD_VENV"
# shellcheck disable=SC1091
source "$BUILD_VENV/bin/activate"
pip install --no-cache-dir --upgrade pip wheel setuptools
pip install --no-cache-dir "${SRC}[dev,discord]"

log "Building RawView .deb from source (PyInstaller + dpkg-deb)..."
( cd "$SRC" && bash build-deb.sh )

DEB="$(find "$SRC/dist_installer" -maxdepth 1 -name 'rawview_*_amd64.deb' | sort -V | tail -1)"
[ -n "$DEB" ] || die "RawView .deb not produced"
deactivate
rm -rf "$BUILD_VENV"

log "Installing $DEB ..."
dpkg -i "$DEB" || apt-get install -f -y

log "Writing system-wide $TARGET_RAWVIEW_ENV ..."
mkdir -p "$(dirname "$TARGET_RAWVIEW_ENV")"
cat > "$TARGET_RAWVIEW_ENV" <<EOF
# RawOS system-wide RawView defaults (lowest priority; per-user Settings override).
GHIDRA_INSTALL_DIR=$TARGET_GHIDRA_DIR
JAVA_EXECUTABLE=$TARGET_JDK_DIR/bin/java
RAWVIEW_THEME=$RAWOS_THEME
ANTHROPIC_MODEL=$RAWVIEW_ANTHROPIC_MODEL
EOF
chmod 644 "$TARGET_RAWVIEW_ENV"

log "RawView $RAWVIEW_VERSION installed and preconfigured."
