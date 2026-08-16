#!/usr/bin/env bash
# Build the RawOS live+install ISO end to end.
#   sudo ./build/build-iso.sh
# Requires (host): debootstrap, squashfs-tools, xorriso, grub-pc-bin,
# grub-efi-amd64-bin, mtools, dosfstools. Run as root.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/00-config.sh"

[ "$(id -u)" -eq 0 ] || die "build-iso.sh must run as root (needs debootstrap/chroot/mount)."

# ── Host prerequisites ───────────────────────────────────────────────────────
need=(debootstrap mksquashfs xorriso grub-mkstandalone mkfs.vfat mcopy)
miss=()
for c in "${need[@]}"; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
if [ "${#miss[@]}" -gt 0 ]; then
    die "Missing host tools: ${miss[*]}
  Install: apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools"
fi

HOOKS=(10-apt-packages 20-github-tools 30-pip-tools 35-local-llm 40-ghidra-jdk 50-rawview 60-branding 70-safety 75-usability)
# ONLY_HOOKS=50,60,70 runs just those hooks against the existing chroot (staging +
# cleanup + ISO assembly still happen). Great for iterating on branding without
# re-running apt/pip/ghidra/PyInstaller.  e.g. sudo ONLY_HOOKS=60,70 make iso
if [ -n "${ONLY_HOOKS:-}" ]; then
    IFS=',' read -ra _SEL <<< "$ONLY_HOOKS"
    _NEW=()
    for h in "${HOOKS[@]}"; do
        for s in "${_SEL[@]}"; do case "$h" in "$s"*) _NEW+=("$h");; esac; done
    done
    HOOKS=("${_NEW[@]}")
fi

mkdir -p "$WORK_DIR" "$OUT_DIR" "$CACHE_DIR" "$IMAGE_DIR"

# ── Cleanup handler (always unmount) ─────────────────────────────────────────
unmount_all() {
    for m in dev/pts dev proc sys run; do
        mountpoint -q "$CHROOT_DIR/$m" && umount -lf "$CHROOT_DIR/$m" 2>/dev/null || true
    done
}
trap unmount_all EXIT

# ── Stage 1: debootstrap base ────────────────────────────────────────────────
if [ ! -e "$CHROOT_DIR/etc/os-release" ]; then
    log "debootstrap $UBUNTU_SUITE -> $CHROOT_DIR (this takes a while)..."
    debootstrap --arch="$ARCH" --variant=minbase \
        --include=ca-certificates,gnupg,curl,systemd-sysv,locales,sudo \
        "$UBUNTU_SUITE" "$CHROOT_DIR" "$UBUNTU_MIRROR"
else
    log "Reusing existing chroot at $CHROOT_DIR (delete work/ for a clean build)."
fi

# Stages 2-4 (staging, hooks, cleanup) can be skipped to re-run only the ISO
# assembly against an already-provisioned chroot:  sudo SKIP_HOOKS=1 make iso
if [ "${SKIP_HOOKS:-0}" = "1" ]; then
    log "SKIP_HOOKS=1 - skipping staging/hooks/cleanup; assembling from existing chroot."
else

# ── Stage 2: prepare chroot ──────────────────────────────────────────────────
log "Preparing chroot mounts and staging build inputs..."
# systemd-resolved (installed during hook 10) may have replaced the chroot's
# resolv.conf with a symlink to /run/... which dangles here - remove it first so
# we always write a real file for in-chroot DNS.
rm -f "$CHROOT_DIR/etc/resolv.conf"
cp -f /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"
echo "rawos" > "$CHROOT_DIR/etc/hostname"
mount --bind /dev  "$CHROOT_DIR/dev"
mount --bind /run  "$CHROOT_DIR/run"
mount -t proc proc "$CHROOT_DIR/proc"
mount -t sysfs sys "$CHROOT_DIR/sys"
mount -t devpts pts "$CHROOT_DIR/dev/pts"

# Stage the RawOS build tree into the chroot.
STAGE="$CHROOT_DIR/rawos-build"
rm -rf "$STAGE"; mkdir -p "$STAGE/cache"
cp -a "$RAWOS_ROOT/chroot-hooks" "$RAWOS_ROOT/packages" "$RAWOS_ROOT/patches" "$RAWOS_ROOT/branding" "$RAWOS_ROOT/installer" "$STAGE/"
[ -d "$CACHE_DIR" ] && cp -a "$CACHE_DIR/." "$STAGE/cache/" 2>/dev/null || true

# Stage the RawView source (exclude heavy build junk but keep ghidra/temurin bundles).
log "Staging RawView source from $RAWVIEW_SRC ..."
[ -f "$RAWVIEW_SRC/pyproject.toml" ] || die "RawView source not found at $RAWVIEW_SRC"
rsync -a --delete \
    --exclude '.git' --exclude '.venv' --exclude 'dist' --exclude 'build' \
    --exclude 'ghidra_projects' --exclude 'work' --exclude 'work_recovery' \
    --exclude '__pycache__' --exclude 'dist_installer' \
    "$RAWVIEW_SRC/" "$STAGE/rawview-src/"

# Write the in-chroot environment consumed by every hook.
cat > "$STAGE/chroot.env" <<EOF
export RAWOS_NAME="$RAWOS_NAME"
export RAWOS_ID="$RAWOS_ID"
export RAWOS_VERSION="$RAWOS_VERSION"
export RAWOS_CODENAME="$RAWOS_CODENAME"
export RAWOS_HOME_URL="$RAWOS_HOME_URL"
export RAWOS_DISCORD_URL="$RAWOS_DISCORD_URL"
export UBUNTU_SUITE="$UBUNTU_SUITE"
export UBUNTU_MIRROR="$UBUNTU_MIRROR"
export GHIDRA_VERSION="$GHIDRA_VERSION"
export GHIDRA_BUILD_DATE="$GHIDRA_BUILD_DATE"
export TEMURIN_MAJOR="$TEMURIN_MAJOR"
export RAWVIEW_VERSION="$RAWVIEW_VERSION"
export RAWVIEW_ANTHROPIC_MODEL="$RAWVIEW_ANTHROPIC_MODEL"
export RAWOS_THEME="$RAWOS_THEME"
export TN_BG="$TN_BG"; export TN_BG_DARK="$TN_BG_DARK"; export TN_FG="$TN_FG"
export TN_ACCENT="$TN_ACCENT"; export TN_ACCENT2="$TN_ACCENT2"
export TN_GREEN="$TN_GREEN"; export TN_RED="$TN_RED"
export TARGET_GHIDRA_DIR="$TARGET_GHIDRA_DIR"
export TARGET_JDK_DIR="$TARGET_JDK_DIR"
export TARGET_RAWVIEW_ENV="$TARGET_RAWVIEW_ENV"
export RAWVIEW_SRC_IN_CHROOT="/rawos-build/rawview-src"
EOF

# ── Stage 3: run hooks in order ──────────────────────────────────────────────
for h in "${HOOKS[@]}"; do
    log "── hook: $h ──"
    chroot "$CHROOT_DIR" /bin/bash "/rawos-build/chroot-hooks/$h.sh"
done

# Persist any freshly downloaded assets back to the host cache.
cp -a "$STAGE/cache/." "$CACHE_DIR/" 2>/dev/null || true

# ── Stage 4: clean the chroot ────────────────────────────────────────────────
log "Cleaning chroot..."
chroot "$CHROOT_DIR" apt-get clean || true
rm -rf "$STAGE"
# DNS on the shipped system: point resolv.conf at the systemd-resolved stub so
# name resolution works (an empty file here = "connected but no websites").
rm -f "$CHROOT_DIR/etc/resolv.conf"
ln -sf ../run/systemd/resolve/stub-resolv.conf "$CHROOT_DIR/etc/resolv.conf"
rm -rf "$CHROOT_DIR/tmp/"* "$CHROOT_DIR/var/lib/apt/lists/"* "$CHROOT_DIR/var/log/"*.log
: > "$CHROOT_DIR/etc/machine-id"
unmount_all
fi   # end SKIP_HOOKS guard
trap - EXIT

# ── Stage 5: assemble the ISO tree ───────────────────────────────────────────
log "Assembling ISO image tree..."
rm -rf "$IMAGE_DIR"; mkdir -p "$IMAGE_DIR/casper" "$IMAGE_DIR/boot/grub" "$IMAGE_DIR/EFI/boot" "$IMAGE_DIR/.disk"

# Kernel + initrd. The kernel postinst defers initramfs generation to a trigger
# that can be a no-op inside a chroot, so generate it explicitly if it's missing.
if ! ls "$CHROOT_DIR"/boot/initrd.img-* >/dev/null 2>&1; then
    log "initramfs missing - generating it inside the chroot..."
    mount --bind /dev "$CHROOT_DIR/dev"
    mount -t proc  proc "$CHROOT_DIR/proc"
    mount -t sysfs sys  "$CHROOT_DIR/sys"
    KVER="$(ls "$CHROOT_DIR"/lib/modules | sort -V | tail -1)"
    log "kernel version: $KVER"
    chroot "$CHROOT_DIR" update-initramfs -c -k "$KVER" || \
    chroot "$CHROOT_DIR" update-initramfs -u -k "$KVER"
    umount -lf "$CHROOT_DIR/dev" "$CHROOT_DIR/proc" "$CHROOT_DIR/sys" 2>/dev/null || true
fi
KERNEL="$(ls -1 "$CHROOT_DIR"/boot/vmlinuz-* | sort -V | tail -1)"
INITRD="$(ls -1 "$CHROOT_DIR"/boot/initrd.img-* | sort -V | tail -1)"
[ -n "$KERNEL" ] || die "no kernel in $CHROOT_DIR/boot"
[ -n "$INITRD" ] || die "no initramfs in $CHROOT_DIR/boot after generation"
cp "$KERNEL" "$IMAGE_DIR/casper/vmlinuz"
cp "$INITRD" "$IMAGE_DIR/casper/initrd"

# Manifest + squashfs
log "Building squashfs (slow)..."
chroot "$CHROOT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' > "$IMAGE_DIR/casper/filesystem.manifest"
# Keep /boot (kernel + initrd) IN the squashfs so an installed system is bootable
# (the live boot uses the separate copies in /casper). Only exclude the build tree.
# mksquashfs otherwise runs one compressor thread per CPU and sizes its cache from
# TOTAL RAM (~25%), which takes no account of what else is running - enough to OOM a
# busy desktop mid-build. Size it from AVAILABLE memory and cap the thread count.
# Override with SQUASHFS_PROCS / SQUASHFS_MEM.
if [ -z "${SQUASHFS_PROCS:-}" ]; then
    SQUASHFS_PROCS=$(nproc)
    [ "$SQUASHFS_PROCS" -gt 4 ] && SQUASHFS_PROCS=4
fi
if [ -z "${SQUASHFS_MEM:-}" ]; then
    avail_mb=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
    SQUASHFS_MEM=$(( avail_mb / 4 ))          # a quarter of what is actually free
    [ "$SQUASHFS_MEM" -lt 512 ] && SQUASHFS_MEM=512
    [ "$SQUASHFS_MEM" -gt 4096 ] && SQUASHFS_MEM=4096
    SQUASHFS_MEM="${SQUASHFS_MEM}M"
fi
log "squashfs: ${SQUASHFS_PROCS} threads, ${SQUASHFS_MEM} cache"
mksquashfs "$CHROOT_DIR" "$IMAGE_DIR/casper/filesystem.squashfs" \
    -noappend -comp zstd -wildcards -e 'rawos-build/*' \
    -processors "$SQUASHFS_PROCS" -mem "$SQUASHFS_MEM"
printf '%s' "$(du -sx --block-size=1 "$CHROOT_DIR" | cut -f1)" > "$IMAGE_DIR/casper/filesystem.size"

# .disk metadata
echo "$RAWOS_NAME $RAWOS_VERSION ($RAWOS_CODENAME) - $ARCH" > "$IMAGE_DIR/.disk/info"
touch "$IMAGE_DIR/.disk/base_installable"
echo "full_cd/single" > "$IMAGE_DIR/.disk/cd_type"

# ── Stage 6: GRUB config (BIOS + UEFI) ───────────────────────────────────────
# Plain black text menu - no gfxterm/theme/background (that rendering broke on
# some hardware). Simple and reliable; the branding lives in Plymouth + desktop.
cat > "$IMAGE_DIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=10
insmod all_video
insmod iso9660
insmod search
# The standalone GRUB image boots with \$root pointing at its own boot image, not
# the ISO. Locate the ISO9660 volume (by a file it contains) and set root to it so
# /casper/* paths resolve.
search --no-floppy --set=root --file /casper/vmlinuz
menuentry "Try or Install $RAWOS_NAME" {
    linux  /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
menuentry "$RAWOS_NAME (safe graphics)" {
    linux  /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd
}
EOF

# ── Stage 7: build the hybrid ISO ────────────────────────────────────────────
log "Creating BIOS + UEFI GRUB boot images..."
GRUB_MODULES="normal iso9660 biosdisk part_msdos part_gpt fat ext2 configfile linux ls search search_label all_video png gfxterm gfxterm_background gfxmenu"
# BIOS core
grub-mkstandalone --format=i386-pc \
    --output="$IMAGE_DIR/boot/grub/core.img" \
    --install-modules="$GRUB_MODULES" --modules="$GRUB_MODULES" --locales="" --fonts="" \
    "boot/grub/grub.cfg=$IMAGE_DIR/boot/grub/grub.cfg"
cat /usr/lib/grub/i386-pc/cdboot.img "$IMAGE_DIR/boot/grub/core.img" > "$IMAGE_DIR/boot/grub/bios.img"

# UEFI bootx64.efi + FAT ESP image
grub-mkstandalone --format=x86_64-efi \
    --output="$IMAGE_DIR/EFI/boot/bootx64.efi" \
    --locales="" --fonts="" \
    "boot/grub/grub.cfg=$IMAGE_DIR/boot/grub/grub.cfg"
( cd "$IMAGE_DIR" && \
  dd if=/dev/zero of=efiboot.img bs=1M count=10 && \
  mkfs.vfat -n RAWOS_EFI efiboot.img && \
  mmd  -i efiboot.img ::/EFI ::/EFI/BOOT && \
  mcopy -i efiboot.img EFI/boot/bootx64.efi ::/EFI/BOOT/BOOTX64.EFI )

log "Running xorriso -> $OUT_DIR/$ISO_FILENAME ..."
xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames -volid "$ISO_LABEL" \
    -output "$OUT_DIR/$ISO_FILENAME" \
    -eltorito-boot boot/grub/bios.img \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        --eltorito-catalog boot/grub/boot.cat \
        --grub2-boot-info --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
    -eltorito-alt-boot -e efiboot.img -no-emul-boot -isohybrid-gpt-basdat \
    -append_partition 2 0xef "$IMAGE_DIR/efiboot.img" \
    "$IMAGE_DIR"

( cd "$OUT_DIR" && sha256sum "$ISO_FILENAME" > "$ISO_FILENAME.sha256" )
log "DONE: $OUT_DIR/$ISO_FILENAME"
ls -lh "$OUT_DIR/$ISO_FILENAME"
