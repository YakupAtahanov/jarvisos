#!/bin/bash
# Inject JARVIS OS components into Arch Linux ISO
# Extracts ISO, modifies SquashFS, injects JARVIS + GUI + Calamares, rebuilds ISO

set -e

ISO_FILE="${1:-archlinux-2025.11.01-x86_64.iso}"
BUILD_DIR="${2:-build}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ ! -f "${ISO_FILE}" ]; then
    echo -e "${RED}❌ Error: ISO file not found: ${ISO_FILE}${NC}"
    exit 1
fi

# Check required tools
for tool in unsquashfs mksquashfs xorriso arch-chroot systemd-nspawn; do
    if ! command -v "${tool}" &> /dev/null && [ "${tool}" != "arch-chroot" ]; then
        echo -e "${YELLOW}⚠️  Warning: ${tool} not found, may cause issues${NC}"
    fi
done

# Create temporary directories
ISO_EXTRACT_DIR="${BUILD_DIR}/iso-extract"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo -e "${BLUE}🚀 Starting JARVIS OS ISO injection...${NC}"
echo -e "${BLUE}📁 ISO: ${ISO_FILE}${NC}"
echo -e "${BLUE}📁 Build dir: ${BUILD_DIR}${NC}"

# Cleanup function
cleanup() {
    echo -e "${YELLOW}🧹 Cleaning up temporary files...${NC}"
    # Unmount in reverse order
    sudo umount -l "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg" 2>/dev/null || true
    sudo umount -l "${SQUASHFS_ROOTFS}/var/lib/pacman/sync" 2>/dev/null || true
    sudo umount -l "${SQUASHFS_ROOTFS}" 2>/dev/null || true  # Unmount bind mount
    sudo umount -l "${SQUASHFS_ROOTFS}/run" 2>/dev/null || true
    sudo umount -l "${SQUASHFS_ROOTFS}/dev/shm" 2>/dev/null || true
    sudo umount -l "${SQUASHFS_ROOTFS}/dev/pts" 2>/dev/null || true
    sudo umount -l "${SQUASHFS_ROOTFS}/dev" 2>/dev/null || true
    sudo umount -l "${SQUASHFS_ROOTFS}/sys" 2>/dev/null || true
    sudo umount -l "${SQUASHFS_ROOTFS}/proc" 2>/dev/null || true
    # Remove rootfs directory with sudo (files are owned by root)
    # Only remove if we're actually cleaning up (not on error during extraction)
    if [ "${1:-}" != "keep-rootfs" ]; then
        sudo rm -rf "${SQUASHFS_ROOTFS}" 2>/dev/null || true
    fi
    # Remove ISO extract directory (may also have root-owned files)
    if [ "${1:-}" != "keep-all" ]; then
        sudo rm -rf "${ISO_EXTRACT_DIR}" 2>/dev/null || true
    fi
}

# Don't trap cleanup on EXIT - we'll call it manually at the end
# trap cleanup EXIT

# Step 1: Extract ISO
echo -e "${BLUE}📦 Step 1: Extracting ISO...${NC}"
# Clean up any existing extraction (may need sudo for root-owned files)
sudo rm -rf "${ISO_EXTRACT_DIR}" 2>/dev/null || true
mkdir -p "${ISO_EXTRACT_DIR}"

# Extract ISO (using 7z or bsdtar)
if command -v 7z &> /dev/null; then
    7z x -o"${ISO_EXTRACT_DIR}" "${ISO_FILE}" > /dev/null
elif command -v bsdtar &> /dev/null; then
    bsdtar -xf "${ISO_FILE}" -C "${ISO_EXTRACT_DIR}"
else
    # Mount ISO and copy
    ISO_MOUNT=$(mktemp -d)
    sudo mount -o loop "${ISO_FILE}" "${ISO_MOUNT}"
    sudo cp -a "${ISO_MOUNT}"/* "${ISO_EXTRACT_DIR}/"
    sudo umount "${ISO_MOUNT}"
    rmdir "${ISO_MOUNT}"
fi

# Find SquashFS file (handle both uppercase and lowercase paths)
SQUASHFS_FILE=$(find "${ISO_EXTRACT_DIR}" -type f -iname "airootfs.sfs" | head -1)

if [ -z "${SQUASHFS_FILE}" ] || [ ! -f "${SQUASHFS_FILE}" ]; then
    echo -e "${RED}❌ Error: Could not find airootfs.sfs in extracted ISO${NC}"
    echo -e "${YELLOW}ISO structure:${NC}"
    find "${ISO_EXTRACT_DIR}" -type f -iname "*.sfs" | head -5
    exit 1
fi

echo -e "${GREEN}✅ ISO extracted${NC}"
echo -e "${BLUE}📁 Found SquashFS: ${SQUASHFS_FILE}${NC}"

# Step 2: Extract SquashFS
echo -e "${BLUE}📦 Step 2: Extracting SquashFS filesystem...${NC}"
# Clean up any existing rootfs (may need sudo for root-owned files)
echo -e "${BLUE}Cleaning up any existing rootfs...${NC}"
sudo rm -rf "${SQUASHFS_ROOTFS}" 2>/dev/null || true
# Create directory with proper permissions
sudo mkdir -p "${SQUASHFS_ROOTFS}"
sudo chmod 755 "${SQUASHFS_ROOTFS}"

# Extract SquashFS (skip xattrs to avoid permission issues, we'll rebuild anyway)
# Try regular extraction first, then sudo if needed
echo -e "${BLUE}Extracting SquashFS (this may take a minute)...${NC}"
# Clean up any partial extraction first
sudo rm -rf "${SQUASHFS_ROOTFS}"/* 2>/dev/null || true

# Extract SquashFS - must extract completely for chroot to work
EXTRACT_LOG="${BUILD_DIR}/squashfs-extract.log"
echo -e "${BLUE}Extracting to: ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}This may take a few minutes...${NC}"

# Ensure extraction directory is clean and has correct permissions
sudo rm -rf "${SQUASHFS_ROOTFS}"/* 2>/dev/null || true
sudo chown root:root "${SQUASHFS_ROOTFS}" 2>/dev/null || true
sudo chmod 755 "${SQUASHFS_ROOTFS}"

# Extract with sudo (needed for proper permissions)
# Use -f to force overwrite and -n to not create device files (we don't need them)
echo -e "${BLUE}Running unsquashfs...${NC}"
if sudo unsquashfs -f -n -no-xattrs -d "${SQUASHFS_ROOTFS}" "${SQUASHFS_FILE}" 2>&1 | tee "${EXTRACT_LOG}"; then
    EXTRACT_EXIT=0
else
    EXTRACT_EXIT=$?
    echo -e "${YELLOW}⚠️  unsquashfs exited with code ${EXTRACT_EXIT}${NC}"
fi

# Show extraction summary
if [ -f "${EXTRACT_LOG}" ]; then
    echo -e "${BLUE}Extraction summary:${NC}"
    tail -10 "${EXTRACT_LOG}" | grep -E "created|inodes|blocks|files|directories|extracted" || tail -5 "${EXTRACT_LOG}"
fi

# Wait a moment for filesystem to sync
sleep 1

# Verify extraction succeeded by checking for key directories/files
# CRITICAL: /usr/bin must exist for chroot to work
EXTRACT_VERIFIED=false
if [ -d "${SQUASHFS_ROOTFS}/etc" ] && [ -d "${SQUASHFS_ROOTFS}/boot" ]; then
    # Check if /usr/bin exists directly (most reliable check)
    if [ -d "${SQUASHFS_ROOTFS}/usr/bin" ] || [ -e "${SQUASHFS_ROOTFS}/usr/bin" ]; then
        # Verify it's not empty
        if [ "$(ls -A "${SQUASHFS_ROOTFS}/usr/bin" 2>/dev/null | wc -l)" -gt 0 ]; then
            EXTRACT_VERIFIED=true
        else
            echo -e "${YELLOW}⚠️  /usr/bin exists but is empty${NC}"
        fi
    elif [ -L "${SQUASHFS_ROOTFS}/bin" ]; then
        # If bin is a symlink, check if it resolves to usr/bin and that target exists
        BIN_TARGET=$(readlink -f "${SQUASHFS_ROOTFS}/bin" 2>/dev/null || readlink "${SQUASHFS_ROOTFS}/bin")
        if [ -e "${BIN_TARGET}" ] || [ -d "${BIN_TARGET}" ]; then
            # Verify the target directory has files
            if [ -d "${BIN_TARGET}" ] && [ "$(ls -A "${BIN_TARGET}" 2>/dev/null | wc -l)" -gt 0 ]; then
                EXTRACT_VERIFIED=true
            else
                echo -e "${YELLOW}⚠️  /bin symlink resolves but target is empty${NC}"
            fi
        fi
    fi
fi

if [ "$EXTRACT_VERIFIED" = "false" ]; then
    echo -e "${RED}❌ Error: SquashFS extraction failed - /usr/bin missing${NC}"
    echo -e "${YELLOW}Checking what was extracted...${NC}"
    ls -la "${SQUASHFS_ROOTFS}" 2>&1 | head -15 || true
    echo -e "${YELLOW}Checking for usr directory...${NC}"
    ls -ld "${SQUASHFS_ROOTFS}/usr" 2>&1 || echo "usr directory not found"
    if [ -d "${SQUASHFS_ROOTFS}/usr" ]; then
        echo -e "${YELLOW}Contents of /usr:${NC}"
        ls -la "${SQUASHFS_ROOTFS}/usr" 2>&1 || true
        echo -e "${YELLOW}Checking if /usr/bin exists...${NC}"
        ls -ld "${SQUASHFS_ROOTFS}/usr/bin" 2>&1 || echo "/usr/bin not found"
    fi
    echo -e "${YELLOW}Checking if bin symlink resolves...${NC}"
    if [ -L "${SQUASHFS_ROOTFS}/bin" ]; then
        readlink -f "${SQUASHFS_ROOTFS}/bin" 2>&1 || readlink "${SQUASHFS_ROOTFS}/bin"
    else
        echo "bin is not a symlink"
    fi
    echo -e "${YELLOW}Checking extraction log for errors...${NC}"
    if [ -f "${EXTRACT_LOG}" ]; then
        echo -e "${YELLOW}Last 50 lines of extraction log:${NC}"
        tail -50 "${EXTRACT_LOG}" | grep -E "error|Error|ERROR|failed|Failed|FAILED|Permission|permission|denied|No space" || tail -30 "${EXTRACT_LOG}"
    else
        echo -e "${RED}❌ Extraction log not found!${NC}"
    fi
    echo -e "${RED}❌ Extraction incomplete - cannot proceed without /usr/bin${NC}"
    echo -e "${YELLOW}💡 This might be due to:${NC}"
    echo -e "${YELLOW}   1. Inode exhaustion (check with: df -i)${NC}"
    echo -e "${YELLOW}   2. Disk space issues (check with: df -h)${NC}"
    echo -e "${YELLOW}   3. Permission issues${NC}"
    echo -e "${YELLOW}   4. Corrupted SquashFS file${NC}"
    exit 1
fi

echo -e "${GREEN}✅ SquashFS extracted successfully${NC}"

# Step 3: Set up chroot environment
echo -e "${BLUE}🔧 Step 3: Setting up chroot environment...${NC}"

# Create mount points
sudo mkdir -p "${SQUASHFS_ROOTFS}/proc"
sudo mkdir -p "${SQUASHFS_ROOTFS}/sys"
sudo mkdir -p "${SQUASHFS_ROOTFS}/dev"
sudo mkdir -p "${SQUASHFS_ROOTFS}/run"
sudo mkdir -p "${SQUASHFS_ROOTFS}/tmp"
sudo mkdir -p "${SQUASHFS_ROOTFS}/dev/pts"
sudo mkdir -p "${SQUASHFS_ROOTFS}/dev/shm"
sudo mkdir -p "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg"

# Determine chroot command
if command -v arch-chroot &> /dev/null; then
    CHROOT_CMD="arch-chroot"
    USE_SUDO="sudo"
elif command -v systemd-nspawn &> /dev/null; then
    CHROOT_CMD="systemd-nspawn"
    USE_SUDO="sudo"
else
    echo -e "${RED}❌ Error: Need arch-chroot or systemd-nspawn${NC}"
    exit 1
fi

chroot_run() {
    if [ "${CHROOT_CMD}" = "arch-chroot" ]; then
        # arch-chroot automatically mounts /proc, /sys, /dev, etc.
        # But we need to ensure the rootfs is complete first
        # Check if usr/bin exists (directly or via symlink)
        if [ ! -d "${SQUASHFS_ROOTFS}/usr/bin" ] && [ ! -e "${SQUASHFS_ROOTFS}/usr/bin" ]; then
            # Check if bin symlink resolves to usr/bin
            if [ -L "${SQUASHFS_ROOTFS}/bin" ]; then
                BIN_TARGET=$(readlink -f "${SQUASHFS_ROOTFS}/bin" 2>/dev/null || readlink "${SQUASHFS_ROOTFS}/bin")
                if [ ! -e "${BIN_TARGET}" ]; then
                    echo -e "${RED}❌ Error: Rootfs appears incomplete - /usr/bin not found${NC}"
                    ls -la "${SQUASHFS_ROOTFS}/usr" 2>&1 | head -5 || true
                    return 1
                fi
            else
                echo -e "${RED}❌ Error: Rootfs appears incomplete - /usr/bin not found${NC}"
                ls -la "${SQUASHFS_ROOTFS}/usr" 2>&1 | head -5 || true
                return 1
            fi
        fi
        # arch-chroot may fail with "No space left on device" when mounting /dev
        # This is usually an inode exhaustion issue, not actual disk space
        # Pre-create essential directories and ensure they're not mount points
        sudo mkdir -p "${SQUASHFS_ROOTFS}/run/systemd/resolve" 2>/dev/null || true
        sudo mkdir -p "${SQUASHFS_ROOTFS}/dev" 2>/dev/null || true
        sudo mkdir -p "${SQUASHFS_ROOTFS}/proc" 2>/dev/null || true
        sudo mkdir -p "${SQUASHFS_ROOTFS}/sys" 2>/dev/null || true
        # Unmount any existing mounts that might be causing conflicts
        sudo umount -l "${SQUASHFS_ROOTFS}/dev" 2>/dev/null || true
        sudo umount -l "${SQUASHFS_ROOTFS}/proc" 2>/dev/null || true
        sudo umount -l "${SQUASHFS_ROOTFS}/sys" 2>/dev/null || true
        # Try arch-chroot - it handles mounts automatically
        # If it fails with "No space left on device", fall back to manual chroot
        if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" "$@" 2>&1; then
            CHROOT_EXIT=$?
            if grep -q "No space left on device" <<< "$(sudo arch-chroot "${SQUASHFS_ROOTFS}" "$@" 2>&1 || true)"; then
                echo -e "${YELLOW}⚠️  arch-chroot failed with 'No space left on device', using manual chroot...${NC}"
                # Mount filesystems manually
                sudo mount -t proc proc "${SQUASHFS_ROOTFS}/proc" 2>/dev/null || true
                sudo mount -t sysfs sysfs "${SQUASHFS_ROOTFS}/sys" 2>/dev/null || true
                sudo mount --bind /dev "${SQUASHFS_ROOTFS}/dev" 2>/dev/null || true
                sudo mount -t devpts devpts "${SQUASHFS_ROOTFS}/dev/pts" 2>/dev/null || true
                sudo mount -t tmpfs tmpfs "${SQUASHFS_ROOTFS}/dev/shm" 2>/dev/null || true
                sudo mount -t tmpfs tmpfs "${SQUASHFS_ROOTFS}/run" 2>/dev/null || true
                sudo cp /etc/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
                # Run command in manual chroot
                sudo chroot "${SQUASHFS_ROOTFS}" "$@"
                CHROOT_EXIT=$?
                # Unmount after command
                sudo umount -l "${SQUASHFS_ROOTFS}/run" 2>/dev/null || true
                sudo umount -l "${SQUASHFS_ROOTFS}/dev/shm" 2>/dev/null || true
                sudo umount -l "${SQUASHFS_ROOTFS}/dev/pts" 2>/dev/null || true
                sudo umount -l "${SQUASHFS_ROOTFS}/dev" 2>/dev/null || true
                sudo umount -l "${SQUASHFS_ROOTFS}/sys" 2>/dev/null || true
                sudo umount -l "${SQUASHFS_ROOTFS}/proc" 2>/dev/null || true
                return $CHROOT_EXIT
            else
                return $CHROOT_EXIT
            fi
        fi
    else
        sudo systemd-nspawn -q -D "${SQUASHFS_ROOTFS}" \
            --bind-ro=/etc/resolv.conf \
            --private-network=false \
            --capability=CAP_SYS_ADMIN \
            --security-label=disable \
            "$@"
    fi
}

# Create pacman directories if they don't exist
echo -e "${BLUE}📁 Setting up pacman directories...${NC}"
# Remove sync directory if it exists (will be replaced by tmpfs)
sudo rm -rf "${SQUASHFS_ROOTFS}/var/lib/pacman/sync" 2>/dev/null || true
# CRITICAL: Remove package cache directory completely - we'll mount tmpfs on it
# This ensures there's no filesystem conflict
sudo rm -rf "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg" 2>/dev/null || true
sudo mkdir -p "${SQUASHFS_ROOTFS}/var/lib/pacman"
sudo mkdir -p "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg"
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/pacman.d"

# Ensure pacman directories are writable and owned by root
# This is critical for pacman to work inside chroot
sudo chown -R root:root "${SQUASHFS_ROOTFS}/var/lib/pacman" 2>/dev/null || true
sudo chown -R root:root "${SQUASHFS_ROOTFS}/var/cache/pacman" 2>/dev/null || true
sudo chmod 755 "${SQUASHFS_ROOTFS}/var/lib/pacman"
sudo chmod 755 "${SQUASHFS_ROOTFS}/var/cache/pacman"
sudo chmod 755 "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg"
# Also ensure parent directories are correct
sudo chown root:root "${SQUASHFS_ROOTFS}/var/lib" 2>/dev/null || true
sudo chown root:root "${SQUASHFS_ROOTFS}/var/cache" 2>/dev/null || true
sudo chmod 755 "${SQUASHFS_ROOTFS}/var/lib"
sudo chmod 755 "${SQUASHFS_ROOTFS}/var/cache"

# Don't mount tmpfs here - it will be mounted inside chroot where pacman runs
# Mounting from outside may not be visible inside chroot
# sudo mount -t tmpfs -o size=2G tmpfs "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg" 2>/dev/null || true

# Prepare pacman sync directory - we'll mount tmpfs inside chroot
# Remove existing directory and create fresh mount point
sudo rm -rf "${SQUASHFS_ROOTFS}/var/lib/pacman/sync" 2>/dev/null || true
sudo mkdir -p "${SQUASHFS_ROOTFS}/var/lib/pacman/sync"
sudo chown root:root "${SQUASHFS_ROOTFS}/var/lib/pacman/sync"
sudo chmod 755 "${SQUASHFS_ROOTFS}/var/lib/pacman/sync"
echo -e "${BLUE}📦 Will mount tmpfs inside chroot for pacman sync directory...${NC}"

# Workaround for pacman mount point detection: create a fake mount entry
# This helps pacman detect / as a mount point
sudo mount --bind "${SQUASHFS_ROOTFS}" "${SQUASHFS_ROOTFS}" 2>/dev/null || true

# Initialize pacman keyring (needed before any package operations)
echo -e "${BLUE}🔑 Initializing pacman keyring...${NC}"
chroot_run pacman-key --init 2>&1 | grep -v "WARNING.*mountpoint" || true
chroot_run pacman-key --populate archlinux 2>&1 | grep -v "WARNING.*mountpoint" || true

# Ensure pacman.conf has all repositories enabled (core, extra, community)
# CRITICAL: Disable DownloadUser to avoid permission issues in chroot
echo -e "${BLUE}📋 Checking pacman configuration...${NC}"
if [ -f "${SQUASHFS_ROOTFS}/etc/pacman.conf" ]; then
    # Disable DownloadUser (pacman 7.0+ feature that causes permission issues in chroot)
    if grep -q "^DownloadUser" "${SQUASHFS_ROOTFS}/etc/pacman.conf"; then
        echo -e "${BLUE}🔧 Disabling DownloadUser in pacman.conf (causes permission issues in chroot)...${NC}"
        sudo sed -i 's/^DownloadUser/#DownloadUser/' "${SQUASHFS_ROOTFS}/etc/pacman.conf"
    fi
    # Check if extra repository is enabled
    if ! grep -q "^\[extra\]" "${SQUASHFS_ROOTFS}/etc/pacman.conf"; then
        echo -e "${YELLOW}⚠️  Extra repository not found, adding it...${NC}"
        sudo tee -a "${SQUASHFS_ROOTFS}/etc/pacman.conf" > /dev/null << 'EOF'

[extra]
Include = /etc/pacman.d/mirrorlist

[community]
Include = /etc/pacman.d/mirrorlist
EOF
    fi
    # Ensure mirrorlist exists
    if [ ! -f "${SQUASHFS_ROOTFS}/etc/pacman.d/mirrorlist" ]; then
        echo -e "${YELLOW}⚠️  Mirrorlist not found, creating default...${NC}"
        sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/pacman.d"
        sudo tee "${SQUASHFS_ROOTFS}/etc/pacman.d/mirrorlist" > /dev/null << 'EOF'
## Arch Linux repository mirrorlist
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.archlinux.no/$repo/os/$arch
EOF
    fi
fi

echo -e "${GREEN}✅ Chroot environment ready${NC}"

# Step 4: Generate configuration (if needed)
if [ ! -f "${PROJECT_ROOT}/build/config.mk" ]; then
    echo -e "${BLUE}⚙️  Generating configuration...${NC}"
    cd "${PROJECT_ROOT}"
    PROFILE="${PROFILE:-gui-iso}" make configure > /dev/null 2>&1 || true
fi

# Step 5: Install GUI packages
echo -e "${BLUE}🖥️  Step 5: Installing GUI packages (KDE Plasma Wayland)...${NC}"
"${SCRIPT_DIR}/install-gui-packages.sh" "${SQUASHFS_ROOTFS}" "${CHROOT_CMD}"

# Step 6: Install Calamares
echo -e "${BLUE}📦 Step 6: Installing Calamares installer...${NC}"
"${SCRIPT_DIR}/install-calamares.sh" "${SQUASHFS_ROOTFS}" "${CHROOT_CMD}" "${PROJECT_ROOT}"

# Step 7: Create default user and configure auto-login
echo -e "${BLUE}👤 Step 7: Creating default user and configuring auto-login...${NC}"

# Create default user "arch" (standard Arch Linux live ISO user)
# Check if user already exists first
chroot_run bash -c "id arch >/dev/null 2>&1 || useradd -m -u 1000 -G wheel,audio,video,optical,storage,power,network,input -s /bin/bash arch" || true

# Set empty password for live ISO (allows login without password)
chroot_run bash -c "passwd -d arch 2>&1 || echo 'arch::1000:1000:Arch Linux Live User:/home/arch:/bin/bash' > /tmp/passwd_entry && chpasswd -e < /tmp/passwd_entry 2>&1 || true" || true

# Ensure user has proper home directory
chroot_run bash -c "mkdir -p /home/arch && chown -R arch:arch /home/arch 2>&1 || true" || true

# Configure SDDM auto-login (override the one from install-gui-packages.sh)
echo -e "${BLUE}Configuring SDDM auto-login for arch user with Wayland...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/sddm.conf.d"

# Detect available Wayland sessions
echo -e "${BLUE}Detecting available Wayland desktop sessions...${NC}"
WAYLAND_SESSIONS=$(chroot_run bash -c "
    if [ -d /usr/share/wayland-sessions ]; then
        ls -1 /usr/share/wayland-sessions/*.desktop 2>/dev/null | xargs -n1 basename -s .desktop || echo 'none'
    else
        echo 'none'
    fi
" 2>&1 | grep -v "WARNING.*mountpoint" | grep -v "^$" || echo "plasma")

echo -e "${BLUE}Found Wayland sessions: ${WAYLAND_SESSIONS}${NC}"

# Try to find the correct Wayland session name
SESSION_NAME="plasma-wayland"
if echo "${WAYLAND_SESSIONS}" | grep -qi "plasma-wayland"; then
    SESSION_NAME="plasma-wayland"
elif echo "${WAYLAND_SESSIONS}" | grep -qi "plasma.desktop"; then
    SESSION_NAME="plasma.desktop"
elif echo "${WAYLAND_SESSIONS}" | grep -qi "plasma"; then
    # Check what the actual .desktop file is named
    DESKTOP_FILE=$(chroot_run bash -c "ls -1 /usr/share/wayland-sessions/plasma*.desktop 2>/dev/null | head -1" 2>&1 | grep -v "WARNING.*mountpoint" | xargs basename -s .desktop 2>/dev/null || echo "plasma-wayland")
    SESSION_NAME="${DESKTOP_FILE:-plasma-wayland}"
else
    # Fallback: try common names
    SESSION_NAME="plasma-wayland"
fi

echo -e "${GREEN}✅ Using Wayland session: ${SESSION_NAME}${NC}"

# Configure SDDM with Wayland as default
sudo tee "${SQUASHFS_ROOTFS}/etc/sddm.conf.d/autologin.conf" > /dev/null << EOF
[Autologin]
User=arch
Session=${SESSION_NAME}
Relogin=yes

[General]
# Use Wayland as default display server
DisplayServer=wayland
EOF

# Create SDDM wayland configuration
sudo tee "${SQUASHFS_ROOTFS}/etc/sddm.conf.d/wayland.conf" > /dev/null << 'EOF'
[General]
DisplayServer=wayland

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions

[X11]
DisplayCommand=/usr/share/sddm/scripts/Xsetup
SessionCommand=/usr/share/sddm/scripts/Xsession
SessionDir=/usr/share/xsessions
EOF

# Ensure Wayland session files exist and are correct
echo -e "${BLUE}Verifying Wayland session files...${NC}"
chroot_run bash -c "
    if [ ! -d /usr/share/wayland-sessions ]; then
        echo 'Creating wayland-sessions directory...'
        mkdir -p /usr/share/wayland-sessions
    fi
    echo 'Wayland session files:'
    ls -la /usr/share/wayland-sessions/ 2>/dev/null || echo 'No wayland-sessions directory'
    
    # Ensure plasma-wayland.desktop exists (plasma-meta should create it, but verify)
    if [ ! -f /usr/share/wayland-sessions/plasma-wayland.desktop ] && [ -f /usr/share/wayland-sessions/plasma.desktop ]; then
        echo 'plasma-wayland.desktop not found, but plasma.desktop exists'
        # Check if plasma.desktop is a Wayland session
        if grep -q 'Exec=.*startplasma-wayland' /usr/share/wayland-sessions/plasma.desktop 2>/dev/null; then
            echo 'plasma.desktop is a Wayland session'
        fi
    fi
" 2>&1 | grep -v "WARNING.*mountpoint" || true

# Create a wrapper script to ensure Wayland session starts correctly
echo -e "${BLUE}Creating Wayland session startup script...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/usr/local/bin"
sudo tee "${SQUASHFS_ROOTFS}/usr/local/bin/start-plasma-wayland.sh" > /dev/null << 'EOF'
#!/bin/bash
# Ensure input devices are accessible before starting Plasma
chmod 666 /dev/input/* 2>/dev/null || true
# Start Plasma Wayland session
exec /usr/bin/startplasma-wayland
EOF
sudo chmod +x "${SQUASHFS_ROOTFS}/usr/local/bin/start-plasma-wayland.sh"

# Also configure for X11 session as fallback
sudo tee "${SQUASHFS_ROOTFS}/etc/sddm.conf.d/default.conf" > /dev/null << 'EOF'
[General]
DisplayServer=wayland

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session

[X11]
DisplayCommand=/usr/share/sddm/scripts/Xsetup
SessionCommand=/usr/share/sddm/scripts/Xsession
SessionDir=/usr/share/xsessions
EOF

# Ensure SDDM is enabled
chroot_run bash -c "systemctl enable sddm.service 2>&1 || true" || true

# Configure input devices (fix mouse/keyboard issues)
echo -e "${BLUE}Configuring input devices...${NC}"

# Ensure input device nodes exist and are accessible
chroot_run bash -c "
    # Create input device nodes if they don't exist
    mkdir -p /dev/input
    chmod 755 /dev/input
    # Ensure udev will create input devices
    systemctl enable systemd-udevd.service 2>&1 || true
" 2>&1 | grep -v "WARNING.*mountpoint" || true

# Configure X11 input devices
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/X11/xorg.conf.d"
sudo tee "${SQUASHFS_ROOTFS}/etc/X11/xorg.conf.d/00-input.conf" > /dev/null << 'EOF'
Section "InputClass"
    Identifier "libinput pointer catchall"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
    Option "AccelProfile" "flat"
    Option "AccelSpeed" "0"
EndSection

Section "InputClass"
    Identifier "libinput keyboard catchall"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput touchpad catchall"
    MatchIsTouchpad "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput tablet catchall"
    MatchIsTablet "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection
EOF

# Configure Wayland input and environment (for Plasma Wayland session)
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/environment.d"
sudo tee "${SQUASHFS_ROOTFS}/etc/environment.d/99-wayland.conf" > /dev/null << 'EOF'
# Force Wayland for all applications
QT_QPA_PLATFORM=wayland
GDK_BACKEND=wayland
SDL_VIDEODRIVER=wayland
MOZ_ENABLE_WAYLAND=1
WLR_NO_HARDWARE_CURSORS=1
EOF

# Also set for user specifically
sudo mkdir -p "${SQUASHFS_ROOTFS}/home/arch/.config"
sudo tee "${SQUASHFS_ROOTFS}/home/arch/.config/environment" > /dev/null << 'EOF'
QT_QPA_PLATFORM=wayland
GDK_BACKEND=wayland
EOF
chroot_run bash -c "chown -R arch:arch /home/arch/.config 2>&1 || true" || true

# Create udev rules to ensure input devices are accessible
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/udev/rules.d"
sudo tee "${SQUASHFS_ROOTFS}/etc/udev/rules.d/99-input-permissions.rules" > /dev/null << 'EOF'
# Make input devices accessible to users in input group
KERNEL=="event*", GROUP="input", MODE="0664"
KERNEL=="mouse*", GROUP="input", MODE="0664"
KERNEL=="mice", GROUP="input", MODE="0664"
KERNEL=="ts[0-9]*", GROUP="input", MODE="0664"
SUBSYSTEM=="input", GROUP="input", MODE="0664"
EOF

# Ensure input group has proper permissions
chroot_run bash -c "groupadd -f input 2>&1 || true" || true
chroot_run bash -c "usermod -aG input,audio,video,optical,storage,power,network arch 2>&1 || true" || true

# Create a startup script to ensure input devices work
echo -e "${BLUE}Creating input device initialization script...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/usr/local/bin"
sudo tee "${SQUASHFS_ROOTFS}/usr/local/bin/fix-input.sh" > /dev/null << 'EOF'
#!/bin/bash
# Fix input device permissions and ensure they're accessible
chmod 666 /dev/input/* 2>/dev/null || true
# Reload udev rules
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=input 2>/dev/null || true
EOF
sudo chmod +x "${SQUASHFS_ROOTFS}/usr/local/bin/fix-input.sh"

# Add to systemd service or autostart
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/systemd/system"
sudo tee "${SQUASHFS_ROOTFS}/etc/systemd/system/fix-input.service" > /dev/null << 'EOF'
[Unit]
Description=Fix Input Device Permissions
After=systemd-udevd.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-input.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chroot_run bash -c "systemctl enable fix-input.service 2>&1 || true" || true

# Step 8: Install JARVIS
echo -e "${BLUE}🤖 Step 8: Installing JARVIS...${NC}"
"${SCRIPT_DIR}/setup-jarvis-iso.sh" "${SQUASHFS_ROOTFS}" "${CHROOT_CMD}" "${PROJECT_ROOT}"

# Step 9: Rebuild SquashFS
echo -e "${BLUE}📦 Step 9: Rebuilding SquashFS filesystem...${NC}"

# Unmount filesystems before rebuilding
sudo umount -l "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/var/lib/pacman/sync" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}" 2>/dev/null || true  # Unmount bind mount
sudo umount -l "${SQUASHFS_ROOTFS}/proc" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/sys" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/dev/pts" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/dev/shm" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/dev" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/run" 2>/dev/null || true

# Detect original compression (try to match it)
# Arch typically uses xz or zstd compression
# Use the same directory as the original SquashFS file
SQUASHFS_DIR=$(dirname "${SQUASHFS_FILE}")
NEW_SQUASHFS="${SQUASHFS_DIR}/airootfs.sfs.new"

# Use xz compression (most common for Arch ISOs)
# -comp xz -b 1M gives good compression ratio
echo -e "${BLUE}Compressing SquashFS (this may take a while)...${NC}"
sudo mksquashfs "${SQUASHFS_ROOTFS}" "${NEW_SQUASHFS}" \
    -comp xz -b 1M -noappend -no-recovery \
    -e boot/grub/grubenv 2>&1 | grep -v "^Parallel" || true

# Verify the new SquashFS was created
if [ ! -f "${NEW_SQUASHFS}" ]; then
    echo -e "${RED}❌ Error: Failed to create new SquashFS${NC}"
    exit 1
fi

# Replace original SquashFS
sudo mv "${NEW_SQUASHFS}" "${SQUASHFS_FILE}"
sudo chmod 644 "${SQUASHFS_FILE}"

echo -e "${GREEN}✅ SquashFS rebuilt${NC}"

# Step 10: Regenerate checksum
echo -e "${BLUE}🔐 Step 10: Regenerating checksum...${NC}"
# Find checksum file (handle both cases)
SQUASHFS_DIR=$(dirname "${SQUASHFS_FILE}")
SHA512_FILE=$(find "${SQUASHFS_DIR}" -type f -iname "airootfs.sha512" | head -1)
if [ -z "${SHA512_FILE}" ]; then
    # Create checksum file if it doesn't exist
    SHA512_FILE="${SQUASHFS_DIR}/airootfs.sha512"
fi
sha512sum "${SQUASHFS_FILE}" | cut -d' ' -f1 | sudo tee "${SHA512_FILE}" > /dev/null
echo -e "${GREEN}✅ Checksum regenerated${NC}"

# Step 11: Rebuild ISO
echo -e "${BLUE}💿 Step 11: Rebuilding ISO...${NC}"
OUTPUT_ISO="${BUILD_DIR}/jarvisos-$(date +%Y%m%d)-x86_64.iso"

# Ensure output directory exists and use absolute path
mkdir -p "${BUILD_DIR}"
OUTPUT_ISO_ABS=$(cd "${BUILD_DIR}" && pwd)/jarvisos-$(date +%Y%m%d)-x86_64.iso

# Use xorriso to rebuild ISO (preserves boot structure)
# Arch Linux ISOs support both BIOS and UEFI boot
cd "${ISO_EXTRACT_DIR}" || exit 1

# Find boot files (Arch ISO uses boot/syslinux/ structure)
ISOLINUX_BIN=""
ISOHDPFX_BIN=""
BOOT_CAT=""
EFI_IMG=""

echo -e "${BLUE}🔍 Searching for boot files...${NC}"

# Check for isolinux.bin in various locations
for path in "boot/syslinux/isolinux.bin" "isolinux/isolinux.bin" "syslinux/isolinux.bin"; do
    if [ -f "${path}" ]; then
        ISOLINUX_BIN="${path}"
        echo -e "${GREEN}✅ Found isolinux.bin: ${path}${NC}"
        break
    fi
done

# Find isohdpfx.bin (MBR boot sector)
for path in "boot/syslinux/isohdpfx.bin" "isolinux/isohdpfx.bin" "syslinux/isohdpfx.bin"; do
    if [ -f "${path}" ]; then
        ISOHDPFX_BIN="${path}"
        echo -e "${GREEN}✅ Found isohdpfx.bin: ${path}${NC}"
        break
    fi
done

# Find boot.cat
for path in "boot/syslinux/boot.cat" "isolinux/boot.cat" "syslinux/boot.cat"; do
    if [ -f "${path}" ]; then
        BOOT_CAT="${path}"
        echo -e "${GREEN}✅ Found boot.cat: ${path}${NC}"
        break
    fi
done

# Verify all required boot files are found
if [ -z "${ISOLINUX_BIN}" ] || [ -z "${ISOHDPFX_BIN}" ] || [ -z "${BOOT_CAT}" ]; then
    echo -e "${RED}❌ Error: Required boot files not found!${NC}"
    echo -e "${YELLOW}Missing:${NC}"
    [ -z "${ISOLINUX_BIN}" ] && echo -e "${YELLOW}  - isolinux.bin${NC}"
    [ -z "${ISOHDPFX_BIN}" ] && echo -e "${YELLOW}  - isohdpfx.bin${NC}"
    [ -z "${BOOT_CAT}" ] && echo -e "${YELLOW}  - boot.cat${NC}"
    echo -e "${YELLOW}Available files:${NC}"
    find . -name "*.bin" -o -name "*.cat" 2>/dev/null | head -10
    exit 1
fi

# Find EFI boot image or EFI directory
EFI_DIR=""
for path in "EFI/archiso/efiboot.img" "EFI/archiso" "EFI/boot" "EFI"; do
    if [ -f "${path}" ]; then
        EFI_IMG="${path}"
        break
    elif [ -d "${path}" ] && [ -n "$(find "${path}" -name "*.EFI" -o -name "*.efi" 2>/dev/null | head -1)" ]; then
        EFI_DIR="${path}"
        break
    fi
done

# Build ISO with proper boot structure
if [ -n "${ISOLINUX_BIN}" ] && [ -n "${ISOHDPFX_BIN}" ] && [ -d "EFI" ]; then
    # Arch Linux dual boot (BIOS + UEFI)
    echo -e "${BLUE}Using Arch Linux dual boot structure (BIOS + UEFI)...${NC}"
    echo -e "${BLUE}Boot files: ${ISOLINUX_BIN}, ${BOOT_CAT}, ${ISOHDPFX_BIN}${NC}"
    if [ -n "${EFI_IMG}" ] && [ -f "${EFI_IMG}" ]; then
        # UEFI boot with efiboot.img
        echo -e "${BLUE}Using EFI boot image: ${EFI_IMG}${NC}"
        xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -volid "ARCH_$(date +%Y.%m.%d)" \
            -eltorito-boot "${ISOLINUX_BIN}" \
            -eltorito-catalog "${BOOT_CAT}" \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -isohybrid-mbr "${ISOHDPFX_BIN}" \
            -eltorito-alt-boot \
            -e "${EFI_IMG}" \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
            -output "${OUTPUT_ISO_ABS}" \
            . 2>&1 | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" || {
            echo -e "${YELLOW}⚠️  xorriso had warnings, checking if ISO was created...${NC}"
        }
    elif [ -n "${EFI_DIR}" ] && [ -d "${EFI_DIR}" ]; then
        # UEFI boot with EFI directory - need to create efiboot.img
        echo -e "${BLUE}Using EFI directory: ${EFI_DIR}${NC}"
        
        # Create efiboot.img from EFI/BOOT directory if it doesn't exist
        EFI_IMG_TEMP=""
        if [ ! -f "EFI/archiso/efiboot.img" ] && [ -d "EFI/BOOT" ]; then
            echo -e "${BLUE}Creating EFI boot image from EFI/BOOT directory...${NC}"
            
            # Create temporary directory for efiboot.img
            EFI_TEMP_DIR=$(mktemp -d)
            mkdir -p "${EFI_TEMP_DIR}/EFI/BOOT"
            
            # Copy EFI files
            cp -r EFI/BOOT/* "${EFI_TEMP_DIR}/EFI/BOOT/" 2>/dev/null || true
            
            # Create efiboot.img (FAT32 filesystem)
            EFI_IMG_TEMP="EFI/archiso/efiboot.img"
            mkdir -p "$(dirname "${EFI_IMG_TEMP}")"
            
            # Calculate size needed (at least 2MB for EFI files)
            EFI_SIZE=$((2 * 1024 * 1024))  # 2MB minimum
            
            # Create FAT32 image using mkfs.fat
            if command -v mkfs.fat >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
                echo -e "${BLUE}Creating FAT32 image using mkfs.fat...${NC}"
                dd if=/dev/zero of="${EFI_IMG_TEMP}" bs=1024 count=$((EFI_SIZE / 1024)) 2>/dev/null
                mkfs.fat -F 32 -n "ARCHISO_EFI" "${EFI_IMG_TEMP}" >/dev/null 2>&1
                
                # Copy EFI files using mcopy (mtools)
                mcopy -i "${EFI_IMG_TEMP}" -s "${EFI_TEMP_DIR}/EFI/BOOT"/* ::EFI/BOOT/ 2>/dev/null || {
                    echo -e "${YELLOW}⚠️  mcopy failed, trying mount method...${NC}"
                    # Fall back to mount method
                    EFI_MOUNT=$(mktemp -d)
                    sudo mount -o loop "${EFI_IMG_TEMP}" "${EFI_MOUNT}" 2>/dev/null || {
                        echo -e "${YELLOW}⚠️  Could not mount efiboot.img${NC}"
                        rm -f "${EFI_IMG_TEMP}"
                        EFI_IMG_TEMP=""
                    }
                    
                    if [ -n "${EFI_IMG_TEMP}" ] && mountpoint -q "${EFI_MOUNT}"; then
                        sudo mkdir -p "${EFI_MOUNT}/EFI/BOOT"
                        sudo cp -r "${EFI_TEMP_DIR}/EFI/BOOT"/* "${EFI_MOUNT}/EFI/BOOT/" 2>/dev/null || true
                        sudo umount "${EFI_MOUNT}" 2>/dev/null || true
                        rmdir "${EFI_MOUNT}" 2>/dev/null || true
                    fi
                }
                
                rm -rf "${EFI_TEMP_DIR}"
            elif command -v mkfs.fat >/dev/null 2>&1; then
                echo -e "${BLUE}Creating FAT32 image using mkfs.fat (mount method)...${NC}"
                dd if=/dev/zero of="${EFI_IMG_TEMP}" bs=1024 count=$((EFI_SIZE / 1024)) 2>/dev/null
                mkfs.fat -F 32 -n "ARCHISO_EFI" "${EFI_IMG_TEMP}" >/dev/null 2>&1
                
                # Mount and copy files
                EFI_MOUNT=$(mktemp -d)
                sudo mount -o loop "${EFI_IMG_TEMP}" "${EFI_MOUNT}" 2>/dev/null || {
                    echo -e "${YELLOW}⚠️  Could not mount efiboot.img${NC}"
                    rm -f "${EFI_IMG_TEMP}"
                    EFI_IMG_TEMP=""
                }
                
                if [ -n "${EFI_IMG_TEMP}" ] && mountpoint -q "${EFI_MOUNT}"; then
                    sudo mkdir -p "${EFI_MOUNT}/EFI/BOOT"
                    sudo cp -r "${EFI_TEMP_DIR}/EFI/BOOT"/* "${EFI_MOUNT}/EFI/BOOT/" 2>/dev/null || true
                    sudo umount "${EFI_MOUNT}" 2>/dev/null || true
                    rmdir "${EFI_MOUNT}" 2>/dev/null || true
                fi
                
                rm -rf "${EFI_TEMP_DIR}"
            else
                echo -e "${YELLOW}⚠️  mkfs.fat not found, cannot create efiboot.img${NC}"
                rm -rf "${EFI_TEMP_DIR}"
                EFI_IMG_TEMP=""
            fi
        fi
        
        # Use efiboot.img if created, otherwise fall back to EFI directory method
        if [ -n "${EFI_IMG_TEMP}" ] && [ -f "${EFI_IMG_TEMP}" ]; then
            echo -e "${GREEN}✅ Using created efiboot.img: ${EFI_IMG_TEMP}${NC}"
            EFI_IMG="${EFI_IMG_TEMP}"
            echo -e "${BLUE}Building ISO with BIOS + UEFI boot support...${NC}"
            XORRISO_OUTPUT=$(xorriso -as mkisofs \
                -iso-level 3 \
                -full-iso9660-filenames \
                -volid "ARCH_$(date +%Y.%m.%d)" \
                -eltorito-boot "${ISOLINUX_BIN}" \
                -eltorito-catalog "${BOOT_CAT}" \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                -isohybrid-mbr "${ISOHDPFX_BIN}" \
                -eltorito-alt-boot \
                -e "${EFI_IMG}" \
                -no-emul-boot \
                -isohybrid-gpt-basdat \
                -output "${OUTPUT_ISO_ABS}" \
                . 2>&1)
            
            XORRISO_EXIT=$?
            echo "${XORRISO_OUTPUT}" | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" || true
            
            if [ ${XORRISO_EXIT} -ne 0 ]; then
                echo -e "${RED}❌ xorriso failed with exit code ${XORRISO_EXIT}${NC}"
                echo -e "${YELLOW}Full error output:${NC}"
                echo "${XORRISO_OUTPUT}" | grep -E "error|Error|ERROR|fail|Fail|FAIL" || echo "${XORRISO_OUTPUT}"
                return 1
            fi
            
            if [ ! -f "${OUTPUT_ISO_ABS}" ]; then
                echo -e "${RED}❌ ISO file was not created!${NC}"
                return 1
            fi
        else
            echo -e "${YELLOW}⚠️  Could not create efiboot.img, creating BIOS-only ISO...${NC}"
            xorriso -as mkisofs \
                -iso-level 3 \
                -full-iso9660-filenames \
                -volid "ARCH_$(date +%Y.%m.%d)" \
                -eltorito-boot "${ISOLINUX_BIN}" \
                -eltorito-catalog "${BOOT_CAT}" \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                -isohybrid-mbr "${ISOHDPFX_BIN}" \
                -output "${OUTPUT_ISO_ABS}" \
                . 2>&1 | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" || {
                echo -e "${YELLOW}⚠️  xorriso had warnings, checking if ISO was created...${NC}"
            }
        fi
    else
        echo -e "${YELLOW}⚠️  EFI boot files not found, creating BIOS-only ISO...${NC}"
        xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -volid "ARCH_$(date +%Y.%m.%d)" \
            -eltorito-boot "${ISOLINUX_BIN}" \
            -eltorito-catalog "${BOOT_CAT}" \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -isohybrid-mbr "${ISOHDPFX_BIN}" \
            -output "${OUTPUT_ISO_ABS}" \
            . 2>&1 | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" || {
            echo -e "${YELLOW}⚠️  xorriso had warnings, checking if ISO was created...${NC}"
        }
    fi
elif [ -n "${ISOLINUX_BIN}" ] && [ -n "${ISOHDPFX_BIN}" ]; then
    # BIOS boot only
    echo -e "${BLUE}Using BIOS boot structure...${NC}"
    echo -e "${BLUE}Boot files: ${ISOLINUX_BIN}, ${BOOT_CAT}, ${ISOHDPFX_BIN}${NC}"
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "ARCH_$(date +%Y.%m.%d)" \
        -eltorito-boot "${ISOLINUX_BIN}" \
        -eltorito-catalog "${BOOT_CAT}" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX_BIN}" \
        -output "${OUTPUT_ISO_ABS}" \
        . 2>&1 | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" || {
        echo -e "${YELLOW}⚠️  xorriso had warnings, checking if ISO was created...${NC}"
    }
else
    echo -e "${RED}❌ Error: Boot files not found!${NC}"
    echo -e "${YELLOW}Searched for:${NC}"
    echo -e "${YELLOW}  - isolinux.bin in: boot/syslinux/, isolinux/, syslinux/${NC}"
    echo -e "${YELLOW}  - isohdpfx.bin in: boot/syslinux/, isolinux/, syslinux/${NC}"
    echo -e "${YELLOW}Available files:${NC}"
    find . -name "*.bin" -o -name "*.cat" 2>/dev/null | head -10
    exit 1
fi

cd - > /dev/null

# Update OUTPUT_ISO to point to the absolute path for verification
OUTPUT_ISO="${OUTPUT_ISO_ABS}"

if [ ! -f "${OUTPUT_ISO}" ]; then
    echo -e "${RED}❌ Error: ISO rebuild failed${NC}"
    cleanup "keep-all"
    exit 1
fi

# Cleanup after successful ISO creation
cleanup "keep-all"

# Make ISO bootable (if isohybrid available)
if command -v isohybrid &> /dev/null; then
    isohybrid "${OUTPUT_ISO}" 2>/dev/null || true
fi

echo -e "${GREEN}✅ ISO rebuilt: ${OUTPUT_ISO}${NC}"

# Show size info
ISO_SIZE=$(du -h "${OUTPUT_ISO}" | cut -f1)
echo -e "${BLUE}📊 Final ISO size: ${ISO_SIZE}${NC}"

echo -e "${GREEN}🎉 JARVIS OS ISO injection complete!${NC}"
echo -e "${YELLOW}💡 Test with: qemu-system-x86_64 -cdrom ${OUTPUT_ISO} -m 2048${NC}"

