#!/usr/bin/env bash
# =============================================================================
# test-jarvis-ollama.sh — JarvisOS Experience Launcher
#
# Bootstraps everything needed and launches the JARVIS autonomous agent:
#   1. Install system deps (portaudio, python venv)
#   2. Create Python venv + install vosk / pyaudio / requests
#   3. Download Vosk small English model (~45 MB) if not present
#   4. Pull an Ollama model if none available
#   5. Launch jarvis_agent.py — voice + text autonomous agent
#
# Usage:
#   ./test-jarvis-ollama.sh
#   JARVIS_MODEL=qwen2.5:7b ./test-jarvis-ollama.sh
# =============================================================================

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
JARVIS_MODEL="${JARVIS_MODEL:-}"
JARVIS_DIR="${HOME}/.local/share/jarvis"
VENV_DIR="${JARVIS_DIR}/venv"
VOSK_DIR="${JARVIS_DIR}/vosk-model-small"
VOSK_ZIP="${JARVIS_DIR}/vosk-model-small.zip"
VOSK_URL="https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SCRIPT="${SCRIPT_DIR}/jarvis_agent.py"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
PRP='\033[0;35m'

die()  { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }
info() { echo -e "${CYN}[INFO]${RESET}  $*"; }
ok()   { echo -e "${GRN}[ OK ]${RESET}  $*"; }
warn() { echo -e "${YEL}[WARN]${RESET}  $*"; }
step() { echo -e "\n${BOLD}${PRP}▶ $*${RESET}"; }

echo -e "${BOLD}${PRP}"
cat <<'BANNER'
     ██╗ █████╗ ██████╗ ██╗   ██╗██╗███████╗      ██████╗ ███████╗
     ██║██╔══██╗██╔══██╗██║   ██║██║██╔════╝     ██╔═══██╗██╔════╝
     ██║███████║██████╔╝██║   ██║██║███████╗     ██║   ██║███████╗
██   ██║██╔══██║██╔══██╗╚██╗ ██╔╝██║╚════██║     ██║   ██║╚════██║
╚█████╔╝██║  ██║██║  ██║ ╚████╔╝ ██║███████║     ╚██████╔╝███████║
 ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚═╝╚══════╝      ╚═════╝ ╚══════╝
                     JarvisOS Experience Launcher
BANNER
echo -e "${RESET}"

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ -f "$AGENT_SCRIPT" ]] || die "jarvis_agent.py not found at ${AGENT_SCRIPT}"
command -v python3 &>/dev/null || die "python3 not found"
command -v curl    &>/dev/null || die "curl not found"

# ── Step 1: System packages ───────────────────────────────────────────────────
step "System Dependencies"

MISSING_PKGS=()
pacman -Qi portaudio    &>/dev/null || MISSING_PKGS+=(portaudio)
pacman -Qi python-pip   &>/dev/null || MISSING_PKGS+=(python-pip)
pacman -Qi unzip        &>/dev/null || MISSING_PKGS+=(unzip)

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    info "Installing: ${MISSING_PKGS[*]}"
    sudo pacman -S --noconfirm --needed "${MISSING_PKGS[@]}"
fi
ok "System packages ready"

# ── Step 2: Python venv + packages ───────────────────────────────────────────
step "Python Environment"

mkdir -p "$JARVIS_DIR"

if [[ ! -f "${VENV_DIR}/bin/activate" ]]; then
    info "Creating venv at ${VENV_DIR}"
    python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

MISSING_PY=()
python3 -c "import vosk"     2>/dev/null || MISSING_PY+=(vosk)
python3 -c "import pyaudio"  2>/dev/null || MISSING_PY+=(pyaudio)
python3 -c "import requests" 2>/dev/null || MISSING_PY+=(requests)

if [[ ${#MISSING_PY[@]} -gt 0 ]]; then
    info "Installing Python packages: ${MISSING_PY[*]}"
    pip install --quiet --upgrade "${MISSING_PY[@]}"
fi

# Check what actually loaded
VOSK_OK=false
VOICE_OK=false
python3 -c "import vosk, pyaudio" 2>/dev/null && VOSK_OK=true && VOICE_OK=true

ok "Python environment ready"
if $VOICE_OK; then
    ok "Voice support: Vosk + PyAudio available"
else
    warn "Voice support: unavailable (vosk/pyaudio missing) — text-only mode"
fi

# ── Step 3: Vosk model ────────────────────────────────────────────────────────
step "Vosk Speech Model"

if $VOICE_OK; then
    if [[ ! -d "$VOSK_DIR" ]]; then
        info "Downloading Vosk small English model (~45 MB)..."
        curl -L --progress-bar -o "$VOSK_ZIP" "$VOSK_URL" \
            || { warn "Download failed — voice disabled"; VOICE_OK=false; }

        if $VOICE_OK; then
            info "Extracting model..."
            cd "$JARVIS_DIR"
            unzip -q "$VOSK_ZIP"
            # The zip extracts to vosk-model-small-en-us-0.15/
            local_extracted=$(ls -d "${JARVIS_DIR}"/vosk-model-small-en-us-* 2>/dev/null | head -1)
            if [[ -n "$local_extracted" ]]; then
                mv "$local_extracted" "$VOSK_DIR"
                rm -f "$VOSK_ZIP"
                ok "Vosk model ready at ${VOSK_DIR}"
            else
                warn "Could not find extracted model directory — voice disabled"
                VOICE_OK=false
            fi
        fi
    else
        ok "Vosk model already present"
    fi
else
    info "Skipping Vosk model download (voice unavailable)"
fi

# ── Step 4: Ollama + model ────────────────────────────────────────────────────
step "Ollama"

curl -sf --max-time 5 "${OLLAMA_URL}/" | grep -q "Ollama" \
    || die "Ollama not reachable at ${OLLAMA_URL}. Run: systemctl start ollama"
ok "Ollama daemon is up"

# Collect available models
AVAILABLE_MODELS=$(curl -sf "${OLLAMA_URL}/api/tags" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
names = [m['name'] for m in d.get('models', [])]
print('\n'.join(names))
" 2>/dev/null || true)

if [[ -z "$AVAILABLE_MODELS" ]]; then
    warn "No models installed."
    echo ""
    # Pick recommendation based on RAM
    MEM_AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    if (( MEM_AVAIL_MB > 20000 )); then
        SUGGEST="qwen3:8b"
    else
        SUGGEST="qwen3:4b"
    fi

    echo -e "  Available RAM: ${BOLD}${MEM_AVAIL_MB} MB${RESET}"
    echo -e "  Recommended:   ${BOLD}${SUGGEST}${RESET}"
    echo ""
    read -rp "  Pull ${SUGGEST} now? [Y/n] " pull_choice
    if [[ "${pull_choice:-Y}" =~ ^[Yy]$ ]]; then
        command -v ollama &>/dev/null || die "ollama CLI not found — install from https://ollama.com"
        info "Pulling ${SUGGEST} (this may take a few minutes)..."
        ollama pull "$SUGGEST" || die "Pull failed"
        AVAILABLE_MODELS="$SUGGEST"
    else
        die "No model available. Pull one first: ollama pull qwen3:4b"
    fi
fi

# Auto-select model if not specified
if [[ -z "$JARVIS_MODEL" ]]; then
    # Prefer larger models on this machine (62GB RAM)
    MEM_AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    PREFER_SIZE="medium"
    (( MEM_AVAIL_MB > 32768 )) && PREFER_SIZE="large"
    (( MEM_AVAIL_MB < 8192  )) && PREFER_SIZE="small"

    JARVIS_MODEL=$(python3 - "$PREFER_SIZE" <<'PYEOF'
import sys
prefer = sys.argv[1]
import os, subprocess
result = subprocess.run(['curl','-sf','http://localhost:11434/api/tags'],
                       capture_output=True, text=True)
import json
models = [m['name'] for m in json.loads(result.stdout).get('models', [])]

large  = ['qwen3:8','qwen3:14','qwen3:32','qwen2.5:7','llama3.1','llama3:8','mistral:7','gemma3:12','gemma3:27','phi4']
medium = ['qwen3:4','qwen2.5:3','llama3.2:3','gemma3:4','phi3','gemma2:9']
small  = ['qwen3:1','qwen2.5:1','gemma3:1','llama3.2:1','tinyllama','phi3:mini']

order = {'large': large+medium+small,
         'medium': medium+large+small,
         'small': small+medium+large}[prefer]

for pat in order:
    for m in models:
        if pat.lower() in m.lower():
            print(m); sys.exit(0)
print(models[0] if models else '')
PYEOF
    )
fi

[[ -z "$JARVIS_MODEL" ]] && die "Could not select a model."
ok "Active model: ${BOLD}${JARVIS_MODEL}${RESET}"

# ── Step 5: Launch agent in a new terminal window ────────────────────────────
step "Launching JARVIS Agent"
echo ""

VOSK_PATH=""
$VOICE_OK && VOSK_PATH="$VOSK_DIR"

export OLLAMA_URL JARVIS_MODEL VOSK_MODEL_PATH="$VOSK_PATH"

# Build the command the new terminal will run.
# Keep the window open on exit so the user can read the last output.
AGENT_CMD="export OLLAMA_URL='${OLLAMA_URL}' JARVIS_MODEL='${JARVIS_MODEL}' VOSK_MODEL_PATH='${VOSK_PATH}'; \
source '${VENV_DIR}/bin/activate'; \
python3 '${AGENT_SCRIPT}'; \
echo; read -rp 'Press Enter to close…'"

# Detect the user's preferred or available terminal emulator.
# Respects \$TERMINAL env var first, then tries common ones in order.
find_terminal() {
    # Explicit override
    if [[ -n "${TERMINAL:-}" ]] && command -v "${TERMINAL}" &>/dev/null; then
        echo "$TERMINAL"; return
    fi
    # KDE
    command -v konsole       &>/dev/null && { echo konsole;       return; }
    # Common alternatives
    command -v alacritty     &>/dev/null && { echo alacritty;     return; }
    command -v kitty         &>/dev/null && { echo kitty;         return; }
    command -v wezterm       &>/dev/null && { echo wezterm;       return; }
    command -v xfce4-terminal &>/dev/null && { echo xfce4-terminal; return; }
    command -v gnome-terminal &>/dev/null && { echo gnome-terminal; return; }
    command -v tilix         &>/dev/null && { echo tilix;         return; }
    command -v xterm         &>/dev/null && { echo xterm;         return; }
    echo ""
}

TERM_BIN=$(find_terminal)

if [[ -z "$TERM_BIN" ]]; then
    warn "No terminal emulator found — running in this terminal."
    echo ""
    source "${VENV_DIR}/bin/activate"
    exec python3 "$AGENT_SCRIPT"
fi

info "Opening JARVIS in: ${BOLD}${TERM_BIN}${RESET}"
echo ""

case "$TERM_BIN" in
    konsole)
        exec konsole \
            --title "JARVIS — JarvisOS Agent" \
            --profile "JARVIS" \
            -e bash -c "$AGENT_CMD" \
            2>/dev/null || \
        exec konsole --title "JARVIS — JarvisOS Agent" \
            -e bash -c "$AGENT_CMD"
        ;;
    alacritty)
        exec alacritty --title "JARVIS — JarvisOS Agent" \
            -e bash -c "$AGENT_CMD"
        ;;
    kitty)
        exec kitty --title "JARVIS — JarvisOS Agent" \
            bash -c "$AGENT_CMD"
        ;;
    wezterm)
        exec wezterm start --title "JARVIS — JarvisOS Agent" \
            -- bash -c "$AGENT_CMD"
        ;;
    xfce4-terminal)
        exec xfce4-terminal --title "JARVIS — JarvisOS Agent" \
            -e "bash -c '$AGENT_CMD'"
        ;;
    gnome-terminal)
        exec gnome-terminal --title "JARVIS — JarvisOS Agent" \
            -- bash -c "$AGENT_CMD"
        ;;
    tilix)
        exec tilix -t "JARVIS — JarvisOS Agent" \
            -e "bash -c '$AGENT_CMD'"
        ;;
    xterm)
        exec xterm -T "JARVIS — JarvisOS Agent" \
            -fa "Monospace" -fs 12 \
            -bg "#0d0d1a" -fg "#c8c8ff" \
            -e bash -c "$AGENT_CMD"
        ;;
    *)
        exec "$TERM_BIN" -e bash -c "$AGENT_CMD"
        ;;
esac
