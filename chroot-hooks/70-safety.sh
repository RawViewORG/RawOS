#!/usr/bin/env bash
# Runs INSIDE the chroot. Safe-by-default posture for a malware-handling box:
# firewall, an isolated libvirt network for detonation, group membership, and a
# first-run welcome app with the safety warning.
set -euo pipefail
source /rawos-build/chroot.env
log()  { printf '\033[1;34m[70-safety]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[70-safety]\033[0m %s\n' "$*" >&2; }

export DEBIAN_FRONTEND=noninteractive

# ── Firewall: deny inbound, no listening services ────────────────────────────
log "Configuring ufw (default deny incoming) ..."
if command -v ufw >/dev/null 2>&1 || apt-get install -y ufw; then
    ufw --force reset || true
    ufw default deny incoming || true
    ufw default allow outgoing || true   # allow so apt/updates work; analysts isolate per-VM
    ufw --force enable || true
    systemctl enable ufw || true
fi

# ── Isolated libvirt network for detonation guests ───────────────────────────
log "Defining isolated libvirt network 'rawos-isolated' ..."
mkdir -p /etc/libvirt/qemu/networks/autostart
cat > /etc/libvirt/qemu/networks/rawos-isolated.xml <<'EOF'
<network>
  <name>rawos-isolated</name>
  <bridge name='virbr-raw' stp='on' delay='0'/>
  <!-- No <forward/> element => fully isolated: guests talk to each other and
       the host only. Point guests at INetSim/fakenet on the host for fake net. -->
  <ip address='10.66.6.1' netmask='255.255.255.0'>
    <dhcp><range start='10.66.6.10' end='10.66.6.254'/></dhcp>
  </ip>
</network>
EOF
# Autostart symlink is honored once libvirtd defines it on first boot.
ln -sf /etc/libvirt/qemu/networks/rawos-isolated.xml \
       /etc/libvirt/qemu/networks/autostart/rawos-isolated.xml 2>/dev/null || true

# ── First-boot: add human users to analysis groups ───────────────────────────
log "Installing first-boot group-membership service ..."
cat > /usr/local/sbin/rawos-firstboot-groups.sh <<'EOF'
#!/bin/sh
# Add every regular (uid>=1000) human user to the tool groups they need.
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd); do
    for g in sudo libvirt libvirt-qemu kvm wireshark; do
        getent group "$g" >/dev/null 2>&1 && usermod -aG "$g" "$u" 2>/dev/null || true
    done
done
EOF
chmod 755 /usr/local/sbin/rawos-firstboot-groups.sh
cat > /etc/systemd/system/rawos-firstboot-groups.service <<'EOF'
[Unit]
Description=RawOS first-boot: add users to analysis groups
After=multi-user.target
ConditionPathExists=!/var/lib/rawos/firstboot-groups.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rawos-firstboot-groups.sh
ExecStartPost=/bin/sh -c 'mkdir -p /var/lib/rawos && touch /var/lib/rawos/firstboot-groups.done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable rawos-firstboot-groups.service || true

# ── Offline documentation ────────────────────────────────────────────────────
log "Installing offline documentation ..."
install -d /usr/share/rawos/docs
if [ -f /rawos-build/branding/docs/index.html ]; then
    install -m 644 /rawos-build/branding/docs/index.html /usr/share/rawos/docs/index.html
else
    warn "docs source missing (branding/docs/index.html); Docs will fall back to the web URL"
fi
# Small launcher: prefer the local offline docs, fall back to the project URL.
cat > /usr/local/bin/rawos-docs <<EOF
#!/bin/sh
D=/usr/share/rawos/docs/index.html
if [ -f "\$D" ]; then T="file://\$D"; else T="$RAWOS_HOME_URL"; fi
x-www-browser "\$T" 2>/dev/null || xdg-open "\$T" 2>/dev/null || exo-open "\$T" 2>/dev/null
EOF
chmod 755 /usr/local/bin/rawos-docs
cat > /usr/share/applications/rawos-docs.desktop <<EOF
[Desktop Entry]
Type=Application
Name=RawOS Documentation
Comment=Offline RawOS guide and safety notes
Exec=rawos-docs
Icon=help-browser
Terminal=false
Categories=System;Documentation;
EOF

# ── Welcome app (safety warning + quick links) ───────────────────────────────
log "Installing RawOS welcome app ..."
cat > /usr/local/bin/rawos-welcome <<EOF
#!/usr/bin/env bash
# RawOS welcome / safety dialog.
ICON="/usr/share/pixmaps/rawos-logo.png"
MARK="\$HOME/.config/rawos/no-welcome"

# When launched by autostart, honor the user's "don't show again" choice.
if [ "\$1" = "--autostart" ] && [ -f "\$MARK" ]; then
  exit 0
fi

open_docs() { rawos-docs & }

if command -v yad >/dev/null 2>&1; then
  OUT=\$(yad --title="Welcome to $RAWOS_NAME" --window-icon="\$ICON" \\
      --width=600 --height=320 --center --borders=14 --wrap --text-align=left \\
      --form --columns=1 --field="Don't show this again:CHK" FALSE \\
      --text="<b>$RAWOS_NAME $RAWOS_VERSION ($RAWOS_CODENAME)</b> - RawView + a curated malware-RE toolkit.\n\n<b>⚠ Detonate malware only in an isolated VM</b> (virt-manager → network <b>rawos-isolated</b>): snapshot first, keep the host network off. The firewall denies inbound by default.\n\nLaunch <b>RawView</b> from the menu - Ghidra + JDK are preinstalled. Add your Anthropic key in <b>File → Settings</b> for the AI agent." \\
      --button="Open RawView:2" --button="Docs:3" --button="Close:0")
  rc=\$?
  # Persist the "don't show again" choice regardless of which button closed it.
  case "\$OUT" in
    TRUE*) mkdir -p "\$(dirname "\$MARK")"; : > "\$MARK" ;;
    FALSE*) rm -f "\$MARK" ;;
  esac
  [ "\$rc" = "2" ] && (rawview &)
  [ "\$rc" = "3" ] && open_docs
fi
EOF
chmod 755 /usr/local/bin/rawos-welcome

cat > /usr/share/applications/rawos-welcome.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Welcome to RawOS
Comment=RawOS quick start and safety notes
Exec=rawos-welcome
Icon=rawos-logo
Terminal=false
Categories=System;
EOF

# Autostart the welcome app once per new user (honors "don't show again").
mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/rawos-welcome.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Welcome to RawOS
Comment=RawOS quick start and safety notes
Exec=rawos-welcome --autostart
Icon=rawos-logo
Terminal=false
Categories=System;
EOF

log "safety posture configured."
