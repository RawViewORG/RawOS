# Secure Boot on RawOS

RawOS v1 ships **without a signed kernel/bootloader of its own**. The ISO includes `shim-signed`
and `grub-efi-amd64-signed` from Ubuntu, so on many machines it will boot under Secure Boot using
Ubuntu's chain - but any custom-built kernel modules (e.g. VirtualBox additions) will not be trusted
until you enroll a key, and some configurations require action.

## Options

### 1. Disable Secure Boot (simplest)
Enter firmware setup (usually `F2`/`Del` at power-on) → Security/Boot → turn **Secure Boot off** →
save and reboot. Recommended for a disposable analysis VM/host.

### 2. Enroll a Machine Owner Key (MOK)
If you need Secure Boot on and custom modules trusted:

```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
# set a one-time password, then reboot; the MOK Manager (blue screen) will
# prompt to "Enroll MOK" - confirm with the password.
```

## Roadmap
Signing RawOS's own boot chain (custom shim + signed GRUB/kernel) is a planned follow-up. It
requires a signing key and, for third-party machines, a Microsoft-signed shim - out of scope for v1.
