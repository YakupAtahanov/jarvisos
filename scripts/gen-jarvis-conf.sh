#!/bin/bash
# Generate build/jarvis.conf from build/config.mk variables (written by 'make configure')
set -e

BUILD_DIR="${BUILD_DIR:-build}"
OUT_FILE="${BUILD_DIR}/jarvis.conf"

# Load defaults if config.mk exists
if [ -f "${BUILD_DIR}/config.mk" ]; then
	# shellcheck disable=SC1090
	. <(sed -n 's/^\([A-Z0-9_]\+\)\s*:=\s*\(.*\)$/\1=\2/p' "${BUILD_DIR}/config.mk")
fi

# Sensible fallbacks
LOADING_STRATEGY="${LOADING_STRATEGY:-disabled}"
BACKGROUND_PRIORITY="${BACKGROUND_PRIORITY:-15}"
ACTIVE_PRIORITY="${ACTIVE_PRIORITY:-0}"
VOSK_MODEL="${VOSK_MODEL:-}"
PIPER_VOICE="${PIPER_VOICE:-}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"

mkdir -p "${BUILD_DIR}"
cat > "${OUT_FILE}" <<EOF
[Loading]
strategy = ${LOADING_STRATEGY}
background_priority = ${BACKGROUND_PRIORITY}
progressive_load = true

[Priority]
active_priority = ${ACTIVE_PRIORITY}
auto_adjust = true
idle_timeout = 30

[Models]
vosk_model = ${VOSK_MODEL}
piper_model = ${PIPER_VOICE}
ollama_model = ${OLLAMA_MODEL}

[Features]
voice_input = $( [ "${JARVIS_MODE}" = "voice" ] && echo true || echo false )
voice_output = $( [ "${JARVIS_MODE}" = "voice" ] && echo true || echo false )
text_interface = true
supermcp = true
EOF

echo "Generated ${OUT_FILE}"


