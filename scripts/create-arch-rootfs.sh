#!/bin/bash
# Create Arch Linux root filesystem for JARVIS OS
# Uses Arch bootstrap tarball (portable, works on any Linux distro)

set -e

BUILD_DIR="${1:-build}"
ROOTFS_DIR="${BUILD_DIR}/arch-rootfs"
BOOTSTRAP_URL="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst"
BOOTSTRAP_TAR="${BUILD_DIR}/archlinux-bootstrap.tar.zst"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🏗️  Building Arch Linux root filesystem for JARVIS OS...${NC}"

# Check for recommended tools
if ! command -v arch-chroot &> /dev/null; then
    echo -e "${YELLOW}⚠️  arch-chroot not found. Installing arch-install-scripts is recommended.${NC}"
    echo -e "${YELLOW}   Run: sudo dnf5 install arch-install-scripts${NC}"
    echo -e "${YELLOW}   Will attempt to use systemd-nspawn as fallback...${NC}"
    echo ""
fi

# Create build directory
mkdir -p "${BUILD_DIR}"

# Download Arch bootstrap if not exists
if [ ! -f "${BOOTSTRAP_TAR}" ]; then
    echo -e "${BLUE}📥 Downloading Arch Linux bootstrap (~140MB)...${NC}"
    curl -L -o "${BOOTSTRAP_TAR}" "${BOOTSTRAP_URL}" || {
        echo -e "${RED}❌ Failed to download bootstrap${NC}"
        exit 1
    }
else
    echo -e "${GREEN}✅ Bootstrap tarball already exists${NC}"
fi

# Check if zstd is available
if ! command -v zstd &> /dev/null && ! command -v unzstd &> /dev/null; then
    echo -e "${RED}❌ Error: zstd not found!${NC}"
    echo -e "${YELLOW}Install it with: sudo dnf5 install zstd${NC}"
    exit 1
fi

# Extract bootstrap (Arch uses zstd compression now, not gzip)
# Note: Must extract as root due to CA certificate permissions
echo -e "${BLUE}📦 Extracting bootstrap (zstd format)...${NC}"
echo -e "${YELLOW}⚠️  This requires root privileges for CA certificates${NC}"

# Clean up any leftover extraction files in build directory
echo -e "${BLUE}🧹 Cleaning up old rootfs and leftover files...${NC}"
# List of root filesystem directories that shouldn't be in build/
ROOTFS_DIRS="bin boot dev etc home lib lib64 mnt opt proc root run sbin srv sys tmp usr var"
for dir in $ROOTFS_DIRS; do
    if [ -e "${BUILD_DIR}/${dir}" ] && [ "${dir}" != "arch-rootfs" ]; then
        echo -e "${YELLOW}  Removing leftover rootfs directory: ${dir}${NC}"
        sudo rm -rf "${BUILD_DIR}/${dir}"
    fi
done

# Unmount any existing mount points before removing
if [ -d "${ROOTFS_DIR}" ]; then
    echo -e "${BLUE}🧹 Cleaning up old rootfs...${NC}"
    # Try to unmount any mounted filesystems (ignore errors if not mounted)
    # Use lazy unmount for stubborn mounts
    sudo umount -l "${ROOTFS_DIR}/var/cache/pacman/pkg" 2>/dev/null || true  # Unmount tmpfs cache first
    sudo umount -l "${ROOTFS_DIR}/proc" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/sys" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/dev/shm" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/dev" 2>/dev/null || true
    sudo umount -l "${ROOTFS_DIR}/run" 2>/dev/null || true
    # Wait a moment for lazy unmounts to complete
    sleep 1
    # Remove the directory, ignoring errors for files that might still be in use
    # Use find to remove files individually, ignoring permission errors
    sudo find "${ROOTFS_DIR}" -mindepth 1 -delete 2>/dev/null || {
        # If find fails, try rm with force
        sudo rm -rf "${ROOTFS_DIR}" 2>/dev/null || {
            echo -e "${YELLOW}⚠️  Some files couldn't be removed (may be in use), continuing...${NC}"
            # Create a new directory with a different name if removal fails
            if [ -d "${ROOTFS_DIR}" ]; then
                OLD_ROOTFS="${ROOTFS_DIR}.old.$(date +%s)"
                sudo mv "${ROOTFS_DIR}" "${OLD_ROOTFS}" 2>/dev/null || true
            fi
        }
    }
fi
mkdir -p "${BUILD_DIR}"

# Extract bootstrap (don't strip components - we need root.x86_64 directory)
# Use sudo for extraction to handle CA certificate permissions
echo -e "${BLUE}📦 Extracting to temporary location...${NC}"
TEMP_EXTRACT_DIR="${BUILD_DIR}/.bootstrap-extract"
sudo rm -rf "${TEMP_EXTRACT_DIR}"
sudo mkdir -p "${TEMP_EXTRACT_DIR}"

if tar --help 2>&1 | grep -q zstd; then
    sudo tar -x --zstd -f "${BOOTSTRAP_TAR}" -C "${TEMP_EXTRACT_DIR}"
else
    # Fallback: pipe through zstd
    if command -v zstd &> /dev/null; then
        zstd -dc "${BOOTSTRAP_TAR}" | sudo tar -x -C "${TEMP_EXTRACT_DIR}"
    elif command -v unzstd &> /dev/null; then
        unzstd -c "${BOOTSTRAP_TAR}" | sudo tar -x -C "${TEMP_EXTRACT_DIR}"
    else
        echo -e "${RED}❌ Cannot extract: need zstd or unzstd${NC}"
        exit 1
    fi
fi

# Verify extraction
if [ ! -d "${TEMP_EXTRACT_DIR}/root.x86_64" ]; then
    echo -e "${RED}❌ Error: Bootstrap extraction failed - root.x86_64 not found${NC}"
    echo -e "${YELLOW}Contents of extract dir:$(NC)"
    sudo ls -la "${TEMP_EXTRACT_DIR}" || true
    exit 1
fi

# Move root.x86_64 to arch-rootfs
echo -e "${BLUE}📦 Moving extracted rootfs to arch-rootfs...${NC}"
sudo mv "${TEMP_EXTRACT_DIR}/root.x86_64" "${ROOTFS_DIR}"
sudo rm -rf "${TEMP_EXTRACT_DIR}"
# Fix ownership
sudo chown -R root:root "${ROOTFS_DIR}" 2>/dev/null || true

# Verify rootfs exists
if [ ! -d "${ROOTFS_DIR}" ]; then
    echo -e "${RED}❌ Error: Rootfs directory does not exist: ${ROOTFS_DIR}${NC}"
    exit 1
fi

# Create necessary mount points for arch-chroot (always needed)
echo -e "${BLUE}📁 Creating mount points...${NC}"
sudo mkdir -p "${ROOTFS_DIR}/proc"
sudo mkdir -p "${ROOTFS_DIR}/sys"
sudo mkdir -p "${ROOTFS_DIR}/dev"
sudo mkdir -p "${ROOTFS_DIR}/run"
sudo mkdir -p "${ROOTFS_DIR}/tmp"
sudo mkdir -p "${ROOTFS_DIR}/dev/pts"
sudo mkdir -p "${ROOTFS_DIR}/dev/shm"

# Workaround for "could not determine root mount point" error
# Pacman checks /proc/mounts to see if / is a mount point
# We need to ensure /proc is mounted and has proper entries
# arch-chroot should mount /proc, but we'll ensure it's there
sudo mkdir -p "${ROOTFS_DIR}/proc"

# Determine chroot command
if command -v arch-chroot &> /dev/null; then
    CHROOT_CMD="arch-chroot"
    USE_SUDO=""
elif command -v systemd-nspawn &> /dev/null; then
    CHROOT_CMD="systemd-nspawn"
    USE_SUDO="sudo"
    echo -e "${YELLOW}⚠️  Using systemd-nspawn (arch-chroot not found)${NC}"
    echo -e "${YELLOW}💡 Tip: Install arch-install-scripts for better compatibility${NC}"
else
    echo -e "${RED}❌ Error: Need arch-chroot or systemd-nspawn!${NC}"
    echo -e "${YELLOW}Install: sudo dnf5 install arch-install-scripts${NC}"
    exit 1
fi

# Function to run commands in chroot
chroot_run() {
    if [ "$CHROOT_CMD" = "arch-chroot" ]; then
        # arch-chroot automatically mounts /proc, /sys, /dev, etc.
        # But pacman needs /proc/mounts to have root entry
        # We'll use --root flag with pacman to bypass mount point check
        sudo arch-chroot "${ROOTFS_DIR}" "$@"
    else
        # systemd-nspawn requires sudo and proper network setup
        # Use --private-network=false to allow network access
        sudo systemd-nspawn \
            -q \
            -D "${ROOTFS_DIR}" \
            --bind-ro=/etc/resolv.conf \
            --private-network=false \
            --capability=CAP_SYS_ADMIN \
            "$@"
    fi
}

# Configure pacman repositories first (bootstrap doesn't include mirrorlist)
echo -e "${BLUE}⚙️  Configuring pacman repositories...${NC}"
sudo mkdir -p "${ROOTFS_DIR}/etc/pacman.d"
sudo tee "${ROOTFS_DIR}/etc/pacman.d/mirrorlist" > /dev/null << 'EOF'
## Arch Linux repository mirrorlist
## Generated for JARVIS OS

## Worldwide
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://archlinux.mirror.liteserver.nl/$repo/os/$arch
EOF

# Also ensure pacman.conf exists and has the right repos
if [ ! -f "${ROOTFS_DIR}/etc/pacman.conf" ]; then
    echo -e "${YELLOW}⚠️  pacman.conf not found, creating default...${NC}"
    sudo tee "${ROOTFS_DIR}/etc/pacman.conf" > /dev/null << 'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
CheckSpace
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

# Note: The community repo was merged into extra; keep only core/extra
EOF
fi

# Initialize pacman keyring using pacstrap (it handles this automatically)
# First install archlinux-keyring which includes pacman-key
echo -e "${BLUE}🔑 Installing and initializing pacman keyring...${NC}"
sudo pacstrap -c "${ROOTFS_DIR}" archlinux-keyring || {
    echo -e "${YELLOW}⚠️  pacstrap failed, trying manual keyring setup...${NC}"
    # Fallback: try to initialize keyring manually if pacman-key exists
    if [ -f "${ROOTFS_DIR}/usr/bin/pacman-key" ]; then
        chroot_run pacman-key --init
        chroot_run pacman-key --populate archlinux
    else
        echo -e "${YELLOW}⚠️  Skipping keyring initialization - will be handled during package install${NC}"
    fi
}

# Update pacman database
echo -e "${BLUE}🔄 Updating package database...${NC}"
chroot_run pacman -Sy --noconfirm

# Ensure cache directory exists and is writable
echo -e "${BLUE}📁 Setting up pacman cache...${NC}"
sudo mkdir -p "${ROOTFS_DIR}/var/cache/pacman/pkg"
sudo chmod 755 "${ROOTFS_DIR}/var/cache/pacman/pkg"
# Ensure the directory is owned by root (pacman expects this)
sudo chown root:root "${ROOTFS_DIR}/var/cache/pacman/pkg"

# The mount point error: pacman uses statfs() which fails in chroot
# Workaround: Mount tmpfs on cache directory - pacman will detect it as a mount point
# This is the most reliable workaround for the chroot mount point detection issue
echo -e "${BLUE}🔧 Creating tmpfs mount for pacman cache...${NC}"
sudo mount -t tmpfs -o size=2G tmpfs "${ROOTFS_DIR}/var/cache/pacman/pkg" 2>/dev/null || {
    # If tmpfs mount fails, try bind mount from host /tmp
    HOST_CACHE_TMP=$(mktemp -d)
    sudo mount --bind "${HOST_CACHE_TMP}" "${ROOTFS_DIR}/var/cache/pacman/pkg" 2>/dev/null || {
        echo -e "${YELLOW}⚠️  Could not mount cache directory, pacman may have issues${NC}"
    }
}

# Also ensure tmp directory is writable (pacman uses it for downloads)
sudo chmod 1777 "${ROOTFS_DIR}/tmp"

# Configure pacman to use the cache directory explicitly
# This prevents "could not determine cachedir mount point" errors
if [ -f "${ROOTFS_DIR}/etc/pacman.conf" ]; then
    # Ensure CacheDir is set in pacman.conf
    if ! grep -q "^CacheDir" "${ROOTFS_DIR}/etc/pacman.conf"; then
        sudo sed -i '/^\[options\]/a CacheDir = /var/cache/pacman/pkg/' "${ROOTFS_DIR}/etc/pacman.conf"
    fi
    # Also set DBPath explicitly
    if ! grep -q "^DBPath" "${ROOTFS_DIR}/etc/pacman.conf"; then
        sudo sed -i '/^\[options\]/a DBPath = /var/lib/pacman/' "${ROOTFS_DIR}/etc/pacman.conf"
    fi
fi

# Skip system update - bootstrap packages are usually recent enough
# If there are dependency conflicts, pacman will handle them during installation
echo -e "${BLUE}ℹ️  Skipping system update (bootstrap is recent, will resolve deps during install)${NC}"

# Install base packages
echo -e "${BLUE}📦 Installing base packages...${NC}"

# First, update systemd packages together to avoid version conflicts
# Use pacstrap (designed for this) - it bypasses mount point detection issues
echo -e "${BLUE}🔄 Updating systemd packages to resolve dependencies...${NC}"
sudo pacstrap -c "${ROOTFS_DIR}" systemd systemd-libs systemd-sysvcompat

PACKAGES=(
    base           # Core system
    base-devel     # Build tools
    linux          # Kernel (we'll boot with custom kernel)
    linux-firmware # Firmware
    mkinitcpio     # Initramfs generator (explicitly choose mkinitcpio)
    bash           # Shell
    python         # Python 3
    python-pip     # pip
    git            # Version control
    sudo           # sudo
    vim            # Editor
    nano           # Simple editor
    openssh        # SSH
)

# Append extra packages from environment (space-separated)
if [ -n "${EXTRA_PACKAGES:-}" ]; then
    echo -e "${BLUE}➕ Adding extra packages from config: ${EXTRA_PACKAGES}${NC}"
    # shellcheck disable=SC2206
    EXTRA_ARRAY=(${EXTRA_PACKAGES})
    PACKAGES+=( "${EXTRA_ARRAY[@]}" )
fi

# Install packages - use pacstrap (designed for this, bypasses mount point issues)
# Don't install systemd again (already updated above)
echo -e "${BLUE}📦 Installing ${#PACKAGES[@]} packages with pacstrap...${NC}"
sudo pacstrap -c "${ROOTFS_DIR}" "${PACKAGES[@]}"

# Configure system
echo -e "${BLUE}⚙️  Configuring system...${NC}"

# Set hostname
echo "jarvisos" | sudo tee "${ROOTFS_DIR}/etc/hostname" > /dev/null

# Configure locale
sudo sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "${ROOTFS_DIR}/etc/locale.gen"
chroot_run locale-gen
echo "LANG=en_US.UTF-8" | sudo tee "${ROOTFS_DIR}/etc/locale.conf" > /dev/null

# Set root password (jarvis123)
echo -e "${BLUE}🔐 Setting root password...${NC}"
chroot_run bash -c "echo 'root:jarvis123' | chpasswd"

# Configure fstab (for QCOW2 - will be /dev/vda3)
sudo tee "${ROOTFS_DIR}/etc/fstab" > /dev/null << 'EOF'
# /etc/fstab: static file system information
# <file system> <dir> <type> <options> <dump> <pass>
/dev/vda3       /     ext4   defaults,noatime 0 1
EOF

# Create directories for JARVIS
sudo mkdir -p "${ROOTFS_DIR}/usr/lib/jarvis"
sudo mkdir -p "${ROOTFS_DIR}/etc/jarvis"
sudo mkdir -p "${ROOTFS_DIR}/var/lib/jarvis"
sudo mkdir -p "${ROOTFS_DIR}/var/log/jarvis"

# Unmount any filesystems that might be mounted (from arch-chroot)
# This is necessary before converting to QCOW2
echo -e "${BLUE}🧹 Unmounting filesystems...${NC}"
sudo umount "${ROOTFS_DIR}/proc" 2>/dev/null || true
sudo umount "${ROOTFS_DIR}/sys" 2>/dev/null || true
sudo umount "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
sudo umount "${ROOTFS_DIR}/dev/shm" 2>/dev/null || true
sudo umount "${ROOTFS_DIR}/dev" 2>/dev/null || true
sudo umount "${ROOTFS_DIR}/run" 2>/dev/null || true
sudo umount "${ROOTFS_DIR}/var/cache/pacman/pkg" 2>/dev/null || true  # Unmount tmpfs cache

echo -e "${GREEN}✅ Arch Linux rootfs created at: ${ROOTFS_DIR}${NC}"
echo -e "${BLUE}📊 Size: $(sudo du -sh ${ROOTFS_DIR} 2>/dev/null | cut -f1 || echo '~2.0G')${NC}"
echo -e "${YELLOW}⚠️  Next step: Convert to QCOW2 image${NC}"

