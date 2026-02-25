#!/bin/bash
# Step 0: Install Build Prerequisites
# Installs all packages required to build the JARVIS OS ISO on the host system.
# Supports Arch Linux, Fedora/RHEL, Ubuntu/Debian, and openSUSE host systems.

set -e

# Source shared utilities (provides detect_host_distro, detect_pkg_family, install_host_package)
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 0: Installing Build Prerequisites${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

DISTRO=$(detect_host_distro)
echo -e "${BLUE}Detected distribution: ${DISTRO}${NC}"

# Required host packages:
# - arch-install-scripts: provides arch-chroot
# - squashfs-tools: provides mksquashfs and unsquashfs
# - xorriso (libisoburn): for creating bootable ISO files
# - p7zip / 7zip: for extracting the source Arch Linux ISO
# - dosfstools: for mkfs.fat (creating EFI boot image)
# - fakeroot: for makepkg without root (calamares-config package build)
# - git: for submodule management
# - curl: for downloading packages during build
# - wget: fallback downloader
# - python3: for various build scripts
# - libarchive: for bsdtar (used in some build operations)

install_arch() {
    echo -e "${BLUE}Installing prerequisites for Arch Linux...${NC}"
    sudo pacman -Sy --needed --noconfirm \
        arch-install-scripts \
        squashfs-tools \
        xorriso \
        p7zip \
        dosfstools \
        fakeroot \
        git \
        curl \
        wget \
        python \
        libarchive \
        qemu-system-x86 \
        qemu-ui-gtk
    echo -e "${GREEN}✓ Arch Linux prerequisites installed${NC}"
}

install_fedora() {
    echo -e "${BLUE}Installing prerequisites for Fedora/RHEL...${NC}"
    sudo dnf install -y \
        arch-install-scripts \
        squashfs-tools \
        xorriso \
        p7zip \
        p7zip-plugins \
        dosfstools \
        fakeroot \
        git \
        curl \
        wget \
        python3 \
        libarchive \
        qemu-system-x86 \
        qemu-ui-gtk 2>/dev/null || \
    sudo dnf install -y \
        arch-install-scripts \
        squashfs-tools \
        xorriso \
        p7zip \
        p7zip-plugins \
        dosfstools \
        fakeroot \
        git \
        curl \
        wget \
        python3 \
        libarchive
    echo -e "${GREEN}✓ Fedora prerequisites installed${NC}"
}

install_ubuntu() {
    echo -e "${BLUE}Installing prerequisites for Ubuntu/Debian...${NC}"
    sudo apt-get update -qq
    sudo apt-get install -y \
        arch-install-scripts \
        squashfs-tools \
        xorriso \
        p7zip-full \
        dosfstools \
        fakeroot \
        git \
        curl \
        wget \
        python3 \
        libarchive-tools \
        qemu-system-x86 \
        qemu-utils 2>/dev/null || \
    sudo apt-get install -y \
        arch-install-scripts \
        squashfs-tools \
        xorriso \
        p7zip-full \
        dosfstools \
        fakeroot \
        git \
        curl \
        wget \
        python3 \
        libarchive-tools
    echo -e "${GREEN}✓ Ubuntu/Debian prerequisites installed${NC}"
}

install_opensuse() {
    echo -e "${BLUE}Installing prerequisites for openSUSE...${NC}"
    sudo zypper install -y \
        arch-install-scripts \
        squashfs \
        xorriso \
        p7zip \
        dosfstools \
        fakeroot \
        git \
        curl \
        wget \
        python3 \
        libarchive-devel
    echo -e "${GREEN}✓ openSUSE prerequisites installed${NC}"
}

# Install based on detected distro family (handles derivatives automatically)
PKG_FAMILY=$(detect_pkg_family)
echo -e "${BLUE}Package manager family: ${PKG_FAMILY}${NC}"

case "${PKG_FAMILY}" in
    arch)
        install_arch
        ;;
    fedora)
        install_fedora
        ;;
    debian)
        install_ubuntu
        ;;
    opensuse)
        install_opensuse
        ;;
    *)
        echo -e "${RED}Error: Cannot detect package manager for '${DISTRO}'.${NC}" >&2
        echo -e "${YELLOW}Please manually install:${NC}"
        echo "  - arch-install-scripts (provides arch-chroot)"
        echo "  - squashfs-tools       (provides mksquashfs, unsquashfs)"
        echo "  - xorriso              (ISO building)"
        echo "  - p7zip / p7zip-full   (provides 7z for ISO extraction)"
        echo "  - dosfstools           (provides mkfs.fat)"
        echo "  - fakeroot             (required for makepkg)"
        echo "  - git, curl, wget, python3"
        exit 1
        ;;
esac

# Verify critical tools are available after installation
echo ""
echo -e "${BLUE}Verifying installed tools...${NC}"

MISSING_TOOLS=()

check_tool() {
    local tool="$1"
    local package="$2"
    if command -v "${tool}" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} ${tool}"
    else
        echo -e "  ${RED}✗${NC} ${tool} (from ${package})"
        MISSING_TOOLS+=("${tool}")
    fi
}

check_tool "arch-chroot"  "arch-install-scripts"
check_tool "unsquashfs"   "squashfs-tools"
check_tool "mksquashfs"   "squashfs-tools"
check_tool "xorriso"      "xorriso/libisoburn"
check_tool "7z"           "p7zip"
check_tool "mkfs.fat"     "dosfstools"
check_tool "fakeroot"     "fakeroot"
check_tool "git"          "git"
check_tool "curl"         "curl"
check_tool "python3"      "python3"

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Error: The following tools are still missing:${NC}" >&2
    for tool in "${MISSING_TOOLS[@]}"; do
        echo -e "${RED}  - ${tool}${NC}" >&2
    done
    echo -e "${YELLOW}Please install them manually before proceeding.${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 0 complete: All prerequisites installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "${BLUE}  1. Place Arch Linux ISO in build-deps/ directory${NC}"
echo -e "${BLUE}     File: build-deps/archlinux-YYYY.MM.DD-x86_64.iso${NC}"
echo -e "${BLUE}  2. Update build.config ISO_FILE to match the filename${NC}"
echo -e "${BLUE}  3. Run: make step1 (extract ISO)${NC}"
echo -e "${BLUE}  4. Run: make step2 (unsquash rootfs)${NC}"
echo -e "${BLUE}  5. Run: make step3 (install KDE Plasma + packages)${NC}"
echo -e "${BLUE}  6. Run: make step4 (install JARVIS)${NC}"
echo -e "${BLUE}  7. Run: make step5 (install Calamares)${NC}"
echo -e "${BLUE}  8. Run: make step6 (rebuild SquashFS)${NC}"
echo -e "${BLUE}  9. Run: make step7 (rebuild ISO)${NC}"
echo -e "${BLUE}     Or: make all (run all steps sequentially)${NC}"
