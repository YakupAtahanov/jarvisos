#!/bin/bash
# Step 7: Rebuild ISO
# Creates the final bootable ISO from the modified files

set -e

# Source config file
source build.config

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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if step 1 was completed (ISO extracted)
if [ ! -d "${ISO_EXTRACT_DIR}" ] || [ -z "$(ls -A "${ISO_EXTRACT_DIR}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: ISO not extracted. Please run step 1 first${NC}" >&2
    exit 1
fi

# Check if step 6 was completed (SquashFS rebuilt)
SQUASHFS_FILE=$(find "${ISO_EXTRACT_DIR}" -type f -iname "airootfs.sfs" | head -1)
if [ -z "${SQUASHFS_FILE}" ] || [ ! -f "${SQUASHFS_FILE}" ]; then
    echo -e "${RED}Error: Could not find airootfs.sfs. Please run step 6 first${NC}" >&2
    exit 1
fi

# Check if xorriso is available
if ! command -v xorriso &> /dev/null; then
    echo -e "${RED}Error: xorriso not found. Please install libisoburn${NC}" >&2
    echo -e "${YELLOW}Install with: sudo dnf install libisoburn${NC}"
    exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 7: Rebuilding ISO${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Source: ${ISO_EXTRACT_DIR}${NC}"

# Create output ISO filename
OUTPUT_ISO="${BUILD_DIR}/jarvisos-$(date +%Y%m%d)-x86_64.iso"
OUTPUT_ISO_ABS=$(cd "${BUILD_DIR}" && pwd)/jarvisos-$(date +%Y%m%d)-x86_64.iso

echo -e "${BLUE}Output: ${OUTPUT_ISO_ABS}${NC}"

# Change to ISO extract directory
cd "${ISO_EXTRACT_DIR}" || exit 1

# Find boot files (Arch ISO uses boot/syslinux/ structure)
ISOLINUX_BIN=""
ISOHDPFX_BIN=""
BOOT_CAT=""
EFI_IMG=""

echo -e "${BLUE}Searching for boot files...${NC}"

# Check for isolinux.bin in various locations
for path in "boot/syslinux/isolinux.bin" "isolinux/isolinux.bin" "syslinux/isolinux.bin"; do
    if [ -f "${path}" ]; then
        ISOLINUX_BIN="${path}"
        echo -e "${GREEN}✓ Found isolinux.bin: ${path}${NC}"
        break
    fi
done

# Find isohdpfx.bin (MBR boot sector)
for path in "boot/syslinux/isohdpfx.bin" "isolinux/isohdpfx.bin" "syslinux/isohdpfx.bin"; do
    if [ -f "${path}" ]; then
        ISOHDPFX_BIN="${path}"
        echo -e "${GREEN}✓ Found isohdpfx.bin: ${path}${NC}"
        break
    fi
done

# Find boot.cat
for path in "boot/syslinux/boot.cat" "isolinux/boot.cat" "syslinux/boot.cat"; do
    if [ -f "${path}" ]; then
        BOOT_CAT="${path}"
        echo -e "${GREEN}✓ Found boot.cat: ${path}${NC}"
        break
    fi
done

# Find EFI boot image (case-insensitive search)
for path in "EFI/archiso/efiboot.img" "EFI/archiso/EFIBOOT.IMG" "EFI/boot/efiboot.img" "EFI/boot/EFIBOOT.IMG"; do
    if [ -f "${path}" ]; then
        EFI_IMG="${path}"
        echo -e "${GREEN}✓ Found EFI boot image: ${path}${NC}"
        break
    fi
done

# Also search case-insensitively
if [ -z "${EFI_IMG}" ]; then
    EFI_FOUND=$(find . -iname "efiboot.img" -type f 2>/dev/null | head -1)
    if [ -n "${EFI_FOUND}" ]; then
        EFI_IMG="${EFI_FOUND#./}"  # Remove leading ./
        echo -e "${GREEN}✓ Found EFI boot image: ${EFI_IMG}${NC}"
    fi
fi

# Verify required boot files are found
if [ -z "${ISOLINUX_BIN}" ] || [ -z "${ISOHDPFX_BIN}" ]; then
    echo -e "${RED}Error: Required boot files not found!${NC}" >&2
    echo -e "${YELLOW}Missing:${NC}"
    [ -z "${ISOLINUX_BIN}" ] && echo -e "${YELLOW}  - isolinux.bin${NC}"
    [ -z "${ISOHDPFX_BIN}" ] && echo -e "${YELLOW}  - isohdpfx.bin${NC}"
    echo -e "${YELLOW}Available boot files:${NC}"
    find . -name "*.bin" -o -name "*.cat" 2>/dev/null | head -10
    exit 1
fi

# Regenerate boot.cat if it doesn't exist or is old
# boot.cat is the boot catalog needed for BIOS boot
if [ ! -f "${BOOT_CAT:-boot/syslinux/boot.cat}" ] || [ "${ISOLINUX_BIN}" -nt "${BOOT_CAT:-boot/syslinux/boot.cat}" ]; then
    echo -e "${BLUE}Regenerating boot.cat...${NC}"
    BOOT_CAT_DIR=$(dirname "${BOOT_CAT:-boot/syslinux/boot.cat}")
    mkdir -p "${BOOT_CAT_DIR}"
    # boot.cat will be created by xorriso, but we ensure the directory exists
    touch "${BOOT_CAT:-boot/syslinux/boot.cat}" 2>/dev/null || true
fi

# Build ISO with proper boot structure
echo -e "${BLUE}Building ISO...${NC}"

if [ -n "${ISOLINUX_BIN}" ] && [ -n "${ISOHDPFX_BIN}" ] && [ -n "${EFI_IMG}" ] && [ -f "${EFI_IMG}" ]; then
    # Dual boot (BIOS + UEFI) - preferred
    echo -e "${BLUE}Using dual boot structure (BIOS + UEFI)...${NC}"
    XORRISO_OUTPUT=$(xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "JARVISOS_$(date +%Y.%m.%d)" \
        -eltorito-boot "${ISOLINUX_BIN}" \
        -eltorito-catalog "${BOOT_CAT:-boot/syslinux/boot.cat}" \
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
        echo -e "${RED}Error: xorriso failed with exit code ${XORRISO_EXIT}${NC}" >&2
        echo -e "${YELLOW}Full error output:${NC}"
        echo "${XORRISO_OUTPUT}" | grep -E "error|Error|ERROR|fail|Fail|FAIL" || echo "${XORRISO_OUTPUT}"
        exit 1
    fi
elif [ -n "${ISOLINUX_BIN}" ] && [ -n "${ISOHDPFX_BIN}" ]; then
    # BIOS boot only
    echo -e "${BLUE}Using BIOS boot structure (UEFI boot files not found)...${NC}"
    XORRISO_OUTPUT=$(xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "JARVISOS_$(date +%Y.%m.%d)" \
        -eltorito-boot "${ISOLINUX_BIN}" \
        -eltorito-catalog "${BOOT_CAT:-boot/syslinux/boot.cat}" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX_BIN}" \
        -output "${OUTPUT_ISO_ABS}" \
        . 2>&1)
    
    XORRISO_EXIT=$?
    echo "${XORRISO_OUTPUT}" | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" || true
    
    if [ ${XORRISO_EXIT} -ne 0 ]; then
        echo -e "${RED}Error: xorriso failed with exit code ${XORRISO_EXIT}${NC}" >&2
        echo -e "${YELLOW}Full error output:${NC}"
        echo "${XORRISO_OUTPUT}" | grep -E "error|Error|ERROR|fail|Fail|FAIL" || echo "${XORRISO_OUTPUT}"
        exit 1
    fi
else
    echo -e "${RED}Error: Insufficient boot files found${NC}" >&2
    exit 1
fi

# Verify ISO was created
if [ ! -f "${OUTPUT_ISO_ABS}" ]; then
    echo -e "${RED}Error: ISO file was not created!${NC}" >&2
    exit 1
fi

# Show ISO information
ISO_SIZE=$(du -h "${OUTPUT_ISO_ABS}" 2>/dev/null | cut -f1)
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 7 complete: ISO rebuilt${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}ISO: ${OUTPUT_ISO_ABS}${NC}"
echo -e "${BLUE}Size: ${ISO_SIZE}${NC}"
echo -e "${BLUE}Boot: ${ISOLINUX_BIN}${NC}"
if [ -n "${EFI_IMG}" ]; then
    echo -e "${BLUE}UEFI: ${EFI_IMG}${NC}"
fi
echo ""
echo -e "${GREEN}✓ ISO is ready for testing!${NC}"
echo -e "${BLUE}You can now boot from this ISO to test KDE Plasma Wayland${NC}"
