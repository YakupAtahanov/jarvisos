#!/bin/bash
# JARVIS OS — First-boot welcome and setup wizard
# Opened automatically by jarvis-welcome.desktop on the first login.
# After it completes successfully it deletes its own autostart entry so it
# never runs again.

set -euo pipefail

# ── Helpers ────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
    clear
    echo -e "${BLUE}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║                                                          ║"
    echo "  ║   ██ █████ █████  █   █ █ ████     ████  ████          ║"
    echo "  ║    █ █   █ █   █  █   █ █ █        █   █ █             ║"
    echo "  ║    █ █████ █████  ╚═══╝ █ ████     █   █ ████          ║"
    echo "  ║    █ █   █ █   █     █  █     █    █   █     █         ║"
    echo "  ║   ███ █   █ █   █  ███  █ ████     ████  ████          ║"
    echo "  ║                                                          ║"
    echo "  ║              AI-Powered Operating System                 ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

press_enter() {
    echo ""
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r
}

section() {
    echo ""
    echo -e "${BOLD}${BLUE}── $* ──${NC}"
    echo ""
}

ok() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err() { echo -e "${RED}✗${NC} $*"; }

# ── Welcome screen ─────────────────────────────────────────────────────────

banner
echo -e "  Welcome to ${BOLD}JARVIS OS${NC} — your AI-integrated Arch Linux system."
echo ""
echo "  This wizard will:"
echo "    1. Verify the JARVIS AI services are running"
echo "    2. Pull the default AI model into Ollama (if not already done)"
echo "    3. Run a quick JARVIS chat test"
echo "    4. Show you how to get started"
echo ""
press_enter

# ── Step 1: Check Ollama service ───────────────────────────────────────────

banner
section "Step 1 of 4 — Checking Ollama AI service"

if systemctl is-active --quiet ollama.service 2>/dev/null; then
    ok "ollama.service is running"
else
    warn "ollama.service is not active — attempting to start it..."
    if systemctl start ollama.service 2>/dev/null; then
        sleep 3
        ok "ollama.service started"
    else
        err "Could not start ollama.service."
        echo "    You can start it manually with: sudo systemctl start ollama"
    fi
fi

# Wait for the Ollama HTTP API
echo "  Waiting for Ollama API..."
READY=0
for i in $(seq 1 15); do
    if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 1
done

if [ "${READY}" -eq 1 ]; then
    ok "Ollama API is ready"
else
    warn "Ollama API did not respond within 15 s — continuing anyway"
fi

press_enter

# ── Step 2: Pull default model ─────────────────────────────────────────────

banner
section "Step 2 of 4 — AI model"

MODEL="${JARVIS_LLM_MODEL:-qwen3:4b}"

# Check if model already present
if ollama list 2>/dev/null | grep -q "^${MODEL}"; then
    ok "Model '${MODEL}' is already installed"
else
    warn "Model '${MODEL}' not found — downloading now."
    echo "  This may take several minutes depending on your internet connection."
    echo "  Model size: ~2-4 GB"
    echo ""
    if ollama pull "${MODEL}"; then
        ok "Model '${MODEL}' downloaded successfully"
    else
        err "Model download failed. Ensure you have internet access."
        echo "  You can retry later with:  ollama pull ${MODEL}"
    fi
fi

press_enter

# ── Step 3: JARVIS service check & quick test ──────────────────────────────

banner
section "Step 3 of 4 — Testing JARVIS"

if systemctl is-active --quiet jarvis.service 2>/dev/null; then
    ok "jarvis.service is running"
else
    warn "jarvis.service is not active — attempting to start it..."
    systemctl start jarvis.service 2>/dev/null || true
    sleep 2
fi

echo ""
echo "  Running a quick JARVIS test..."
echo ""

if command -v jarvis >/dev/null 2>&1; then
    RESPONSE=$(timeout 30 jarvis "Hello! Please introduce yourself in one sentence." 2>/dev/null || true)
    if [ -n "${RESPONSE}" ]; then
        echo -e "  ${BOLD}JARVIS says:${NC}"
        echo "  ─────────────────────────────────────────────────────────"
        echo "  ${RESPONSE}" | fold -s -w 57 | sed 's/^/  /'
        echo "  ─────────────────────────────────────────────────────────"
        ok "JARVIS is working!"
    else
        warn "JARVIS did not respond. The service may still be initialising."
        echo "  Try again with:  jarvis 'Hello!'"
    fi
else
    warn "The 'jarvis' command was not found in PATH."
    echo "  Check that /usr/bin/jarvis exists and is executable."
fi

press_enter

# ── Step 4: Getting started ────────────────────────────────────────────────

banner
section "Step 4 of 4 — How to use JARVIS OS"

echo "  ${BOLD}Terminal commands${NC}"
echo "    jarvis 'Your question'      — single-shot query"
echo "    jarvis-daemon               — run in interactive daemon mode"
echo "    ollama list                 — list installed AI models"
echo "    ollama pull <model>         — download a new model"
echo ""
echo "  ${BOLD}Recommended Ollama models${NC}"
echo "    qwen3:4b        — default, fast, ~2 GB  (already installed)"
echo "    qwen3:8b        — smarter, ~5 GB"
echo "    mistral:7b      — general purpose, ~4 GB"
echo "    codellama:7b    — code-focused, ~4 GB"
echo "    llama3.2:3b     — Meta's compact model, ~2 GB"
echo ""
echo "  ${BOLD}Configuration files${NC}"
echo "    /etc/jarvis/jarvis.conf     — main JARVIS config"
echo "    /var/lib/jarvis/models/     — speech model directory"
echo ""
echo "  ${BOLD}Service management${NC}"
echo "    sudo systemctl start|stop|restart jarvis.service"
echo "    sudo systemctl status jarvis.service"
echo ""
echo "  ${BOLD}Documentation${NC}"
echo "    https://github.com/ChatGPT-based-AI/JARVIS-OS"
echo ""

press_enter

# ── Cleanup autostart ──────────────────────────────────────────────────────

AUTOSTART="${HOME}/.config/autostart/jarvis-welcome.desktop"
if [ -f "${AUTOSTART}" ]; then
    rm -f "${AUTOSTART}"
fi

banner
echo -e "  ${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "  JARVIS OS is ready. Open a terminal and run:"
echo ""
echo -e "    ${BOLD}jarvis 'What can you do?'${NC}"
echo ""
echo "  Enjoy your AI-powered system."
echo ""
