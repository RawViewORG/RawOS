# Changelog

## 0.2.0 "Ghostwire"

### Offline AI: local models, no key, no network

RawOS now ships a local model runtime, so RawView's agent can work on an air-gapped
analysis box. That matters for malware work, where sending sample-derived strings and
decompilation to a third party is often not an option.

- **Ollama** is installed from its official static tarball and runs as a dedicated
  system user, bound to loopback only. It is **not** enabled at boot: models cost real
  RAM and the live session may not have it to spare.
- **Local AI models (Ollama)** in the menu, or `rawos-local-llm` in a terminal, starts
  the server, lists what is installed, and prints the exact steps to point RawView at
  it.
- No model ships in the image. Models are large and hardware-specific, so the choice
  is yours; the helper suggests how to pick and pull one.

Installed from the tarball rather than upstream's `install.sh` deliberately: that
script probes systemd and GPUs on the *build* host, which would bake the builder's
hardware into everyone's image.

RawView 1.3.0 (below) adds provider presets, so the local server is a two-click setup:
**File → Settings → Provider → Ollama (local)**, then **Refresh** to list your models.
Cloud providers other than Anthropic work the same way.

### Ships RawView 1.3.0 (was 1.2.4)

Multi-provider support plus Claude Opus 5. Opus 5 was previously unusable - RawView
sent parameters it rejects - and is now the preset default model in
`/etc/rawview/rawview.env`.

### Build

- `RAWVIEW_VERSION` → 1.3.0, `RAWVIEW_ANTHROPIC_MODEL` → `claude-opus-5`.
- New `35-local-llm` chroot hook.
- The RawView model-default patch is now a no-op against upstream, which already
  defaults to Opus 5. It stays as the `RAWVIEW_ANTHROPIC_MODEL` override hook and as a
  guard against upstream drift.

### Not re-verified in this release

The Calamares installer and the appliance builder (`.ova` / `.qcow2`) have not been
re-tested on hardware since 0.1.0.

## 0.1.0 "Ghostwire"

First public build. Ubuntu 24.04 (noble) live+install ISO, XFCE, Tokyo Night
system-wide, RawView built from source with a curated RE toolkit, Wine, and
virtualization for isolated detonation.
