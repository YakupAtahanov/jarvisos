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

# Fixed volume ID for consistency (used with archisolabel)
JARVISOS_VOLID="JARVISOS_202601"

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

# Remove existing ISO if it exists (might be locked or corrupted)
if [ -f "${OUTPUT_ISO_ABS}" ]; then
    echo -e "${YELLOW}Removing existing ISO file...${NC}"
    rm -f "${OUTPUT_ISO_ABS}" || {
        echo -e "${RED}Error: Cannot remove existing ISO file. It may be in use.${NC}" >&2
        exit 1
    }
fi

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

# Check for EFI boot image - use original if it exists, otherwise create from EFI/BOOT/
# Arch Linux ISO includes efiboot.img with full boot menu configuration
# Boot menu files are in loader/ directory in ISO root and need to be in EFI/archiso/loader/ inside efiboot.img
EFI_BOOT_DIR="EFI/BOOT"
EFI_ARCHISO_DIR="EFI/archiso"
EFI_IMG_PATH="${EFI_ARCHISO_DIR}/efiboot.img"
LOADER_DIR="loader"
LOADER_ENTRIES_DIR="${LOADER_DIR}/entries"

# Function to fix EFI boot structure for systemd-boot
# systemd-boot expects loader configuration at /loader/ (root of EFI partition), not /EFI/archiso/loader/
fix_efi_boot_structure() {
    local EFI_MOUNT="$1"
    
    if [ -z "${EFI_MOUNT}" ] || [ ! -d "${EFI_MOUNT}" ]; then
        echo -e "${RED}Error: Invalid EFI mount point${NC}" >&2
        return 1
    fi
    
    echo -e "${BLUE}Fixing EFI boot structure for systemd-boot...${NC}"
    
    # 1. Copy loader configuration to root level
    # Only copy if not already at root level (to avoid unnecessary operations)
    if [ -f "${EFI_MOUNT}/EFI/archiso/loader/loader.conf" ] && [ ! -f "${EFI_MOUNT}/loader/loader.conf" ]; then
        sudo mkdir -p "${EFI_MOUNT}/loader/entries"
        sudo cp "${EFI_MOUNT}/EFI/archiso/loader/loader.conf" "${EFI_MOUNT}/loader/loader.conf" || true
        echo -e "${GREEN}✓ Copied loader.conf to root level${NC}"
    elif [ -f "${EFI_MOUNT}/loader/loader.conf" ]; then
        echo -e "${BLUE}Loader.conf already at root level${NC}"
    fi
    
    # Copy boot menu entries to root level
    if [ -d "${EFI_MOUNT}/EFI/archiso/loader/entries" ]; then
        sudo mkdir -p "${EFI_MOUNT}/loader/entries"
        sudo cp -r "${EFI_MOUNT}/EFI/archiso/loader/entries"/* "${EFI_MOUNT}/loader/entries/" 2>/dev/null || true
        ENTRY_COUNT=$(ls -1 "${EFI_MOUNT}/loader/entries"/*.conf 2>/dev/null | wc -l)
        if [ "${ENTRY_COUNT}" -gt 0 ]; then
            echo -e "${GREEN}✓ Copied ${ENTRY_COUNT} boot entries to root level${NC}"
        fi
    elif [ -d "${EFI_MOUNT}/loader/entries" ]; then
        ENTRY_COUNT=$(ls -1 "${EFI_MOUNT}/loader/entries"/*.conf 2>/dev/null | wc -l)
        if [ "${ENTRY_COUNT}" -gt 0 ]; then
            echo -e "${BLUE}Boot entries already at root level (${ENTRY_COUNT} entries)${NC}"
        fi
    fi
    
    # 2. Detect kernel file location
    KERNEL_PATH=""
    INITRD_PATH=""
    
    # Check inside efiboot.img first
    if [ -f "${EFI_MOUNT}/EFI/archiso/boot/x86_64/vmlinuz-linux" ]; then
        KERNEL_PATH="/EFI/archiso/boot/x86_64/vmlinuz-linux"
        INITRD_PATH="/EFI/archiso/boot/x86_64/initramfs-linux.img"
        echo -e "${BLUE}Found kernel inside efiboot.img at ${KERNEL_PATH}${NC}"
    # Check ISO root paths (these won't work from efiboot.img, but we'll try to update paths anyway)
    elif [ -f "arch/boot/x86_64/vmlinuz-linux" ]; then
        KERNEL_PATH="/arch/boot/x86_64/vmlinuz-linux"
        INITRD_PATH="/arch/boot/x86_64/initramfs-linux.img"
        echo -e "${BLUE}Found kernel in ISO root at ${KERNEL_PATH}${NC}"
    # Check EFI/BOOT as fallback
    elif [ -f "${EFI_MOUNT}/EFI/BOOT/vmlinuz-linux" ]; then
        KERNEL_PATH="/EFI/BOOT/vmlinuz-linux"
        INITRD_PATH="/EFI/BOOT/initramfs-linux.img"
        echo -e "${BLUE}Found kernel in EFI/BOOT at ${KERNEL_PATH}${NC}"
    else
        echo -e "${YELLOW}⚠ Could not detect kernel location, boot entries may need manual path updates${NC}"
    fi
    
    # 3. Fix boot entry paths to match actual file locations (/arch/boot/x86_64/)
    if [ -d "${EFI_MOUNT}/loader/entries" ]; then
        echo -e "${BLUE}Fixing boot entry paths in efiboot.img...${NC}"
        for ENTRY_FILE in "${EFI_MOUNT}/loader/entries"/*.conf; do
            if [ -f "${ENTRY_FILE}" ]; then
                # Fix linux path to /arch/boot/x86_64/
                sudo sed -i 's|^linux[[:space:]]*/.*/boot/|linux    /arch/boot/|' "${ENTRY_FILE}" 2>/dev/null || true
                # Fix initrd path to /arch/boot/x86_64/
                sudo sed -i 's|^initrd[[:space:]]*/.*/boot/|initrd   /arch/boot/|' "${ENTRY_FILE}" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✓ Fixed boot entry paths${NC}"
    fi
    
    # 3.5. Fix volume ID in boot entries (use archisolabel with volume label)
    if [ -d "${EFI_MOUNT}/loader/entries" ]; then
        echo -e "${BLUE}Updating boot entry volume ID...${NC}"
        for ENTRY_FILE in "${EFI_MOUNT}/loader/entries"/*.conf; do
            if [ -f "${ENTRY_FILE}" ]; then
                # Replace archisosearchuuid with archisolabel using our volume label
                sudo sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${ENTRY_FILE}" 2>/dev/null || true
                # Ensure archisolabel uses our volume label
                sudo sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${ENTRY_FILE}" 2>/dev/null || true
                # Fix options line to use archisolabel
                sudo sed -i "s|^options .*|options archisobasedir=arch archisolabel=${JARVISOS_VOLID}|g" "${ENTRY_FILE}" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}✓ Updated boot entry volume IDs${NC}"
    fi
    
    # 4. Ensure BOOTx64.EFI exists
    if [ ! -f "${EFI_MOUNT}/EFI/BOOT/BOOTx64.EFI" ]; then
        # Try to copy from systemd-boot location
        if [ -f "${EFI_MOUNT}/EFI/systemd/systemd-bootx64.efi" ]; then
            sudo mkdir -p "${EFI_MOUNT}/EFI/BOOT"
            sudo cp "${EFI_MOUNT}/EFI/systemd/systemd-bootx64.efi" "${EFI_MOUNT}/EFI/BOOT/BOOTx64.EFI" || true
            echo -e "${GREEN}✓ Copied systemd-bootx64.efi to BOOTx64.EFI${NC}"
        elif [ -f "${EFI_MOUNT}/EFI/archiso/loader/loader.conf" ]; then
            # If loader.conf exists but BOOTx64.EFI doesn't, this is a problem
            echo -e "${YELLOW}⚠ BOOTx64.EFI not found and cannot be created from systemd-boot${NC}"
        fi
    else
        echo -e "${GREEN}✓ BOOTx64.EFI exists${NC}"
    fi
    
    echo -e "${GREEN}✓ EFI boot structure fixed${NC}"
}

# First, check if original efiboot.img exists from extracted ISO
if [ -f "${EFI_IMG_PATH}" ]; then
    echo -e "${GREEN}✓ Found existing EFI boot image: ${EFI_IMG_PATH}${NC}"
    
    # Verify efiboot.img contains boot menu configuration and kernel/initramfs
    EFI_MOUNT=$(mktemp -d)
    EFI_HAS_LOADER=false
    EFI_HAS_KERNEL=false
    
    if sudo mount -o loop "${EFI_IMG_PATH}" "${EFI_MOUNT}" 2>/dev/null; then
        # Check for loader entries
        if [ -d "${EFI_MOUNT}/EFI/archiso/loader/entries" ] && [ -n "$(ls -A "${EFI_MOUNT}/EFI/archiso/loader/entries" 2>/dev/null)" ]; then
            EFI_HAS_LOADER=true
            echo -e "${GREEN}✓ EFI boot image contains boot menu configuration${NC}"
        else
            echo -e "${YELLOW}⚠ EFI boot image missing boot menu configuration, will add it...${NC}"
        fi
        
        # Check for kernel/initramfs files
        if [ -f "${EFI_MOUNT}/EFI/archiso/boot/x86_64/vmlinuz-linux" ] && [ -f "${EFI_MOUNT}/EFI/archiso/boot/x86_64/initramfs-linux.img" ]; then
            EFI_HAS_KERNEL=true
            echo -e "${GREEN}✓ EFI boot image contains kernel/initramfs files${NC}"
        else
            echo -e "${YELLOW}⚠ EFI boot image missing kernel/initramfs files, will add them...${NC}"
        fi
        
        sudo umount "${EFI_MOUNT}" 2>/dev/null || sudo umount -l "${EFI_MOUNT}" 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠ Could not mount efiboot.img for verification, will ensure all files are added...${NC}"
    fi
    rmdir "${EFI_MOUNT}" 2>/dev/null || true
    
    # If loader files or kernel/initramfs are missing, copy them into efiboot.img
    if [ "${EFI_HAS_LOADER}" = false ] || [ "${EFI_HAS_KERNEL}" = false ]; then
        EFI_MOUNT=$(mktemp -d)
        
        if sudo mount -o loop "${EFI_IMG_PATH}" "${EFI_MOUNT}" 2>/dev/null; then
            # Copy loader configuration if missing
            if [ "${EFI_HAS_LOADER}" = false ] && [ -d "${LOADER_ENTRIES_DIR}" ] && [ -f "${LOADER_DIR}/loader.conf" ]; then
                echo -e "${BLUE}Copying boot menu configuration into EFI boot image...${NC}"
                # Create loader directory structure at root level (systemd-boot requirement)
                sudo mkdir -p "${EFI_MOUNT}/loader/entries"
                
                # Copy loader.conf
                if [ -f "${LOADER_DIR}/loader.conf" ]; then
                    sudo cp "${LOADER_DIR}/loader.conf" "${EFI_MOUNT}/loader/" || true
                    echo -e "${GREEN}✓ Copied loader.conf${NC}"
                fi
                
                # Copy all boot menu entries
                if [ -d "${LOADER_ENTRIES_DIR}" ]; then
                    sudo cp -r "${LOADER_ENTRIES_DIR}"/* "${EFI_MOUNT}/loader/entries/" 2>/dev/null || true
                    ENTRY_COUNT=$(ls -1 "${LOADER_ENTRIES_DIR}"/*.conf 2>/dev/null | wc -l)
                    echo -e "${GREEN}✓ Copied ${ENTRY_COUNT} boot menu entries${NC}"
                fi
            fi
            
            # Copy kernel/initramfs files if missing
            if [ "${EFI_HAS_KERNEL}" = false ]; then
                KERNEL_SRC="arch/boot/x86_64"
                KERNEL_DST="${EFI_MOUNT}/EFI/archiso/boot/x86_64"
                
                if [ -d "${KERNEL_SRC}" ]; then
                    echo -e "${BLUE}Copying kernel/initramfs files into EFI boot image...${NC}"
                    sudo mkdir -p "${KERNEL_DST}"
                    
                    # Copy kernel
                    if [ -f "${KERNEL_SRC}/vmlinuz-linux" ]; then
                        sudo cp "${KERNEL_SRC}/vmlinuz-linux" "${KERNEL_DST}/" || true
                        echo -e "${GREEN}✓ Copied vmlinuz-linux${NC}"
                    fi
                    
                    # Copy initramfs
                    if [ -f "${KERNEL_SRC}/initramfs-linux.img" ]; then
                        sudo cp "${KERNEL_SRC}/initramfs-linux.img" "${KERNEL_DST}/" || true
                        echo -e "${GREEN}✓ Copied initramfs-linux.img${NC}"
                    fi
                    
                    # Copy fallback initramfs if it exists
                    if [ -f "${KERNEL_SRC}/initramfs-linux-fallback.img" ]; then
                        sudo cp "${KERNEL_SRC}/initramfs-linux-fallback.img" "${KERNEL_DST}/" || true
                        echo -e "${GREEN}✓ Copied initramfs-linux-fallback.img${NC}"
                    fi
                    
                    # Copy microcode updates if they exist
                    if [ -f "${KERNEL_SRC}/amd-ucode.img" ]; then
                        sudo cp "${KERNEL_SRC}/amd-ucode.img" "${KERNEL_DST}/" || true
                        echo -e "${GREEN}✓ Copied amd-ucode.img${NC}"
                    fi
                    if [ -f "${KERNEL_SRC}/intel-ucode.img" ]; then
                        sudo cp "${KERNEL_SRC}/intel-ucode.img" "${KERNEL_DST}/" || true
                        echo -e "${GREEN}✓ Copied intel-ucode.img${NC}"
                    fi
                else
                    echo -e "${YELLOW}⚠ Kernel source directory not found: ${KERNEL_SRC}${NC}"
                fi
            fi
            
            # Fix EFI boot structure for systemd-boot (copy loader files to root level and update paths)
            fix_efi_boot_structure "${EFI_MOUNT}"
            
            sudo umount "${EFI_MOUNT}" 2>/dev/null || sudo umount -l "${EFI_MOUNT}" 2>/dev/null || true
            echo -e "${GREEN}✓ Updated EFI boot image${NC}"
        else
            echo -e "${YELLOW}Warning: Could not mount efiboot.img to add files${NC}"
        fi
        rmdir "${EFI_MOUNT}" 2>/dev/null || true
    fi
# If not found, create new one from EFI/BOOT/ directory (fallback scenario)
elif [ ! -f "${EFI_IMG_PATH}" ] && [ -d "${EFI_BOOT_DIR}" ]; then
    echo -e "${BLUE}Creating EFI boot image from EFI/BOOT directory...${NC}"
    
    # Check if required tools are available
    if ! command -v mkfs.fat &> /dev/null && ! command -v mkfs.vfat &> /dev/null; then
        echo -e "${YELLOW}Warning: mkfs.fat/mkfs.vfat not found. Attempting to install dosfstools...${NC}"
        if command -v dnf &> /dev/null; then
            sudo dnf install -y dosfstools 2>/dev/null || echo -e "${YELLOW}Could not install dosfstools automatically${NC}"
        elif command -v apt-get &> /dev/null; then
            sudo apt-get install -y dosfstools 2>/dev/null || echo -e "${YELLOW}Could not install dosfstools automatically${NC}"
        fi
    fi
    
    # Determine mkfs command
    MKFS_CMD=""
    if command -v mkfs.fat &> /dev/null; then
        MKFS_CMD="mkfs.fat"
    elif command -v mkfs.vfat &> /dev/null; then
        MKFS_CMD="mkfs.vfat"
    else
        echo -e "${RED}Error: mkfs.fat or mkfs.vfat not found. Please install dosfstools${NC}" >&2
        echo -e "${YELLOW}Install with: sudo dnf install dosfstools${NC}"
        exit 1
    fi
    
    # Create archiso directory if it doesn't exist
    mkdir -p "${EFI_ARCHISO_DIR}"
    
    # Create a temporary mount point
    EFI_MOUNT=$(mktemp -d)
    
    # Create FAT32 filesystem image (400MB to fit 224M initramfs + kernel + boot files)
    echo -e "${BLUE}Creating FAT32 filesystem image (400MB)...${NC}"
    dd if=/dev/zero of="${EFI_IMG_PATH}" bs=1M count=400 status=progress
    
    # Format as FAT32 with label
    ${MKFS_CMD} -F 32 -n "ARCHISO_EFI" "${EFI_IMG_PATH}" >/dev/null 2>&1 || {
        echo -e "${RED}Error: Failed to format EFI boot image${NC}" >&2
        rm -f "${EFI_IMG_PATH}"
        rmdir "${EFI_MOUNT}" 2>/dev/null || true
        exit 1
    }
    
    # Mount the image
    sudo mount -o loop "${EFI_IMG_PATH}" "${EFI_MOUNT}" || {
        echo -e "${RED}Error: Failed to mount EFI boot image${NC}" >&2
        rm -f "${EFI_IMG_PATH}"
        rmdir "${EFI_MOUNT}" 2>/dev/null || true
        exit 1
    }
    
    # Create EFI/BOOT directory structure in the image
    sudo mkdir -p "${EFI_MOUNT}/EFI/BOOT"
    
    # Copy EFI boot files
    echo -e "${BLUE}Copying EFI boot files...${NC}"
    if [ -f "${EFI_BOOT_DIR}/BOOTx64.EFI" ]; then
        sudo cp "${EFI_BOOT_DIR}/BOOTx64.EFI" "${EFI_MOUNT}/EFI/BOOT/" || true
        echo -e "${GREEN}✓ Copied BOOTx64.EFI${NC}"
    fi
    if [ -f "${EFI_BOOT_DIR}/BOOTIA32.EFI" ]; then
        sudo cp "${EFI_BOOT_DIR}/BOOTIA32.EFI" "${EFI_MOUNT}/EFI/BOOT/" || true
        echo -e "${GREEN}✓ Copied BOOTIA32.EFI${NC}"
    fi
    
    # Copy boot menu configuration (loader directory structure)
    echo -e "${BLUE}Copying boot menu configuration...${NC}"
    if [ -d "${LOADER_ENTRIES_DIR}" ] && [ -f "${LOADER_DIR}/loader.conf" ]; then
        # Create loader directory structure at root level (systemd-boot requirement)
        sudo mkdir -p "${EFI_MOUNT}/loader/entries"
        
        # Copy loader.conf
        sudo cp "${LOADER_DIR}/loader.conf" "${EFI_MOUNT}/loader/" || true
        echo -e "${GREEN}✓ Copied loader.conf${NC}"
        
        # Copy all boot menu entries
        if [ -d "${LOADER_ENTRIES_DIR}" ]; then
            sudo cp -r "${LOADER_ENTRIES_DIR}"/* "${EFI_MOUNT}/loader/entries/" 2>/dev/null || true
            ENTRY_COUNT=$(ls -1 "${LOADER_ENTRIES_DIR}"/*.conf 2>/dev/null | wc -l)
            if [ "${ENTRY_COUNT}" -gt 0 ]; then
                echo -e "${GREEN}✓ Copied ${ENTRY_COUNT} boot menu entries${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}⚠ Boot menu configuration not found in loader/ directory${NC}"
    fi
    
    # Copy kernel/initramfs files into efiboot.img
    KERNEL_SRC="arch/boot/x86_64"
    KERNEL_DST="${EFI_MOUNT}/EFI/archiso/boot/x86_64"
    
    if [ -d "${KERNEL_SRC}" ]; then
        echo -e "${BLUE}Copying kernel/initramfs files into EFI boot image...${NC}"
        sudo mkdir -p "${KERNEL_DST}"
        
        # Copy kernel
        if [ -f "${KERNEL_SRC}/vmlinuz-linux" ]; then
            sudo cp "${KERNEL_SRC}/vmlinuz-linux" "${KERNEL_DST}/" || true
            echo -e "${GREEN}✓ Copied vmlinuz-linux${NC}"
        fi
        
        # Copy initramfs
        if [ -f "${KERNEL_SRC}/initramfs-linux.img" ]; then
            sudo cp "${KERNEL_SRC}/initramfs-linux.img" "${KERNEL_DST}/" || true
            echo -e "${GREEN}✓ Copied initramfs-linux.img${NC}"
        fi
        
        # Copy fallback initramfs if it exists
        if [ -f "${KERNEL_SRC}/initramfs-linux-fallback.img" ]; then
            sudo cp "${KERNEL_SRC}/initramfs-linux-fallback.img" "${KERNEL_DST}/" || true
            echo -e "${GREEN}✓ Copied initramfs-linux-fallback.img${NC}"
        fi
        
        # Copy microcode updates if they exist
        if [ -f "${KERNEL_SRC}/amd-ucode.img" ]; then
            sudo cp "${KERNEL_SRC}/amd-ucode.img" "${KERNEL_DST}/" || true
            echo -e "${GREEN}✓ Copied amd-ucode.img${NC}"
        fi
        if [ -f "${KERNEL_SRC}/intel-ucode.img" ]; then
            sudo cp "${KERNEL_SRC}/intel-ucode.img" "${KERNEL_DST}/" || true
            echo -e "${GREEN}✓ Copied intel-ucode.img${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Kernel source directory not found: ${KERNEL_SRC}${NC}"
    fi
    
    # Fix EFI boot structure for systemd-boot (copy loader files to root level and update paths)
    fix_efi_boot_structure "${EFI_MOUNT}"
    
    # Unmount the image
    sudo umount "${EFI_MOUNT}" || {
        echo -e "${YELLOW}Warning: Failed to unmount EFI boot image, attempting force unmount...${NC}"
        sudo umount -l "${EFI_MOUNT}" 2>/dev/null || true
    }
    rmdir "${EFI_MOUNT}" 2>/dev/null || true
    
    if [ -f "${EFI_IMG_PATH}" ]; then
        echo -e "${GREEN}✓ Created EFI boot image: ${EFI_IMG_PATH}${NC}"
        if [ -d "${LOADER_ENTRIES_DIR}" ] && [ -f "${LOADER_DIR}/loader.conf" ]; then
            echo -e "${GREEN}  (Contains full boot menu configuration with all options)${NC}"
        else
            echo -e "${YELLOW}  Note: Created EFI image, but boot menu configuration was not found.${NC}"
        fi
    else
        echo -e "${RED}Error: Failed to create EFI boot image${NC}" >&2
        exit 1
    fi
fi

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

# CRITICAL FIX: Update boot entry paths to match actual file locations
echo -e "${BLUE}Fixing boot entry paths...${NC}"

# Fix paths in loader entries from /EFI/archiso/boot/ to /arch/boot/
if [ -d "loader/entries" ]; then
    for entry in loader/entries/*.conf; do
        if [ -f "${entry}" ]; then
            # Fix linux path
            sed -i 's|^linux[[:space:]]*/.*/boot/|linux    /arch/boot/|' "${entry}"
            # Fix initrd path
            sed -i 's|^initrd[[:space:]]*/.*/boot/|initrd   /arch/boot/|' "${entry}"
            # Replace archisosearchuuid with archisolabel using our volume label
            sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
            sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
            # Fix options line to use archisolabel
            sed -i "s|^options .*|options archisobasedir=arch archisolabel=${JARVISOS_VOLID}|g" "${entry}"
            echo -e "${GREEN}✓ Fixed $(basename "${entry}")${NC}"
        fi
    done
fi

# CRITICAL FIX: Create proper UUID file
echo -e "${BLUE}Fixing UUID file...${NC}"
# Remove all old UUID files (especially timestamp-based ones)
find boot/ -name "2026-*.uuid" -delete 2>/dev/null || true
# Create UUID file with volume label
echo "${JARVISOS_VOLID}" > "boot/${JARVISOS_VOLID}.uuid"
echo -e "${GREEN}✓ Created boot/${JARVISOS_VOLID}.uuid${NC}"

# CRITICAL: Also fix paths inside efiboot.img
EFI_IMG_PATH="EFI/archiso/efiboot.img"
if [ -f "${EFI_IMG_PATH}" ]; then
    echo -e "${BLUE}Fixing boot entries inside efiboot.img...${NC}"
    EFI_MOUNT=$(mktemp -d)
    
    if sudo mount -o loop "${EFI_IMG_PATH}" "${EFI_MOUNT}" 2>/dev/null; then
        # Fix paths to match actual file locations inside efiboot.img
        if [ -d "${EFI_MOUNT}/loader/entries" ]; then
            for entry in "${EFI_MOUNT}/loader/entries"/*.conf; do
                if [ -f "${entry}" ]; then
                    # Files inside efiboot.img are at /EFI/archiso/boot/x86_64/
                    sudo sed -i 's|^linux[[:space:]]*/arch/boot/|linux    /EFI/archiso/boot/|' "${entry}"
                    sudo sed -i 's|^initrd[[:space:]]*/arch/boot/|initrd   /EFI/archiso/boot/|' "${entry}"
                    # Replace archisosearchuuid with archisolabel using our volume label
                    sudo sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
                    sudo sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
                    # Fix options line to use archisolabel
                    sudo sed -i "s|^options .*|options archisobasedir=arch archisolabel=${JARVISOS_VOLID}|g" "${entry}"
                    echo -e "${GREEN}✓ Fixed $(basename "${entry}") in efiboot.img${NC}"
                fi
            done
        fi
        
        sudo umount "${EFI_MOUNT}" || sudo umount -l "${EFI_MOUNT}"
    fi
    rmdir "${EFI_MOUNT}" 2>/dev/null || true
fi

# Build ISO with proper boot structure
# CRITICAL: Use archisolabel instead of archisosearchuuid
# xorriso auto-generates timestamp UUID which we cannot control
# archisolabel uses the volume label (JARVISOS_202601) which we DO control

echo -e "${BLUE}Building ISO...${NC}"

# Ensure output directory exists
OUTPUT_DIR=$(dirname "${OUTPUT_ISO_ABS}")
mkdir -p "${OUTPUT_DIR}" || {
    echo -e "${RED}Error: Cannot create output directory: ${OUTPUT_DIR}${NC}" >&2
    exit 1
}

# Update boot entries to use archisolabel (volume label we control)
echo -e "${BLUE}Updating boot entries to use archisolabel...${NC}"

# Update ISO root loader entries
if [ -d "loader/entries" ]; then
    for entry in loader/entries/*.conf; do
        if [ -f "${entry}" ]; then
            sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
            sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
            echo -e "${GREEN}✓ Updated $(basename "${entry}")${NC}"
        fi
    done
fi

# Update efiboot.img loader entries
EFI_IMG_PATH="EFI/archiso/efiboot.img"
if [ -f "${EFI_IMG_PATH}" ]; then
    EFI_MOUNT=$(mktemp -d)
    if sudo mount -o loop "${EFI_IMG_PATH}" "${EFI_MOUNT}" 2>/dev/null; then
        if [ -d "${EFI_MOUNT}/loader/entries" ]; then
            for entry in "${EFI_MOUNT}/loader/entries"/*.conf; do
                if [ -f "${entry}" ]; then
                    sudo sed -i "s/archisosearchuuid=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
                    sudo sed -i "s/archisolabel=[^ ]*/archisolabel=${JARVISOS_VOLID}/g" "${entry}"
                    echo -e "${GREEN}✓ Updated $(basename "${entry}") in efiboot.img${NC}"
                fi
            done
        fi
        sudo umount "${EFI_MOUNT}" || sudo umount -l "${EFI_MOUNT}"
    fi
    rmdir "${EFI_MOUNT}" 2>/dev/null || true
fi

# Update UUID files - use volume label instead of timestamp
find boot/ -name "2026-*.uuid" -delete 2>/dev/null || true
echo "${JARVISOS_VOLID}" > "boot/${JARVISOS_VOLID}.uuid"
echo -e "${GREEN}✓ Created boot/${JARVISOS_VOLID}.uuid${NC}"

# Build ISO with proper boot structure
if [ -n "${ISOLINUX_BIN}" ] && [ -n "${ISOHDPFX_BIN}" ] && [ -n "${EFI_IMG}" ] && [ -f "${EFI_IMG}" ]; then
    # Dual boot (BIOS + UEFI) - preferred
    # CRITICAL: These flags match Arch Linux ISO boot structure for USB compatibility
    # -partition_offset 16: Creates proper partition offset (Arch Linux standard)
    # -partition_cyl_align off: Matches Arch ISO cylinder alignment setting
    # --mbr-force-bootable: Ensures MBR partition has boot flag (0x80) for legacy BIOS boot
    echo -e "${BLUE}Using dual boot structure (BIOS + UEFI)...${NC}"
    XORRISO_OUTPUT=$(xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -joliet \
        -joliet-long \
        -rational-rock \
        -volid "${JARVISOS_VOLID}" \
        -publisher "JARVIS OS PROJECT" \
        -preparer "JARVISOS BUILD SYSTEM" \
        -appid "JARVISOS LIVE/INSTALL MEDIUM" \
        -partition_offset 16 \
        -partition_cyl_align off \
        -eltorito-boot "${ISOLINUX_BIN}" \
        -eltorito-catalog "${BOOT_CAT:-boot/syslinux/boot.cat}" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX_BIN}" \
        --mbr-force-bootable \
        -eltorito-alt-boot \
        -e "${EFI_IMG}" \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -append_partition 2 0xef "${EFI_IMG}" \
        -output "${OUTPUT_ISO_ABS}" \
        . 2>&1)
    
    XORRISO_EXIT=$?
    
    if [ ${XORRISO_EXIT} -ne 0 ]; then
        echo -e "${RED}Error: xorriso failed with exit code ${XORRISO_EXIT}${NC}" >&2
        echo -e "${YELLOW}Full xorriso output:${NC}"
        echo "${XORRISO_OUTPUT}"
        echo ""
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "  - Check if output directory exists: ${OUTPUT_DIR}"
        echo "  - Check disk space: df -h ${OUTPUT_DIR}"
        echo "  - Check if boot files are valid"
        exit 1
    fi
    
    # Show filtered output on success
    echo "${XORRISO_OUTPUT}" | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" | tail -20 || true
elif [ -n "${ISOLINUX_BIN}" ] && [ -n "${ISOHDPFX_BIN}" ]; then
    # BIOS boot only
    # CRITICAL: These flags match Arch Linux ISO boot structure for USB compatibility
    # -partition_offset 16: Creates proper partition offset (Arch Linux standard)
    # -partition_cyl_align off: Matches Arch ISO cylinder alignment setting
    # --mbr-force-bootable: Ensures MBR partition has boot flag (0x80) for legacy BIOS boot
    echo -e "${BLUE}Using BIOS boot structure (UEFI boot files not found)...${NC}"
    
    XORRISO_OUTPUT=$(xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -joliet \
        -joliet-long \
        -rational-rock \
        -volid "${JARVISOS_VOLID}" \
        -publisher "JARVIS OS PROJECT" \
        -preparer "JARVISOS BUILD SYSTEM" \
        -appid "JARVISOS LIVE/INSTALL MEDIUM" \
        -partition_offset 16 \
        -partition_cyl_align off \
        -eltorito-boot "${ISOLINUX_BIN}" \
        -eltorito-catalog "${BOOT_CAT:-boot/syslinux/boot.cat}" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr "${ISOHDPFX_BIN}" \
        --mbr-force-bootable \
        -output "${OUTPUT_ISO_ABS}" \
        . 2>&1)
    
    XORRISO_EXIT=$?
    
    if [ ${XORRISO_EXIT} -ne 0 ]; then
        echo -e "${RED}Error: xorriso failed with exit code ${XORRISO_EXIT}${NC}" >&2
        echo -e "${YELLOW}Full xorriso output:${NC}"
        echo "${XORRISO_OUTPUT}"
        echo ""
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "  - Output directory: ${OUTPUT_DIR}"
        echo "  - Disk space: $(df -h "${OUTPUT_DIR}" | tail -1 | awk '{print $4 " available"}')"
        echo "  - Boot files: ${ISOLINUX_BIN}, ${ISOHDPFX_BIN}"
        exit 1
    fi
    
    # Show filtered output on success
    echo "${XORRISO_OUTPUT}" | grep -vE "^xorriso|^libisofs|^Drive current|^Media current|^Media status|^Media summary|^Added to ISO" | tail -20 || true
else
    echo -e "${RED}Error: Insufficient boot files found${NC}" >&2
    exit 1
fi

echo -e "${GREEN}✓ ISO built successfully with volume label: ${JARVISOS_VOLID}${NC}"

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
