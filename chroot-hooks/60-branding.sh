#!/usr/bin/env bash
# Runs INSIDE the chroot. Applies the RawOS (Tokyo Night) identity across the
# whole desktop: os-release, Plymouth, GRUB, LightDM, XFCE defaults, Qt/Kvantum,
# fastfetch, wallpaper. Best-effort per surface - a missing themer never aborts.
set -euo pipefail
source /rawos-build/chroot.env
log()  { printf '\033[1;34m[60-brand]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[60-brand]\033[0m %s\n' "$*" >&2; }

BRAND="/rawos-build/branding"
CACHE="/rawos-build/cache"
export DEBIAN_FRONTEND=noninteractive

# ── os-release / lsb-release ─────────────────────────────────────────────────
log "Writing os-release / lsb-release ..."
cat > /etc/os-release <<EOF
NAME="$RAWOS_NAME"
PRETTY_NAME="$RAWOS_NAME $RAWOS_VERSION ($RAWOS_CODENAME)"
ID=$RAWOS_ID
ID_LIKE=ubuntu
VERSION="$RAWOS_VERSION ($RAWOS_CODENAME)"
VERSION_ID="$RAWOS_VERSION"
HOME_URL="$RAWOS_HOME_URL"
SUPPORT_URL="$RAWOS_DISCORD_URL"
BUG_REPORT_URL="$RAWOS_HOME_URL/issues"
EOF
# On Ubuntu /etc/os-release is a symlink to /usr/lib/os-release, so the cat above
# already wrote through it. Only copy when they are genuinely different files.
[ /etc/os-release -ef /usr/lib/os-release ] || cp -f /etc/os-release /usr/lib/os-release
cat > /etc/lsb-release <<EOF
DISTRIB_ID=$RAWOS_NAME
DISTRIB_RELEASE=$RAWOS_VERSION
DISTRIB_CODENAME=$RAWOS_CODENAME
DISTRIB_DESCRIPTION="$RAWOS_NAME $RAWOS_VERSION ($RAWOS_CODENAME)"
EOF

# ── Logo / wallpaper assets ──────────────────────────────────────────────────
log "Installing logo + wallpaper ..."
mkdir -p /usr/share/backgrounds/rawos /usr/share/pixmaps
LOGO_SRC=""
# Prefer the small square app icon (256px) over the wide banner (920px) so dialogs
# that show this image (e.g. the welcome app) don't blow up to banner width.
for c in "$BRAND/icons/rawos-logo.png" \
         "$RAWVIEW_SRC_IN_CHROOT/rawview/qt_ui/resources/app_icon.png" \
         "$RAWVIEW_SRC_IN_CHROOT/assets/banner.png"; do
    [ -f "$c" ] && { LOGO_SRC="$c"; break; }
done
[ -n "$LOGO_SRC" ] && cp "$LOGO_SRC" /usr/share/pixmaps/rawos-logo.png || warn "no logo asset found"

WALL="$BRAND/wallpaper/rawos-wallpaper.png"
if [ -f "$WALL" ]; then
    cp "$WALL" /usr/share/backgrounds/rawos/rawos-wallpaper.png
elif command -v convert >/dev/null 2>&1 && [ -n "$LOGO_SRC" ]; then
    # Generate a simple Tokyo Night wallpaper with the logo centered.
    convert -size 3840x2160 "xc:${TN_BG}" \
        \( "$LOGO_SRC" -resize 1200x \) -gravity center -composite \
        /usr/share/backgrounds/rawos/rawos-wallpaper.png || warn "wallpaper gen failed"
else
    warn "no wallpaper (ship branding/wallpaper/rawos-wallpaper.png or install imagemagick)"
fi

# Dedicated login/GRUB backgrounds (shipped by branding/make-assets.sh).
[ -f "$BRAND/lightdm/rawos-greeter-bg.png" ] && \
    cp "$BRAND/lightdm/rawos-greeter-bg.png" /usr/share/backgrounds/rawos/rawos-greeter-bg.png
GREETER_BG=/usr/share/backgrounds/rawos/rawos-greeter-bg.png
[ -f "$GREETER_BG" ] || GREETER_BG=/usr/share/backgrounds/rawos/rawos-wallpaper.png

# ── GTK + icon theme (Tokyo Night, best-effort fetch, fallback to dark) ───────
log "Installing GTK theme ..."
GTK_THEME="Greybird-dark"   # safe fallback shipped by xfce4-goodies
TN_GTK_ZIP="$CACHE/tokyonight-gtk.zip"
if [ -s "$TN_GTK_ZIP" ] || curl -fsL --retry 2 -o "$TN_GTK_ZIP" \
     "https://github.com/Fausto-Korpsvart/Tokyo-Night-GTK-Theme/archive/refs/heads/master.zip" 2>/dev/null; then
    tmp="$(mktemp -d)"; unzip -qo "$TN_GTK_ZIP" -d "$tmp" || true
    THEMESRC="$(find "$tmp" -type d -path '*themes*/Tokyonight-Dark*' | head -1)"
    if [ -n "$THEMESRC" ]; then
        mkdir -p /usr/share/themes
        cp -a "$THEMESRC" "/usr/share/themes/$(basename "$THEMESRC")"
        GTK_THEME="$(basename "$THEMESRC")"
        log "Installed GTK theme: $GTK_THEME"
    fi
    rm -rf "$tmp"
else
    warn "Tokyo Night GTK theme fetch failed; using $GTK_THEME"
fi
ICON_THEME="Papirus-Dark"
# Guarantee the chosen GTK theme actually exists on disk, else the desktop just
# falls back to the ugly default. greybird-gtk-theme is in the manifest.
[ -d "/usr/share/themes/$GTK_THEME" ] || GTK_THEME="Greybird-dark"
[ -d "/usr/share/themes/$GTK_THEME" ] || GTK_THEME="Default"
[ -d "/usr/share/icons/$ICON_THEME" ] || ICON_THEME="Adwaita"
log "Using GTK theme: $GTK_THEME, icons: $ICON_THEME"

# ── Plymouth boot splash ─────────────────────────────────────────────────────
log "Configuring Plymouth splash ..."
PT_DIR="/usr/share/plymouth/themes/rawos"
mkdir -p "$PT_DIR"
[ -f /usr/share/pixmaps/rawos-logo.png ] && cp /usr/share/pixmaps/rawos-logo.png "$PT_DIR/logo.png"
cat > "$PT_DIR/rawos.plymouth" <<EOF
[Plymouth Theme]
Name=RawOS
Description=RawOS Tokyo Night splash
ModuleName=script

[script]
ImageDir=$PT_DIR
ScriptFile=$PT_DIR/rawos.script
EOF
TN_BG_R="0.101"; TN_BG_G="0.105"; TN_BG_B="0.149"   # #1a1b26 normalized
cat > "$PT_DIR/rawos.script" <<EOF
Window.SetBackgroundTopColor($TN_BG_R, $TN_BG_G, $TN_BG_B);
Window.SetBackgroundBottomColor($TN_BG_R, $TN_BG_G, $TN_BG_B);
logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.sprite.SetX(Window.GetWidth()/2 - logo.image.GetWidth()/2);
logo.sprite.SetY(Window.GetHeight()/2 - logo.image.GetHeight()/2);
progress = 0;
fun refresh_cb() { progress++; }
Plymouth.SetRefreshFunction(refresh_cb);
EOF
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    plymouth-set-default-theme rawos || warn "plymouth-set-default-theme failed"
    update-initramfs -u || warn "update-initramfs failed (will regenerate at install)"
fi

# ── GRUB (installed-system) - plain black text menu, just rebranded name ─────
log "Configuring GRUB (plain) ..."
sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="RawOS"/' /etc/default/grub 2>/dev/null || \
    echo 'GRUB_DISTRIBUTOR="RawOS"' >> /etc/default/grub
# Make sure no leftover theme/background is referenced (keep it plain + reliable).
sed -i '/^GRUB_THEME=/d;/^GRUB_BACKGROUND=/d' /etc/default/grub 2>/dev/null || true
rm -rf /boot/grub/themes/rawos

# ── LightDM greeter ──────────────────────────────────────────────────────────
log "Configuring LightDM greeter ..."
mkdir -p /etc/lightdm
cat > /etc/lightdm/lightdm-gtk-greeter.conf <<EOF
[greeter]
background = $GREETER_BG
theme-name = $GTK_THEME
icon-theme-name = $ICON_THEME
font-name = JetBrains Mono 11
user-background = false
indicators = ~host;~spacer;~clock;~spacer;~session;~power
EOF

# ── XFCE defaults for every new user (/etc/skel) ─────────────────────────────
log "Seeding XFCE defaults into /etc/skel ..."
SKEL_XFCE="/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$SKEL_XFCE"
cat > "$SKEL_XFCE/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$GTK_THEME"/>
    <property name="IconThemeName" type="string" value="$ICON_THEME"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Noto Sans 10"/>
    <property name="MonospaceFontName" type="string" value="JetBrains Mono 11"/>
  </property>
</channel>
EOF
cat > "$SKEL_XFCE/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$GTK_THEME"/>
    <property name="title_font" type="string" value="JetBrains Mono Bold 10"/>
  </property>
</channel>
EOF
cat > "$SKEL_XFCE/xfce4-desktop.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="/usr/share/backgrounds/rawos/rawos-wallpaper.png"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF

# XFCE keys the backdrop to the monitor's connector name (e.g. "Virtual-1" in a
# VM), which won't match the hardcoded monitor0 above - so also set the wallpaper
# on whatever monitors actually exist, at first login, via a tiny autostart script.
cat > /usr/local/bin/rawos-set-wallpaper <<'WSET'
#!/bin/sh
# Apply the RawOS wallpaper on EVERY real monitor. XFCE keys the backdrop to the
# connector name (Virtual-1 in a VM, eDP-1/HDMI-1 on hardware), so we enumerate
# actual outputs with xrandr instead of guessing "monitor0".
WP=/usr/share/backgrounds/rawos/rawos-wallpaper.png
[ -f "$WP" ] || exit 0
# Wait for X + xfdesktop to be up.
for _ in $(seq 1 20); do xfconf-query -c xfce4-desktop -l >/dev/null 2>&1 && break; sleep 1; done

set_prop() { # path type value
    xfconf-query -c xfce4-desktop -p "$1" -n -t "$2" -s "$3" 2>/dev/null || \
    xfconf-query -c xfce4-desktop -p "$1" -s "$3" 2>/dev/null
}

# 1) Every connected xrandr output, workspace0.
if command -v xrandr >/dev/null 2>&1; then
    for MON in $(xrandr --query 2>/dev/null | awk '/ connected/{print $1}'); do
        set_prop "/backdrop/screen0/monitor$MON/workspace0/last-image"  string "$WP"
        set_prop "/backdrop/screen0/monitor$MON/workspace0/image-style" int    5
        set_prop "/backdrop/screen0/monitor$MON/image-path"             string "$WP"
    done
fi
# 2) Any backdrop props xfdesktop already created.
xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E 'last-image$|image-path$' | while read -r p; do
    xfconf-query -c xfce4-desktop -p "$p" -s "$WP" 2>/dev/null
done
xfconf-query -c xfce4-desktop -l 2>/dev/null | grep 'image-style$' | while read -r p; do
    xfconf-query -c xfce4-desktop -p "$p" -s 5 2>/dev/null
done
# 3) Legacy fallback + force a repaint.
set_prop "/backdrop/screen0/monitor0/workspace0/last-image" string "$WP"
xfdesktop --reload 2>/dev/null || true
WSET
chmod 755 /usr/local/bin/rawos-set-wallpaper

mkdir -p /etc/skel/.config/autostart
cat > /etc/skel/.config/autostart/rawos-wallpaper.desktop <<EOF
[Desktop Entry]
Type=Application
Name=RawOS Wallpaper
Exec=rawos-set-wallpaper
Terminal=false
X-XFCE-Autostart-Phase=Application
NoDisplay=true
EOF

# xfce4-terminal Tokyo Night palette
mkdir -p /etc/skel/.config/xfce4/terminal
cat > /etc/skel/.config/xfce4/terminal/terminalrc <<EOF
[Configuration]
FontName=JetBrains Mono 11
ColorForeground=$TN_FG
ColorBackground=$TN_BG
ColorCursor=$TN_ACCENT
ColorBold=$TN_FG
ColorPalette=#15161e;#f7768e;#9ece6a;#e0af68;#7aa2f7;#bb9af7;#7dcfff;#a9b1d6;#414868;#f7768e;#9ece6a;#e0af68;#7aa2f7;#bb9af7;#7dcfff;#c0caf5
MiscAlwaysShowTabs=FALSE
MiscBordersDefault=TRUE
ScrollingUnlimited=TRUE
EOF

# ── Qt theming (Kvantum / qt6ct) so Cutter etc. can opt in ───────────────────
# NOTE: deliberately NOT setting a global QT_QPA_PLATFORMTHEME. Forcing qt6ct
# breaks any Qt app that can't load that plugin - Qt5 apps (DIE, edb) look for it
# in the Qt5 plugin dir, and the frozen PySide6 RawView in its own bundle - all
# fail to start. We ship the qt6ct/Kvantum configs so users can enable it per
# session if they want; leaving it unset keeps every app launching reliably.
mkdir -p /etc/skel/.config/qt6ct /etc/skel/.config/Kvantum
[ -d "$BRAND/kvantum" ] && cp -a "$BRAND/kvantum/." /etc/skel/.config/Kvantum/ 2>/dev/null || true
cat > /etc/skel/.config/qt6ct/qt6ct.conf <<EOF
[Appearance]
style=kvantum-dark
icon_theme=$ICON_THEME
EOF

# ── fastfetch RawOS branding ─────────────────────────────────────────────────
log "Configuring fastfetch ..."
mkdir -p /etc/skel/.config/fastfetch
if [ -f "$BRAND/fastfetch/config.jsonc" ]; then
    cp "$BRAND/fastfetch/config.jsonc" /etc/skel/.config/fastfetch/config.jsonc
fi
if [ -f "$BRAND/fastfetch/logo.txt" ]; then
    mkdir -p /usr/share/rawos
    cp "$BRAND/fastfetch/logo.txt" /usr/share/rawos/logo.txt
fi
# Greet on interactive login shells.
cat > /etc/profile.d/99-rawos-fastfetch.sh <<'EOF'
if command -v fastfetch >/dev/null 2>&1 && [ -n "$PS1" ] && [ -z "$RAWOS_GREETED" ]; then
    export RAWOS_GREETED=1
    fastfetch 2>/dev/null || true
fi
EOF

# ── RawView launcher hardening (Qt platform theme) ───────────────────────────
# RawView is a frozen PySide6 bundle with its own Qt and NO qt6ct plugin, so the
# global QT_QPA_PLATFORMTHEME=qt6ct set above (for system Qt apps like Cutter)
# makes RawView abort before its window opens. Neutralize it in RawView's launcher
# only. (Lives here, not in 50-rawview, so branding-only rebuilds pick it up.)
if [ -x /opt/rawview/RawView ]; then
    log "Hardening RawView launcher against QT_QPA_PLATFORMTHEME ..."
    cat > /usr/bin/rawview <<'LAUNCH'
#!/bin/sh
# RawView themes itself internally (Tokyo Night); don't let a system Qt platform
# theme plugin that isn't bundled here abort startup.
export QT_QPA_PLATFORMTHEME=
export QT_STYLE_OVERRIDE=
exec /opt/rawview/RawView "$@"
LAUNCH
    chmod 755 /usr/bin/rawview
    [ -f /usr/share/applications/rawview.desktop ] && \
        sed -i 's#^Exec=.*#Exec=/usr/bin/rawview %u#' /usr/share/applications/rawview.desktop
fi

log "branding done (GTK=$GTK_THEME, icons=$ICON_THEME)."
