#!/bin/bash
# Called by Calamares shellprocess@ollama-model during installation.
# Pulls the default JARVIS Ollama model into the installed system so JARVIS
# works on first boot without waiting for jarvis-setup.service.
#
# Runs inside the target chroot — all paths are relative to the installed root.
# jarvis-setup.service remains enabled as a silent fallback if this fails.

set -euo pipefail

MODEL="qwen3:4b"
LOG="/tmp/ollama-install.log"

echo "[JARVIS] Pulling Ollama model: ${MODEL}"

if [ ! -x /usr/local/bin/ollama ]; then
    echo "[JARVIS] WARNING: ollama binary not found — model will be pulled by jarvis-setup.service on first boot."
    exit 0
fi

# Ensure the model store exists and is owned by the ollama user
mkdir -p /usr/share/ollama/.ollama/models
chown -R ollama:ollama /usr/share/ollama 2>/dev/null || true

# Start ollama serve in the background
export HOME=/usr/share/ollama
export OLLAMA_MODELS=/usr/share/ollama/.ollama/models

/usr/local/bin/ollama serve >"${LOG}" 2>&1 &
OLLAMA_PID=$!

# Wait up to 60 seconds for the API
READY=0
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        echo "[JARVIS] Ollama ready."
        READY=1
        break
    fi
    sleep 2
done

if [ "${READY}" -eq 0 ]; then
    echo "[JARVIS] WARNING: Ollama did not start — model will be pulled by jarvis-setup.service on first boot."
    cat "${LOG}" || true
    kill "${OLLAMA_PID}" 2>/dev/null || true
    exit 0
fi

echo "[JARVIS] Downloading model ${MODEL} (this may take several minutes)..."
/usr/local/bin/ollama pull "${MODEL}"

kill "${OLLAMA_PID}" 2>/dev/null || true
wait "${OLLAMA_PID}" 2>/dev/null || true

chown -R ollama:ollama /usr/share/ollama 2>/dev/null || true
echo "[JARVIS] Model ${MODEL} installed successfully."
