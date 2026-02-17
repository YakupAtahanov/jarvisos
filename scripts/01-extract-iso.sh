#!/bin/bash
# Extract Arch Linux ISO to iso-extract
# Usage: ./01-extract-iso.sh [iso_file] [build_dir]
# Variables come from build.config

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
BUILD_DEPS_DIR="${PROJECT_ROOT}${BUILD_DEPS_DIR}"
ISO_EXTRACT_DIR="${BUILD_DIR}${ISO_EXTRACT_DIR}"
ISO_FILE="${BUILD_DEPS_DIR}/${ISO_FILE}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if ISO file exists
if [ ! -f "${ISO_FILE}" ]; then
    echo -e "${RED}Error: ISO file not found: ${ISO_FILE}${NC}"
    exit 1
fi

echo -e "${BLUE}Extracting ISO...${NC}"
echo -e "${BLUE}ISO: ${ISO_FILE}${NC}"
echo -e "${BLUE}Output: ${ISO_EXTRACT_DIR}${NC}"

# Clean up any existing extraction
sudo rm -rf "${ISO_EXTRACT_DIR}"
mkdir -p "${ISO_EXTRACT_DIR}"

# Check if 7z is available
if ! command -v 7z &> /dev/null; then
    echo -e "${RED}Error: 7z not found.${NC}"
    echo -e "${YELLOW}Install: $(pkg_install_hint_multi "p7zip" "p7zip p7zip-plugins" "p7zip-full" "p7zip")${NC}"
    exit 1
fi

# Extract ISO using 7z
echo -e "${BLUE}Using 7z to extract...${NC}"
7z x -o"${ISO_EXTRACT_DIR}" "${ISO_FILE}" > /dev/null
echo -e "${GREEN}Extraction complete${NC}"

# Verify extraction succeeded
if [ ! -d "${ISO_EXTRACT_DIR}" ] || [ -z "$(ls -A "${ISO_EXTRACT_DIR}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Extraction failed - output directory is empty${NC}"
    exit 1
fi

# Show extracted structure
echo -e "${BLUE}Extracted structure:${NC}"
find "${ISO_EXTRACT_DIR}" -maxdepth 2 -type d | sort | sed "s|${ISO_EXTRACT_DIR}|  |" | sed "s|^  $|  .|"

echo -e "${GREEN}ISO extraction complete!${NC}"
echo -e "${BLUE}Extracted to: ${ISO_EXTRACT_DIR}${NC}"
