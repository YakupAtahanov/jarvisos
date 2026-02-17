#!/bin/bash
# Step 6: Rebuild SquashFS
# Compresses the modified rootfs back into a SquashFS file

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
ISO_EXTRACT_DIR="${BUILD_DIR}${ISO_EXTRACT_DIR}"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"

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

# Check if step 1 was completed (ISO extracted)
if [ ! -d "${ISO_EXTRACT_DIR}" ] || [ -z "$(ls -A "${ISO_EXTRACT_DIR}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: ISO not extracted. Please run step 1 first${NC}" >&2
    exit 1
fi

# Find original SquashFS file
SQUASHFS_FILE=$(find "${ISO_EXTRACT_DIR}" -type f -iname "airootfs.sfs" | head -1)

if [ -z "${SQUASHFS_FILE}" ] || [ ! -f "${SQUASHFS_FILE}" ]; then
    echo -e "${RED}Error: Could not find airootfs.sfs in extracted ISO${NC}" >&2
    echo -e "${YELLOW}Looking for SquashFS files:${NC}"
    find "${ISO_EXTRACT_DIR}" -type f -iname "*.sfs" | head -5 || echo "  None found"
    exit 1
fi

# Check if mksquashfs is available
if ! command -v mksquashfs &> /dev/null; then
    echo -e "${RED}Error: mksquashfs not found. Please install squashfs-tools${NC}" >&2
    echo -e "${YELLOW}Install: $(pkg_install_hint squashfs-tools)${NC}"
    exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 6: Rebuilding SquashFS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}Output: ${SQUASHFS_FILE}${NC}"

# Unmount all filesystems before rebuilding
echo -e "${BLUE}Unmounting virtual filesystems...${NC}"
sudo umount -l "${SQUASHFS_ROOTFS}/var/lib/pacman/sync" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/tmp" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/dev/shm" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/dev" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/run" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/sys" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}/proc" 2>/dev/null || true
sudo umount -l "${SQUASHFS_ROOTFS}" 2>/dev/null || true

# Wait a moment for lazy unmounts to complete
sleep 1

# Verify nothing is still mounted
if mount | grep -q "${SQUASHFS_ROOTFS}"; then
    echo -e "${YELLOW}Warning: Some filesystems may still be mounted:${NC}"
    mount | grep "${SQUASHFS_ROOTFS}"
    echo -e "${YELLOW}Attempting force unmount...${NC}"
    mount | grep "${SQUASHFS_ROOTFS}" | awk '{print $3}' | xargs -r sudo umount -f 2>/dev/null || true
fi

# CRITICAL: Clean virtual filesystem directories that cause mksquashfs to hang
# These directories shouldn't be in the SquashFS anyway (created at runtime)
echo -e "${BLUE}Cleaning virtual filesystem directories...${NC}"
sudo rm -rf "${SQUASHFS_ROOTFS}/proc"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/sys"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/dev"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/run"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/tmp"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/var/lib/pacman/sync"/* 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/var/tmp"/* 2>/dev/null || true

# Keep directory structure but ensure they're empty
sudo mkdir -p "${SQUASHFS_ROOTFS}/proc" "${SQUASHFS_ROOTFS}/sys" "${SQUASHFS_ROOTFS}/dev" \
    "${SQUASHFS_ROOTFS}/run" "${SQUASHFS_ROOTFS}/tmp" \
    "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg" \
    "${SQUASHFS_ROOTFS}/var/lib/pacman/sync" \
    "${SQUASHFS_ROOTFS}/var/tmp" 2>/dev/null || true

# Remove DNS resolution file copy (not needed in SquashFS)
sudo rm -f "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true

# Create backup of original SquashFS
SQUASHFS_BACKUP="${SQUASHFS_FILE}.backup"
if [ ! -f "${SQUASHFS_BACKUP}" ]; then
    echo -e "${BLUE}Creating backup of original SquashFS...${NC}"
    sudo cp "${SQUASHFS_FILE}" "${SQUASHFS_BACKUP}"
fi

# Create new SquashFS file
SQUASHFS_DIR=$(dirname "${SQUASHFS_FILE}")
NEW_SQUASHFS="${SQUASHFS_DIR}/airootfs.sfs.new"

# Use xz compression (most common for Arch ISOs)
# -comp xz -b 1M gives good compression ratio
# CRITICAL: Exclude virtual filesystems and cache directories
echo -e "${BLUE}Compressing SquashFS (this may take a while)...${NC}"
echo -e "${BLUE}This can take 5-15 minutes depending on rootfs size...${NC}"

# Show rootfs size before compression
ROOTFS_SIZE=$(sudo du -sh "${SQUASHFS_ROOTFS}" 2>/dev/null | cut -f1)
echo -e "${BLUE}Rootfs size: ${ROOTFS_SIZE}${NC}"

# Build SquashFS with xz compression
# Exclude virtual filesystems, cache, and temporary directories
if sudo mksquashfs "${SQUASHFS_ROOTFS}" "${NEW_SQUASHFS}" \
    -comp xz \
    -b 1M \
    -noappend \
    -e boot/grub/grubenv \
    -e proc \
    -e sys \
    -e dev \
    -e run \
    -e tmp \
    -e var/cache/pacman/pkg \
    -e var/lib/pacman/sync \
    -e var/tmp \
    -e .snapshots \
    -e lost+found \
    2>&1 | tee "${BUILD_DIR}/squashfs-build.log"; then
    echo -e "${GREEN}✓ SquashFS compression complete${NC}"
else
    BUILD_EXIT=$?
    echo -e "${RED}Error: mksquashfs failed with exit code ${BUILD_EXIT}${NC}" >&2
    echo -e "${YELLOW}Check log: ${BUILD_DIR}/squashfs-build.log${NC}"
    exit 1
fi

# Verify the new SquashFS was created
if [ ! -f "${NEW_SQUASHFS}" ]; then
    echo -e "${RED}Error: Failed to create new SquashFS${NC}" >&2
    exit 1
fi

# Show new SquashFS size
NEW_SIZE=$(du -h "${NEW_SQUASHFS}" 2>/dev/null | cut -f1)
ORIGINAL_SIZE=$(du -h "${SQUASHFS_FILE}" 2>/dev/null | cut -f1)
echo -e "${BLUE}Original SquashFS: ${ORIGINAL_SIZE}${NC}"
echo -e "${BLUE}New SquashFS: ${NEW_SIZE}${NC}"

# Replace original SquashFS
echo -e "${BLUE}Replacing original SquashFS...${NC}"
sudo mv "${NEW_SQUASHFS}" "${SQUASHFS_FILE}"
sudo chmod 644 "${SQUASHFS_FILE}"

# Regenerate checksum
echo -e "${BLUE}Regenerating checksum...${NC}"
SQUASHFS_DIR=$(dirname "${SQUASHFS_FILE}")
SHA512_FILE=$(find "${SQUASHFS_DIR}" -type f -iname "airootfs.sha512" | head -1)
if [ -z "${SHA512_FILE}" ]; then
    # Create checksum file if it doesn't exist
    SHA512_FILE="${SQUASHFS_DIR}/airootfs.sha512"
fi
sha512sum "${SQUASHFS_FILE}" | sudo tee "${SHA512_FILE}" > /dev/null

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 6 complete: SquashFS rebuilt${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}SquashFS: ${SQUASHFS_FILE}${NC}"
echo -e "${BLUE}Size: ${NEW_SIZE}${NC}"
echo -e "${BLUE}Backup: ${SQUASHFS_BACKUP}${NC}"
