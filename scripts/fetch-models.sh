#!/bin/bash
# Download Vosk and Piper models into staged rootfs under /var/lib/jarvis
set -e

ROOTFS_DIR="$1"
VOSK_MODEL="$2"
PIPER_VOICE="$3"

if [ -z "$ROOTFS_DIR" ]; then
	echo "Usage: $0 <rootfs_dir> [vosk_model] [piper_voice]"
	exit 1
fi

if [ ! -d "$ROOTFS_DIR" ]; then
	echo "❌ Rootfs directory not found: $ROOTFS_DIR"
	exit 1
fi

# Basic tool checks
if ! command -v wget >/dev/null 2>&1; then
	echo "❌ 'wget' is required to download models. Install it and re-run."
	exit 1
fi
if [ -n "$VOSK_MODEL" ] && ! command -v unzip >/dev/null 2>&1; then
	echo "❌ 'unzip' is required to extract Vosk models. Install it and re-run."
	exit 1
fi

MODELS_DIR="$ROOTFS_DIR/var/lib/jarvis/models"
mkdir -p "$MODELS_DIR" "$MODELS_DIR/piper"

# Vosk
if [ -n "$VOSK_MODEL" ]; then
	echo "🔊 Fetching Vosk model: $VOSK_MODEL"
	pushd "$MODELS_DIR" >/dev/null
	# Known model file name mapping for common choices
	ZIP_NAME="${VOSK_MODEL}.zip"
	URL="https://alphacephei.com/vosk/models/${ZIP_NAME}"
	if ! command -v wget >/dev/null 2>&1; then
		echo "Installing wget is recommended to fetch models."
	fi
	if [ ! -d "$VOSK_MODEL" ]; then
		wget -q --show-progress "$URL" -O "$ZIP_NAME" || { echo "⚠️ Failed to download $URL"; exit 1; }
		unzip -q "$ZIP_NAME"
		rm -f "$ZIP_NAME"
	else
		echo "✅ Vosk model already present."
	fi
	popd >/dev/null
fi

# Piper
if [ -n "$PIPER_VOICE" ]; then
	echo "🗣️  Fetching Piper voice: $PIPER_VOICE"
	pushd "$MODELS_DIR/piper" >/dev/null
	# Piper voices are stored on HF under rhasspy/piper-voices with a structured path
	# Expect format like: en_US-libritts_r-medium
	LANG_PREFIX="$(echo "$PIPER_VOICE" | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
	# Build URLs
	BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/${LANG_PREFIX}/$(echo "$PIPER_VOICE" | tr '-' '/' )"
	ONNX_URL="${BASE}.onnx"
	JSON_URL="${BASE}.onnx.json"
	if [ ! -f "${PIPER_VOICE}.onnx" ]; then
		wget -q --show-progress "$ONNX_URL" -O "${PIPER_VOICE}.onnx" || { echo "⚠️ Failed to download ${ONNX_URL}"; exit 1; }
	else
		echo "✅ Piper ONNX already present."
	fi
	if [ ! -f "${PIPER_VOICE}.onnx.json" ]; then
		wget -q --show-progress "$JSON_URL" -O "${PIPER_VOICE}.onnx.json" || { echo "⚠️ Failed to download ${JSON_URL}"; exit 1; }
	else
		echo "✅ Piper JSON already present."
	fi
	popd >/dev/null
fi

echo "✅ Model fetch complete."


