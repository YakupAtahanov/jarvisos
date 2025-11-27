#!/bin/bash
# Install GUI packages (KDE Plasma Wayland) into ISO rootfs

set -e

ROOTFS_DIR="${1}"
CHROOT_CMD="${2:-arch-chroot}"

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
        sudo arch-chroot "${ROOTFS_DIR}" "$@"
    else
        sudo systemd-nspawn -q -D "${ROOTFS_DIR}" \
            --bind-ro=/etc/resolv.conf \
            --private-network=false \
            --capability=CAP_SYS_ADMIN \
            --security-label=disable \
            "$@"
    fi
}

echo -e "${BLUE}🖥️  Installing KDE Plasma Wayland and GUI components...${NC}"

# Initialize pacman keyring (required for package installation)
echo -e "${BLUE}🔑 Initializing pacman keyring...${NC}"
chroot_run pacman-key --init 2>&1 | grep -v "WARNING.*mountpoint" || true
chroot_run pacman-key --populate archlinux 2>&1 | grep -v "WARNING.*mountpoint" || true

# Mount tmpfs for pacman sync and cache directories INSIDE chroot
# This is critical - pacman needs to write temp files during sync and package downloads
echo -e "${BLUE}📁 Mounting tmpfs for pacman directories inside chroot...${NC}"
# Mount tmpfs inside chroot - this ensures it's visible to pacman
# Note: This requires CAP_SYS_ADMIN capability which arch-chroot/systemd-nspawn should provide
chroot_run bash -c "
    # Mount tmpfs for sync directory
    if ! mountpoint -q /var/lib/pacman/sync 2>/dev/null; then
        rm -rf /var/lib/pacman/sync/*
        mkdir -p /var/lib/pacman/sync
        if mount -t tmpfs -o size=100M,mode=1777 tmpfs /var/lib/pacman/sync 2>&1; then
            echo 'Sync tmpfs mounted successfully'
        else
            echo 'Sync tmpfs mount failed - using regular directory'
            chmod 777 /var/lib/pacman/sync
            chown root:root /var/lib/pacman/sync
        fi
    fi
    
    # Mount tmpfs for package cache directory (critical for package downloads)
    # Disable SELinux labeling to avoid permission issues
    if ! mountpoint -q /var/cache/pacman/pkg 2>/dev/null; then
        rm -rf /var/cache/pacman/pkg/*
        mkdir -p /var/cache/pacman/pkg
        if mount -t tmpfs -o size=2G,mode=1777 tmpfs /var/cache/pacman/pkg 2>&1; then
            echo 'Package cache tmpfs mounted successfully'
        else
            echo 'Package cache tmpfs mount failed - using regular directory'
            chmod 777 /var/cache/pacman/pkg
            chown root:root /var/cache/pacman/pkg
        fi
    fi
    
    # Verify mounts and permissions
    if mountpoint -q /var/lib/pacman/sync 2>/dev/null; then
        chmod 1777 /var/lib/pacman/sync
        echo 'Sync mount verified: OK'
    else
        chmod 777 /var/lib/pacman/sync
        chown root:root /var/lib/pacman/sync
    fi
    
    if mountpoint -q /var/cache/pacman/pkg 2>/dev/null; then
        chmod 1777 /var/cache/pacman/pkg
        echo 'Package cache mount verified: OK'
    else
        chmod 777 /var/cache/pacman/pkg
        chown root:root /var/cache/pacman/pkg
    fi
    
    # Test write access in both directories
    TEST_SYNC=\"/var/lib/pacman/sync/test-\$(date +%s)\"
    mkdir -p \"\${TEST_SYNC}\" && touch \"\${TEST_SYNC}/test\" && rm -rf \"\${TEST_SYNC}\" && echo 'Sync write test: OK' || echo 'Sync write test: FAILED'
    
    TEST_CACHE=\"/var/cache/pacman/pkg/test-\$(date +%s)\"
    mkdir -p \"\${TEST_CACHE}\" && touch \"\${TEST_CACHE}/test.part\" && rm -rf \"\${TEST_CACHE}\" && echo 'Cache write test: OK' || echo 'Cache write test: FAILED'
" 2>&1 | grep -v "WARNING.*mountpoint" || true
# Also ensure parent directory permissions
chroot_run bash -c "chown root:root /var/lib/pacman /var/cache/pacman && chmod 755 /var/lib/pacman /var/cache/pacman" 2>&1 | grep -v "WARNING.*mountpoint" || true

# Update package database and system together to resolve dependencies
echo -e "${BLUE}🔄 Updating package database and system...${NC}"

# Try syncing databases - use separate sync command first
echo -e "${BLUE}📥 Syncing package databases...${NC}"
# Try alternative approach: sync databases on host and copy them in
echo -e "${BLUE}📥 Pre-syncing databases on host system...${NC}"
HOST_SYNC_DIR=$(mktemp -d)
sudo pacman -Sy --dbpath "${HOST_SYNC_DIR}" --noconfirm > /dev/null 2>&1 || {
    echo -e "${YELLOW}⚠️  Host sync failed, trying direct chroot sync...${NC}"
    HOST_SYNC_DIR=""
}

if [ -n "${HOST_SYNC_DIR}" ] && [ -d "${HOST_SYNC_DIR}/sync" ]; then
    echo -e "${GREEN}✅ Host databases synced, copying to chroot...${NC}"
    sudo cp -a "${HOST_SYNC_DIR}/sync"/* "${ROOTFS_DIR}/var/lib/pacman/sync/" 2>/dev/null || true
    sudo rm -rf "${HOST_SYNC_DIR}"
    echo -e "${GREEN}✅ Databases copied${NC}"
else
    # Fallback: try direct sync in chroot with maximum permissions
    echo -e "${BLUE}Trying direct sync in chroot...${NC}"
    chroot_run bash -c "
        # Ensure tmpfs is mounted and writable
        if ! mountpoint -q /var/lib/pacman/sync 2>/dev/null; then
            mount -t tmpfs -o size=100M,mode=1777 tmpfs /var/lib/pacman/sync 2>/dev/null || true
        fi
        chmod 1777 /var/lib/pacman/sync
        chown root:root /var/lib/pacman/sync
        # Try sync with verbose output to see what's happening
        pacman -Sy --noconfirm --debug 2>&1 | head -20
    " 2>&1 | grep -vE "WARNING.*mountpoint|Enter a number" || {
        echo -e "${RED}❌ Direct sync also failed${NC}"
        exit 1
    }
fi

# Now update system packages
echo -e "${BLUE}🔄 Updating system packages...${NC}"
chroot_run bash -c "pacman -Su --noconfirm" 2>&1 | grep -vE "WARNING.*mountpoint" || {
    echo -e "${YELLOW}⚠️  System update had issues, but continuing...${NC}"
}

# Install GUI packages
GUI_PACKAGES=(
    # Desktop Environment
    plasma-meta
    sddm
    
    # Wayland & Graphics
    wayland
    xorg-xwayland
    mesa
    
    # Input devices (fix mouse/keyboard issues)
    xf86-input-libinput
    libinput
    
    # Audio (PipeWire)
    pipewire
    pipewire-pulse
    pipewire-jack
    wireplumber
    
    # Applications
    firefox
    konsole
    dolphin
    
    # Fonts
    ttf-dejavu
    noto-fonts
    noto-fonts-emoji
)

echo -e "${BLUE}📦 Installing ${#GUI_PACKAGES[@]} GUI packages...${NC}"
# CRITICAL: Use bind mount to a writable location instead of tmpfs
# This avoids SELinux and filesystem permission issues
HOST_CACHE_DIR="${ROOTFS_DIR}/var/cache/pacman/pkg"
HOST_TMP_CACHE="/tmp/jarvis-pacman-cache-$$"
echo -e "${BLUE}📁 Preparing package cache directory...${NC}"
sudo umount "${HOST_CACHE_DIR}" 2>/dev/null || true
# Remove directory completely (may be on read-only SquashFS)
sudo rm -rf "${HOST_CACHE_DIR}" 2>/dev/null || true
# Create writable directory on host tmpfs
sudo mkdir -p "${HOST_TMP_CACHE}"
sudo chmod 777 "${HOST_TMP_CACHE}"
sudo chown root:root "${HOST_TMP_CACHE}"
# Create parent directories in rootfs
sudo mkdir -p "${ROOTFS_DIR}/var/cache/pacman"
# Create mount point
sudo mkdir -p "${HOST_CACHE_DIR}"
# Ensure parent is writable
sudo chmod 755 "${ROOTFS_DIR}/var/cache/pacman"
sudo chown root:root "${ROOTFS_DIR}/var/cache/pacman"

# Bind mount writable directory to pacman cache location
echo -e "${BLUE}💾 Bind mounting writable directory to package cache...${NC}"
if sudo mount --bind "${HOST_TMP_CACHE}" "${HOST_CACHE_DIR}" 2>&1; then
    echo -e "${GREEN}✅ Package cache bind mounted on host${NC}"
    # Verify mount
    if mountpoint -q "${HOST_CACHE_DIR}" 2>/dev/null; then
        echo -e "${GREEN}✅ Mount verified as mountpoint${NC}"
        sudo chmod 1777 "${HOST_CACHE_DIR}"
        sudo chown root:root "${HOST_CACHE_DIR}"
        # Test write on host (exactly what pacman does)
        TEST_DIR="${HOST_CACHE_DIR}/download-test-$(date +%s)"
        if sudo mkdir -p "${TEST_DIR}" && \
           sudo touch "${TEST_DIR}/test.pkg.tar.zst.part" && \
           sudo rm -rf "${TEST_DIR}"; then
            echo -e "${GREEN}✅ Host write test: OK${NC}"
        else
            echo -e "${RED}❌ Host write test: FAILED${NC}"
            sudo chmod 777 "${HOST_CACHE_DIR}"
        fi
    else
        echo -e "${YELLOW}⚠️  Mount not detected as mountpoint${NC}"
        sudo chmod 777 "${HOST_CACHE_DIR}"
    fi
else
    echo -e "${YELLOW}⚠️  Failed to bind mount, trying tmpfs fallback...${NC}"
    if sudo mount -t tmpfs -o size=2G,uid=0,gid=0,mode=1777 tmpfs "${HOST_CACHE_DIR}" 2>&1; then
        echo -e "${GREEN}✅ Fallback tmpfs mounted${NC}"
        sudo chmod 777 "${HOST_CACHE_DIR}"
    else
        echo -e "${YELLOW}⚠️  All mount attempts failed, using regular directory${NC}"
        sudo chmod 777 "${HOST_CACHE_DIR}"
        sudo chown root:root "${HOST_CACHE_DIR}"
    fi
fi

# Now run pacman inside chroot - the mount from host should be visible
# Try disabling SELinux enforcement if it's causing issues
chroot_run bash -c "
    # Check if SELinux is enabled and try to set permissive mode
    if command -v setenforce &>/dev/null; then
        setenforce 0 2>/dev/null || true
        echo 'SELinux set to permissive mode (if enabled)'
    fi
    
    # Verify the mount is visible inside chroot
    echo 'Checking mount status inside chroot...'
    mountpoint /var/cache/pacman/pkg 2>&1 || echo 'Not a mountpoint'
    mount | grep '/var/cache/pacman/pkg' || echo 'Mount not found in mount table'
    ls -ld /var/cache/pacman/pkg || echo 'Directory listing failed'
    id || echo 'id command failed'
    
    # Ensure permissions - use 777 for maximum compatibility
    chmod 777 /var/cache/pacman/pkg
    chown root:root /var/cache/pacman/pkg
    # Also ensure parent directory is writable
    chmod 755 /var/cache/pacman
    chown root:root /var/cache/pacman
    
    # Test write inside chroot (exactly what pacman does)
    TEST_DOWNLOAD=\"/var/cache/pacman/pkg/download-test-\$(date +%s)\"
    echo \"Testing write to: \${TEST_DOWNLOAD}\"
    if mkdir -p \"\${TEST_DOWNLOAD}\" 2>&1; then
        echo \"Directory created: OK\"
        if touch \"\${TEST_DOWNLOAD}/test.pkg.tar.zst.part\" 2>&1; then
            echo \"File created: OK\"
            # Test if we can write actual data (like pacman does)
            echo 'test data' > \"\${TEST_DOWNLOAD}/test.pkg.tar.zst.part\" 2>&1 && \
            rm -rf \"\${TEST_DOWNLOAD}\" 2>&1 && \
            echo 'Package cache write test: OK' || echo 'Package cache write test: FAILED (data write)'
        else
            echo \"File creation FAILED\"
            ls -ld \"\${TEST_DOWNLOAD}\" || true
            ls -ld /var/cache/pacman/pkg || true
            echo 'Package cache write test: FAILED'
        fi
    else
        echo \"Directory creation FAILED\"
        ls -ld /var/cache/pacman/pkg || true
        echo 'Package cache write test: FAILED'
    fi
    
    # Install packages - use strace to see what system call fails
    echo 'Installing packages...'
    yes 1 | pacman -S --needed --noconfirm ${GUI_PACKAGES[*]} 2>&1 | grep -vE 'WARNING.*mountpoint|Enter a number|Proceed with installation' || {
        echo 'Package installation had errors - checking what failed...'
        # Try to see what the actual error is
        ls -la /var/cache/pacman/pkg/ 2>&1 | head -10 || true
    }
" || {
    echo -e "${YELLOW}⚠️  Package installation had issues, but continuing...${NC}"
}

# Cleanup temporary cache directory after installation
sudo umount "${HOST_CACHE_DIR}" 2>/dev/null || true
sudo rm -rf "${HOST_TMP_CACHE}" 2>/dev/null || true

# Configure SDDM (Display Manager)
echo -e "${BLUE}⚙️  Configuring SDDM...${NC}"
sudo mkdir -p "${ROOTFS_DIR}/etc/sddm.conf.d"
# SDDM will automatically detect Wayland sessions from plasma-meta
# We just need to ensure it's configured properly
sudo tee "${ROOTFS_DIR}/etc/sddm.conf.d/wayland.conf" > /dev/null << 'EOF'
[General]
# SDDM will auto-detect Wayland sessions from /usr/share/wayland-sessions
# Plasma-meta installs plasma.desktop which provides Wayland session

[X11]
DisplayServer=xorg
SessionDir=/usr/share/xsessions
SessionCommand=/usr/share/sddm/scripts/xorg-session
EOF

# Enable SDDM service (may fail in chroot, that's OK)
chroot_run systemctl enable sddm.service 2>&1 | grep -v "WARNING.*mountpoint" || {
    echo -e "${YELLOW}⚠️  Could not enable sddm.service (may need to enable after boot)${NC}"
}

# Enable PipeWire services
chroot_run systemctl enable pipewire.service 2>&1 | grep -v "WARNING.*mountpoint" || {
    echo -e "${YELLOW}⚠️  Could not enable pipewire.service${NC}"
}
chroot_run systemctl enable pipewire-pulse.service 2>&1 | grep -v "WARNING.*mountpoint" || {
    echo -e "${YELLOW}⚠️  Could not enable pipewire-pulse.service${NC}"
}

# Note: Autologin will be configured by inject-jarvis-iso.sh for the "arch" user
# This file will be overridden, so we don't set it here

# Create desktop launcher for Calamares (will be created by install-calamares.sh)
sudo mkdir -p "${ROOTFS_DIR}/usr/share/applications"
sudo mkdir -p "${ROOTFS_DIR}/root/Desktop"

# Set up desktop environment
echo -e "${BLUE}🎨 Configuring desktop environment...${NC}"

# Create autostart directory
sudo mkdir -p "${ROOTFS_DIR}/etc/xdg/autostart"

# Configure default session
sudo mkdir -p "${ROOTFS_DIR}/etc/systemd/system/display-manager.service.d"
sudo tee "${ROOTFS_DIR}/etc/systemd/system/display-manager.service.d/override.conf" > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/sddm
EOF

echo -e "${GREEN}✅ GUI packages installed and configured${NC}"

