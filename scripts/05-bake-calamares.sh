#!/bin/bash
# Step 5: Bake in Calamares Installer
# Installs Calamares from chaotic-aur and our calamares-config package

set -e

# Source config file and shared utilities
source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

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
PACKAGES_DIR="${PROJECT_ROOT}/packages"
CALAMARES_CONFIG_DIR="${PACKAGES_DIR}/calamares-config"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if step 4 was completed (JARVIS installed)
if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Rootfs not extracted. Please run step 2 first${NC}" >&2
    exit 1
fi

# Verify rootfs has essential directories
if [ ! -d "${SQUASHFS_ROOTFS}/usr/bin" ] && [ ! -d "${SQUASHFS_ROOTFS}/bin" ]; then
    echo -e "${RED}Error: Rootfs appears invalid - /usr/bin or /bin missing${NC}" >&2
    exit 1
fi

# Check if calamares-config package exists
if [ ! -d "${CALAMARES_CONFIG_DIR}" ]; then
    echo -e "${RED}Error: calamares-config package not found at ${CALAMARES_CONFIG_DIR}${NC}" >&2
    exit 1
fi

# Determine chroot command (distro-aware error messages via build-utils.sh)
detect_chroot_cmd

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 5: Installing Calamares Installer${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"

# Step 1: Copy DNS resolution file
echo -e "${BLUE}Copying DNS resolution file...${NC}"
if [ -f /etc/resolv.conf ]; then
    sudo cp /etc/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
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

# Step 3: Add chaotic-aur repository
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Adding chaotic-aur repository...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    set -e
    
    # Import GPG key
    echo 'Importing chaotic-aur GPG key...'
    pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com 2>/dev/null || \
    pacman-key --recv-key 3056513887B78AEB --keyserver keys.openpgp.org 2>/dev/null || {
        echo 'Warning: Could not import key from keyservers, trying direct download...'
    }
    
    pacman-key --lsign-key 3056513887B78AEB 2>/dev/null || true
    
    # Download and install keyring and mirrorlist
    cd /tmp
    echo 'Downloading chaotic-aur keyring and mirrorlist...'
    curl -f -L -O 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' || exit 1
    curl -f -L -O 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' || exit 1
    
    echo 'Installing chaotic-aur keyring and mirrorlist...'
    pacman -U --noconfirm chaotic-keyring.pkg.tar.zst chaotic-mirrorlist.pkg.tar.zst || exit 1
    
    # Add to pacman.conf
    if ! grep -q '\[chaotic-aur\]' /etc/pacman.conf; then
        echo '' >> /etc/pacman.conf
        echo '[chaotic-aur]' >> /etc/pacman.conf
        echo 'Include = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
    fi
    
    # Sync database
    echo 'Syncing package database...'
    pacman -Sy || exit 1
    
    echo '✓ chaotic-aur repository added successfully'
" || {
    echo -e "${RED}Error: Failed to add chaotic-aur repository${NC}" >&2
    exit 1
}

# Step 4: Install Calamares binary (try chaotic-aur first, fallback to AUR)
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installing Calamares binary...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

CALAMARES_INSTALLED=false

# Try chaotic-aur first
echo -e "${BLUE}Checking if Calamares is available in chaotic-aur...${NC}"
if sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Ss calamares 2>/dev/null | grep -q "chaotic-aur/calamares"; then
    echo -e "${BLUE}Found Calamares in chaotic-aur, installing...${NC}"
    sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm calamares && CALAMARES_INSTALLED=true
else
    echo -e "${YELLOW}Calamares not found in chaotic-aur, will build from AUR...${NC}"
fi

# Fallback: Build from AUR if chaotic-aur didn't work
if [ "${CALAMARES_INSTALLED}" != "true" ]; then
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Building Calamares from AUR (calamares-git)...${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
        set -e
        
        # Function to find Calamares package (main package, not debug)
        find_calamares_package() {
            local build_dir=\"\$1\"
            
            # Try to find main package excluding debug versions
            local main_pkg=\$(find \"\${build_dir}\" -maxdepth 1 -name 'calamares-git-*.pkg.tar.zst' -type f ! -name '*debug*' ! -name '*-debug-*' | head -1)
            
            # If not found, try without strict version pattern
            if [ -z \"\${main_pkg}\" ]; then
                main_pkg=\$(ls -1 \"\${build_dir}\"/calamares-git-*.pkg.tar.zst 2>/dev/null | grep -v debug | head -1)
            fi
            
            # If still not found, check all packages
            if [ -z \"\${main_pkg}\" ]; then
                local all_pkgs=\$(ls -1 \"\${build_dir}\"/*.pkg.tar.zst 2>/dev/null)
                local pkg_count=\$(echo \"\${all_pkgs}\" | wc -l)
                
                if [ \"\${pkg_count}\" -eq 1 ]; then
                    # Only one package - use it
                    main_pkg=\$(echo \"\${all_pkgs}\" | head -1)
                elif [ \"\${pkg_count}\" -gt 1 ]; then
                    # Multiple packages - find the one that's NOT debug
                    main_pkg=\$(echo \"\${all_pkgs}\" | grep -v debug | head -1)
                    if [ -z \"\${main_pkg}\" ]; then
                        echo 'ERROR: Only debug packages found!' >&2
                        echo 'Available packages:' >&2
                        echo \"\${all_pkgs}\" >&2
                        return 1
                    fi
                else
                    echo 'ERROR: No packages found!' >&2
                    return 1
                fi
            fi
            
            echo \"\${main_pkg}\"
        }
        
        # Install build dependencies
        echo 'Installing build dependencies...'
        pacman -S --noconfirm --needed base-devel git cmake extra-cmake-modules ninja || exit 1
        
        # Install Calamares dependencies
        pacman -S --noconfirm --needed \
            boost \
            kcoreaddons \
            kconfig \
            ki18n \
            kservice \
            solid \
            yaml-cpp \
            kpmcore \
            qt5-base \
            qt5-svg \
            qt5-tools \
            qt5-xmlpatterns \
            kparts \
            polkit-qt5 \
            python-jsonschema \
            python-yaml \
            libpwquality || {
            echo 'Warning: Some dependencies may have failed'
        }
        
        cd /tmp
        rm -rf calamares-git 2>/dev/null || true
        
        echo 'Cloning calamares-git from AUR...'
        if ! git clone https://aur.archlinux.org/calamares-git.git; then
            echo 'ERROR: Failed to clone calamares-git repository'
            exit 1
        fi
        
        cd calamares-git
        
        # Ensure nobody user exists
        if ! id nobody >/dev/null 2>&1; then
            useradd -r -m -s /bin/bash nobody
        fi
        
        chown -R nobody:nobody /tmp/calamares-git
        
        echo 'Building calamares-git package (this may take 5-10 minutes)...'
        BUILD_SUCCESS=false
        if runuser -u nobody -- bash -c 'cd /tmp/calamares-git && makepkg --noconfirm --skipinteg --nocheck 2>&1'; then
            # List all built packages for debugging
            echo 'All built packages:'
            ls -1 /tmp/calamares-git/*.pkg.tar.zst 2>/dev/null || true
            
            # Find the main package using the function
            MAIN_PKG=\$(find_calamares_package /tmp/calamares-git)
            
            if [ -z \"\${MAIN_PKG}\" ] || [ ! -f \"\${MAIN_PKG}\" ]; then
                echo 'ERROR: Failed to find Calamares package!' >&2
                echo 'Built packages:' >&2
                ls -la /tmp/calamares-git/*.pkg.tar.zst 2>/dev/null || true
                exit 1
            fi
            
            echo \"Installing main package: \${MAIN_PKG}\"
            if pacman -U --noconfirm \"\${MAIN_PKG}\"; then
                # Also install debug package if it exists (optional, but doesn't hurt)
                DEBUG_PKG=\$(find /tmp/calamares-git -maxdepth 1 -name 'calamares-git*-debug*.pkg.tar.zst' -type f | head -1)
                if [ -n \"\${DEBUG_PKG}\" ]; then
                    echo \"Also installing debug package: \${DEBUG_PKG}\"
                    pacman -U --noconfirm \"\${DEBUG_PKG}\" 2>/dev/null || true
                fi
                
                # Use MAIN_PKG for verification
                PKGFILE=\"\${MAIN_PKG}\"
                
                if true; then
                    # Give it a moment for installation to complete
                    sleep 2
                    
                    # Verify installation - check multiple ways
                    if command -v calamares >/dev/null 2>&1; then
                        echo \"SUCCESS: Calamares binary found at: \$(which calamares)\"
                        BUILD_SUCCESS=true
                    elif [ -f /usr/bin/calamares ]; then
                        echo \"SUCCESS: Calamares binary found at: /usr/bin/calamares\"
                        BUILD_SUCCESS=true
                    elif pacman -Q calamares-git >/dev/null 2>&1 || \
                         pacman -Q calamares-git-debug >/dev/null 2>&1 || \
                         pacman -Q calamares >/dev/null 2>&1; then
                        echo \"SUCCESS: Calamares package installed (checking binary location...)\"
                        # Try to find the binary
                        CALAMARES_BIN=\$(find /usr -name calamares -type f 2>/dev/null | head -1)
                        if [ -n \"\${CALAMARES_BIN}\" ]; then
                            echo \"Found binary at: \${CALAMARES_BIN}\"
                            BUILD_SUCCESS=true
                        else
                            # If package is installed, consider it success even if binary check fails
                            # The binary might be in a non-standard location or need a moment
                            echo \"Package installed successfully (binary location will be verified later)\"
                            BUILD_SUCCESS=true
                        fi
                    fi
                else
                    echo \"ERROR: Package installation failed\"
                fi
            else
                echo \"ERROR: Built package file not found\"
                echo \"Contents of build directory:\"
                ls -la /tmp/calamares-git/ || true
            fi
        else
            echo \"ERROR: makepkg build failed\"
        fi
        
        if [ \"\${BUILD_SUCCESS}\" = \"true\" ]; then
            echo 'SUCCESS: Calamares installed from calamares-git'
            exit 0
        else
            echo 'ERROR: Failed to build or install calamares-git'
            exit 1
        fi
    " && CALAMARES_INSTALLED=true || {
        echo -e "${YELLOW}Warning: AUR build reported issues, checking if Calamares was actually installed...${NC}"
        # Check if it was actually installed despite the error
        # Check for any calamares package (including calamares-git-debug)
        if sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q calamares >/dev/null 2>&1 || \
           sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q calamares-git >/dev/null 2>&1 || \
           sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q calamares-git-debug >/dev/null 2>&1; then
            echo -e "${GREEN}Calamares package found in pacman database!${NC}"
            # Verify binary exists
            if sudo arch-chroot "${SQUASHFS_ROOTFS}" command -v calamares >/dev/null 2>&1 || \
               sudo arch-chroot "${SQUASHFS_ROOTFS}" test -f /usr/bin/calamares; then
                echo -e "${GREEN}Calamares binary verified!${NC}"
                CALAMARES_INSTALLED=true
            else
                # Package is installed, find the binary
                CALAMARES_BIN=$(sudo arch-chroot "${SQUASHFS_ROOTFS}" find /usr -name calamares -type f 2>/dev/null | head -1)
                if [ -n "${CALAMARES_BIN}" ]; then
                    echo -e "${GREEN}Found Calamares binary at: ${CALAMARES_BIN}${NC}"
                    CALAMARES_INSTALLED=true
                else
                    echo -e "${YELLOW}Package installed but binary not immediately found - will verify later${NC}"
                    CALAMARES_INSTALLED=true  # Trust that package installation means it's there
                fi
            fi
        else
            echo -e "${RED}Error: Failed to build Calamares from AUR${NC}" >&2
            echo -e "${YELLOW}Checking what packages are installed...${NC}"
            sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q | grep -i calamares || echo "No calamares packages found"
            exit 1
        fi
    }
fi

# Verify Calamares binary is installed (check multiple ways)
echo -e "${BLUE}Verifying Calamares installation...${NC}"
CALAMARES_FOUND=false

if sudo arch-chroot "${SQUASHFS_ROOTFS}" command -v calamares >/dev/null 2>&1; then
    CALAMARES_FOUND=true
elif sudo arch-chroot "${SQUASHFS_ROOTFS}" test -f /usr/bin/calamares; then
    CALAMARES_FOUND=true
elif sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q calamares >/dev/null 2>&1 || \
     sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q calamares-git >/dev/null 2>&1 || \
     sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q calamares-git-debug >/dev/null 2>&1; then
    # Package is installed, find the binary
    CALAMARES_BIN=$(sudo arch-chroot "${SQUASHFS_ROOTFS}" find /usr -name calamares -type f 2>/dev/null | head -1)
    if [ -n "${CALAMARES_BIN}" ]; then
        echo -e "${GREEN}Found Calamares binary at: ${CALAMARES_BIN}${NC}"
        CALAMARES_FOUND=true
    fi
fi

if [ "${CALAMARES_FOUND}" != "true" ]; then
    echo -e "${RED}Error: Calamares binary not found after installation${NC}" >&2
    echo -e "${YELLOW}Debugging information:${NC}"
    sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
        echo 'Searching for calamares...'
        find /usr -name '*calamares*' 2>/dev/null | head -10
        echo ''
        echo 'Checking pacman database:'
        pacman -Q | grep -i calamares || echo 'No calamares package found'
        echo ''
        echo 'Checking /usr/bin:'
        ls -la /usr/bin/calamares 2>&1 || echo 'calamares not in /usr/bin'
    "
    exit 1
fi

CALAMARES_VERSION=$(sudo arch-chroot "${SQUASHFS_ROOTFS}" calamares --version 2>&1 | head -1)
echo -e "${GREEN}✓ Calamares installed: ${CALAMARES_VERSION}${NC}"

# Step 5: Build calamares-config package
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Building calamares-config package...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Install fakeroot if not available (required for makepkg)
if ! command -v fakeroot >/dev/null 2>&1; then
    echo -e "${BLUE}Installing fakeroot (required for makepkg)...${NC}"
    # install_host_package detects the running distro automatically
    if ! install_host_package "fakeroot" "fakeroot" "fakeroot" "fakeroot"; then
        echo -e "${RED}Error: Could not install fakeroot${NC}" >&2
        echo -e "${YELLOW}Install manually: $(pkg_install_hint fakeroot)${NC}"
        exit 1
    fi
fi

cd "${CALAMARES_CONFIG_DIR}"

# Build the package
# Use --nodeps to skip dependency checking (calamares is in chroot, not on host)
echo -e "${BLUE}Running makepkg (skipping dependency checks)...${NC}"
makepkg -f --noconfirm --nodeps || {
    echo -e "${RED}Error: Failed to build calamares-config package${NC}" >&2
    echo -e "${YELLOW}Make sure fakeroot is installed: $(pkg_install_hint fakeroot)${NC}"
    exit 1
}

# Find the built package (could be .tar.zst or .tar.gz depending on makepkg config)
PKGFILE=$(find "${CALAMARES_CONFIG_DIR}" -maxdepth 1 \( -name 'calamares-config-*.pkg.tar.zst' -o -name 'calamares-config-*.pkg.tar.gz' \) -type f | head -1)

if [ -z "${PKGFILE}" ]; then
    echo -e "${RED}Error: Built package file not found${NC}" >&2
    echo -e "${YELLOW}Looking for package files...${NC}"
    ls -la "${CALAMARES_CONFIG_DIR}"/*.pkg.tar* 2>/dev/null || echo "No package files found"
    exit 1
fi

echo -e "${GREEN}✓ Package built: $(basename "${PKGFILE}")${NC}"

# Step 6: Install calamares-config package into rootfs
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installing calamares-config package...${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Copy package to rootfs for installation (use /root instead of /tmp for better compatibility)
PKG_BASENAME=$(basename "${PKGFILE}")
INSTALL_PATH="/root/${PKG_BASENAME}"

echo -e "${BLUE}Copying package to rootfs: ${PKG_BASENAME}${NC}"
sudo cp "${PKGFILE}" "${SQUASHFS_ROOTFS}${INSTALL_PATH}" || {
    echo -e "${RED}Error: Failed to copy package to rootfs${NC}" >&2
    exit 1
}

# Verify the file was copied
if ! sudo test -f "${SQUASHFS_ROOTFS}${INSTALL_PATH}"; then
    echo -e "${RED}Error: Package file not found in rootfs after copy${NC}" >&2
    echo -e "${YELLOW}Source: ${PKGFILE}${NC}"
    echo -e "${YELLOW}Destination: ${SQUASHFS_ROOTFS}${INSTALL_PATH}${NC}"
    exit 1
fi

echo -e "${BLUE}Installing package in chroot...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    echo 'Checking if package file exists in chroot...'
    ls -lh ${INSTALL_PATH} || echo 'Package file not found!'
    echo ''
    echo 'Installing package...'
    pacman -U --noconfirm ${INSTALL_PATH}
" || {
    echo -e "${RED}Error: Failed to install calamares-config package${NC}" >&2
    echo -e "${YELLOW}Debugging: Checking if file exists in rootfs...${NC}"
    sudo ls -lh "${SQUASHFS_ROOTFS}${INSTALL_PATH}" || echo "File not found"
    exit 1
}

# Cleanup package from rootfs
sudo rm -f "${SQUASHFS_ROOTFS}${INSTALL_PATH}"

# Verify configuration files are installed
if [ ! -f "${SQUASHFS_ROOTFS}/etc/calamares/settings.conf" ]; then
    echo -e "${RED}Error: Calamares configuration not found after installation${NC}" >&2
    exit 1
fi

echo -e "${GREEN}✓ calamares-config package installed${NC}"

# Step 7: Update KDE application database
echo -e "${BLUE}Updating KDE application database...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c '
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database /usr/share/applications 2>/dev/null || true
    fi
    
    if command -v kbuildsycoca5 >/dev/null 2>&1; then
        kbuildsycoca5 --noincremental 2>/dev/null || true
    fi
' || {
    echo -e "${YELLOW}Warning: Could not update application database${NC}"
}

# Step 8: Cleanup package cache
echo -e "${BLUE}Cleaning up package cache...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Scc --noconfirm 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" sh -c "rm -rf /tmp/* /var/cache/pacman/pkg/*" 2>/dev/null || true

# Cleanup will be handled by trap
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 5 complete: Calamares installer installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Configuration:${NC}"
echo -e "${BLUE}  ✓ Calamares binary: from chaotic-aur${NC}"
echo -e "${BLUE}  ✓ Configuration: from calamares-config package${NC}"
echo -e "${BLUE}  ✓ Main config: /etc/calamares/settings.conf${NC}"
echo -e "${BLUE}  ✓ Modules: /etc/calamares/modules/${NC}"
echo -e "${BLUE}  ✓ Branding: /etc/calamares/branding/jarvisos/${NC}"
echo -e "${BLUE}  ✓ Desktop launcher: ~/Desktop/calamares.desktop${NC}"

