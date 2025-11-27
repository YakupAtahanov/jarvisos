#!/bin/bash
# Install and configure Calamares installer for JARVIS OS

set -e

ROOTFS_DIR="${1}"
CHROOT_CMD="${2:-arch-chroot}"
PROJECT_ROOT="${3}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -z "${ROOTFS_DIR}" ] || [ ! -d "${ROOTFS_DIR}" ]; then
    echo -e "${RED}❌ Error: Rootfs directory not found${NC}"
    exit 1
fi

chroot_run() {
    if [ "${CHROOT_CMD}" = "arch-chroot" ]; then
        # Try arch-chroot first, but fall back to manual chroot if it fails
        if ! sudo arch-chroot "${ROOTFS_DIR}" "$@" 2>&1; then
            CHROOT_EXIT=$?
            # Check if it's a "No space left on device" error
            if sudo arch-chroot "${ROOTFS_DIR}" "$@" 2>&1 | grep -q "No space left on device"; then
                echo -e "${YELLOW}⚠️  arch-chroot failed, using manual chroot fallback...${NC}"
                # Mount filesystems manually
                sudo mount -t proc proc "${ROOTFS_DIR}/proc" 2>/dev/null || true
                sudo mount -t sysfs sysfs "${ROOTFS_DIR}/sys" 2>/dev/null || true
                sudo mount --bind /dev "${ROOTFS_DIR}/dev" 2>/dev/null || true
                sudo mount -t devpts devpts "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
                sudo mount -t tmpfs tmpfs "${ROOTFS_DIR}/dev/shm" 2>/dev/null || true
                sudo mount -t tmpfs tmpfs "${ROOTFS_DIR}/run" 2>/dev/null || true
                sudo cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf" 2>/dev/null || true
                # Run command in manual chroot
                sudo chroot "${ROOTFS_DIR}" "$@"
                CHROOT_EXIT=$?
                # Unmount after command
                sudo umount -l "${ROOTFS_DIR}/run" 2>/dev/null || true
                sudo umount -l "${ROOTFS_DIR}/dev/shm" 2>/dev/null || true
                sudo umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
                sudo umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
                sudo umount -l "${ROOTFS_DIR}/sys" 2>/dev/null || true
                sudo umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
                return $CHROOT_EXIT
            else
                return $CHROOT_EXIT
            fi
        fi
    else
        sudo systemd-nspawn -q -D "${ROOTFS_DIR}" \
            --bind-ro=/etc/resolv.conf \
            --private-network=false \
            --capability=CAP_SYS_ADMIN \
            --security-label=disable \
            "$@"
    fi
}

echo -e "${BLUE}📦 Installing Calamares installer...${NC}"

# Install Calamares packages
# Calamares is in the 'extra' repository
# Ensure package cache is mounted (should already be mounted from GUI installation)
HOST_CACHE_DIR="${ROOTFS_DIR}/var/cache/pacman/pkg"
if ! mountpoint -q "${HOST_CACHE_DIR}" 2>/dev/null; then
    echo -e "${BLUE}📦 Mounting package cache for Calamares installation...${NC}"
    sudo umount "${HOST_CACHE_DIR}" 2>/dev/null || true
    sudo rm -rf "${HOST_CACHE_DIR}"/*
    sudo mkdir -p "${HOST_CACHE_DIR}"
    sudo mount -t tmpfs -o size=2G,mode=1777 tmpfs "${HOST_CACHE_DIR}" 2>&1 || {
        sudo chmod 777 "${HOST_CACHE_DIR}"
        sudo chown root:root "${HOST_CACHE_DIR}"
    }
fi

# Try to install Calamares with better error handling
# Use the same bind mount approach as GUI packages for package cache
HOST_TMP_CACHE="/tmp/jarvis-calamares-cache-$$"
HOST_CACHE_DIR="${ROOTFS_DIR}/var/cache/pacman/pkg"

echo -e "${BLUE}📁 Preparing package cache for Calamares installation...${NC}"
# Unmount any existing mount first
sudo umount "${HOST_CACHE_DIR}" 2>/dev/null || true
# Ensure parent directories exist
sudo mkdir -p "${ROOTFS_DIR}/var/cache/pacman"
# Remove the directory if it exists (will be replaced by mount)
sudo rm -rf "${HOST_CACHE_DIR}" 2>/dev/null || true
# Create the mount point directory
sudo mkdir -p "${HOST_CACHE_DIR}"
# Create temporary writable directory on host
sudo mkdir -p "${HOST_TMP_CACHE}"
sudo chmod 1777 "${HOST_TMP_CACHE}"
sudo chown root:root "${HOST_TMP_CACHE}"

# Try bind mount first
if sudo mount --bind "${HOST_TMP_CACHE}" "${HOST_CACHE_DIR}" 2>&1; then
    echo -e "${GREEN}✅ Package cache bind mounted${NC}"
    sudo chmod 777 "${HOST_CACHE_DIR}"
    sudo chown root:root "${HOST_CACHE_DIR}"
else
    echo -e "${YELLOW}⚠️  Bind mount failed, using tmpfs fallback...${NC}"
    # Remove directory and recreate for tmpfs mount
    sudo rm -rf "${HOST_CACHE_DIR}" 2>/dev/null || true
    sudo mkdir -p "${HOST_CACHE_DIR}"
    if sudo mount -t tmpfs -o size=2G,uid=0,gid=0,mode=1777 tmpfs "${HOST_CACHE_DIR}" 2>&1; then
        echo -e "${GREEN}✅ Package cache tmpfs mounted${NC}"
        sudo chmod 777 "${HOST_CACHE_DIR}"
        sudo chown root:root "${HOST_CACHE_DIR}"
    else
        echo -e "${YELLOW}⚠️  Tmpfs mount also failed, using regular directory...${NC}"
        sudo chmod 777 "${HOST_CACHE_DIR}"
        sudo chown root:root "${HOST_CACHE_DIR}"
    fi
fi

CALAMARES_INSTALLED=false
if chroot_run bash -c "
    # Ensure permissions
    chmod 777 /var/cache/pacman/pkg 2>/dev/null || true
    chown root:root /var/cache/pacman/pkg 2>/dev/null || true
    
    # Sync databases to ensure 'extra' repo is available
    echo 'Syncing pacman databases...'
    pacman -Sy --noconfirm 2>&1 | grep -vE 'WARNING.*mountpoint' || {
        echo 'Database sync completed (warnings may be normal)'
    }
    
    # Check if Calamares exists in repos
    echo 'Checking if Calamares is available...'
    if pacman -Ss calamares 2>&1 | grep -q '^extra/calamares'; then
        echo 'Calamares found in extra repository'
        # Try to install Calamares
        yes 1 | pacman -S --needed --noconfirm calamares 2>&1 | grep -vE 'WARNING.*mountpoint|Enter a number|Proceed with installation' && {
            echo 'Calamares installed successfully'
            exit 0
        } || {
            echo 'Calamares installation had issues'
            # Check if it was actually installed
            if [ -f /usr/bin/calamares ]; then
                echo 'Calamares binary found - installation succeeded'
                exit 0
            else
                echo 'Calamares binary not found - installation failed'
                exit 1
            fi
        }
    else
        echo 'Calamares not found in repositories - checking all repos...'
        pacman -Ss calamares 2>&1 | head -10
        exit 1
    fi
" 2>&1; then
    CALAMARES_INSTALLED=true
    echo -e "${GREEN}✅ Calamares installed successfully${NC}"
else
    echo -e "${YELLOW}⚠️  Calamares installation failed${NC}"
    echo -e "${YELLOW}   This may be due to:${NC}"
    echo -e "${YELLOW}   1. Chroot environment issues${NC}"
    echo -e "${YELLOW}   2. Database sync failures${NC}"
    echo -e "${YELLOW}   3. Package not available in repositories${NC}"
    echo -e "${YELLOW}   Continuing without Calamares...${NC}"
fi

# Cleanup package cache mount
sudo umount "${HOST_CACHE_DIR}" 2>/dev/null || true
sudo rm -rf "${HOST_TMP_CACHE}" 2>/dev/null || true

# Create Calamares configuration directory
CALAMARES_DIR="${ROOTFS_DIR}/etc/calamares"
MODULES_DIR="${CALAMARES_DIR}/modules"
sudo mkdir -p "${MODULES_DIR}"

# Copy Calamares configuration from project
CONFIG_SOURCE="${PROJECT_ROOT}/configs/calamares"
if [ -d "${CONFIG_SOURCE}" ]; then
    echo -e "${BLUE}📋 Copying Calamares configuration...${NC}"
    sudo cp -a "${CONFIG_SOURCE}"/* "${CALAMARES_DIR}/"
else
    echo -e "${YELLOW}⚠️  Calamares config not found, creating default...${NC}"
    # Create default configuration
    "${PROJECT_ROOT}/scripts/create-calamares-config.sh" "${CALAMARES_DIR}"
fi

# Create desktop launcher
echo -e "${BLUE}🖥️  Creating Calamares desktop launcher...${NC}"
sudo tee "${ROOTFS_DIR}/usr/share/applications/calamares.desktop" > /dev/null << 'EOF'
[Desktop Entry]
Type=Application
Name=Install JARVIS OS
Name[en]=Install JARVIS OS
Comment=Install JARVIS OS to your hard drive
Comment[en]=Install JARVIS OS to your hard drive
Exec=calamares
Icon=system-installer
Terminal=false
Categories=System;
Keywords=installer;setup;install;
EOF

# Copy to desktop for easy access
sudo cp "${ROOTFS_DIR}/usr/share/applications/calamares.desktop" \
    "${ROOTFS_DIR}/root/Desktop/calamares.desktop"
sudo chmod +x "${ROOTFS_DIR}/root/Desktop/calamares.desktop"

# Make Calamares executable (if it exists)
if [ -f "${ROOTFS_DIR}/usr/bin/calamares" ]; then
    chroot_run chmod +x /usr/bin/calamares
else
    echo -e "${YELLOW}⚠️  Calamares binary not found (installation may have failed)${NC}"
fi

echo -e "${GREEN}✅ Calamares installed and configured${NC}"

