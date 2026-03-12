#!/bin/bash
# Post-installation JARVIS configuration script
# Called by Calamares shellprocess with dontChroot: true.
# $1 = target root path (@@ROOT@@ substituted by Calamares)
#
# Configures SDDM, creates XDG autostart, removes live-ISO cruft.
# Voice settings are deferred to first-boot JARVIS welcome wizard.

set -e

ROOT="${1:?ERROR: target root path not provided}"

echo "Configuring JARVIS for target: ${ROOT}"

# ---------------------------------------------------------------------------
# Remove live-ISO autologin
# ---------------------------------------------------------------------------
echo "Removing live ISO autologin configuration..."
rm -f "${ROOT}/etc/sddm.conf.d/autologin.conf" 2>/dev/null || true

mkdir -p "${ROOT}/etc/sddm.conf.d"
cat > "${ROOT}/etc/sddm.conf.d/jarvisos.conf" << 'SDDM_CONF'
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
mkdir -p "${ROOT}/etc/xdg/autostart"
if [ ! -f "${ROOT}/etc/xdg/autostart/jarvis.desktop" ]; then
    cat > "${ROOT}/etc/xdg/autostart/jarvis.desktop" << 'JDESKTOP'
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
    chmod 644 "${ROOT}/etc/xdg/autostart/jarvis.desktop"
fi

# ---------------------------------------------------------------------------
# Create first-boot welcome terminal autostart
# ---------------------------------------------------------------------------
echo "Creating JARVIS welcome autostart..."

# Detect the username Calamares created — look for real users in target /home
INSTALL_USER=""
INSTALL_USER=$(ls "${ROOT}/home/" 2>/dev/null | head -1)

if [ -n "${INSTALL_USER}" ]; then
    AUTOSTART_DIR="${ROOT}/home/${INSTALL_USER}/.config/autostart"
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
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "${ROOT}/home/${INSTALL_USER}/.config"
    echo "  Welcome autostart created for user: ${INSTALL_USER}"
else
    echo "  Warning: Could not determine installed user — welcome autostart skipped"
fi

echo "JARVIS configuration complete."
exit 0
