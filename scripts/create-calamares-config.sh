#!/bin/bash
# Create default Calamares configuration if not present

set -e

CALAMARES_DIR="${1}"

if [ -z "${CALAMARES_DIR}" ]; then
    echo "Usage: $0 <calamares_config_dir>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_SOURCE="${PROJECT_ROOT}/configs/calamares"

# If configs exist, copy them
if [ -d "${CONFIG_SOURCE}" ]; then
    mkdir -p "${CALAMARES_DIR}/modules"
    cp -a "${CONFIG_SOURCE}"/* "${CALAMARES_DIR}/"
    echo "✅ Copied Calamares configuration from ${CONFIG_SOURCE}"
else
    echo "⚠️  Calamares config source not found at ${CONFIG_SOURCE}"
    exit 1
fi







