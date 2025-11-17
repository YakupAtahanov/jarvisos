#!/bin/bash
# Convert Arch rootfs directory to QCOW2 disk image
# Creates a bootable disk with partitions

set -e

ROOTFS_DIR="${1}"
QCOW2_IMAGE="${2}"
SIZE_GB="${3:-20}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -z "${ROOTFS_DIR}" ] || [ -z "${QCOW2_IMAGE}" ]; then
    echo -e "${RED}Usage: $0 <rootfs_dir> <qcow2_image> [size_gb]${NC}"
    exit 1
fi

if [ ! -d "${ROOTFS_DIR}" ]; then
    echo -e "${RED}❌ Error: Rootfs directory not found: ${ROOTFS_DIR}${NC}"
    exit 1
fi

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

echo -e "${BLUE}💾 Converting Arch rootfs to QCOW2 image...${NC}"

# Create QCOW2 image
echo -e "${BLUE}📦 Creating ${SIZE_GB}GB QCOW2 image...${NC}"
qemu-img create -f qcow2 "${QCOW2_IMAGE}" "${SIZE_GB}G"

# If user requests loop method explicitly, skip virt-make-fs
if [ -n "${USE_LOOP:-}" ]; then
    echo -e "${YELLOW}⚠️  USE_LOOP=1 set; skipping libguestfs and using loop-device method${NC}"
elif command -v virt-make-fs &> /dev/null; then
    echo -e "${BLUE}🔧 Using virt-make-fs to create filesystem...${NC}"
    echo -e "${BLUE}🧹 Staging clean rootfs (excluding /proc,/sys,/dev,/run, pacman cache)...${NC}"
    # Create staging dir on the same filesystem as ROOTFS_DIR (avoids small /tmp)
    STAGE_PARENT="$(dirname "${ROOTFS_DIR}")"
    STAGE_DIR="$(mktemp -d -p "${STAGE_PARENT}" .stage.XXXXXX)"
    # Prefer rsync with excludes; fallback to cp -a then prune
    if command -v rsync >/dev/null 2>&1; then
        sudo rsync -aHAX --delete --numeric-ids \
            --exclude='/proc/*' \
            --exclude='/sys/*' \
            --exclude='/dev/*' \
            --exclude='/run/*' \
            --exclude='/var/cache/pacman/pkg/*' \
            "${ROOTFS_DIR}/" "${STAGE_DIR}/"
    else
        echo -e "${YELLOW}⚠️  rsync not found; falling back to cp -a and pruning excludes${NC}"
        sudo cp -a "${ROOTFS_DIR}/." "${STAGE_DIR}/"
        sudo rm -rf "${STAGE_DIR}/proc" "${STAGE_DIR}/sys" "${STAGE_DIR}/dev" "${STAGE_DIR}/run" \
            "${STAGE_DIR}/var/cache/pacman/pkg" 2>/dev/null || true
    fi
    echo -e "${BLUE}🔐 virt-make-fs needs root to read protected dirs (du)${NC}"
    # Use XFS to match kernel support in initramfs reliably
    sudo virt-make-fs --format=qcow2 --size="${SIZE_GB}G" --type=xfs \
        --label="JARVISOS" \
        "${STAGE_DIR}" "${QCOW2_IMAGE}.tmp"
    sudo rm -rf "${STAGE_DIR}"
    sudo mv "${QCOW2_IMAGE}.tmp" "${QCOW2_IMAGE}"
    sudo chown "$(id -u)":"$(id -g)" "${QCOW2_IMAGE}"
    echo -e "${GREEN}✅ QCOW2 image created!${NC}"
    exit 0
fi

# Fallback: Use loop device (requires root)
echo -e "${YELLOW}⚠️  virt-make-fs not found, using loop device method${NC}"
echo -e "${YELLOW}⚠️  This requires root privileges${NC}"

# Create temporary raw image
RAW_IMAGE="${QCOW2_IMAGE%.qcow2}.raw"
qemu-img create -f raw "${RAW_IMAGE}" "${SIZE_GB}G"

# Partition the image
echo -e "${BLUE}🔧 Partitioning disk...${NC}"
LOOP_DEV=$(sudo losetup --find --show "${RAW_IMAGE}")
sudo parted -s "${LOOP_DEV}" mklabel msdos
sudo parted -s "${LOOP_DEV}" mkpart primary ext4 1MiB 100%

# Format partition
echo -e "${BLUE}📝 Formatting partition...${NC}"
PART_DEV="${LOOP_DEV}p1"
sudo mkfs.ext4 -F "${PART_DEV}"

# Mount and copy rootfs
echo -e "${BLUE}📋 Copying rootfs to image...${NC}"
MNT_DIR=$(mktemp -d)
sudo mount "${PART_DEV}" "${MNT_DIR}"
sudo cp -a "${ROOTFS_DIR}"/* "${MNT_DIR}/"
sudo umount "${MNT_DIR}"
rmdir "${MNT_DIR}"

# Cleanup loop device
sudo losetup -d "${LOOP_DEV}"

# Convert raw to qcow2
echo -e "${BLUE}🔄 Converting raw to QCOW2...${NC}"
qemu-img convert -f raw -O qcow2 "${RAW_IMAGE}" "${QCOW2_IMAGE}"
rm -f "${RAW_IMAGE}"

echo -e "${GREEN}✅ QCOW2 image created: ${QCOW2_IMAGE}${NC}"

