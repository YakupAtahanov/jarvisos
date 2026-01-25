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
if [ -f /etc/resolv.conf ]; then
    sudo cp ${BUILD_DEPS_DIR}/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
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

# Step 6: Install GUI packages in groups
echo -e "${BLUE}Installing GUI packages...${NC}"

# Wayland core
echo -e "${BLUE}Installing Wayland core...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm wayland wayland-protocols xorg-xwayland

# KDE Plasma Desktop Environment
echo -e "${BLUE}Installing KDE Plasma Desktop Environment...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm plasma-meta kde-applications-meta sddm

# Graphics drivers
echo -e "${BLUE}Installing graphics drivers...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm mesa vulkan-intel vulkan-radeon libva-mesa-driver

# Linux firmware (critical for hardware support - audio, network, touchpad, touchscreen)
echo -e "${BLUE}Installing Linux firmware...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm linux-firmware

# Audio stack (PipeWire)
echo -e "${BLUE}Installing audio stack...${NC}"
echo -e "${BLUE}Installing audio stack (PipeWire)...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Install pipewire-jack which will prompt to replace jack2
    # 'yes' command auto-answers the prompt
    yes | pacman -S --needed pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber || {
        echo 'Retrying with force...'
        pacman -Rdd --noconfirm jack2  # Remove without checking deps
        pacman -S --noconfirm pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    }
"

# KDE Audio Applet
echo -e "${BLUE}Installing KDE audio applet...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm plasma-pa

# ALSA utilities and firmware (required for audio hardware detection)
echo -e "${BLUE}Installing ALSA utilities and firmware...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm alsa-utils alsa-firmware alsa-plugins

# Cursor themes
echo -e "${BLUE}Installing cursor themes...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm xcursor-themes breeze breeze-icons adwaita-cursors

# Networking
echo -e "${BLUE}Installing networking...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm networkmanager plasma-nm

# Bluetooth
echo -e "${BLUE}Installing Bluetooth...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm bluez bluez-utils bluedevil

# Fonts
echo -e "${BLUE}Installing fonts...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji ttf-hack

# Development tools for JARVIS
echo -e "${BLUE}Installing development tools...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm base-devel git python python-pip nodejs npm wget curl vim

# Python packages
echo -e "${BLUE}Installing Python packages...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm python-numpy python-scipy python-requests python-cryptography python-yaml python-toml

# Essential applications
echo -e "${BLUE}Installing essential applications...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm firefox konsole dolphin kate

# Touchpad/Input drivers
echo -e "${BLUE}Installing input drivers...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm libinput xf86-input-libinput

# Ensure kernel modules for touchpad/touchscreen are available
# linux-firmware (installed above) provides firmware for these modules
# Modules (psmouse, i2c_hid, hid_multitouch) will load automatically via udev
echo -e "${BLUE}Configuring input device kernel modules...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Create modprobe configuration to ensure modules are available
    # Modules will load automatically when hardware is detected
    echo 'options psmouse proto=auto' > /etc/modprobe.d/psmouse.conf 2>/dev/null || true
    echo 'options i2c_hid delay_override=1' > /etc/modprobe.d/i2c_hid.conf 2>/dev/null || true
" || true

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
    # Filesystem support
    ext4 vfat exfat ntfs3
    
    # USB support (CRITICAL for live USB boot)
    usb_storage uas
    
    # Storage controllers
    ahci sd_mod nvme
    
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
HOOKS=(
    base          # Basic initramfs structure
    udev          # Device manager
    modconf       # Load modules from /etc/modprobe.d/
    kms           # Kernel mode setting (graphics)
    keyboard      # Keyboard support
    keymap        # Keyboard layout
    consolefont   # Console font
    block         # Block device support
    filesystems   # Filesystem drivers
    fsck          # Filesystem check
)

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

# Rebuild initramfs to include firmware and ALL kernel modules
# This ensures firmware files (linux-firmware) are available during early boot
# and ALL hardware modules are included (not just build machine's hardware)
echo -e "${BLUE}Rebuilding initramfs with firmware support and all hardware modules...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" mkinitcpio -P || {
    echo -e "${YELLOW}Warning: mkinitcpio had issues, but continuing...${NC}"
}

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
# Disable iwd.service - conflicts with NetworkManager (both try to manage wireless)
# NetworkManager can use IWD as backend, but standalone iwd.service must be disabled
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl disable iwd.service 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl mask iwd.service 2>/dev/null || true

# Enable systemd-resolved (required for NetworkManager DNS resolution)
echo -e "${BLUE}Enabling systemd-resolved...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable systemd-resolved.service

# Enable NetworkManager and other services
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable sddm
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable NetworkManager
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable bluetooth

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

# Only run if PipeWire is not already running
if ! systemctl --user is-active --quiet pipewire.service 2>/dev/null; then
    # Ensure systemd user instance is running
    if ! systemctl --user is-system-running >/dev/null 2>&1; then
        # Start systemd user instance
        systemctl --user start default.target 2>/dev/null || true
    fi
    
    # Start PipeWire services
    systemctl --user start pipewire.service 2>/dev/null || true
    systemctl --user start wireplumber.service 2>/dev/null || true
    systemctl --user start pipewire-pulse.service 2>/dev/null || true
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
