#!/bin/bash
# Step 4: Bake in Project-JARVIS
# Installs Project-JARVIS code, dependencies, and services into the rootfs

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
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"
BUILD_DEPS_DIR="${PROJECT_ROOT}${BUILD_DEPS_DIR}"
PROJECT_JARVIS="${PROJECT_ROOT}/Project-JARVIS"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if step 3 was completed (Wayland installed)
if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Rootfs not extracted. Please run step 2 first${NC}" >&2
    exit 1
fi

# Verify rootfs has essential directories
if [ ! -d "${SQUASHFS_ROOTFS}/usr/bin" ] && [ ! -d "${SQUASHFS_ROOTFS}/bin" ]; then
    echo -e "${RED}Error: Rootfs appears invalid - /usr/bin or /bin missing${NC}" >&2
    exit 1
fi

# Check if Project-JARVIS exists
if [ ! -d "${PROJECT_JARVIS}" ]; then
    echo -e "${RED}Error: Project-JARVIS not found at ${PROJECT_JARVIS}${NC}" >&2
    echo -e "${YELLOW}Please ensure Project-JARVIS submodule is initialized${NC}"
    exit 1
fi

# Determine chroot command (distro-aware error messages via build-utils.sh)
detect_chroot_cmd

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 4: Installing Project-JARVIS${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"
echo -e "${BLUE}Project-JARVIS: ${PROJECT_JARVIS}${NC}"

# Step 1: Copy DNS resolution file
echo -e "${BLUE}Copying DNS resolution file...${NC}"
if [ -f /etc/resolv.conf ]; then
    sudo cp /etc/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
fi

# Step 2: Bind mount iso-rootfs to itself
echo -e "${BLUE}Bind mounting iso-rootfs to itself...${NC}"
sudo mount --bind "${SQUASHFS_ROOTFS}" "${SQUASHFS_ROOTFS}" || {
    echo -e "${RED}Error: Failed to bind mount rootfs${NC}" >&2
    exit 1
}

# Function to cleanup on exit
cleanup() {
    echo -e "${BLUE}Cleaning up...${NC}"
    # Unmount bind mount
    sudo umount "${SQUASHFS_ROOTFS}" 2>/dev/null || true
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Step 3: Install system dependencies for JARVIS
echo -e "${BLUE}Installing system dependencies for JARVIS...${NC}"

# Audio libraries (for voice input/output)
# Note: PipeWire is already installed in step 3, so we don't need pulseaudio
echo -e "${BLUE}Installing audio libraries...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    portaudio \
    alsa-utils \
    python-pyaudio

# Python development tools (for building Python packages)
echo -e "${BLUE}Installing Python development tools...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    python \
    python-pip \
    python-virtualenv \
    python-setuptools \
    python-wheel \
    gcc \
    make \
    pkg-config

# Step 4: Install Ollama
echo -e "${BLUE}Installing Ollama...${NC}"
# The install.sh script tries to run systemd in chroot which will fail - we suppress that
# We use a custom approach: download the binary and install it manually
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Try the official install script first (it handles binary download and GPU detection)
    # OLLAMA_NO_SYSTEM_SERVICE=1 prevents systemd service creation in chroot
    if curl -fsSL https://ollama.com/install.sh | OLLAMA_NO_SYSTEM_SERVICE=1 sh 2>/dev/null; then
        echo '✓ Ollama installed via install.sh'
    else
        echo 'Warning: Ollama install.sh failed or not available, trying direct binary download...'
        ARCH=\$(uname -m)
        if [ \"\${ARCH}\" = 'x86_64' ]; then
            OLLAMA_URL='https://ollama.com/download/ollama-linux-amd64'
        elif [ \"\${ARCH}\" = 'aarch64' ]; then
            OLLAMA_URL='https://ollama.com/download/ollama-linux-arm64'
        else
            echo 'Warning: Unsupported architecture for Ollama: '\${ARCH}
            exit 0
        fi

        if curl -fsSL -o /usr/local/bin/ollama \"\${OLLAMA_URL}\"; then
            chmod +x /usr/local/bin/ollama
            echo '✓ Ollama binary installed manually'
        else
            echo 'Warning: Could not download Ollama binary - it can be installed later'
            echo 'Run: curl -fsSL https://ollama.com/install.sh | sh'
            exit 0
        fi
    fi

    # Install systemd service file for use after installation (not enabled in chroot)
    mkdir -p /usr/lib/systemd/system
    cat > /usr/lib/systemd/system/ollama.service << 'OLLAMAEOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment=\"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
Environment=\"HOME=/usr/share/ollama\"
Environment=\"OLLAMA_HOST=0.0.0.0\"

[Install]
WantedBy=default.target
OLLAMAEOF

    # Create ollama user/group for the service
    if ! getent group ollama >/dev/null 2>&1; then
        groupadd -r ollama 2>/dev/null || true
    fi
    if ! getent passwd ollama >/dev/null 2>&1; then
        useradd -r -g ollama -d /usr/share/ollama -s /bin/false -c 'Ollama Service' ollama 2>/dev/null || true
    fi
    mkdir -p /usr/share/ollama
    chown -R ollama:ollama /usr/share/ollama 2>/dev/null || true
"

# Note: Ollama service not enabled in chroot (systemd not running)
# It will be started via autostart on live boot, and can be enabled after installation
echo -e "${BLUE}Ollama installed - service will autostart via XDG autostart on live boot${NC}"

# Step 5: Create jarvis user and group
echo -e "${BLUE}Creating jarvis user and group...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Create group if it doesn't exist
    if ! getent group jarvis >/dev/null 2>&1; then
        groupadd -r jarvis
    fi
    
    # Create user if it doesn't exist
    if ! getent passwd jarvis >/dev/null 2>&1; then
        useradd -r -g jarvis -d /var/lib/jarvis -s /sbin/nologin \
                -c 'JARVIS AI Assistant' jarvis
    fi
"

# Step 6: Create directories
echo -e "${BLUE}Creating JARVIS directories...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    mkdir -p /usr/lib/jarvis
    mkdir -p /etc/jarvis
    mkdir -p /var/lib/jarvis/models/piper
    mkdir -p /var/lib/jarvis/models/vosk
    mkdir -p /var/log/jarvis
    
    # Set ownership
    chown -R jarvis:jarvis /var/lib/jarvis
    chown -R jarvis:jarvis /var/log/jarvis
    chmod 755 /var/lib/jarvis
    chmod 755 /var/log/jarvis
"

# Step 7: Copy Project-JARVIS code
echo -e "${BLUE}Copying Project-JARVIS code...${NC}"
sudo cp -r "${PROJECT_JARVIS}/jarvis"/* "${SQUASHFS_ROOTFS}/usr/lib/jarvis/"
# Copy requirements.txt for venv installation
sudo cp "${PROJECT_JARVIS}/requirements.txt" "${SQUASHFS_ROOTFS}/usr/lib/jarvis/requirements.txt"
# Chown inside chroot (user exists there)
sudo arch-chroot "${SQUASHFS_ROOTFS}" chown -R jarvis:jarvis /usr/lib/jarvis

# Verify SuperMCP was copied correctly
echo -e "${BLUE}Verifying SuperMCP installation...${NC}"
if [ ! -d "${SQUASHFS_ROOTFS}/usr/lib/jarvis/SuperMCP" ]; then
    echo -e "${RED}ERROR: SuperMCP directory not found after copy${NC}" >&2
    echo -e "${YELLOW}Expected: ${SQUASHFS_ROOTFS}/usr/lib/jarvis/SuperMCP${NC}" >&2
    exit 1
fi

if [ ! -f "${SQUASHFS_ROOTFS}/usr/lib/jarvis/SuperMCP/SuperMCP.py" ]; then
    echo -e "${RED}ERROR: SuperMCP.py not found after copy${NC}" >&2
    echo -e "${YELLOW}Expected: ${SQUASHFS_ROOTFS}/usr/lib/jarvis/SuperMCP/SuperMCP.py${NC}" >&2
    exit 1
fi

echo -e "${GREEN}✓ SuperMCP verified successfully${NC}"

# Step 8: Install Python dependencies in virtual environment
echo -e "${BLUE}Installing Python dependencies...${NC}"

# First verify requirements.txt was copied
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" test -f /usr/lib/jarvis/requirements.txt; then
    echo -e "${RED}ERROR: requirements.txt not found at /usr/lib/jarvis/requirements.txt${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Requirements.txt contents:${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" cat /usr/lib/jarvis/requirements.txt

sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    set -e  # Exit on any error
    
    cd /var/lib/jarvis
    
    # Create virtual environment
    echo 'Creating virtual environment...'
    python3 -m venv venv
    
    # Activate venv and install dependencies
    source venv/bin/activate
    
    # Upgrade pip first
    echo 'Upgrading pip...'
    pip install --upgrade pip
    
    # Install dependencies with verbose output
    echo 'Installing dependencies from requirements.txt...'
    pip install -r /usr/lib/jarvis/requirements.txt --verbose
    
    # Verify critical packages were installed
    echo 'Verifying installations...'
    python -c 'import dotenv; print(\"✓ dotenv installed\")'
    python -c 'import ollama; print(\"✓ ollama installed\")'
    python -c 'import vosk; print(\"✓ vosk installed\")'
    
    # Show installed package count
    PACKAGE_COUNT=\$(pip list | wc -l)
    echo \"Total packages installed: \${PACKAGE_COUNT}\"
    
    if [ \${PACKAGE_COUNT} -lt 20 ]; then
        echo 'ERROR: Too few packages installed, something went wrong'
        exit 1
    fi
    
    deactivate
    
    # Set ownership
    chown -R jarvis:jarvis venv
    
    echo '✓ All dependencies installed successfully'
"

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to install Python dependencies${NC}" >&2
    exit 1
fi

echo -e "${GREEN}✓ Python dependencies installed successfully${NC}"

# Step 9: Create jarvis CLI wrapper script
echo -e "${BLUE}Creating jarvis CLI wrapper...${NC}"
sudo tee "${SQUASHFS_ROOTFS}/usr/bin/jarvis" > /dev/null << 'EOF'
#!/bin/bash
# JARVIS CLI Wrapper
# Activates the virtual environment and runs jarvis CLI

VENV_PATH="/var/lib/jarvis/venv"
JARVIS_PATH="/usr/lib/jarvis"

if [ -f "${VENV_PATH}/bin/activate" ]; then
    source "${VENV_PATH}/bin/activate"
else
    echo "Warning: Virtual environment not found at ${VENV_PATH}" >&2
fi

# Set PYTHONPATH to /usr/lib so Python can find the jarvis module
# The jarvis module is at /usr/lib/jarvis/, so PYTHONPATH should be /usr/lib
export PYTHONPATH="/usr/lib:${PYTHONPATH}"
cd "${JARVIS_PATH}"
python -m jarvis.cli "$@"
EOF

sudo chmod +x "${SQUASHFS_ROOTFS}/usr/bin/jarvis"
sudo chown root:root "${SQUASHFS_ROOTFS}/usr/bin/jarvis"

# Step 10: Install jarvis-daemon script (with venv support)
echo -e "${BLUE}Installing jarvis-daemon...${NC}"
# Create a wrapper that activates venv before running the daemon
sudo tee "${SQUASHFS_ROOTFS}/usr/bin/jarvis-daemon" > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
JARVIS System Daemon
Main entry point for JARVIS when running as a system service
"""

import sys
import os
import signal
import logging
from pathlib import Path

# Activate virtual environment if it exists
VENV_PATH = Path("/var/lib/jarvis/venv")
if VENV_PATH.exists():
    venv_python = VENV_PATH / "bin" / "python3"
    if venv_python.exists():
        # Find the actual versioned site-packages directory (e.g., python3.12)
        import glob
        venv_site_pattern = str(VENV_PATH / "lib" / "python3*" / "site-packages")
        venv_sites = glob.glob(venv_site_pattern)
        for venv_site in venv_sites:
            if Path(venv_site).exists():
                sys.path.insert(0, venv_site)

# Add JARVIS to Python path
# The jarvis module is at /usr/lib/jarvis/, so add /usr/lib to path
sys.path.insert(0, '/usr/lib')

from jarvis.main import Jarvis
from jarvis.config import Config

class JarvisDaemon:
    def __init__(self):
        self.jarvis = None
        self.running = False
        self.setup_logging()
        
    def setup_logging(self):
        """Setup system logging"""
        log_dir = Path(os.environ.get('JARVIS_LOG_DIR', '/var/log/jarvis'))
        log_dir.mkdir(parents=True, exist_ok=True)
        
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_dir / 'jarvis.log'),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger('jarvis-daemon')
        
    def signal_handler(self, signum, frame):
        """Handle system signals"""
        self.logger.info(f"Received signal {signum}, shutting down gracefully...")
        self.running = False
        if self.jarvis:
            # JARVIS doesn't have a stop method, but we can set running to False
            pass
            
    def setup_environment(self):
        """Setup environment for system service"""
        # Ensure required directories exist
        for dir_name in ['JARVIS_DATA_DIR', 'JARVIS_MODELS_DIR', 'JARVIS_LOG_DIR']:
            dir_path = Path(os.environ.get(dir_name))
            dir_path.mkdir(parents=True, exist_ok=True)
            
        # Set default model paths if not configured
        models_dir = Path(os.environ.get('JARVIS_MODELS_DIR', '/var/lib/jarvis/models'))
        if not os.getenv('TTS_MODEL_ONNX'):
            os.environ['TTS_MODEL_ONNX'] = str(models_dir / 'piper' / 'en_US-libritts_r-medium.onnx')
        if not os.getenv('TTS_MODEL_JSON'):
            os.environ['TTS_MODEL_JSON'] = str(models_dir / 'piper' / 'en_US-libritts_r-medium.onnx.json')
        if not os.getenv('VOSK_MODEL_PATH'):
            os.environ['VOSK_MODEL_PATH'] = str(models_dir / 'vosk-model-small-en-us-0.15')
            
    def run(self):
        """Main daemon loop"""
        self.logger.info("Starting JARVIS daemon...")
        
        # Setup signal handlers
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGHUP, self.signal_handler)
        
        try:
            # Setup environment
            self.setup_environment()
            
            # Initialize JARVIS
            self.logger.info("Initializing JARVIS...")
            self.jarvis = Jarvis()
            
            self.running = True
            self.logger.info("JARVIS daemon started successfully")
            
            # Start voice activation mode (listening for wake words)
            self.jarvis.listen_with_activation()
                        
        except Exception as e:
            self.logger.error(f"Fatal error starting JARVIS: {e}", exc_info=True)
            return 1
        finally:
            self.logger.info("JARVIS daemon stopped")
            
        return 0

if __name__ == '__main__':
    daemon = JarvisDaemon()
    sys.exit(daemon.run())
EOF

sudo chmod +x "${SQUASHFS_ROOTFS}/usr/bin/jarvis-daemon"
sudo chown root:root "${SQUASHFS_ROOTFS}/usr/bin/jarvis-daemon"

# Step 11: Install systemd service
echo -e "${BLUE}Installing systemd service...${NC}"
sudo cp "${PROJECT_JARVIS}/packaging/jarvis.service" "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/jarvis.service"
sudo chown root:root "${SQUASHFS_ROOTFS}/usr/lib/systemd/system/jarvis.service"

# Step 12: Set up configuration
echo -e "${BLUE}Setting up JARVIS configuration...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" bash -c "
    # Copy config template
    cp /usr/lib/jarvis/config.env.template /etc/jarvis/jarvis.conf.template
    chown jarvis:jarvis /etc/jarvis/jarvis.conf.template
    
    # Create initial .env file from template (if it doesn't exist)
    if [ ! -f /usr/lib/jarvis/.env ]; then
        cp /usr/lib/jarvis/config.env.template /usr/lib/jarvis/.env
        chown jarvis:jarvis /usr/lib/jarvis/.env
    fi
"

# Step 13: Skip enabling services in arch-chroot (systemd not running)
# Services will be enabled by Calamares post-install scripts after actual OS installation
echo -e "${BLUE}Systemd services installed - will be enabled after Calamares installation${NC}"

# Create autostart script for Ollama in live environment
echo -e "${BLUE}Creating Ollama autostart for live environment...${NC}"
sudo mkdir -p "${SQUASHFS_ROOTFS}/etc/xdg/autostart"
sudo tee "${SQUASHFS_ROOTFS}/etc/xdg/autostart/ollama.desktop" > /dev/null << 'EOF'
[Desktop Entry]
Type=Application
Name=Ollama Service
Comment=Start Ollama server for JARVIS
Exec=/usr/local/bin/ollama serve
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
Hidden=false
NoDisplay=true
EOF

sudo chmod 644 "${SQUASHFS_ROOTFS}/etc/xdg/autostart/ollama.desktop"

# Step 14: Cleanup package cache
echo -e "${BLUE}Cleaning up package cache...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Scc --noconfirm 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" sh -c "rm -rf /tmp/* /var/cache/pacman/pkg/*" 2>/dev/null || true

# Cleanup will be handled by trap
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 4 complete: Project-JARVIS installed${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Note: Users will need to:${NC}"
echo -e "${BLUE}  1. Pull an Ollama model: ollama pull <model_name>${NC}"
echo -e "${BLUE}  2. Set the model: jarvis model -n '<model_name>'${NC}"
echo -e "${BLUE}  3. Start the service: systemctl start jarvis${NC}"
