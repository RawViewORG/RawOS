#!/usr/bin/env bash
# Generate RawOS branding raster assets (Tokyo Night + the RawView eye) with
# ImageMagick, so the build ships ready-made PNGs and needs no imagemagick in the
# chroot. Run on a host with `convert` + DejaVu fonts:  bash make-assets.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EYE="${RAWVIEW_SRC:-/home/codeminute/RawView}/rawview/qt_ui/resources/app_icon.png"
[ -f "$EYE" ] || { echo "RawView eye icon not found: $EYE"; exit 1; }

FONT_B=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf
FONT_R=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
[ -f "$FONT_B" ] || FONT_B="$FONT_R"

# ── Tokyo Night palette ──────────────────────────────────────────────────────
BG=#1a1b26; BG2=#16161e; FG=#c0caf5; MUTE=#565f89; BLUE=#7aa2f7; DIM=#242844

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$HERE/wallpaper" "$HERE/grub" "$HERE/lightdm" "$HERE/icons" "$HERE/plymouth"

gen() {  # gen <W> <H> <out> <eye_px> <title_pt> <tag_pt>
  local W=$1 H=$2 OUT=$3 EYE_PX=$4 TPT=$5 GPT=$6

  # 1) base vertical gradient
  convert -size "${W}x${H}" gradient:"$BG"-"$BG2" "$TMP/base.png"

  # 2) faint binary "matrix" texture - echoes the eye's pupil (inline text; IM6
  #    policy blocks caption:@file, so pass the string directly).
  local cols=$(( W/230 )); [ "$cols" -lt 1 ] && cols=1
  local rows=$(( H/46 ));  [ "$rows" -lt 1 ] && rows=1
  local BITS; BITS="$(python3 -c "import random;print('\n'.join(' '.join(''.join(random.choice('01') for _ in range(8)) for _ in range($cols)) for _ in range($rows)))")"
  if convert -background none -fill "$DIM" -font "$FONT_R" -pointsize $((H/56)) \
        label:"$BITS" "$TMP/bits.png" 2>/dev/null; then
      convert "$TMP/base.png" "$TMP/bits.png" -gravity center -compose over -composite "$TMP/bg.png"
  else
      cp "$TMP/base.png" "$TMP/bg.png"   # texture is decorative; gradient alone is fine
  fi

  # 3) crisp pixel-art upscale of the eye + soft blue glow behind it
  convert "$EYE" -filter point -resize "${EYE_PX}x${EYE_PX}" "$TMP/eye.png"
  convert "$TMP/eye.png" \
      \( +clone -fill "$BLUE" -colorize 100 -channel A -blur 0x$((EYE_PX/12)) +channel \) \
      +swap -background none -compose over -flatten "$TMP/glow.png" 2>/dev/null || cp "$TMP/eye.png" "$TMP/glow.png"

  local EY=$(( H/2 - EYE_PX )); [ "$EY" -lt $((H/14)) ] && EY=$((H/14))
  convert "$TMP/bg.png" "$TMP/glow.png" -gravity north -geometry +0+${EY} -composite "$TMP/w1.png"

  # 4) wordmark: "Raw" in FG + "OS" in blue, appended
  convert -background none -fill "$FG"   -font "$FONT_B" -pointsize "$TPT" label:"Raw" "$TMP/p1.png"
  convert -background none -fill "$BLUE" -font "$FONT_B" -pointsize "$TPT" label:"OS"  "$TMP/p2.png"
  convert "$TMP/p1.png" "$TMP/p2.png" +append "$TMP/word.png"
  local TY=$(( EY + EYE_PX + TPT/3 ))
  convert "$TMP/w1.png" "$TMP/word.png" -gravity north -geometry +0+${TY} -composite "$TMP/w2.png"

  # 5) tagline + corner footer
  local GY=$(( TY + TPT*7/5 ))
  convert "$TMP/w2.png" \
      -gravity north -font "$FONT_R" -pointsize "$GPT" -fill "$MUTE" \
          -annotate +0+${GY} "reverse engineering, raw." \
      -gravity southeast -font "$FONT_R" -pointsize $((GPT*3/4)) -fill "$MUTE" \
          -annotate +$((W/40))+$((H/40)) "RawOS  ·  Ghostwire" \
      "$OUT"
  echo "  wrote $OUT ($(identify -format '%wx%h' "$OUT"))"
}

# Never overwrite a user-supplied wallpaper - only generate a default if none exists.
if [ -f "$HERE/wallpaper/rawos-wallpaper.png" ]; then
  echo "[assets] keeping existing wallpaper ($(identify -format '%wx%h' "$HERE/wallpaper/rawos-wallpaper.png"))"
else
  echo "[assets] wallpaper 3840x2160 ...";      gen 3840 2160 "$HERE/wallpaper/rawos-wallpaper.png" 760 300 96
fi
echo "[assets] greeter bg 1920x1080 ...";       gen 1920 1080 "$HERE/lightdm/rawos-greeter-bg.png"  360 150 46
# GRUB boot menu: deliberately minimal - no eye (that read as "cult"), just a
# clean dark gradient + the wordmark up top so the menu below stays legible.
echo "[assets] grub bg 1920x1080 (minimal, no eye) ..."
convert -size 1920x1080 gradient:"$BG"-"$BG2" "$TMP/gb.png"
convert -background none -fill "$FG"   -font "$FONT_B" -pointsize 72 label:"Raw" "$TMP/g1.png"
convert -background none -fill "$BLUE" -font "$FONT_B" -pointsize 72 label:"OS"  "$TMP/g2.png"
convert "$TMP/g1.png" "$TMP/g2.png" +append "$TMP/gw.png"
convert "$TMP/gb.png" "$TMP/gw.png" -gravity north -geometry +0+120 -composite \
    -gravity north -font "$FONT_R" -pointsize 26 -fill "$MUTE" -annotate +0+215 "reverse engineering, raw." \
    "$HERE/grub/background.png"
echo "  wrote $HERE/grub/background.png"
echo "[assets] plymouth + icon logo ...";       convert "$EYE" -filter point -resize 320x320 "$HERE/plymouth/logo.png"; cp "$HERE/plymouth/logo.png" "$HERE/icons/rawos-logo.png"
echo "[assets] done."
