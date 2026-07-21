#!/usr/bin/env bash
# Runs INSIDE the chroot. Installs the RawOS apt package manifest.
set -euo pipefail
source /rawos-build/chroot.env
log()  { printf '\033[1;34m[10-apt]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[10-apt]\033[0m %s\n' "$*" >&2; }

export DEBIAN_FRONTEND=noninteractive

# ── Locale: fix the endless "perl: Setting locale failed" / "Cannot set LC_*" ─
# spam by actually generating and setting a UTF-8 locale before anything runs.
log "Generating en_US.UTF-8 locale ..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen en_US.UTF-8 || warn "locale-gen failed"
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 || true
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 LANGUAGE=en_US:en

log "Configuring apt sources for ${UBUNTU_SUITE} (main restricted universe multiverse)..."
cat > /etc/apt/sources.list <<EOF
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE} main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-updates main restricted universe multiverse
deb ${UBUNTU_MIRROR} ${UBUNTU_SUITE}-security main restricted universe multiverse
EOF

# ── Firefox from Mozilla's APT repo (the noble `firefox` deb is a snap shim that
#    breaks in a custom live ISO). Real .deb, no snapd needed. ──────────────────
log "Adding Mozilla APT repo for Firefox ..."
install -d -m 0755 /etc/apt/keyrings
MOZ_OK=0
if curl -fsSL --retry 3 https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc; then
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
        > /etc/apt/preferences.d/mozilla
    MOZ_OK=1
else
    warn "Mozilla repo key fetch failed - skipping Firefox (Epiphany is the browser)"
fi

log "apt-get update..."
apt-get update -y

log "Upgrading base..."
apt-get upgrade -y

# wireshark/tshark ask (via debconf) whether non-root users may capture - preseed 'yes'.
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
# libvirt/qemu: no interactive prompts expected, but keep noninteractive.

log "Reading package manifest..."
mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' /rawos-build/packages/package-list.txt | sed 's/#.*//' | awk '{print $1}')
log "Installing ${#PKGS[@]} packages..."

# Install; tolerate individual failures so one missing package (e.g. a rename
# between Ubuntu point releases) does not abort the whole build. Report at end.
FAILED=()
if ! apt-get install -y --no-install-recommends "${PKGS[@]}"; then
    warn_note="one-shot install failed; retrying package-by-package to isolate"
    printf '\033[1;33m[10-apt]\033[0m %s\n' "$warn_note"
    for p in "${PKGS[@]}"; do
        apt-get install -y --no-install-recommends "$p" || FAILED+=("$p")
    done
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '\033[1;33m[10-apt] WARNING: %d packages failed: %s\033[0m\n' "${#FAILED[@]}" "${FAILED[*]}"
    printf '%s\n' "${FAILED[@]}" > /rawos-build/apt-failed.txt
fi

# Real Firefox - only from the Mozilla repo (never the snap-shim).
if [ "$MOZ_OK" = 1 ]; then
    log "Installing Firefox from the Mozilla repo ..."
    apt-get install -y firefox || warn "Firefox install failed (Epiphany is still available)"
fi

log "Enabling display + libvirt services for the installed system..."
systemctl enable lightdm.service   || true
systemctl set-default graphical.target || true
systemctl enable libvirtd.service  || true
systemctl enable NetworkManager.service || true

log "apt packages done."
