#!/bin/bash
# Post-installation JARVIS configuration script
# Configures voice features based on user selections

set -e

JARVIS_ENV="/usr/lib/jarvis/.env"
JARVIS_CONFIG_TEMPLATE="/etc/jarvis/jarvis.conf.template"

# Function to update .env file
update_env() {
    local key=$1
    local value=$2
    
    if [ -f "${JARVIS_ENV}" ]; then
        if grep -q "^${key}=" "${JARVIS_ENV}"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "${JARVIS_ENV}"
        else
            echo "${key}=${value}" >> "${JARVIS_ENV}"
        fi
    else
        echo "${key}=${value}" > "${JARVIS_ENV}"
    fi
}

# Check for voice selections from packagechooser
# Calamares stores these in global storage as packagechooser_packagechooser
# which is a comma-separated list of selected IDs

VOICE_OUTPUT=false
VOICE_RECOGNITION=false

# Try to read from Calamares global storage file if it exists
if [ -f "/tmp/calamares-global-storage.yaml" ]; then
    if grep -q "voice-output" "/tmp/calamares-global-storage.yaml"; then
        VOICE_OUTPUT=true
    fi
    if grep -q "voice-recognition" "/tmp/calamares-global-storage.yaml"; then
        VOICE_RECOGNITION=true
    fi
fi

echo "Configuring JARVIS..."
echo "Voice Output: ${VOICE_OUTPUT}"
echo "Voice Recognition: ${VOICE_RECOGNITION}"

# Configure voice output
if [ "${VOICE_OUTPUT}" = "true" ]; then
    update_env "ENABLE_TTS" "True"
    echo "✓ Voice output enabled"
else
    update_env "ENABLE_TTS" "False"
    echo "✗ Voice output disabled"
fi

# Configure voice recognition
if [ "${VOICE_RECOGNITION}" = "true" ]; then
    update_env "ENABLE_STT" "True"
    update_env "VOICE_ACTIVATION" "True"
    echo "✓ Voice recognition enabled"
else
    update_env "ENABLE_STT" "False"
    update_env "VOICE_ACTIVATION" "False"
    echo "✗ Voice recognition disabled"
fi

# Set ownership
chown jarvis:jarvis "${JARVIS_ENV}" 2>/dev/null || true

# Remove the SDDM autologin configuration (it's only for live ISO)
echo "Removing live ISO autologin configuration..."
rm -f /etc/sddm.conf.d/autologin.conf 2>/dev/null || true

# Create a clean SDDM configuration for installed system
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/jarvisos.conf << 'SDDM_CONF'
[General]
DisplayServer=wayland
Numlock=on

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions

[X11]
DisplayCommand=/usr/share/sddm/scripts/Xsetup
SessionCommand=/usr/share/sddm/scripts/Xsession
SessionDir=/usr/share/xsessions
SDDM_CONF

echo "✓ JARVIS configuration complete"
echo ""
echo "Note: To complete JARVIS setup after first boot:"
echo "  1. Pull an Ollama model: ollama pull llama2"
echo "  2. Set the model: jarvis model -n 'llama2'"
echo "  3. Start JARVIS: systemctl --user start jarvis"
echo ""
if [ "${VOICE_OUTPUT}" = "true" ]; then
    echo "  4. Download TTS models: jarvis tts-download"
fi
if [ "${VOICE_RECOGNITION}" = "true" ]; then
    echo "  5. Download STT models: jarvis stt-download"
fi

exit 0



