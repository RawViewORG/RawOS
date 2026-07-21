# Building RawOS

## Host requirements

A **Debian or Ubuntu** host (or container) with **root**. The build uses `debootstrap` + `chroot`,
loop devices (for appliances), and standard live-ISO tooling.

```bash
make deps
# installs: debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin
#           mtools dosfstools rsync qemu-utils parted e2fsprogs imagemagick
```

> Building appliances (`.qcow2`/`.ova`) needs `/dev/loop` access - run on a real host or a
> `--privileged` container, not an unprivileged sandbox.

## RawView source

RawOS builds RawView from source. Provide it one of two ways:

```bash
# (a) as a git submodule (recommended, pins a version):
git submodule add https://github.com/codeminute-the-dev/RawView vendor/RawView
git -C vendor/RawView checkout v1.2.4    # canonical version RawOS ships

# (b) or point at an existing checkout:
export RAWVIEW_SRC=/path/to/RawView
```

If `vendor/RawView` is absent, the build falls back to `RAWVIEW_SRC` (default `/home/codeminute/RawView`).

Ghidra + Temurin: the build reuses the `ghidra_bundle/` and `temurin_bundle/` already present in the
RawView tree when available; otherwise it downloads the pinned Ghidra release and latest Temurin
`$TEMURIN_MAJOR` GA. Downloads are cached under `.cache/` and reused across builds.

## Build

```bash
sudo make iso          # out/rawos-<ver>-amd64-live.iso  (+ .sha256)
sudo make appliances   # out/rawos-<ver>-amd64.qcow2 and .ova   (run after iso)
sudo make all          # both
```

Configuration knobs live in `build/00-config.sh` and are all env-overridable, e.g.:

```bash
sudo RAWOS_VERSION=0.2.0 RAWVIEW_VERSION=1.2.5 UBUNTU_MIRROR=http://mirror.local/ubuntu make iso
```

## What a build does

1. `debootstrap` a minbase `noble` rootfs into `work/chroot`.
2. Stage `chroot-hooks/`, `packages/`, `patches/`, `branding/`, and the RawView source into the chroot.
3. Run hooks `10→70`: apt packages · GitHub-release tools · pip tools · Ghidra+JDK · RawView build ·
   branding · safety.
4. Clean the chroot, `mksquashfs` it, and assemble a hybrid BIOS+UEFI GRUB ISO with `xorriso`.
5. (appliances) rsync the rootfs onto a GPT disk image, install GRUB, create a default user, then
   emit `.qcow2` and `.ova`.

## Testing the result

```bash
# Boot the live ISO in QEMU (UEFI):
qemu-system-x86_64 -enable-kvm -m 6144 -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -cdrom out/rawos-*-live.iso

# Boot the qcow2 appliance:
qemu-system-x86_64 -enable-kvm -m 6144 -smp 4 out/rawos-*-amd64.qcow2
```

Verify: XFCE with Tokyo Night branding; RawView launches and finds Ghidra with **no** download
prompt; `rizin -v`, `yara -v`, `capa -h`, `wine --version`, `virt-manager` all work.

## Rebuilds

`sudo make clean` removes `work/` for a fresh chroot but keeps `.cache/` (downloads) and `out/`.
Re-running `build-iso.sh` over an existing `work/chroot` reuses it - delete `work/` to start clean.
