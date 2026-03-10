#!/bin/bash
# Post-installation JARVIS configuration script
# Called by Calamares shellprocess after OS installation.
# Configures voice features, creates XDG autostart, removes live-ISO cruft.

set -e

JARVIS_ENV="/usr/lib/jarvis/.env"

# ---------------------------------------------------------------------------
# Helper: update a key=value in .env (create if missing)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Read Calamares voice selections
# ---------------------------------------------------------------------------
VOICE_OUTPUT=false
VOICE_RECOGNITION=false

if [ -f "/tmp/calamares-global-storage.yaml" ]; then
    grep -q "voice-output" "/tmp/calamares-global-storage.yaml" && VOICE_OUTPUT=true
    grep -q "voice-recognition" "/tmp/calamares-global-storage.yaml" && VOICE_RECOGNITION=true
fi

echo "Configuring JARVIS..."
echo "  Voice Output: ${VOICE_OUTPUT}"
echo "  Voice Recognition: ${VOICE_RECOGNITION}"

# ---------------------------------------------------------------------------
# Apply voice settings
# ---------------------------------------------------------------------------
if [ "${VOICE_OUTPUT}" = "true" ]; then
    update_env "ENABLE_TTS" "True"
    update_env "OUTPUT_MODE" "voice"
else
    update_env "ENABLE_TTS" "False"
    update_env "OUTPUT_MODE" "text"
fi

if [ "${VOICE_RECOGNITION}" = "true" ]; then
    update_env "ENABLE_STT" "True"
    update_env "VOICE_ACTIVATION" "True"
else
    update_env "ENABLE_STT" "False"
    update_env "VOICE_ACTIVATION" "False"
fi

chown jarvis:jarvis "${JARVIS_ENV}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Remove live-ISO autologin
# ---------------------------------------------------------------------------
echo "Removing live ISO autologin configuration..."
rm -f /etc/sddm.conf.d/autologin.conf 2>/dev/null || true

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

# ---------------------------------------------------------------------------
# Ensure XDG autostart for JARVIS exists (should already be there from build)
# ---------------------------------------------------------------------------
mkdir -p /etc/xdg/autostart
if [ ! -f /etc/xdg/autostart/jarvis.desktop ]; then
    cat > /etc/xdg/autostart/jarvis.desktop << 'JDESKTOP'
[Desktop Entry]
Type=Application
Name=JARVIS AI Assistant
Comment=Start JARVIS voice assistant
Exec=/usr/bin/jarvis-daemon
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=true
X-KDE-autostart-phase=2
JDESKTOP
    chmod 644 /etc/xdg/autostart/jarvis.desktop
fi

# If voice is completely disabled, hide the autostart
if [ "${VOICE_OUTPUT}" = "false" ] && [ "${VOICE_RECOGNITION}" = "false" ]; then
    # Keep the desktop file but hide it — user can re-enable via settings
    sed -i 's/^Hidden=false/Hidden=true/' /etc/xdg/autostart/jarvis.desktop 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Create first-boot welcome terminal autostart
# This opens a Konsole window on the user's first login after installation,
# showing the JARVIS setup progress (model download, verification, usage tips).
# The welcome script removes this autostart file after it runs once.
# ---------------------------------------------------------------------------
echo "Creating JARVIS welcome autostart..."

# Detect the username Calamares created (from global storage or /home)
INSTALL_USER=""
if [ -f "/tmp/calamares-global-storage.yaml" ]; then
    INSTALL_USER=$(grep -E '^\s*username:' /tmp/calamares-global-storage.yaml \
                   | head -1 | sed 's/.*username:\s*//' | tr -d '"' | xargs)
fi
# Fallback: first real user in /home
if [ -z "${INSTALL_USER}" ]; then
    INSTALL_USER=$(ls /home/ 2>/dev/null | head -1)
fi

if [ -n "${INSTALL_USER}" ]; then
    AUTOSTART_DIR="/home/${INSTALL_USER}/.config/autostart"
    mkdir -p "${AUTOSTART_DIR}"
    cat > "${AUTOSTART_DIR}/jarvis-welcome.desktop" << 'WELCOMEDESKTOP'
[Desktop Entry]
Type=Application
Name=JARVIS Setup
Comment=First-boot JARVIS AI setup wizard
Exec=konsole -e /usr/local/bin/jarvis-welcome.sh
Icon=utilities-terminal
Terminal=false
StartupNotify=true
X-KDE-autostart-phase=2
WELCOMEDESKTOP
    chmod 644 "${AUTOSTART_DIR}/jarvis-welcome.desktop"
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "/home/${INSTALL_USER}/.config"
    echo "  Welcome autostart created for user: ${INSTALL_USER}"
else
    echo "  Warning: Could not determine installed user — welcome autostart skipped"
fi

echo "JARVIS configuration complete."
exit 0
