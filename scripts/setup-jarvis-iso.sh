#!/bin/bash
# Install JARVIS into ISO rootfs (similar to jarvis-install-arch but for ISO)

set -e

ROOTFS_DIR="${1}"
CHROOT_CMD="${2:-arch-chroot}"
PROJECT_ROOT="${3}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -z "${ROOTFS_DIR}" ] || [ ! -d "${ROOTFS_DIR}" ]; then
    echo -e "${RED}❌ Error: Rootfs directory not found${NC}"
    exit 1
fi

if [ -z "${PROJECT_ROOT}" ]; then
    PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

chroot_run() {
    if [ "${CHROOT_CMD}" = "arch-chroot" ]; then
        sudo arch-chroot "${ROOTFS_DIR}" "$@"
    else
        sudo systemd-nspawn -q -D "${ROOTFS_DIR}" \
            --bind-ro=/etc/resolv.conf \
            --private-network=false \
            --capability=CAP_SYS_ADMIN \
            "$@"
    fi
}

echo -e "${BLUE}🤖 Installing JARVIS into ISO rootfs...${NC}"

# Initialize Project-JARVIS submodules
echo -e "${BLUE}📋 Initializing Project-JARVIS submodules...${NC}"
(cd "${PROJECT_ROOT}/Project-JARVIS" && git submodule update --init --recursive) || {
    echo -e "${YELLOW}⚠️  Submodule init failed, continuing...${NC}"
}

# Copy Project-JARVIS code
echo -e "${BLUE}📋 Copying Project-JARVIS code...${NC}"
sudo mkdir -p "${ROOTFS_DIR}/usr/lib/jarvis"
sudo cp -a "${PROJECT_ROOT}/Project-JARVIS/jarvis"/* "${ROOTFS_DIR}/usr/lib/jarvis/"
if [ -f "${PROJECT_ROOT}/Project-JARVIS/requirements.txt" ]; then
    sudo cp "${PROJECT_ROOT}/Project-JARVIS/requirements.txt" "${ROOTFS_DIR}/usr/lib/jarvis/"
fi

# Create Python virtual environment
echo -e "${BLUE}🧰 Creating Python virtual environment...${NC}"
if [ ! -d "${ROOTFS_DIR}/usr/lib/jarvis/.venv" ]; then
    chroot_run bash -c "cd /usr/lib/jarvis && python3 -m venv .venv"
    chroot_run bash -c "/usr/lib/jarvis/.venv/bin/pip install --upgrade pip" || {
        echo -e "${YELLOW}⚠️  Failed to upgrade pip (non-fatal)${NC}"
    }
else
    echo -e "${YELLOW}⚠️  Virtual environment already exists, skipping creation${NC}"
fi

# Install system dependencies required by Python packages
echo -e "${BLUE}📦 Installing system dependencies for JARVIS...${NC}"
SYSTEM_DEPS=(
    portaudio          # Required by sounddevice (audio I/O)
    alsa-lib           # ALSA audio library
    alsa-utils         # ALSA utilities
    python-pyaudio     # Python audio library (alternative)
    gcc                # Compiler for some Python packages
    python-pip         # Pip package manager
    python-setuptools  # Setuptools for Python packages
    python-wheel       # Wheel support
    git                # Git for submodules
)

chroot_run bash -c "pacman -S --needed --noconfirm ${SYSTEM_DEPS[*]}" 2>&1 | grep -vE "WARNING.*mountpoint|Enter a number" || {
    echo -e "${YELLOW}⚠️  Some system dependencies may have failed to install${NC}"
}

# Install Python dependencies
echo -e "${BLUE}📦 Installing Python dependencies...${NC}"
if [ -f "${ROOTFS_DIR}/usr/lib/jarvis/requirements.txt" ]; then
    chroot_run bash -c "cd /usr/lib/jarvis && /usr/lib/jarvis/.venv/bin/pip install --no-cache-dir -r requirements.txt" || {
        echo -e "${YELLOW}⚠️  Some dependencies may have failed to install${NC}"
        echo -e "${BLUE}Trying to install critical packages individually...${NC}"
        # Try installing critical packages individually
        chroot_run bash -c "cd /usr/lib/jarvis && /usr/lib/jarvis/.venv/bin/pip install --no-cache-dir sounddevice portaudio19-dev" || true
        chroot_run bash -c "cd /usr/lib/jarvis && /usr/lib/jarvis/.venv/bin/pip install --no-cache-dir -r requirements.txt" || true
    }
fi

# Create CLI wrapper
echo -e "${BLUE}📟 Creating 'jarvis' CLI wrapper...${NC}"
JARVIS_WRAPPER=$(mktemp)
cat > "${JARVIS_WRAPPER}" << 'EOF'
#!/bin/bash
export PYTHONPATH=/usr/lib${PYTHONPATH:+:${PYTHONPATH}}
exec /usr/lib/jarvis/.venv/bin/python -m jarvis.cli "$@"
EOF
sudo cp "${JARVIS_WRAPPER}" "${ROOTFS_DIR}/usr/bin/jarvis"
sudo chmod +x "${ROOTFS_DIR}/usr/bin/jarvis"
rm -f "${JARVIS_WRAPPER}"

# Create systemd service
echo -e "${BLUE}⚙️  Creating systemd service...${NC}"
sudo mkdir -p "${ROOTFS_DIR}/etc/systemd/system"
sudo mkdir -p "${ROOTFS_DIR}/etc/jarvis"
sudo mkdir -p "${ROOTFS_DIR}/var/lib/jarvis"
sudo mkdir -p "${ROOTFS_DIR}/var/log/jarvis"

# Generate jarvis.conf if config.mk exists
if [ -f "${PROJECT_ROOT}/build/config.mk" ]; then
    bash "${PROJECT_ROOT}/scripts/gen-jarvis-conf.sh" || {
        echo -e "${YELLOW}⚠️  Could not generate jarvis.conf, continuing...${NC}"
    }
fi

# Copy service file
if [ -f "${PROJECT_ROOT}/build/jarvis.service" ]; then
    sudo cp "${PROJECT_ROOT}/build/jarvis.service" "${ROOTFS_DIR}/etc/systemd/system/"
elif [ -f "${PROJECT_ROOT}/Project-JARVIS/packaging/jarvis.service" ]; then
    sudo cp "${PROJECT_ROOT}/Project-JARVIS/packaging/jarvis.service" \
        "${ROOTFS_DIR}/etc/systemd/system/jarvis.service"
else
    # Create default service file
    sudo tee "${ROOTFS_DIR}/etc/systemd/system/jarvis.service" > /dev/null << 'EOF'
[Unit]
Description=JARVIS AI Assistant
After=network.target sound.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/lib/jarvis
Environment="PYTHONPATH=/usr/lib"
ExecStart=/usr/lib/jarvis/.venv/bin/python -m jarvis.main
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
fi

# Copy configuration
if [ -f "${PROJECT_ROOT}/build/jarvis.conf" ]; then
    sudo cp "${PROJECT_ROOT}/build/jarvis.conf" "${ROOTFS_DIR}/etc/jarvis/"
fi

# Enable service (may fail in chroot, that's OK)
chroot_run systemctl enable jarvis.service 2>&1 | grep -v "WARNING.*mountpoint" || {
    echo -e "${YELLOW}⚠️  Could not enable jarvis.service (may need to enable after boot)${NC}"
}

echo -e "${GREEN}✅ JARVIS installed and configured${NC}"

