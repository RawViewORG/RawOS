#!/usr/bin/env bash
# Runs INSIDE the chroot. Installs Ollama so RawOS can run local models with no
# API key and no network - the offline path for RawView's agent.
#
# Ollama is installed from its official static tarball rather than the upstream
# install.sh, which probes systemd and GPUs on the *build* host and would bake the
# builder's hardware into the image. No model is pulled here: models are large,
# hardware-specific, and the user's choice. `rawos-local-llm` walks them through it.
set -euo pipefail
source /rawos-build/chroot.env
log()  { printf '\033[1;34m[35-llm]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[35-llm]\033[0m %s\n' "$*" >&2; }

CACHE="/rawos-build/cache"
mkdir -p "$CACHE" /usr/local/bin /usr/share/applications
export DEBIAN_FRONTEND=noninteractive

OLLAMA_TGZ="$CACHE/ollama-linux-amd64.tgz"
if [ ! -s "$OLLAMA_TGZ" ]; then
    log "downloading Ollama ..."
    curl -fL --retry 3 --connect-timeout 30 \
        -o "$OLLAMA_TGZ" \
        "https://ollama.com/download/ollama-linux-amd64.tgz" || warn "Ollama download failed"
fi

if [ -s "$OLLAMA_TGZ" ]; then
    log "installing Ollama into /usr ..."
    tar -C /usr -xzf "$OLLAMA_TGZ"
    # A system user keeps model blobs out of $HOME and off the live squashfs.
    if ! id ollama >/dev/null 2>&1; then
        useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama || true
    fi
    cat > /etc/systemd/system/ollama.service <<'UNIT'
[Unit]
Description=Ollama local model server
After=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="HOME=/usr/share/ollama"
# Loopback only: this is a local runtime, not a network service.
Environment="OLLAMA_HOST=127.0.0.1:11434"

[Install]
WantedBy=multi-user.target
UNIT
    # Not enabled by default: it costs RAM and the live session may have none to
    # spare. `rawos-local-llm` starts it on demand.
    systemctl disable ollama.service >/dev/null 2>&1 || true
else
    warn "Ollama not installed; RawOS will still work against cloud providers."
fi

# Helper that starts the server and explains how to point RawView at it.
cat > /usr/local/bin/rawos-local-llm <<'HELPER'
#!/usr/bin/env bash
# Start the local model server and show how to wire RawView to it.
set -euo pipefail
if ! command -v ollama >/dev/null 2>&1; then
    echo "Ollama is not installed in this image." >&2
    exit 1
fi
if ! systemctl is-active --quiet ollama; then
    echo "Starting the local model server ..."
    sudo systemctl start ollama
fi
echo
echo "Local model server: http://localhost:11434/v1"
echo
if [ -z "$(ollama list 2>/dev/null | tail -n +2)" ]; then
    echo "No models yet. Pull one, for example:"
    echo "    ollama pull qwen2.5-coder:7b"
    echo
    echo "Reverse engineering wants tool calling, so prefer a model whose"
    echo "template supports it. Size to your RAM: roughly 8 GB for a 7B."
else
    echo "Installed models:"
    ollama list
fi
echo
echo "In RawView: File -> Settings -> Provider -> \"Ollama (local)\","
echo "then Refresh next to the model box and pick one."
HELPER
chmod 755 /usr/local/bin/rawos-local-llm

cat > /usr/share/applications/rawos-local-llm.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Local AI models (Ollama)
Comment=Start the offline model server for RawView's agent
Exec=xfce4-terminal --title="RawOS local models" -e "bash -lc 'rawos-local-llm; exec bash'"
Icon=utilities-terminal
Categories=Development;Utility;
Terminal=false
EOF

log "local LLM support ready (server disabled until first use)"
