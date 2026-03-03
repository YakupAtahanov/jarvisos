#!/bin/bash
# Step 3b: Build linux-jarvisos custom kernel
#
# Compiles the JARVIS-integrated Linux kernel (7.0.0-rc2) from the linux/
# source tree and installs it into the rootfs alongside the stock Arch linux
# kernel.
#
# Design:
#   - Stock linux kernel (from step 3) stays for maximum live boot hardware compat.
#   - linux-jarvisos kernel (from this step) is what Calamares installs on the
#     target system — it carries the JARVIS AI kernel drivers (jarvis.ko etc.).
#   - Both kernels live in the same rootfs / squashfs.
#
# Prerequisites: step 2 (rootfs extracted) + step 3 (packages + mkinitcpio.conf)
#
# Host build tools required:
#   Arch:         sudo pacman -S base-devel bc flex bison openssl libelf pahole
#   Ubuntu/Debian: sudo apt-get install build-essential bc flex bison \
#                     libssl-dev libelf-dev dwarves

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
echo -e "${BLUE}Step 3b: Building linux-jarvisos custom kernel${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Kernel source : ${KERNEL_SRC}${NC}"
echo -e "${BLUE}Rootfs        : ${SQUASHFS_ROOTFS}${NC}"
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
KERNEL_VERSION=$(make -s kernelversion 2>/dev/null || echo "unknown")
KERNELRELEASE="${KERNEL_VERSION}${LOCALVERSION}"
echo -e "${BLUE}Kernel release: ${KERNELRELEASE}${NC}"
echo ""

# ── Configure kernel ──────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Configuring linux-jarvisos...${NC}"

if [ -f ".config" ]; then
    echo -e "${BLUE}Existing .config found — updating with olddefconfig...${NC}"
    make olddefconfig LOCALVERSION="${LOCALVERSION}"
else
    echo -e "${BLUE}Generating baseline config from x86_64_defconfig...${NC}"
    make x86_64_defconfig LOCALVERSION="${LOCALVERSION}"
fi

# Apply JARVIS-specific options via scripts/config
echo -e "${BLUE}Applying JARVIS kernel options...${NC}"

# ------------------------------------------------------------------
# Core requirements for the JARVIS driver
# ------------------------------------------------------------------
scripts/config --enable  CONFIG_MISC_DEVICES        # JARVIS core uses misc device
scripts/config --enable  CONFIG_SYSFS               # sysfs attributes
scripts/config --enable  CONFIG_KEYS                # kernel keyring (JARVIS_KEYS)
scripts/config --enable  CONFIG_THERMAL             # thermal zones (JARVIS_SYSMON)
scripts/config --enable  CONFIG_THERMAL_HWMON       # hwmon thermal reporting

# ------------------------------------------------------------------
# JARVIS driver and sub-modules
# ------------------------------------------------------------------
scripts/config --module  CONFIG_JARVIS              # jarvis.ko (loadable module)
scripts/config --enable  CONFIG_JARVIS_SYSMON       # CPU/mem/thermal metrics
scripts/config --enable  CONFIG_JARVIS_POLICY       # AI action security policy engine
scripts/config --enable  CONFIG_JARVIS_KEYS         # Kernel keyring API-key storage

# DIBS zero-copy integration (optional — depends on DIBS driver in tree)
if grep -q "config DIBS" "${KERNEL_SRC}/drivers/dibs/Kconfig" 2>/dev/null; then
    scripts/config --module CONFIG_DIBS
    scripts/config --enable CONFIG_JARVIS_DIBS
    echo -e "${GREEN}  ✓ DIBS zero-copy integration enabled${NC}"
else
    scripts/config --disable CONFIG_JARVIS_DIBS
    echo -e "${YELLOW}  ⚠ DIBS not found — CONFIG_JARVIS_DIBS disabled${NC}"
fi

# ------------------------------------------------------------------
# Security & audit (needed by ELEVATED/DANGEROUS policy tiers)
# ------------------------------------------------------------------
scripts/config --enable  CONFIG_SECURITY
scripts/config --enable  CONFIG_AUDIT

# ------------------------------------------------------------------
# Networking (required by systemd and the OS in general)
# ------------------------------------------------------------------
scripts/config --enable  CONFIG_NET
scripts/config --enable  CONFIG_INET
scripts/config --enable  CONFIG_UNIX
scripts/config --enable  CONFIG_IPV6

# ------------------------------------------------------------------
# Live boot / squashfs (CRITICAL for archiso live boot hook)
# ------------------------------------------------------------------
scripts/config --enable  CONFIG_SQUASHFS
scripts/config --enable  CONFIG_SQUASHFS_ZSTD       # zstd-compressed squashfs
scripts/config --enable  CONFIG_OVERLAY_FS           # overlayfs for live boot

# ------------------------------------------------------------------
# USB boot support (needed for live USB)
# ------------------------------------------------------------------
scripts/config --enable  CONFIG_USB_SUPPORT
scripts/config --enable  CONFIG_USB_XHCI_HCD
scripts/config --enable  CONFIG_USB_EHCI_HCD
scripts/config --enable  CONFIG_USB_STORAGE
scripts/config --enable  CONFIG_USB_UAS

# ------------------------------------------------------------------
# Storage (SATA, NVMe)
# ------------------------------------------------------------------
scripts/config --enable  CONFIG_ATA
scripts/config --enable  CONFIG_SATA_AHCI
scripts/config --enable  CONFIG_BLK_DEV_NVME

# ------------------------------------------------------------------
# Filesystems (needed for installer target)
# ------------------------------------------------------------------
scripts/config --enable  CONFIG_EXT4_FS
scripts/config --enable  CONFIG_VFAT_FS
scripts/config --enable  CONFIG_BTRFS_FS

# Resolve any new symbols introduced by the options above
make olddefconfig LOCALVERSION="${LOCALVERSION}"

echo -e "${GREEN}✓ Kernel configured with JARVIS options${NC}"
echo ""

# ── Compile kernel ────────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Compiling kernel (${NCPU} threads)...${NC}"
echo -e "${YELLOW}Time estimate: 20–60 min (first build). Grab a coffee.${NC}"
echo ""

make -j"${NCPU}" LOCALVERSION="${LOCALVERSION}" bzImage modules

echo ""
echo -e "${GREEN}✓ Kernel compilation complete${NC}"

# ── Install kernel + modules into rootfs ──────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Installing into rootfs...${NC}"

# Temp staging dir for modules (keeps host /lib/modules clean)
STAGING_DIR=$(mktemp -d)
trap 'rm -rf "${STAGING_DIR}"' EXIT

# Install modules to staging area
echo -e "${BLUE}Installing kernel modules to staging dir...${NC}"
make modules_install \
    LOCALVERSION="${LOCALVERSION}" \
    INSTALL_MOD_PATH="${STAGING_DIR}" \
    INSTALL_MOD_STRIP=1

BZIMAGE="${KERNEL_SRC}/arch/x86/boot/bzImage"
if [ ! -f "${BZIMAGE}" ]; then
    echo -e "${RED}FATAL: bzImage not found at ${BZIMAGE}${NC}" >&2
    exit 1
fi

# Install kernel image into rootfs
echo -e "${BLUE}Installing vmlinuz-linux-jarvisos → /boot/vmlinuz-linux-jarvisos${NC}"
sudo cp "${BZIMAGE}" "${SQUASHFS_ROOTFS}/boot/vmlinuz-linux-jarvisos"
sudo chmod 644 "${SQUASHFS_ROOTFS}/boot/vmlinuz-linux-jarvisos"

# Sync modules into rootfs (strip dangling build/source symlinks pointing to host paths)
MOD_DEST="${SQUASHFS_ROOTFS}/usr/lib/modules/${KERNELRELEASE}"
echo -e "${BLUE}Syncing kernel modules → /usr/lib/modules/${KERNELRELEASE}${NC}"
sudo mkdir -p "${MOD_DEST}"
sudo rsync -a --delete \
    "${STAGING_DIR}/lib/modules/${KERNELRELEASE}/" \
    "${MOD_DEST}/"

# Remove host-path symlinks (build/source point to the host build tree, useless in rootfs)
sudo rm -f "${MOD_DEST}/build" "${MOD_DEST}/source"

echo -e "${GREEN}✓ Kernel image installed: /boot/vmlinuz-linux-jarvisos${NC}"
echo -e "${GREEN}✓ Modules installed: /usr/lib/modules/${KERNELRELEASE}${NC}"

# ── mkinitcpio preset ─────────────────────────────────────────────────────────
echo -e "${BLUE}Creating mkinitcpio preset for linux-jarvisos...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/mkinitcpio.d"

sudo tee "${SQUASHFS_ROOTFS}/etc/mkinitcpio.d/linux-jarvisos.preset" > /dev/null << EOF
# mkinitcpio preset file for 'linux-jarvisos'
# JARVIS OS — custom kernel with AI/system integration drivers

# System-wide mkinitcpio.conf is used for hook and module selection.
# In the live environment this includes the archiso/memdisk hooks.
# Calamares's initcpiocfg module rewrites mkinitcpio.conf on the
# installed system to remove live-only hooks before regenerating.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-jarvisos"

PRESETS=('default' 'fallback')

default_image="/boot/initramfs-linux-jarvisos.img"

fallback_image="/boot/initramfs-linux-jarvisos-fallback.img"
fallback_options="-S autodetect"
EOF

echo -e "${GREEN}✓ Preset created: /etc/mkinitcpio.d/linux-jarvisos.preset${NC}"

# ── Generate initramfs ────────────────────────────────────────────────────────
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
echo -e "${BLUE}Kernel image   : vmlinuz-linux-jarvisos (${KERNEL_SIZE})${NC}"
echo -e "${BLUE}Initramfs      : initramfs-linux-jarvisos.img (${INITRAMFS_SIZE})${NC}"
echo -e "${BLUE}Modules dir    : /usr/lib/modules/${KERNELRELEASE}${NC}"
echo ""
echo -e "${GREEN}✓ Calamares will install linux-jarvisos onto the target system${NC}"
echo -e "${GREEN}✓ Stock linux kernel remains for live boot hardware compatibility${NC}"
echo ""
echo -e "${BLUE}JARVIS kernel drivers included:${NC}"
echo -e "${BLUE}  jarvis.ko        — /dev/jarvis AI query/response channel${NC}"
echo -e "${BLUE}  jarvis_sysmon    — CPU/memory/thermal metrics for model selection${NC}"
echo -e "${BLUE}  jarvis_policy    — AI action security policy (SAFE/ELEVATED/DANGEROUS)${NC}"
echo -e "${BLUE}  jarvis_keys      — Kernel keyring for API-key secure storage${NC}"
