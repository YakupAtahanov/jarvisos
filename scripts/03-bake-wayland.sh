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

# Step 3: Initialize pacman keyring
echo -e "${BLUE}Initializing pacman keyring...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --init
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --populate archlinux

# Step 4: Update system and fix dependencies
echo -e "${BLUE}Updating system packages (this may take a while)...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Syu --noconfirm 2>&1

# Step 5: Install GUI packages in groups
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

# Cursor themes
echo -e "${BLUE}Installing cursor themes...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm xcursor-themes breeze breeze-icons adwaita-cursors

# Networking
echo -e "${BLUE}Installing networking...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm networkmanager network-manager-applet

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

# Step 6: Ensure root user setup for autologin
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

# Step 7: Enable services
echo -e "${BLUE}Enabling services...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable sddm
sudo arch-chroot "${SQUASHFS_ROOTFS}" systemctl enable NetworkManager

# Step 8: Configure SDDM autologin for live boot
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

# Step 9: Cleanup inside chroot
echo -e "${BLUE}Cleaning up package cache and temporary files...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Scc --noconfirm
sudo arch-chroot "${SQUASHFS_ROOTFS}" sh -c "rm -rf /tmp/* /var/cache/pacman/pkg/*"

# Cleanup will be handled by trap
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 3 complete: KDE Plasma Wayland installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
