#!/bin/bash
# Step 3b: Build linux-jarvisos custom kernel packages
#
# Builds the JARVIS-integrated Linux kernel (6.19.6) from the linux/
# submodule using the PKGBUILD at packages/linux-jarvisos/PKGBUILD, producing
# two pacman packages:
#
#   linux-jarvisos         — kernel image + modules
#   linux-jarvisos-headers — build headers for out-of-tree modules
#
# Both packages are installed into the rootfs alongside the stock Arch linux
# kernel.  The stock kernel (from step 3) handles live boot hardware compat;
# linux-jarvisos is what Calamares installs on the target system.
#
# Prerequisites: step 2 (rootfs extracted) + step 3 (packages + mkinitcpio.conf)
#
# Host build tools required:
#   Arch:          sudo pacman -S base-devel bc flex bison openssl libelf pahole
#   Ubuntu/Debian: sudo apt-get install build-essential bc flex bison \
#                      libssl-dev libelf-dev dwarves

set -e

# Source config file and shared utilities
source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

# Validate required variables
if [ -z "${PROJECT_ROOT}" ]; then
    echo "Error: PROJECT_ROOT not set in build.config" >&2
    exit 1
fi

# ── Resolve paths ─────────────────────────────────────────────────────────────
BUILD_DIR="${PROJECT_ROOT}${BUILD_DIR}"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"
KERNEL_SRC="${PROJECT_ROOT}/linux"
KERNEL_BACKUP_DIR="${BUILD_DIR}/kernel-files"
PKGBUILD_DIR="${PROJECT_ROOT}/packages/linux-jarvisos"
PKG_DEST="${BUILD_DIR}/kernel-pkg"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Kernel build settings ─────────────────────────────────────────────────────
LOCALVERSION="-jarvisos"
NCPU=$(nproc)

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 3b: Building linux-jarvisos kernel packages${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Kernel source : ${KERNEL_SRC}${NC}"
echo -e "${BLUE}Rootfs        : ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}PKGBUILD      : ${PKGBUILD_DIR}${NC}"
echo -e "${BLUE}Package dest  : ${PKG_DEST}${NC}"
echo -e "${BLUE}Build threads : ${NCPU}${NC}"
echo -e "${YELLOW}NOTE: Initial kernel compilation takes 20–60 minutes.${NC}"
echo -e "${YELLOW}      Install ccache for much faster incremental rebuilds.${NC}"
echo ""

# ── Prerequisite checks ───────────────────────────────────────────────────────
echo -e "${BLUE}Checking build prerequisites...${NC}"

# Kernel source must be present
if [ ! -f "${KERNEL_SRC}/Makefile" ]; then
    echo -e "${RED}FATAL: linux/ kernel source not found at ${KERNEL_SRC}${NC}" >&2
    echo -e "${YELLOW}Ensure the linux submodule is initialized:${NC}"
    echo -e "${YELLOW}  git submodule update --init linux${NC}"
    exit 1
fi

# PKGBUILD must be present
if [ ! -f "${PKGBUILD_DIR}/PKGBUILD" ]; then
    echo -e "${RED}FATAL: PKGBUILD not found at ${PKGBUILD_DIR}/PKGBUILD${NC}" >&2
    exit 1
fi

# Step 3 (rootfs) must be done first
if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}FATAL: Rootfs not found. Run step 3 first.${NC}" >&2
    exit 1
fi

# mkinitcpio must be installed in rootfs (placed there by step 3)
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" which mkinitcpio &>/dev/null; then
    echo -e "${RED}FATAL: mkinitcpio not found in rootfs. Run step 3 first.${NC}" >&2
    exit 1
fi

# makepkg must be installed on the host
if ! command -v makepkg &>/dev/null; then
    echo -e "${RED}FATAL: makepkg not found. Install base-devel:${NC}" >&2
    echo -e "${YELLOW}  sudo pacman -S base-devel${NC}" >&2
    exit 1
fi

# Check host build tools
MISSING_TOOLS=()
for tool in make gcc bc flex bison perl; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

# openssl headers (for kernel cert generation / module signing)
if ! pkg-config --exists openssl 2>/dev/null \
   && [ ! -f /usr/include/openssl/ssl.h ]; then
    MISSING_TOOLS+=("openssl-dev (libssl-dev / openssl)")
fi

# libelf headers (for BTF/BPF)
if ! pkg-config --exists libelf 2>/dev/null \
   && [ ! -f /usr/include/libelf.h ] \
   && [ ! -f /usr/include/gelf.h ]; then
    MISSING_TOOLS+=("libelf (libelf-dev / elfutils / libelf)")
fi

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo -e "${RED}FATAL: Missing host build tools:${NC}" >&2
    for t in "${MISSING_TOOLS[@]}"; do
        echo -e "${RED}  - $t${NC}" >&2
    done
    echo ""
    echo -e "${YELLOW}Arch Linux:    sudo pacman -S base-devel bc flex bison openssl libelf pahole${NC}"
    echo -e "${YELLOW}Ubuntu/Debian: sudo apt-get install build-essential bc flex bison libssl-dev libelf-dev dwarves${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Build prerequisites OK (${NCPU} CPU threads)${NC}"

# Enable ccache if available
if command -v ccache &>/dev/null; then
    export CC="ccache gcc"
    export HOSTCC="ccache gcc"
    echo -e "${GREEN}✓ ccache enabled for faster incremental builds${NC}"
fi

# ── Kernel version info ───────────────────────────────────────────────────────
cd "${KERNEL_SRC}"
KERNELRELEASE=$(make -s kernelrelease LOCALVERSION="${LOCALVERSION}")
echo -e "${BLUE}Kernel release: ${KERNELRELEASE}${NC}"
echo ""

# ── Build packages with makepkg ───────────────────────────────────────────────
mkdir -p "${PKG_DEST}"

# Export env vars consumed by the PKGBUILD
export KERNEL_SRC
export MAKEFLAGS="-j${NCPU}"

# Allow skipping the kernel compilation when packages are already built.
# Set SKIP_KERNEL_BUILD=1 to reuse existing packages in ${PKG_DEST} and jump
# straight to the install + initramfs steps.
EXISTING_PKG_LINUX=$(ls "${PKG_DEST}"/linux-jarvisos-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)
EXISTING_PKG_HEADERS=$(ls "${PKG_DEST}"/linux-jarvisos-headers-*.pkg.tar.zst 2>/dev/null | head -1)

if [[ "${SKIP_KERNEL_BUILD:-0}" == "1" ]] \
   && [[ -n "${EXISTING_PKG_LINUX}" ]] \
   && [[ -n "${EXISTING_PKG_HEADERS}" ]]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}SKIP_KERNEL_BUILD=1: Reusing pre-built packages (skipping makepkg)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  linux-jarvisos         : $(basename "${EXISTING_PKG_LINUX}")${NC}"
    echo -e "${BLUE}  linux-jarvisos-headers : $(basename "${EXISTING_PKG_HEADERS}")${NC}"
    echo ""
else
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Building linux-jarvisos + linux-jarvisos-headers with makepkg...${NC}"
    echo -e "${BLUE}(PKGBUILD handles configure, compile, and packaging)${NC}"
    echo ""

    cd "${PKGBUILD_DIR}"
    PKGDEST="${PKG_DEST}" makepkg --nodeps --nocheck --skipinteg --force

    echo ""
    echo -e "${GREEN}✓ Packages built successfully${NC}"
fi

# Locate the produced packages
PKG_LINUX=$(ls "${PKG_DEST}"/linux-jarvisos-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)
PKG_HEADERS=$(ls "${PKG_DEST}"/linux-jarvisos-headers-*.pkg.tar.zst 2>/dev/null | head -1)

if [[ -z "${PKG_LINUX}" || -z "${PKG_HEADERS}" ]]; then
    echo -e "${RED}FATAL: Expected package files not found in ${PKG_DEST}${NC}" >&2
    ls -la "${PKG_DEST}/" || true
    exit 1
fi

echo -e "${BLUE}  linux-jarvisos         : $(basename "${PKG_LINUX}")${NC}"
echo -e "${BLUE}  linux-jarvisos-headers : $(basename "${PKG_HEADERS}")${NC}"

# ── Install packages into rootfs ──────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installing packages into rootfs...${NC}"

# Stage packages in rootfs /tmp for pacman
sudo cp "${PKG_LINUX}" "${PKG_HEADERS}" "${SQUASHFS_ROOTFS}/tmp/"

# Install via pacman in the chroot.
# --noscriptlet: skip the .install hooks here; we run mkinitcpio explicitly
# below so it uses the live-boot mkinitcpio.conf (archiso/memdisk hooks).
sudo arch-chroot "${SQUASHFS_ROOTFS}" \
    pacman -U --noconfirm --noscriptlet \
    "/tmp/$(basename "${PKG_LINUX}")" \
    "/tmp/$(basename "${PKG_HEADERS}")"

# Clean up staged packages from rootfs
sudo rm -f "${SQUASHFS_ROOTFS}/tmp/linux-jarvisos"*.pkg.tar.zst

echo -e "${GREEN}✓ linux-jarvisos installed into rootfs via pacman${NC}"
echo -e "${GREEN}✓ linux-jarvisos-headers installed into rootfs via pacman${NC}"

# ── Generate initramfs ────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}Generating initramfs for linux-jarvisos...${NC}"
echo -e "${BLUE}(Uses live-boot mkinitcpio.conf — includes archiso/memdisk hooks)${NC}"

MKINITCPIO_OUT=$(sudo arch-chroot "${SQUASHFS_ROOTFS}" mkinitcpio -p linux-jarvisos 2>&1)
MKINITCPIO_EXIT=$?

echo "${MKINITCPIO_OUT}" | tail -25

if [ ${MKINITCPIO_EXIT} -ne 0 ]; then
    echo -e "${RED}FATAL: mkinitcpio failed for linux-jarvisos preset${NC}" >&2
    echo "${MKINITCPIO_OUT}"
    echo ""
    echo -e "${YELLOW}Boot directory contents:${NC}"
    sudo ls -lah "${SQUASHFS_ROOTFS}/boot/" || true
    echo -e "${YELLOW}Modules directory:${NC}"
    sudo ls -la "${SQUASHFS_ROOTFS}/usr/lib/modules/" || true
    exit 1
fi

# Verify generated images
INITRAMFS_MAIN="${SQUASHFS_ROOTFS}/boot/initramfs-linux-jarvisos.img"
if ! sudo test -f "${INITRAMFS_MAIN}"; then
    echo -e "${RED}FATAL: initramfs-linux-jarvisos.img was not created${NC}" >&2
    sudo ls -lah "${SQUASHFS_ROOTFS}/boot/" || true
    exit 1
fi

echo -e "${GREEN}✓ Initramfs generated${NC}"

# ── Backup kernel files for step 7 ───────────────────────────────────────────
echo -e "${BLUE}Preserving linux-jarvisos kernel files for ISO build (step 7)...${NC}"
mkdir -p "${KERNEL_BACKUP_DIR}"

sudo cp "${SQUASHFS_ROOTFS}/boot/vmlinuz-linux-jarvisos" \
        "${KERNEL_BACKUP_DIR}/"
sudo cp "${SQUASHFS_ROOTFS}/boot/initramfs-linux-jarvisos.img" \
        "${KERNEL_BACKUP_DIR}/"

if sudo test -f "${SQUASHFS_ROOTFS}/boot/initramfs-linux-jarvisos-fallback.img"; then
    sudo cp "${SQUASHFS_ROOTFS}/boot/initramfs-linux-jarvisos-fallback.img" \
            "${KERNEL_BACKUP_DIR}/"
fi

# Fix ownership so step 7 can read without sudo
sudo chmod 644 "${KERNEL_BACKUP_DIR}"/vmlinuz-linux-jarvisos \
               "${KERNEL_BACKUP_DIR}"/initramfs-linux-jarvisos*.img 2>/dev/null || true
sudo chown -R "$(id -u):$(id -g)" "${KERNEL_BACKUP_DIR}"

KERNEL_SIZE=$(du -h "${KERNEL_BACKUP_DIR}/vmlinuz-linux-jarvisos" | cut -f1)
INITRAMFS_SIZE=$(du -h "${KERNEL_BACKUP_DIR}/initramfs-linux-jarvisos.img" | cut -f1)

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 3b complete: linux-jarvisos built and installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Kernel release : ${KERNELRELEASE}${NC}"
echo -e "${BLUE}Packages       : linux-jarvisos, linux-jarvisos-headers${NC}"
echo -e "${BLUE}Kernel image   : vmlinuz-linux-jarvisos (${KERNEL_SIZE})${NC}"
echo -e "${BLUE}Initramfs      : initramfs-linux-jarvisos.img (${INITRAMFS_SIZE})${NC}"
echo -e "${BLUE}Modules dir    : /usr/lib/modules/${KERNELRELEASE}${NC}"
echo ""
echo -e "${GREEN}✓ Packages installed in rootfs via pacman${NC}"
echo -e "${GREEN}✓ Calamares will install linux-jarvisos onto the target system${NC}"
echo -e "${GREEN}✓ Stock linux kernel remains for live boot hardware compatibility${NC}"
echo ""
echo -e "${BLUE}JARVIS kernel drivers included:${NC}"
echo -e "${BLUE}  jarvis.ko        — /dev/jarvis AI query/response channel${NC}"
echo -e "${BLUE}  jarvis_sysmon    — CPU/memory/thermal metrics for model selection${NC}"
echo -e "${BLUE}  jarvis_policy    — AI action security policy (SAFE/ELEVATED/DANGEROUS)${NC}"
echo -e "${BLUE}  jarvis_keys      — Kernel keyring for API-key secure storage${NC}"
