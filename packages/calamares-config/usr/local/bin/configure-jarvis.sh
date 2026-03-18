#!/bin/bash
# Post-installation JARVIS configuration script
# Called by Calamares shellprocess with dontChroot: true.
# $1 = target root path (@@ROOT@@ substituted by Calamares)
#
# Configures SDDM, creates XDG autostart, removes live-ISO cruft.
# Voice settings are deferred to first-boot JARVIS welcome wizard.

set -e

ROOT="${1:?ERROR: target root path not provided}"

if [ ! -d "${ROOT}" ]; then
    echo "ERROR: Target root directory does not exist: ${ROOT}" >&2
    exit 1
fi

echo "Configuring JARVIS for target: ${ROOT}"

# ---------------------------------------------------------------------------
# Remove stock linux kernel boot files (linux-jarvisos is the installed kernel)
# ---------------------------------------------------------------------------
# The squashfs rootfs contains both the stock 'linux' and 'linux-jarvisos'
# packages.  After Calamares installs, only linux-jarvisos should be active.
# Remove stock linux boot files so the bootloader and mkinitcpio only see
# linux-jarvisos, preventing confusion and wasted /boot space.
echo "Removing stock linux kernel files (linux-jarvisos is the installed kernel)..."
rm -f "${ROOT}/boot/vmlinuz-linux" 2>/dev/null || true
rm -f "${ROOT}/boot/initramfs-linux.img" 2>/dev/null || true
rm -f "${ROOT}/boot/initramfs-linux-fallback.img" 2>/dev/null || true
rm -f "${ROOT}/etc/mkinitcpio.d/linux.preset" 2>/dev/null || true

# Remove stock linux bootloader entries if using systemd-boot
# (the bootloader module may have created entries for both kernels)
if [ -d "${ROOT}/boot/loader/entries" ]; then
    for entry in "${ROOT}"/boot/loader/entries/*linux.conf; do
        # Only remove entries for stock linux, not linux-jarvisos
        if [ -f "${entry}" ] && grep -q "vmlinuz-linux$" "${entry}" 2>/dev/null; then
            echo "  Removing stock linux boot entry: $(basename "${entry}")"
            rm -f "${entry}"
        fi
    done
fi

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

# Detect the username Calamares created — look for real users in target /home.
# Filter out "liveuser" (live-ISO account) and pick the first real user.
INSTALL_USER=""
INSTALL_USER=$(find "${ROOT}/home/" -maxdepth 1 -mindepth 1 -type d \
    ! -name "liveuser" -printf '%f\n' 2>/dev/null | sort | head -1)

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
