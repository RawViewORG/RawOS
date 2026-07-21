#!/usr/bin/env bash
# Turn the built RawOS rootfs (work/chroot, produced by build-iso.sh) into
# bootable VM appliances: a QEMU .qcow2 and a VirtualBox .ova.
#   sudo ./build/build-appliances.sh
# Requires: qemu-img, parted, dosfstools, e2fsprogs, rsync, and a chroot with
# grub-efi/grub-pc already installed (the RawOS chroot has both).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/00-config.sh"

[ "$(id -u)" -eq 0 ] || die "build-appliances.sh must run as root (loop devices + chroot)."
[ -d "$CHROOT_DIR/etc" ] || die "No rootfs at $CHROOT_DIR. Run build-iso.sh first."

for c in qemu-img parted mkfs.vfat mkfs.ext4 rsync losetup; do
    command -v "$c" >/dev/null 2>&1 || die "missing host tool: $c"
done

SIZE_GB="${APPLIANCE_SIZE_GB:-40}"
RAW="$WORK_DIR/${RAWOS_ID}-${RAWOS_VERSION}.raw"
QCOW="$OUT_DIR/${RAWOS_ID}-${RAWOS_VERSION}-${ARCH}.qcow2"
VMDK="$WORK_DIR/${RAWOS_ID}-${RAWOS_VERSION}-${ARCH}.vmdk"
OVA="$OUT_DIR/${RAWOS_ID}-${RAWOS_VERSION}-${ARCH}.ova"
DEFAULT_USER="${RAWOS_DEFAULT_USER:-analyst}"
DEFAULT_PASS="${RAWOS_DEFAULT_PASS:-rawos}"

mkdir -p "$OUT_DIR" "$WORK_DIR"
MNT="$WORK_DIR/mnt"; mkdir -p "$MNT"
LOOP=""
cleanup() {
    for m in dev/pts dev proc sys run boot/efi ""; do
        mountpoint -q "$MNT/$m" && umount -lf "$MNT/$m" 2>/dev/null || true
    done
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

# ── Raw disk: GPT with ESP + ext4 root ───────────────────────────────────────
log "Creating ${SIZE_GB}G raw disk..."
rm -f "$RAW"; qemu-img create -f raw "$RAW" "${SIZE_GB}G" >/dev/null
parted -s "$RAW" mklabel gpt
parted -s "$RAW" mkpart ESP fat32 1MiB 513MiB
parted -s "$RAW" set 1 esp on
parted -s "$RAW" mkpart root ext4 513MiB 100%

LOOP="$(losetup -Pf --show "$RAW")"
log "Loop device: $LOOP"
mkfs.vfat -F32 -n RAWOS_EFI "${LOOP}p1" >/dev/null
mkfs.ext4 -L RAWOS_ROOT "${LOOP}p2" >/dev/null

mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "${LOOP}p1" "$MNT/boot/efi"

# ── Copy rootfs ──────────────────────────────────────────────────────────────
log "Copying rootfs into disk (rsync)..."
rsync -aHAX --numeric-ids \
    --exclude '/proc/*' --exclude '/sys/*' --exclude '/dev/*' \
    --exclude '/run/*' --exclude '/tmp/*' --exclude '/rawos-build' \
    "$CHROOT_DIR/" "$MNT/"

# ── fstab ────────────────────────────────────────────────────────────────────
ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p2")"
EFI_UUID="$(blkid -s UUID -o value "${LOOP}p1")"
cat > "$MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID /          ext4  errors=remount-ro 0 1
UUID=$EFI_UUID  /boot/efi  vfat  umask=0077        0 1
EOF

# ── Default user for the appliance ───────────────────────────────────────────
log "Creating default user '$DEFAULT_USER'..."
cp -f /etc/resolv.conf "$MNT/etc/resolv.conf"
for fs in dev proc sys run; do mount --bind "/$fs" "$MNT/$fs"; done
chroot "$MNT" /bin/bash -euo pipefail <<CHROOT_EOF
id "$DEFAULT_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$DEFAULT_USER"
echo "$DEFAULT_USER:$DEFAULT_PASS" | chpasswd
# Install GRUB for both BIOS and UEFI so the appliance boots on either firmware.
grub-install --target=i386-pc --boot-directory=/boot "$LOOP" || true
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=RawOS --removable --recheck || true
update-grub || grub-mkconfig -o /boot/grub/grub.cfg || true
CHROOT_EOF

cleanup; trap - EXIT

# ── Convert to qcow2 + build OVA ─────────────────────────────────────────────
log "Converting raw -> qcow2 ..."
qemu-img convert -f raw -O qcow2 -c "$RAW" "$QCOW"

log "Converting raw -> vmdk (stream-optimized) for OVA ..."
qemu-img convert -f raw -O vmdk -o subformat=streamOptimized "$RAW" "$VMDK"

log "Packaging OVA ..."
"$HERE/mk-ova.sh" "$VMDK" "$OVA" "$RAWOS_NAME-$RAWOS_VERSION" "$SIZE_GB"

( cd "$OUT_DIR" && sha256sum "$(basename "$QCOW")" "$(basename "$OVA")" >> SHA256SUMS )
log "DONE:"
ls -lh "$QCOW" "$OVA"
