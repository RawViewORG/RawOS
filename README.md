<div align="center">

<img src="https://raw.githubusercontent.com/codeminute-the-dev/RawOS/master/branding/wallpaper/rawos-wallpaper.png" width="920" alt="RawOS banner">

<br><br>

<a href="https://github.com/codeminute-the-dev" title="CODEMINUTE on GitHub"><img src="https://github.com/codeminute-the-dev.png" width="72" height="72" alt="CODEMINUTE"></a>

</div>

# RawOS

A **malware reverse-engineering Linux distribution** built around [**RawView**](https://github.com/codeminute-the-dev/RawView): a live + install **ISO** (and downloadable **VM appliances**) that boots straight into a ready-to-work RE environment. RawView, **Ghidra**, and a **JDK** come preinstalled and wired together, next to a curated analysis toolkit, with safe-by-default handling for live samples.

**Base:** Ubuntu 24.04 LTS (Noble), amd64. **Desktop:** XFCE, themed **Tokyo Night**. RawView keeps its own in-app theme picker.

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL%20v3-blue" alt="GPL v3"></a>
  <img src="https://img.shields.io/badge/platform-Linux-blue" alt="Linux">
  <img src="https://img.shields.io/badge/base-Ubuntu%2024.04-blue" alt="Ubuntu 24.04">
  <img src="https://img.shields.io/badge/arch-amd64-blue" alt="amd64">
</p>

**Author:** [@codeminute-the-dev](https://github.com/codeminute-the-dev)

**Discord:** [Codeminute's Discord Server](https://discord.gg/aHRjNzhNgk)

---

## What's inside

- **RawView** built from source, with Ghidra at `/opt/ghidra` and a Temurin JDK at `/opt/jdk`, preconfigured via `/etc/rawview/rawview.env` so there is no first-run download.
- **Disassembly / decompile:** RawView (Ghidra), radare2, Cutter.
- **Debuggers / tracing:** gdb, edb-debugger, strace, ltrace, and x64dbg via Wine.
- **Static / triage:** file, binwalk, yara, capa, FLOSS, Detect-It-Easy, upx, ssdeep, exiftool, hexedit, wxHexEditor, ClamAV.
- **Dynamic / network:** Wireshark, tshark, tcpdump, netcat, INetSim.
- **Scripting:** Python with pefile, capstone, unicorn, and more in `/opt/rawos-venv`.
- **Windows / PE:** Wine and winetricks.
- **Virtualization:** QEMU/KVM, libvirt, and virt-manager, with a preconfigured **isolated** network (`rawos-isolated`) for detonating samples.
- **Tokyo Night** identity across GRUB, Plymouth, LightDM, XFCE, the terminal, and fastfetch, plus a graphical installer and an offline documentation page.

## Safety

RawOS is meant for handling live malware, so it ships safe-by-default: the firewall denies inbound traffic, no services listen by default, and an isolated libvirt network (`rawos-isolated`) has no route to the internet. **Detonate samples only inside a guest VM on that network, snapshot before you run anything, and revert after.** RawOS makes careful handling easier; it does not make careless handling safe. Windows guests are **bring-your-own** (not redistributable).

## Requirements (to build)

| | |
|--|--|
| Host OS | A **Debian/Ubuntu** host (or container) with **root** |
| Tools | `debootstrap`, `squashfs-tools`, `xorriso`, `grub-pc-bin`, `grub-efi-amd64-bin` (installed by `make deps`) |
| Appliances | **QEMU + KVM** for the `.qcow2` / `.ova` build |
| RawView source | Set `RAWVIEW_SRC` to a RawView checkout, or use the pinned `vendor/` submodule |
| Disk | Roughly **30 GB** free for the working tree and outputs |

## Build

```bash
make deps                       # install host build tools
git submodule update --init     # or set RAWVIEW_SRC to a RawView checkout
sudo make iso                   # -> out/rawos-<ver>-amd64-live.iso
sudo make appliances            # -> out/rawos-<ver>-amd64.qcow2  and  .ova
make check                      # syntax-check every build script
```

Full build notes are in [`docs/BUILDING.md`](docs/BUILDING.md). Secure Boot status and MOK enrollment are covered in [`docs/SECUREBOOT.md`](docs/SECUREBOOT.md).

## Try it

Boot the ISO in QEMU with a host-passthrough CPU (RawView's Qt build needs a modern CPU baseline):

```bash
qemu-system-x86_64 -enable-kvm -cpu host -m 8192 -machine q35 -cdrom out/rawos-*-live.iso
```

Inside the live session, launch **RawView** from the menu (Ghidra and the JDK are already set up; add your Anthropic key under **File -> Settings** for the AI agent), or click **Install RawOS** to install to disk.

## Repository layout

| Path | Purpose |
|------|---------|
| `build/` | `00-config.sh` (versions, theme, paths), `build-iso.sh`, `build-appliances.sh` |
| `chroot-hooks/` | Ordered scripts run inside the chroot (packages, tools, Ghidra/JDK, RawView, branding, safety, usability) |
| `packages/` | `package-list.txt`, the apt manifest |
| `installer/` | The RawOS graphical installer (GTK wizard) and its install engine |
| `branding/` | Wallpaper, logos, Plymouth, GRUB, LightDM, and the offline docs page |
| `patches/` | Small RawView integration patches applied at build time |
| `vendor/` | Pinned RawView source (submodule / tarball) |
| `docs/` | `BUILDING.md`, `SECUREBOOT.md` |
| `Makefile` | `make iso`, `make appliances`, `make all`, `make check`, `make clean` |

## Licensing

RawOS is GPLv3. It bundles third-party software under its own licenses (Ghidra: Apache-2.0, Temurin JDK: GPLv2+CE, Wine: LGPL, and the various GPL/Apache RE tools), all redistributable. A `THIRD_PARTY_LICENSES` manifest ships on the image. RawOS does **not** bundle any Windows guest.

## Notes

- Offline images are large (roughly a 3.5 to 4.5 GB ISO; appliances larger). GitHub Release assets cap at about 2 GB per file, so host the big files on an external mirror or torrent and publish `SHA256SUMS` on the release.
- Secure Boot: v1 ships **unsigned**. See [`docs/SECUREBOOT.md`](docs/SECUREBOOT.md) for MOK enrollment or booting with Secure Boot off.

## License

[GNU General Public License v3.0](LICENSE).
