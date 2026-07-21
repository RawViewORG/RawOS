#!/usr/bin/env bash
# Runs INSIDE the chroot. Installs RE tools not packaged in Ubuntu noble, from
# upstream GitHub release assets (resolved via the API so URLs don't go stale).
# Downloads are cached on the host under .cache/ and reused.
set -euo pipefail
source /rawos-build/chroot.env
log()  { printf '\033[1;34m[20-gh]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[20-gh]\033[0m %s\n' "$*" >&2; }

CACHE="/rawos-build/cache"
mkdir -p "$CACHE" /opt/rawos-tools /usr/local/bin /usr/share/applications
export DEBIAN_FRONTEND=noninteractive

fetch() {  # fetch <url> <dest> - cached copy wins, else download
    local url="$1" dest="$2"
    [ -s "$dest" ] && { log "cached: $(basename "$dest")"; return 0; }
    [ -n "$url" ] || return 1
    log "download: $url"
    curl -fL --retry 3 --connect-timeout 30 -o "$dest" "$url"
}

# gh_asset <owner/repo> <latest|tag> <regex> → first matching browser_download_url
gh_asset() {
    local repo="$1" ref="$2" pat="$3" api
    if [ "$ref" = "latest" ]; then api="https://api.github.com/repos/$repo/releases/latest"
    else api="https://api.github.com/repos/$repo/releases/tags/$ref"; fi
    curl -fsSL --retry 3 --connect-timeout 30 -H "Accept: application/vnd.github+json" "$api" 2>/dev/null \
        | grep -o '"browser_download_url":[[:space:]]*"[^"]*"' | cut -d'"' -f4 \
        | grep -iE "$pat" | head -1
}

# ── capa (static capability detection) ───────────────────────────────────────
CAPA_URL="$(gh_asset mandiant/capa latest 'capa-v[0-9.]+-linux\.zip$' || true)"
if fetch "$CAPA_URL" "$CACHE/capa.zip"; then
    rm -rf /opt/rawos-tools/capa; mkdir -p /opt/rawos-tools/capa
    unzip -o "$CACHE/capa.zip" -d /opt/rawos-tools/capa >/dev/null
    BIN="$(find /opt/rawos-tools/capa -maxdepth 2 -type f -name capa | head -1)"
    [ -n "$BIN" ] && { chmod +x "$BIN"; ln -sf "$BIN" /usr/local/bin/capa; }
else warn "capa download failed"; fi

# ── FLOSS (obfuscated string extraction) ─────────────────────────────────────
FLOSS_URL="$(gh_asset mandiant/flare-floss latest 'floss-v[0-9.]+-linux\.zip$' || true)"
if fetch "$FLOSS_URL" "$CACHE/floss.zip"; then
    rm -rf /opt/rawos-tools/floss; mkdir -p /opt/rawos-tools/floss
    unzip -o "$CACHE/floss.zip" -d /opt/rawos-tools/floss >/dev/null
    BIN="$(find /opt/rawos-tools/floss -maxdepth 2 -type f -name floss | head -1)"
    [ -n "$BIN" ] && { chmod +x "$BIN"; ln -sf "$BIN" /usr/local/bin/floss; }
else warn "floss download failed"; fi

# ── Detect-It-Easy (packer / compiler detection) - Ubuntu 24.04 .deb ─────────
DIE_URL="$(gh_asset horsicq/DIE-engine latest 'Ubuntu_24\.04_amd64\.deb$' || true)"
if fetch "$DIE_URL" "$CACHE/die.deb"; then
    apt-get install -y "$CACHE/die.deb" || { dpkg -i "$CACHE/die.deb" || apt-get -f install -y; }
else warn "Detect-It-Easy download failed"; fi

# ── fastfetch (system info; not in noble apt) - GitHub .deb ──────────────────
FF_URL="$(gh_asset fastfetch-cli/fastfetch latest 'linux-amd64\.deb$' || true)"
if fetch "$FF_URL" "$CACHE/fastfetch.deb"; then
    apt-get install -y "$CACHE/fastfetch.deb" || { dpkg -i "$CACHE/fastfetch.deb" || apt-get -f install -y; }
else warn "fastfetch download failed (fetch greeting will be skipped)"; fi

# ── Cutter (rizin GUI; bundles the rizin engine) - AppImage, extracted so it ──
#    needs no FUSE at runtime ───────────────────────────────────────────────
CUT_URL="$(gh_asset rizinorg/cutter latest 'Linux-x86_64\.AppImage$' || true)"
if fetch "$CUT_URL" "$CACHE/cutter.AppImage"; then
    chmod +x "$CACHE/cutter.AppImage"
    rm -rf /opt/rawos-tools/cutter "$CACHE/squashfs-root"
    if ( cd "$CACHE" && ./cutter.AppImage --appimage-extract >/dev/null 2>&1 ) && [ -d "$CACHE/squashfs-root" ]; then
        mv "$CACHE/squashfs-root" /opt/rawos-tools/cutter
        ln -sf /opt/rawos-tools/cutter/AppRun /usr/local/bin/cutter
        # rizin engine binaries live inside the AppImage; expose rizin if present.
        RZ="$(find /opt/rawos-tools/cutter -type f -name rizin 2>/dev/null | head -1)"
        [ -n "$RZ" ] && ln -sf "$RZ" /usr/local/bin/rizin
        cat > /usr/share/applications/cutter.desktop <<D
[Desktop Entry]
Type=Application
Name=Cutter
Comment=Rizin-powered reverse engineering platform
Exec=/usr/local/bin/cutter %f
Icon=/opt/rawos-tools/cutter/.DirIcon
Terminal=false
Categories=Development;Debugger;
D
    else warn "Cutter AppImage extraction failed"; fi
else warn "Cutter download failed (radare2 is available as the r2 CLI)"; fi

# ── x64dbg (Windows debugger, run under Wine) - 'snapshot' rolling release ────
X64_URL="$(gh_asset x64dbg/x64dbg snapshot '\.zip$' || true)"
if fetch "$X64_URL" "$CACHE/x64dbg.zip"; then
    rm -rf /opt/rawos-tools/x64dbg; mkdir -p /opt/rawos-tools/x64dbg
    unzip -o "$CACHE/x64dbg.zip" -d /opt/rawos-tools/x64dbg >/dev/null || warn "x64dbg unzip failed"
else warn "x64dbg download failed (run under Wine once fetched)"; fi

# ── fakenet-ng / frida / volatility3 / pwntools are installed via pip (30). ──
log "github tools done."
