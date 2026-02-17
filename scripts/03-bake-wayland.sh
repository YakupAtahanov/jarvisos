#!/bin/bash
# Step 3: Bake in Wayland and GUI packages
# Installs Wayland, KDE Plasma, and GUI components into the rootfs

set -e

# Source config file
source build.config

# Validate required variables
if [ -z "${SCRIPTS_DIR}" ]; then
    echo "Error: SCRIPTS_DIR not set in build.config" >&2
    exit 1
fi

if [ -z "${PROJECT_ROOT}" ]; then
    echo "Error: PROJECT_ROOT not set in build.config" >&2
    exit 1
fi

# Construct paths from build.config (paths starting with / are relative to PROJECT_ROOT)
SCRIPTS_DIR="${PROJECT_ROOT}${SCRIPTS_DIR}"
BUILD_DIR="${PROJECT_ROOT}${BUILD_DIR}"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"
BUILD_DEPS_DIR="${PROJECT_ROOT}${BUILD_DEPS_DIR}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if step 2 was completed (rootfs extracted)
if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Rootfs not extracted. Please run step 2 first${NC}" >&2
    exit 1
fi

# Verify rootfs has essential directories
if [ ! -d "${SQUASHFS_ROOTFS}/usr/bin" ] && [ ! -d "${SQUASHFS_ROOTFS}/bin" ]; then
    echo -e "${RED}Error: Rootfs appears invalid - /usr/bin or /bin missing${NC}" >&2
    exit 1
fi

# Determine chroot command
if command -v arch-chroot >/dev/null 2>&1; then
    CHROOT_CMD="arch-chroot"
    echo -e "${BLUE}Using arch-chroot${NC}"
elif command -v systemd-nspawn >/dev/null 2>&1; then
    CHROOT_CMD="systemd-nspawn"
    echo -e "${YELLOW}Using systemd-nspawn (arch-chroot not found)${NC}"
    echo -e "${YELLOW}Tip: Install arch-install-scripts for better compatibility${NC}"
else
    echo -e "${RED}Error: Need arch-chroot or systemd-nspawn!${NC}" >&2
    echo -e "${YELLOW}Install: sudo dnf install arch-install-scripts${NC}"
    exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 3: Installing KDE Plasma Wayland${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"

# Step 1: Copy DNS resolution file
echo -e "${BLUE}Copying DNS resolution file...${NC}"
# Prefer build-deps/resolv.conf (with known-good DNS), fallback to host resolv.conf
if [ -f "${BUILD_DEPS_DIR}/resolv.conf" ]; then
    sudo cp "${BUILD_DEPS_DIR}/resolv.conf" "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
elif [ -f /etc/resolv.conf ]; then
    sudo cp /etc/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
fi
# Ensure resolv.conf has fallback DNS if empty or missing
if [ ! -s "${SQUASHFS_ROOTFS}/etc/resolv.conf" ]; then
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' | sudo tee "${SQUASHFS_ROOTFS}/etc/resolv.conf" > /dev/null
fi

# Step 2: Bind mount iso-rootfs to itself
echo -e "${BLUE}Bind mounting iso-rootfs to itself...${NC}"
sudo mount --bind "${SQUASHFS_ROOTFS}" "${SQUASHFS_ROOTFS}" || {
    echo -e "${RED}Error: Failed to bind mount rootfs${NC}" >&2
    exit 1
}

# Function to cleanup on exit
cleanup() {
    echo -e "${BLUE}Cleaning up...${NC}"
    # Unmount bind mount
    sudo umount "${SQUASHFS_ROOTFS}" 2>/dev/null || true
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Function to check if pacman-key refresh is needed (48-hour interval)
should_refresh_keys() {
    local timestamp_file="${BUILD_DIR}/.pacman-key-refresh-timestamp"
    local refresh_interval=172800  # 48 hours in seconds
    
    if [ ! -f "${timestamp_file}" ]; then
        return 0  # Refresh needed
    fi
    
    local last_refresh=$(stat -c %Y "${timestamp_file}" 2>/dev/null || echo 0)
    local current_time=$(date +%s)
    local time_diff=$((current_time - last_refresh))
    
    if [ $time_diff -gt $refresh_interval ]; then
        return 0  # Refresh needed
    fi
    
    return 1  # No refresh needed
}

# Step 3: Initialize pacman keyring
echo -e "${BLUE}Initializing pacman keyring...${NC}"
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --init 2>&1; then
    echo -e "${YELLOW}Warning: pacman-key --init had issues, continuing...${NC}"
fi

if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --populate archlinux 2>&1; then
    echo -e "${RED}Error: Failed to populate archlinux keyring${NC}" >&2
    exit 1
fi

# Refresh keyring to get latest keys from keyservers (only if >48 hours since last refresh)
TIMESTAMP_FILE="${BUILD_DIR}/.pacman-key-refresh-timestamp"
if should_refresh_keys; then
    echo -e "${BLUE}Refreshing keyring from keyservers (this may take a moment)...${NC}"
    if sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "pacman-key --refresh-keys 2>&1 | head -20"; then
        # Update timestamp file on successful refresh
        touch "${TIMESTAMP_FILE}" 2>/dev/null || true
        echo -e "${GREEN}✓ Keyring refreshed successfully${NC}"
    else
        echo -e "${YELLOW}Warning: Key refresh had issues, but continuing...${NC}"
    fi
else
    LAST_REFRESH=$(stat -c %Y "${TIMESTAMP_FILE}" 2>/dev/null || echo 0)
    HOURS_AGO=$(( ($(date +%s) - LAST_REFRESH) / 3600 ))
    echo -e "${BLUE}Skipping keyring refresh (last refreshed ${HOURS_AGO} hours ago, <48 hours)${NC}"
fi

# Update archlinux-keyring package to ensure we have latest keys
# This is important as it contains the most up-to-date keys
echo -e "${BLUE}Updating archlinux-keyring package...${NC}"
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Sy archlinux-keyring --noconfirm 2>&1; then
    echo -e "${YELLOW}Warning: Could not update keyring package, trying to continue...${NC}"
    # Only refresh keys if we haven't refreshed recently (avoid redundant refresh)
    if should_refresh_keys; then
        sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --refresh-keys 2>&1 | head -10 || true
    fi
fi

# Re-populate after updating keyring package
echo -e "${BLUE}Re-populating keyring after update...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --populate archlinux 2>&1 || {
    echo -e "${YELLOW}Warning: Re-population had issues, but continuing...${NC}"
}

# Step 4: Clean package cache to remove any corrupted packages
echo -e "${BLUE}Cleaning package cache...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "rm -rf /var/cache/pacman/pkg/*.pkg.tar.* 2>/dev/null || true"

# Step 5: Update system and fix dependencies
echo -e "${BLUE}Updating system packages (this may take a while)...${NC}"
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Syu --noconfirm 2>&1; then
    echo -e "${YELLOW}First update attempt failed, cleaning cache and retrying...${NC}"
    # Clean cache again and retry
    sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "rm -rf /var/cache/pacman/pkg/*.pkg.tar.* 2>/dev/null || true"
    # Refresh keys one more time
    sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --refresh-keys 2>&1 | head -10 || true
    # Retry update
    sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Syu --noconfirm 2>&1
fi

# ============================================================================
# CRITICAL: Install Linux kernel package
# ============================================================================
echo -e "${BLUE}Installing Linux kernel...${NC}"
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm linux linux-headers 2>&1; then
    echo -e "${RED}FATAL: Failed to install linux kernel package${NC}" >&2
    exit 1
fi

# Verify kernel package was installed
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q linux >/dev/null 2>&1; then
    echo -e "${RED}FATAL: Linux kernel package not found after installation${NC}" >&2
    exit 1
fi

KERNEL_VERSION=$(sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q linux | awk '{print $2}')
echo -e "${GREEN}✓ Linux kernel installed: ${KERNEL_VERSION}${NC}"

# Step 6: Install GUI packages in groups
echo -e "${BLUE}Installing GUI packages...${NC}"

# Wayland core
echo -e "${BLUE}Installing Wayland core...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm wayland wayland-protocols xorg-xwayland

# KDE Plasma Desktop Environment
echo -e "${BLUE}Installing KDE Plasma Desktop Environment...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm plasma-meta sddm

# Essential KDE applications (kde-applications-meta was removed from Arch repos)
echo -e "${BLUE}Installing essential KDE applications...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    ark \
    dolphin \
    gwenview \
    kate \
    konsole \
    okular \
    spectacle \
    elisa \
    kcalc \
    plasma-systemmonitor \
    kwrite \
    filelight \
    partitionmanager \
    kdeconnect

# Graphics drivers
echo -e "${BLUE}Installing graphics drivers...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm mesa vulkan-intel vulkan-radeon libva-mesa-driver

# ============================================================================
# Linux firmware (CRITICAL for hardware support - WiFi, audio, touchpad, etc)
# ============================================================================
echo -e "${BLUE}Installing comprehensive Linux firmware...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    linux-firmware \
    linux-firmware-marvell \
    linux-firmware-bnx2x \
    linux-firmware-liquidio \
    linux-firmware-mellanox \
    linux-firmware-nfp \
    linux-firmware-qcom \
    linux-firmware-qlogic \
    linux-firmware-whence

echo -e "${GREEN}✓ Linux firmware installed${NC}"

# CPU microcode (Intel and AMD)
echo -e "${BLUE}Installing CPU microcode...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm intel-ucode amd-ucode

# ============================================================================
# Audio stack (PipeWire) - CRITICAL for working audio
# ============================================================================
echo -e "${BLUE}Installing PipeWire audio stack...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Install pipewire-jack which will prompt to replace jack2
    # 'yes' command auto-answers the prompt
    yes | pacman -S --needed pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber || {
        echo 'Retrying with force...'
        pacman -Rdd --noconfirm jack2  # Remove without checking deps
        pacman -S --noconfirm pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    }
"

# KDE Audio Applet and volume control
echo -e "${BLUE}Installing KDE audio applet...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm plasma-pa pavucontrol

# ALSA utilities and firmware (required for audio hardware detection)
echo -e "${BLUE}Installing ALSA utilities and firmware...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    alsa-utils \
    alsa-firmware \
    alsa-plugins \
    alsa-lib \
    alsa-topology-conf \
    alsa-ucm-conf

# RealtimeKit and Sound Open Firmware (CRITICAL for PipeWire audio)
echo -e "${BLUE}Installing RealtimeKit and SOF firmware for real-time audio...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    rtkit \
    sof-firmware
# Note: alsa-card-profiles is provided by pipewire-alsa, no need to install separately

echo -e "${GREEN}✓ PipeWire audio stack installed${NC}"

# Cursor themes
echo -e "${BLUE}Installing cursor themes...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm xcursor-themes breeze breeze-icons adwaita-icon-theme

# ============================================================================
# Networking and WiFi (CRITICAL for live boot connectivity)
# ============================================================================
echo -e "${BLUE}Installing networking stack...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    networkmanager \
    plasma-nm \
    network-manager-applet

# WiFi authentication and tools (CRITICAL for password-protected networks)
echo -e "${BLUE}Installing WiFi authentication and management tools...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    wpa_supplicant \
    iw \
    wireless_tools \
    wireless-regdb \
    dialog \
    dhcpcd \
    modemmanager
# Note: crda was removed from Arch repos in 2021; wireless-regdb replaces it

echo -e "${GREEN}✓ WiFi tools installed${NC}"

# Bluetooth
echo -e "${BLUE}Installing Bluetooth...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm bluez bluez-utils bluedevil

# Fonts
echo -e "${BLUE}Installing fonts...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji ttf-hack

# Development tools for JARVIS
echo -e "${BLUE}Installing development tools...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm base-devel git python python-pip nodejs npm wget curl vim

# System utilities (standard in Arch ISO)
echo -e "${BLUE}Installing system utilities...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    sudo \
    less \
    man-db \
    man-pages \
    dmidecode \
    usbutils \
    pciutils \
    ethtool \
    iproute2 \
    bind-tools \
    traceroute

# Python packages (use --needed to skip already-installed packages)
echo -e "${BLUE}Installing Python packages...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm --needed \
    python-numpy \
    python-scipy \
    python-requests \
    python-cryptography \
    python-yaml \
    python-tomli \
    python-setuptools \
    python-pip

# Essential applications (browser - kate/konsole/dolphin already installed with KDE apps)
echo -e "${BLUE}Installing essential applications...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm firefox vlc

# ============================================================================
# Touchpad/Input drivers (CRITICAL for laptop touchpad functionality)
# ============================================================================
echo -e "${BLUE}Installing input drivers and utilities...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    libinput \
    xf86-input-libinput \
    xorg-xinput \
    xf86-input-evdev \
    xf86-input-synaptics

# Input device debugging tools (for troubleshooting touchpad issues)
echo -e "${BLUE}Installing input debugging tools...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm evtest libevdev

echo -e "${GREEN}✓ Input drivers installed${NC}"

# ============================================================================
# Kernel module configuration for hardware support
# ============================================================================
echo -e "${BLUE}Configuring kernel modules for hardware support...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Create modprobe configurations for input devices
    mkdir -p /etc/modprobe.d

    # Touchpad configuration
    echo 'options psmouse proto=auto' > /etc/modprobe.d/psmouse.conf
    echo 'options i2c_hid delay_override=1' > /etc/modprobe.d/i2c_hid.conf

    # Audio configuration - enable power saving for HDA Intel
    echo 'options snd_hda_intel power_save=1' > /etc/modprobe.d/audio.conf

    # WiFi configuration - disable power management for iwlwifi (power saving causes connection drops)
    echo 'options iwlwifi power_save=0' > /etc/modprobe.d/wifi.conf

    # Bluetooth configuration
    echo 'options btusb enable_autosuspend=0' > /etc/modprobe.d/bluetooth.conf
" || true

echo -e "${GREEN}✓ Kernel modules configured${NC}"

# Create modules-load configuration to ensure critical modules load at boot
echo -e "${BLUE}Configuring automatic module loading at boot...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    mkdir -p /etc/modules-load.d

    # Load WiFi modules
    cat > /etc/modules-load.d/wifi.conf << 'WIFIEOF'
# WiFi kernel modules
iwlwifi
mt76_connac_lib
rtw88_core
brcmfmac
WIFIEOF

    # Load audio modules
    cat > /etc/modules-load.d/audio.conf << 'AUDIOEOF'
# Audio kernel modules
snd_hda_intel
snd_hda_codec_generic
snd_hda_codec_realtek
snd_hda_codec_hdmi
snd_soc_core
AUDIOEOF

    # Load input device modules
    cat > /etc/modules-load.d/input.conf << 'INPUTEOF'
# Input device kernel modules
i2c_hid
i2c_hid_acpi
hid_multitouch
psmouse
usbhid
INPUTEOF

    # Load bluetooth modules
    cat > /etc/modules-load.d/bluetooth.conf << 'BTEOF'
# Bluetooth kernel modules
btusb
btintel
btrtl
BTEOF
" || true

echo -e "${GREEN}✓ Automatic module loading configured${NC}"

# Configure ALSA to work properly with PipeWire
echo -e "${BLUE}Configuring ALSA for PipeWire compatibility...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    mkdir -p /etc/alsa/conf.d

    # Create ALSA configuration for PipeWire
    cat > /etc/alsa/conf.d/99-pipewire-default.conf << 'ALSAEOF'
pcm.!default {
    type pipewire
}

ctl.!default {
    type pipewire
}
ALSAEOF

    # Ensure user is in audio group (for root in live boot)
    usermod -aG audio root 2>/dev/null || true
" || true

echo -e "${GREEN}✓ ALSA configured for PipeWire${NC}"

# ============================================================================
# CRITICAL: Install archiso package for live boot hooks
# ============================================================================
# The archiso package provides the 'archiso' and 'memdisk' mkinitcpio hooks
# These hooks are REQUIRED for the initramfs to mount the squashfs rootfs
# during live boot. Without archiso hook, the kernel cannot find root.
echo -e "${BLUE}Installing archiso package (live boot hooks)...${NC}"
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm archiso 2>&1; then
    echo -e "${RED}FATAL: Failed to install archiso package${NC}" >&2
    echo -e "${YELLOW}The archiso package provides memdisk and archiso mkinitcpio hooks${NC}"
    echo -e "${YELLOW}Without these hooks, the live ISO CANNOT BOOT${NC}"
    exit 1
fi
echo -e "${GREEN}✓ archiso package installed (provides memdisk and archiso hooks)${NC}"

# ============================================================================
# CRITICAL FIX: Create mkinitcpio.conf for maximum hardware compatibility
# ============================================================================
# The 'autodetect' hook only includes modules for the BUILD machine's hardware
# For a live ISO, we need ALL hardware modules included, not just autodetected ones
echo -e "${BLUE}Creating mkinitcpio.conf for live ISO (all hardware support)...${NC}"

# Backup original config
if [ -f "${SQUASHFS_ROOTFS}/etc/mkinitcpio.conf" ]; then
    sudo cp "${SQUASHFS_ROOTFS}/etc/mkinitcpio.conf" \
           "${SQUASHFS_ROOTFS}/etc/mkinitcpio.conf.backup"
fi

# Create new mkinitcpio.conf with explicit module list
sudo tee "${SQUASHFS_ROOTFS}/etc/mkinitcpio.conf" > /dev/null << 'MKINITCPIO_EOF'
# JARVIS OS - Live ISO Configuration
# Optimized for maximum hardware compatibility
# 
# CRITICAL: NO autodetect hook - includes ALL modules explicitly
# This ensures the ISO works on any hardware, not just the build machine

# ============================================================================
# MODULES - Explicitly list all critical hardware modules
# ============================================================================
MODULES=(
    # ========================================================================
    # LIVE BOOT CRITICAL - squashfs, overlay, loop MUST be in initramfs
    # The archiso hook needs these to mount the live rootfs from the squashfs
    # ========================================================================
    squashfs overlay loop

    # Filesystem support
    ext4 vfat exfat ntfs3

    # USB support (CRITICAL for live USB boot)
    usb_storage uas xhci_hcd xhci_pci ehci_hcd ehci_pci ohci_hcd

    # Storage controllers
    ahci sd_mod nvme nvme_core

    # ========================================================================
    # INPUT DEVICES (Touchpad, Touchscreen, Keyboard, Mouse)
    # ========================================================================
    # I2C HID devices (modern touchpads/touchscreens)
    i2c_hid i2c_hid_acpi hid_multitouch hid_generic usbhid
    # PS/2 touchpad (legacy laptops)
    psmouse
    # I2C controller drivers (Intel, AMD, generic)
    i2c_i801 i2c_designware_platform i2c_designware_core

    # ========================================================================
    # GRAPHICS DRIVERS (for display output)
    # ========================================================================
    i915 amdgpu radeon nouveau

    # ========================================================================
    # AUDIO DRIVERS (Sound cards, speakers, microphones)
    # ========================================================================
    # HDA Intel (most common audio chipset)
    snd_hda_intel
    # HDA Codecs (various audio chip models)
    snd_hda_codec_generic snd_hda_codec_realtek snd_hda_codec_hdmi
    snd_hda_codec_conexant snd_hda_codec_ca0132
    # SOF (Sound Open Firmware - modern Intel laptops)
    snd_soc_skl snd_soc_avs snd_soc_core

    # ========================================================================
    # NETWORK DRIVERS
    # ========================================================================
    # Ethernet controllers
    e1000e r8169 igb ixgbe atlantic

    # WiFi - Intel (most common)
    iwlwifi iwlmvm

    # WiFi - MediaTek (MT7921, MT7922, etc)
    mt7921e mt76_connac_lib mt76

    # WiFi - Realtek (RTW88 series)
    rtw88_8822ce rtw88_core rtw89_core rtw89_8852ae

    # WiFi - Broadcom
    brcmfmac brcmutil

    # WiFi - Atheros/Qualcomm
    ath10k_core ath10k_pci ath11k ath11k_pci

    # ========================================================================
    # BLUETOOTH
    # ========================================================================
    btusb btintel btrtl btbcm

    # ========================================================================
    # OTHER DEVICES
    # ========================================================================
    # Webcam
    uvcvideo
    # DM for device mapper (used by some storage/crypto setups)
    dm_mod
)

# ============================================================================
# BINARIES - Additional binaries to include (usually empty for live ISO)
# ============================================================================
BINARIES=()

# ============================================================================
# FILES - Additional files to include (usually empty)
# ============================================================================
FILES=()

# ============================================================================
# HOOKS - Build hooks determine what gets included in initramfs
# ============================================================================
# CRITICAL: 'autodetect' hook is REMOVED
# autodetect only includes modules for the build machine's hardware
# Without it, ALL modules in MODULES array are included
#
# CRITICAL: 'memdisk' and 'archiso' hooks REQUIRED for live boot
# Without archiso hook, the kernel cannot find the root filesystem
# The archiso hook: finds the live medium by label, mounts squashfs, sets up overlayfs
# The memdisk hook: helper required by archiso for detecting the live medium
HOOKS=(
    base          # Basic initramfs structure
    udev          # Device manager (needed to find live medium by label)
    modconf       # Load modules from /etc/modprobe.d/
    kms           # Kernel mode setting (graphics)
    memdisk       # REQUIRED: helper for archiso to detect live medium
    archiso       # REQUIRED: mounts squashfs as rootfs with overlayfs for live boot
    keyboard      # Keyboard support (for emergency shell)
    keymap        # Keyboard layout
    block         # Block device support
    filesystems   # Filesystem drivers
)

# Note: Firmware files from /usr/lib/firmware/ are automatically included
# when corresponding kernel modules are added to the initramfs

# ============================================================================
# COMPRESSION - Use zstd for fast decompression during boot
# ============================================================================
COMPRESSION="zstd"
COMPRESSION_OPTIONS=(-9)

# Uncomment for debugging (no compression, faster build)
#COMPRESSION="cat"
MKINITCPIO_EOF

echo -e "${GREEN}✓ Created mkinitcpio.conf with explicit module list${NC}"
echo -e "${BLUE}  - Removed 'autodetect' hook${NC}"
echo -e "${BLUE}  - Added explicit MODULES array with all critical hardware${NC}"
echo -e "${BLUE}  - Initramfs will now work on ANY hardware${NC}"
echo ""

# ============================================================================
# Pre-check: Verify kernel modules directory exists
# ============================================================================
echo -e "${BLUE}Verifying kernel installation...${NC}"
# Arch Linux kernel modules are in directories like "6.18.7-arch1-1" (not ending in "-linux")
# Find any directory that looks like a kernel version (contains numbers and dashes)
KERNEL_MODULES_DIR=$(sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c 'ls -1 /usr/lib/modules/ 2>/dev/null | grep -E "^[0-9]+\." | head -1')
if [ -z "${KERNEL_MODULES_DIR}" ]; then
    echo -e "${RED}FATAL: Kernel modules directory not found in /usr/lib/modules/${NC}" >&2
    echo -e "${YELLOW}Available directories:${NC}"
    sudo arch-chroot "${SQUASHFS_ROOTFS}" ls -la /usr/lib/modules/ || true
    exit 1
fi
echo -e "${GREEN}✓ Found kernel modules: ${KERNEL_MODULES_DIR}${NC}"

# Ensure boot directory exists with correct permissions
sudo arch-chroot "${SQUASHFS_ROOTFS}" mkdir -p /boot
sudo arch-chroot "${SQUASHFS_ROOTFS}" chmod 755 /boot

# Rebuild initramfs to include firmware and ALL kernel modules
# This ensures firmware files (linux-firmware) are available during early boot
# and ALL hardware modules are included (not just build machine's hardware)
echo -e "${BLUE}Rebuilding initramfs with firmware support and all hardware modules...${NC}"
echo -e "${BLUE}This may take several minutes...${NC}"

# Run mkinitcpio with verbose output for debugging
MKINITCPIO_OUTPUT=$(sudo arch-chroot "${SQUASHFS_ROOTFS}" mkinitcpio -P 2>&1)
MKINITCPIO_EXIT=$?

if [ ${MKINITCPIO_EXIT} -ne 0 ]; then
    echo -e "${RED}FATAL: mkinitcpio failed to generate initramfs${NC}" >&2
    echo -e "${YELLOW}mkinitcpio output:${NC}"
    echo "${MKINITCPIO_OUTPUT}"
    echo ""
    echo -e "${YELLOW}Checking for common issues:${NC}"
    echo -e "${BLUE}Boot directory:${NC}"
    sudo arch-chroot "${SQUASHFS_ROOTFS}" ls -la /boot/ || true
    echo -e "${BLUE}Kernel modules:${NC}"
    sudo arch-chroot "${SQUASHFS_ROOTFS}" ls -la /usr/lib/modules/ || true
    exit 1
fi

# Show last 20 lines of output
echo "${MKINITCPIO_OUTPUT}" | tail -20
echo -e "${GREEN}✓ mkinitcpio completed successfully${NC}"

# ============================================================================
# CRITICAL: Verify kernel files were created
# ============================================================================
echo -e "${BLUE}Verifying kernel files were generated...${NC}"
if ! sudo test -f "${SQUASHFS_ROOTFS}/boot/vmlinuz-linux"; then
    echo -e "${RED}FATAL: vmlinuz-linux was not created!${NC}" >&2
    echo -e "${YELLOW}Boot directory contents:${NC}"
    sudo ls -lah "${SQUASHFS_ROOTFS}/boot/" || true
    exit 1
fi

if ! sudo test -f "${SQUASHFS_ROOTFS}/boot/initramfs-linux.img"; then
    echo -e "${RED}FATAL: initramfs-linux.img was not created!${NC}" >&2
    echo -e "${YELLOW}Boot directory contents:${NC}"
    sudo ls -lah "${SQUASHFS_ROOTFS}/boot/" || true
    exit 1
fi

KERNEL_SIZE=$(sudo du -h "${SQUASHFS_ROOTFS}/boot/vmlinuz-linux" | cut -f1)
INITRAMFS_SIZE=$(sudo du -h "${SQUASHFS_ROOTFS}/boot/initramfs-linux.img" | cut -f1)

echo -e "${GREEN}✓ Kernel files verified:${NC}"
echo -e "${GREEN}  - vmlinuz-linux (${KERNEL_SIZE})${NC}"
echo -e "${GREEN}  - initramfs-linux.img (${INITRAMFS_SIZE})${NC}"

# ============================================================================
# CRITICAL: Copy kernel files outside rootfs for later use
# ============================================================================
# The kernel files will be needed by step 7 (rebuild-iso) to copy into the ISO
# structure. We copy them out now to ensure they're accessible even if rootfs
# is modified or cleaned up by subsequent steps.
echo -e "${BLUE}Preserving kernel files for ISO build...${NC}"
KERNEL_BACKUP_DIR="${BUILD_DIR}/kernel-files"
sudo mkdir -p "${KERNEL_BACKUP_DIR}"
sudo cp "${SQUASHFS_ROOTFS}/boot/vmlinuz-linux" "${KERNEL_BACKUP_DIR}/"
sudo cp "${SQUASHFS_ROOTFS}/boot/initramfs-linux.img" "${KERNEL_BACKUP_DIR}/"
if sudo test -f "${SQUASHFS_ROOTFS}/boot/initramfs-linux-fallback.img"; then
    sudo cp "${SQUASHFS_ROOTFS}/boot/initramfs-linux-fallback.img" "${KERNEL_BACKUP_DIR}/"
fi
if sudo test -f "${SQUASHFS_ROOTFS}/boot/amd-ucode.img"; then
    sudo cp "${SQUASHFS_ROOTFS}/boot/amd-ucode.img" "${KERNEL_BACKUP_DIR}/"
fi
if sudo test -f "${SQUASHFS_ROOTFS}/boot/intel-ucode.img"; then
    sudo cp "${SQUASHFS_ROOTFS}/boot/intel-ucode.img" "${KERNEL_BACKUP_DIR}/"
fi

echo -e "${GREEN}✓ Kernel files backed up to ${KERNEL_BACKUP_DIR}${NC}"

# Step 7: Ensure root user setup for autologin
echo -e "${BLUE}Setting up root user for autologin...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Ensure root has a home directory
    if [ ! -d /root ]; then
        mkdir -p /root
        chmod 700 /root
    fi

    # Create basic shell config files if they don't exist
    if [ ! -f /root/.bashrc ]; then
        cp /etc/skel/.bashrc /root/.bashrc 2>/dev/null || true
    fi
    if [ ! -f /root/.bash_profile ]; then
        cp /etc/skel/.bash_profile /root/.bash_profile 2>/dev/null || true
    fi

    # Remove root password for live boot (standard for Arch live ISO)
    passwd -d root 2>/dev/null || true

    # Generate default locale
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/^#en_US ISO-8859-1/en_US ISO-8859-1/' /etc/locale.gen 2>/dev/null || true
    locale-gen 2>/dev/null || true
    echo 'LANG=en_US.UTF-8' > /etc/locale.conf

    # Set hostname
    echo 'jarvisos' > /etc/hostname
    cat > /etc/hosts << 'HOSTSEOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   jarvisos.localdomain jarvisos
HOSTSEOF

    # Ensure root can login (check passwd entry)
    if ! getent passwd root >/dev/null 2>&1; then
        echo 'Warning: root user not found in passwd'
    fi
" 2>&1 | grep -vE "WARNING.*mountpoint" || true

# Step 8: Enable services
echo -e "${BLUE}Enabling services...${NC}"

# Disable conflicting network services (may conflict with NetworkManager)
echo -e "${BLUE}Disabling conflicting network services...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl disable systemd-networkd.service 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl disable dhcpcd.service 2>/dev/null || true
# Note: iwd is not installed, so no need to disable it
# NetworkManager will use wpa_supplicant as the WiFi backend

# Enable systemd-resolved (required for NetworkManager DNS resolution)
echo -e "${BLUE}Enabling systemd-resolved...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable systemd-resolved.service

# Enable NetworkManager and other critical services
echo -e "${BLUE}Enabling NetworkManager and other services...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable sddm.service
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable NetworkManager.service
# IMPORTANT: Disable NetworkManager-wait-online to prevent 90-second boot timeout
# when no network is immediately available (common on live boot)
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable NetworkManager-dispatcher.service
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable wpa_supplicant.service
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable bluetooth.service
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable ModemManager.service

echo -e "${GREEN}✓ Services enabled${NC}"

# Step 8.5: Enable PipeWire audio services for root user (autologin)
echo -e "${BLUE}Enabling PipeWire audio services for root user...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Enable PipeWire services globally
    systemctl --user --global enable pipewire.service
    systemctl --user --global enable pipewire-pulse.service
    systemctl --user --global enable wireplumber.service
    
    # Create root user systemd directory
    mkdir -p /root/.config/systemd/user/default.target.wants
    
    # Create symlinks for root user (autologin)
    ln -sf /usr/lib/systemd/user/pipewire.service /root/.config/systemd/user/default.target.wants/ 2>/dev/null || true
    ln -sf /usr/lib/systemd/user/pipewire-pulse.service /root/.config/systemd/user/default.target.wants/ 2>/dev/null || true
    ln -sf /usr/lib/systemd/user/wireplumber.service /root/.config/systemd/user/default.target.wants/ 2>/dev/null || true
"

echo -e "${GREEN}✓ PipeWire audio services enabled${NC}"

# Step 8.6: Create PipeWire autostart script for live ISO
echo -e "${BLUE}Creating PipeWire autostart script...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/etc/profile.d/pipewire-start.sh" > /dev/null << 'EOF'
#!/bin/bash
# PipeWire autostart script for live ISO
# Starts PipeWire services when user session begins

# Only run in interactive shell with user session
if [ -n "$PS1" ] && [ -n "$XDG_RUNTIME_DIR" ]; then
    # Only run if PipeWire is not already running
    if ! systemctl --user is-active --quiet pipewire.service 2>/dev/null; then
        # Ensure systemd user instance is running
        if ! systemctl --user is-system-running >/dev/null 2>&1; then
            # Start systemd user instance
            systemctl --user start default.target 2>/dev/null || true
        fi

        # Start PipeWire services with delay to ensure system is ready
        (
            sleep 2
            systemctl --user start pipewire.service 2>/dev/null || true
            systemctl --user start wireplumber.service 2>/dev/null || true
            systemctl --user start pipewire-pulse.service 2>/dev/null || true
        ) &
    fi
fi
EOF

sudo chmod +x "${SQUASHFS_ROOTFS}/etc/profile.d/pipewire-start.sh"

# Also create KDE Plasma environment script for Wayland session
sudo mkdir -p "${SQUASHFS_ROOTFS}/root/.config/plasma-workspace/env"
sudo tee "${SQUASHFS_ROOTFS}/root/.config/plasma-workspace/env/pipewire.sh" > /dev/null << 'EOF'
#!/bin/bash
# Start PipeWire services for KDE Plasma session
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user start pipewire.service 2>/dev/null || true
    systemctl --user start wireplumber.service 2>/dev/null || true
    systemctl --user start pipewire-pulse.service 2>/dev/null || true
fi
EOF

sudo chmod +x "${SQUASHFS_ROOTFS}/root/.config/plasma-workspace/env/pipewire.sh"
sudo chown -R root:root "${SQUASHFS_ROOTFS}/root/.config/plasma-workspace/env/pipewire.sh" 2>/dev/null || true

echo -e "${GREEN}✓ PipeWire autostart scripts created${NC}"

# Step 8.7: Configure NetworkManager for proper WiFi support
echo -e "${BLUE}Configuring NetworkManager for WiFi...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/NetworkManager/conf.d"

# Configure NetworkManager to use wpa_supplicant backend (not iwd)
sudo tee "${SQUASHFS_ROOTFS}/etc/NetworkManager/conf.d/wifi-backend.conf" > /dev/null << 'EOF'
[device]
wifi.backend=wpa_supplicant
EOF

# Enable WiFi and networking
sudo tee "${SQUASHFS_ROOTFS}/etc/NetworkManager/conf.d/wifi.conf" > /dev/null << 'EOF'
[main]
plugins=keyfile

[keyfile]
unmanaged-devices=none

[device]
wifi.scan-rand-mac-address=yes

[connection]
wifi.powersave=2
EOF

echo -e "${GREEN}✓ NetworkManager configured for WiFi${NC}"

# Step 9: Configure SDDM autologin for live boot
echo -e "${BLUE}Configuring SDDM autologin for live boot...${NC}"

# Create SDDM configuration directory
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/sddm.conf.d"

# Configure autologin as root for live boot
sudo tee "${SQUASHFS_ROOTFS}/etc/sddm.conf.d/autologin.conf" > /dev/null << 'EOF'
[Autologin]
User=root
Session=plasma

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
EOF

echo -e "${GREEN}✓ SDDM autologin configured for root user with Wayland session${NC}"

# Step 10: Cleanup inside chroot
echo -e "${BLUE}Cleaning up package cache and temporary files...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Scc --noconfirm
sudo arch-chroot "${SQUASHFS_ROOTFS}" sh -c "rm -rf /tmp/* /var/cache/pacman/pkg/*"

# Cleanup will be handled by trap
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 3 complete: KDE Plasma Wayland installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
