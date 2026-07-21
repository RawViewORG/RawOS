#!/usr/bin/env bash
# Runs INSIDE the chroot. Makes RawOS pleasant and reliable to actually use:
# no suicide-on-sleep, no screen-lock lockouts, and a working graphical installer.
set -euo pipefail
source /rawos-build/chroot.env
log()  { printf '\033[1;34m[75-use]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[75-use]\033[0m %s\n' "$*" >&2; }

export DEBIAN_FRONTEND=noninteractive

# ── Never suspend/hibernate (it "commits suicide" on VMs and analysis boxes) ──
log "Disabling suspend/hibernate/sleep ..."
for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    ln -sf /dev/null "/etc/systemd/system/$t"   # robust mask that works in a chroot
done
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/rawos.conf <<EOF
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandlePowerKey=poweroff
IdleAction=ignore
EOF

# ── No screen blanking / DPMS / lock (the "black screen that never comes back") ─
log "Disabling screen blanking + lock ..."
PM_DIR=/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p "$PM_DIR"
cat > "$PM_DIR/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="dpms-on-ac-sleep" type="int" value="0"/>
    <property name="dpms-on-ac-off" type="int" value="0"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
    <property name="logind-handle-lid-switch" type="bool" value="false"/>
  </property>
</channel>
EOF
mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/rawos-noblank.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=RawOS no-blank
Exec=sh -c "xset s off; xset -dpms; xset s noblank"
Terminal=false
NoDisplay=true
X-XFCE-Autostart-Phase=Application
EOF

# ── Friction-free admin: let sudo-group users pass polkit without a password ──
# (so the graphical installer / pkexec just work in the live session).
log "Installing polkit rule for sudo-group users ..."
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-rawos-sudo-nopasswd.rules <<'EOF'
// RawOS: admins (sudo group) pass polkit actions without a password prompt.
// Keeps the installer (pkexec calamares) and admin GUIs friction-free.
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("sudo")) { return polkit.Result.YES; }
});
EOF

# ── Networking: actually let NetworkManager manage the interfaces ────────────
# A fresh custom ISO has an empty /etc/netplan and NetworkManager.conf managed=false,
# so NOTHING manages the NICs -> no internet. Ship the same config Ubuntu desktop
# does: hand every device to NetworkManager.
log "Enabling NetworkManager-managed networking ..."
mkdir -p /etc/netplan
cat > /etc/netplan/01-network-manager-all.yaml <<EOF
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 600 /etc/netplan/01-network-manager-all.yaml
# Flip NetworkManager's ifupdown plugin to managed=true.
if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
    sed -i 's/^managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf
fi
# Belt-and-suspenders: NM manages EVERYTHING (ethernet, wifi, VM virtio/e1000).
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-rawos-manage-all.conf <<EOF
[main]
plugins=keyfile,ifupdown
[ifupdown]
managed=true
[device]
wifi.backend=wpa_supplicant
EOF
# Don't let anything mark devices unmanaged.
rm -f /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf 2>/dev/null || true
printf '[keyfile]\nunmanaged-devices=none\n' > /etc/NetworkManager/conf.d/20-rawos-unmanaged-none.conf

systemctl enable NetworkManager.service 2>/dev/null || true
# DNS: systemd-resolved must run so the /etc/resolv.conf stub (set at build time)
# actually resolves names. Without this you get "connected but no websites".
systemctl enable systemd-resolved.service 2>/dev/null || true
# systemd-networkd would fight NM; make sure it's not the one in charge.
systemctl disable systemd-networkd.service 2>/dev/null || true
systemctl mask systemd-networkd.service 2>/dev/null || ln -sf /dev/null /etc/systemd/system/systemd-networkd.service

# Unblock wifi/bluetooth radios at every boot (rfkill can soft-block them).
cat > /etc/systemd/system/rawos-rfkill-unblock.service <<'EOF'
[Unit]
Description=RawOS: unblock all rfkill radios
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock all
[Install]
WantedBy=multi-user.target
EOF
systemctl enable rawos-rfkill-unblock.service 2>/dev/null || \
    ln -sf /etc/systemd/system/rawos-rfkill-unblock.service \
        /etc/systemd/system/multi-user.target.wants/rawos-rfkill-unblock.service

# ── Default web browser so links / the welcome "Docs" button actually open ───
log "Setting the default web browser ..."
BROWSER_DESK=""; BROWSER_BIN=""
if [ -f /usr/share/applications/firefox.desktop ]; then
    BROWSER_DESK=firefox.desktop; BROWSER_BIN=/usr/bin/firefox
elif [ -f /usr/share/applications/org.gnome.Epiphany.desktop ]; then
    BROWSER_DESK=org.gnome.Epiphany.desktop; BROWSER_BIN=/usr/bin/epiphany-browser
elif [ -f /usr/share/applications/epiphany.desktop ]; then
    BROWSER_DESK=epiphany.desktop; BROWSER_BIN=/usr/bin/epiphany-browser
fi
if [ -n "$BROWSER_DESK" ]; then
    [ -x "$BROWSER_BIN" ] && { update-alternatives --install /usr/bin/x-www-browser x-www-browser "$BROWSER_BIN" 200 || true; \
                              update-alternatives --set x-www-browser "$BROWSER_BIN" || true; }
    mkdir -p /etc/skel/.config
    cat > /etc/skel/.config/mimeapps.list <<EOF
[Default Applications]
text/html=$BROWSER_DESK
x-scheme-handler/http=$BROWSER_DESK
x-scheme-handler/https=$BROWSER_DESK
x-scheme-handler/about=$BROWSER_DESK
x-scheme-handler/unknown=$BROWSER_DESK
EOF
else
    warn "no browser .desktop found to set as default"
fi

# ── RawOS installer (our own GTK wizard + proven engine; no Calamares) ───────
log "Installing the RawOS installer (GUI + engine) ..."
install -m 755 /rawos-build/installer/rawos-installer        /usr/local/bin/rawos-installer
install -m 755 /rawos-build/installer/rawos-installer-gui.py /usr/local/bin/rawos-installer-gui

# Launcher: run the GRAPHICAL installer as the normal user. The window always
# opens (no pkexec-over-X fragility); the wizard escalates only the disk-writing
# engine internally. Falls back to the terminal engine only if the GUI can't start
# at all (e.g. missing GTK libraries).
cat > /usr/local/bin/rawos-install <<'INST'
#!/bin/sh
GUI=/usr/local/bin/rawos-installer-gui
# Verify the GUI can import its toolkit before committing to it; if not, fall back.
if [ -x "$GUI" ] && python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" 2>/dev/null; then
    exec "$GUI"
fi
# Fallback: the proven terminal installer (asks for the same details).
if command -v xfce4-terminal >/dev/null 2>&1; then
    exec xfce4-terminal --title="Install RawOS" --geometry=100x36 \
        -e "sh -c 'sudo /usr/local/bin/rawos-installer; exec bash'"
fi
exec x-terminal-emulator -e sh -c "sudo /usr/local/bin/rawos-installer; exec bash"
INST
chmod 755 /usr/local/bin/rawos-install

cat > /usr/share/applications/install-rawos.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Install $RAWOS_NAME
Comment=Install $RAWOS_NAME to your hard disk
Exec=rawos-install
Icon=rawos-logo
Terminal=false
Categories=System;Settings;
Keywords=install;installer;calamares;
EOF
# Put it on the live desktop too.
mkdir -p /etc/skel/Desktop
cp /usr/share/applications/install-rawos.desktop /etc/skel/Desktop/install-rawos.desktop
chmod +x /etc/skel/Desktop/install-rawos.desktop

# ── Calamares config ─────────────────────────────────────────────────────────
# calamares-settings-ubuntu-common ships the MODULE configs but NOT settings.conf,
# unpackfs.conf, users.conf or branding, so Calamares has no sequence and refuses
# to run ("Install does nothing"). Write a complete, standard config here.
log "Writing Calamares settings + missing module configs ..."
mkdir -p /etc/calamares/modules /etc/calamares/branding/rawos

cat > /etc/calamares/settings.conf <<'EOF'
---
modules-search: [ local, /usr/lib/x86_64-linux-gnu/calamares/modules ]
sequence:
- show:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - summary
- exec:
  - partition
  - mount
  - unpackfs
  - machineid
  - fstab
  - locale
  - keyboard
  - localecfg
  - users
  - displaymanager
  - networkcfg
  - hwclock
  - services-systemd
  - grubcfg
  - bootloader
  - umount
- show:
  - finished
branding: rawos
prompt-install: true
dont-chroot: false
oem-setup: false
disable-cancel: false
disable-cancel-during-exec: false
EOF

# Copy the live squashfs onto the target.
cat > /etc/calamares/modules/unpackfs.conf <<'EOF'
---
unpack:
    - source: "/cdrom/casper/filesystem.squashfs"
      sourcefs: "squashfs"
      destination: ""
EOF

cat > /etc/calamares/modules/users.conf <<'EOF'
---
defaultGroups: [ adm, cdrom, sudo, dip, plugdev, lpadmin, libvirt, kvm, wireshark ]
autologinGroup: autologin
doAutologin: false
sudoersGroup: sudo
setRootPassword: false
doReusePassword: false
availableShells: /bin/bash
avatarFilePath: ""
allowWeakPasswords: true
allowWeakPasswordsDefault: true
EOF

cat > /etc/calamares/modules/displaymanager.conf <<'EOF'
---
displaymanagers:
  - lightdm
basicSetup: false
EOF

# THE installer fix: without partition.conf the partition module never sets up a
# root the mount module can mount, so unpackfs rsyncs into RAM-backed /tmp and dies
# with "rsync error code 11". This tells erase-disk to make ESP + ext4 root.
cat > /etc/calamares/modules/partition.conf <<'EOF'
---
efiSystemPartition: "/boot/efi"
efiSystemPartitionSize: 512M
efiSystemPartitionName: "EFI"
userSwapChoices:
    - none
    - small
    - suspend
    - file
drawNestedPartitions: false
alwaysShowPartitionLabels: true
allowManualPartitioning: true
initialPartitioningChoice: erase
initialSwapChoice: none
defaultFileSystemType: "ext4"
availableFileSystemTypes: [ "ext4", "btrfs", "xfs" ]
EOF

# Minimal branding so Calamares has a product identity + a slideshow it can load.
[ -f /usr/share/pixmaps/rawos-logo.png ] && cp /usr/share/pixmaps/rawos-logo.png /etc/calamares/branding/rawos/logo.png
cat > /etc/calamares/branding/rawos/branding.desc <<EOF
---
componentName: rawos
welcomeStyleCalamares: true
welcomeExpandingLogo: true
windowExpanding: normal
strings:
    productName: "$RAWOS_NAME"
    shortProductName: "$RAWOS_NAME"
    version: "$RAWOS_VERSION"
    shortVersion: "$RAWOS_VERSION"
    versionedName: "$RAWOS_NAME $RAWOS_VERSION ($RAWOS_CODENAME)"
    shortVersionedName: "$RAWOS_NAME $RAWOS_VERSION"
    bootloaderEntryName: "$RAWOS_NAME"
    productUrl: "$RAWOS_HOME_URL"
    supportUrl: "$RAWOS_HOME_URL"
images:
    productLogo: "logo.png"
    productIcon: "logo.png"
    productWelcome: "logo.png"
slideshow: "show.qml"
slideshowAPI: 2
style:
    sidebarBackground: "#16161e"
    sidebarText: "#c0caf5"
    sidebarTextSelect: "#7aa2f7"
    sidebarTextHighlight: "#7aa2f7"
EOF
cat > /etc/calamares/branding/rawos/show.qml <<'EOF'
import QtQuick 2.0;
import calamares.slideshow 1.0;
Presentation {
    id: presentation
    Timer { interval: 20000; running: true; repeat: true; onTriggered: presentation.goToNextSlide() }
    Slide { Rectangle { anchors.fill: parent; color: "#1a1b26"
        Text { anchors.centerIn: parent; color: "#c0caf5"; font.pixelSize: 22
               text: "Installing RawOS - reverse engineering, raw." } } }
}
EOF

log "usability + installer configured."
