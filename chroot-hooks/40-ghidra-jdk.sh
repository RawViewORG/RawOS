#!/usr/bin/env bash
# Runs INSIDE the chroot. Installs Ghidra -> /opt/ghidra and Temurin JDK -> /opt/jdk
# so RawView works fully offline (no first-run download).
set -euo pipefail
source /rawos-build/chroot.env
log()  { printf '\033[1;34m[40-ghidra]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[40-ghidra]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[40-ghidra] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

CACHE="/rawos-build/cache"
mkdir -p "$CACHE"

fetch() {
    local url="$1" dest="$2"
    if [ -s "$dest" ]; then log "cached: $(basename "$dest")"; return 0; fi
    log "download: $url"
    curl -fL --retry 3 --connect-timeout 30 -o "$dest" "$url"
}

# ── Ghidra ───────────────────────────────────────────────────────────────────
# Prefer a copy already extracted in the RawView working tree (present on the
# build machine); otherwise download the pinned NSA release.
GHIDRA_LOCAL="$RAWVIEW_SRC_IN_CHROOT/ghidra_bundle/ghidra_extract"
if [ -d "$GHIDRA_LOCAL" ] && [ -n "$(find "$GHIDRA_LOCAL" -maxdepth 1 -name 'ghidra_*_PUBLIC' -type d 2>/dev/null)" ]; then
    log "Using Ghidra from vendored bundle."
    GH_ROOT="$(find "$GHIDRA_LOCAL" -maxdepth 1 -name 'ghidra_*_PUBLIC' -type d | head -1)"
    rm -rf "$TARGET_GHIDRA_DIR"; mkdir -p "$TARGET_GHIDRA_DIR"
    cp -a "$GH_ROOT/." "$TARGET_GHIDRA_DIR/"
else
    GH_ZIP="ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_BUILD_DATE}.zip"
    GH_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/${GH_ZIP}"
    fetch "$GH_URL" "$CACHE/$GH_ZIP" || die "Ghidra download failed"
    tmp="$(mktemp -d)"; unzip -q "$CACHE/$GH_ZIP" -d "$tmp"
    GH_ROOT="$(find "$tmp" -maxdepth 1 -name 'ghidra_*_PUBLIC' -type d | head -1)"
    rm -rf "$TARGET_GHIDRA_DIR"; mkdir -p "$TARGET_GHIDRA_DIR"
    cp -a "$GH_ROOT/." "$TARGET_GHIDRA_DIR/"
    rm -rf "$tmp"
fi
[ -d "$TARGET_GHIDRA_DIR/support" ] && [ -d "$TARGET_GHIDRA_DIR/Ghidra" ] \
    || die "Ghidra install looks invalid at $TARGET_GHIDRA_DIR"
log "Ghidra installed at $TARGET_GHIDRA_DIR"

# ── Temurin JDK ──────────────────────────────────────────────────────────────
JDK_LOCAL="$RAWVIEW_SRC_IN_CHROOT/temurin_bundle/temurin${TEMURIN_MAJOR}_extract"
if [ -d "$JDK_LOCAL" ] && [ -n "$(find "$JDK_LOCAL" -maxdepth 1 -name 'jdk-*' -type d 2>/dev/null)" ]; then
    log "Using Temurin from vendored bundle."
    JDK_ROOT="$(find "$JDK_LOCAL" -maxdepth 1 -name 'jdk-*' -type d | head -1)"
    rm -rf "$TARGET_JDK_DIR"; mkdir -p "$TARGET_JDK_DIR"
    cp -a "$JDK_ROOT/." "$TARGET_JDK_DIR/"
else
    # Adoptium redirect API resolves latest GA for the major version + platform.
    JDK_URL="https://api.adoptium.net/v3/binary/latest/${TEMURIN_MAJOR}/ga/linux/x64/jdk/hotspot/normal/eclipse"
    fetch "$JDK_URL" "$CACHE/temurin${TEMURIN_MAJOR}.tar.gz" || die "Temurin download failed"
    tmp="$(mktemp -d)"; tar -xzf "$CACHE/temurin${TEMURIN_MAJOR}.tar.gz" -C "$tmp"
    JDK_ROOT="$(find "$tmp" -maxdepth 1 -name 'jdk-*' -type d | head -1)"
    rm -rf "$TARGET_JDK_DIR"; mkdir -p "$TARGET_JDK_DIR"
    cp -a "$JDK_ROOT/." "$TARGET_JDK_DIR/"
    rm -rf "$tmp"
fi
[ -x "$TARGET_JDK_DIR/bin/java" ] || die "JDK install looks invalid at $TARGET_JDK_DIR"
log "Temurin JDK installed at $TARGET_JDK_DIR ($("$TARGET_JDK_DIR/bin/java" -version 2>&1 | head -1))"

log "ghidra + jdk done."
