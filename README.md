# JARVIS OS - AI-Native Linux Distribution

**The world's first operating system designed around AI voice interaction.**

JARVIS OS is a custom Arch Linux-based distribution where voice is the primary interface. The AI assistant (JARVIS) handles system administration, file management, and system control through natural language, creating a revolutionary computing experience.

## 🎯 **What is JARVIS OS?**

JARVIS OS is a custom Linux distribution built on Arch Linux where:
- **Voice is the primary interface** - Users talk to their computer instead of using mouse/keyboard
- **AI handles system administration** - JARVIS manages files, installs software, and controls the system
- **Dynamic capability discovery** - The system automatically learns new tools via SuperMCP
- **Privacy-first design** - All AI processing happens locally on your device with Ollama
- **Professional desktop environment** - KDE Plasma Wayland provides a modern GUI when needed
- **Easy installation** - Calamares installer for straightforward setup

## 🏗️ **Project Structure**

```
jarvisos/
├── Project-JARVIS/           # AI voice assistant (submodule)
├── packages/                 # Custom packages
│   └── calamares-config/    # Calamares installer configuration
├── scripts/                  # Build scripts (step-by-step process)
│   ├── Makefile             # Build orchestration
│   ├── build.config         # Build configuration
│   ├── 01-extract-iso.sh    # Extract base Arch Linux ISO
│   ├── 02-unsquash-fs.sh    # Extract SquashFS rootfs
│   ├── 03-bake-wayland.sh   # Install KDE Plasma Wayland
│   ├── 04-bake-jarvis.sh    # Install Project-JARVIS
│   ├── 05-bake-calamares.sh # Install Calamares installer
│   ├── 06-squash-fs.sh      # Rebuild SquashFS
│   ├── 07-rebuild-iso.sh    # Rebuild bootable ISO
│   └── booter.sh            # QEMU launcher for testing
├── build-deps/              # Build dependencies (ISO files)
└── README.md                # This file
```

## 🚀 **Quick Start - Building JARVIS OS**

### **Prerequisites**

- **Host System**: Fedora or any Linux distribution with these tools:
  - `arch-install-scripts` (for arch-chroot)
  - `squashfs-tools` (for mksquashfs/unsquashfs)
  - `xorriso` (for ISO creation)
  - `qemu-system-x86` (for testing)
- **Hardware Requirements**:
  - 16GB+ RAM (for building)
  - 50GB+ free disk space
  - Internet connection
  - Root/sudo access

### **Step 1: Initial Setup**

```bash
# Clone repository with submodules
git clone --recursive https://github.com/YourUsername/jarvisos.git
cd jarvisos

# Install build dependencies (Fedora)
sudo dnf install arch-install-scripts squashfs-tools xorriso qemu-system-x86

# Download base Arch Linux ISO
cd build-deps
wget https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso
# Rename to match your config (e.g., archlinux-2025.11.01-x86_64.iso)
cd ..
```

### **Step 2: Configure Build System**

```bash
cd scripts

# Copy example configuration
cp build.config.example build.config

# Edit build.config and set your paths
# Most importantly, set:
#   PROJECT_ROOT="/absolute/path/to/jarvisos"
#   ISO_FILE="archlinux-2025.11.01-x86_64.iso"
nano build.config
```

**Example build.config:**
```bash
PROJECT_ROOT="/home/user/jarvisos"
SCRIPTS_DIR="/scripts"
BUILD_DIR="/build"
BUILD_DEPS_DIR="/build-deps"
ISO_EXTRACT_DIR="/iso-extract"
ISO_FILE="archlinux-2025.11.01-x86_64.iso"
JARVIS_ISO_FILE="jarvisos-*-x86_64.iso"
```

### **Step 3: Build JARVIS OS ISO**

You can build the entire ISO in one command or run steps individually for debugging:

#### **Option A: Build Everything (Recommended)**
```bash
# Run all build steps automatically
make all
```

This will:
1. Extract the base Arch Linux ISO
2. Extract the SquashFS filesystem
3. Install KDE Plasma Wayland desktop environment
4. Install Project-JARVIS and dependencies
5. Install Calamares installer
6. Rebuild SquashFS with all changes
7. Create the final bootable ISO

**Build time: ~30-60 minutes** (depending on your system and internet speed)

#### **Option B: Step-by-Step Build (For Debugging)**

```bash
# Step 1: Extract ISO
make step1

# Step 2: Unsquash filesystem
make step2

# Step 3: Install Wayland/KDE Plasma
make step3

# Step 4: Install JARVIS
make step4

# Step 5: Install Calamares (installer)
make step5

# Step 6: Rebuild SquashFS
make step6

# Step 7: Rebuild final ISO
make step7

# Check build status at any time
make status
```

### **Step 4: Test with QEMU**

```bash
# Boot the ISO in QEMU
./booter.sh

# Or manually:
qemu-system-x86_64 -cdrom ../build/jarvisos-*-x86_64.iso \
    -boot d -m 4096 -enable-kvm
```

### **Step 5: Install to Physical Machine**

1. Write ISO to USB drive:
   ```bash
   sudo dd if=build/jarvisos-*.iso of=/dev/sdX bs=4M status=progress
   ```
2. Boot from USB
3. Follow Calamares installer prompts
4. Reboot into installed system

## 🎤 **Using JARVIS**

### **After Installation**

**Login credentials** (live ISO and default installation):
- Username: `root` (live) or your created user
- Password: `jarvis123` (live) or your set password

### **First-Time Setup**

```bash
# 1. Pull an Ollama model
ollama pull llama3.2

# 2. Configure JARVIS to use the model
jarvis model -n 'llama3.2'

# 3. Test JARVIS
jarvis ask "Hello, how are you?"

# 4. Start JARVIS voice service
systemctl start jarvis

# 5. Check service status
systemctl status jarvis
journalctl -u jarvis -f
```

### **JARVIS Commands**

```bash
# Interactive CLI modes
jarvis text          # Text-only interaction
jarvis voice         # Voice interaction (one-time)
jarvis                # Default voice activation mode

# Direct queries
jarvis ask "What files are in my home directory?"
jarvis ask "Create a new file called notes.txt"

# Model management
jarvis model -l      # List available models
jarvis model -n 'model-name'  # Set active model

# System information
jarvis --help        # Show help
jarvis --version     # Show version
```

### **JARVIS Service Management**

```bash
# Start/stop service
sudo systemctl start jarvis
sudo systemctl stop jarvis

# Enable/disable on boot
sudo systemctl enable jarvis
sudo systemctl disable jarvis

# View logs
sudo journalctl -u jarvis -f
sudo tail -f /var/log/jarvis/jarvis.log
```

## 🔧 **Architecture Overview**

### **How JARVIS Works**

```
┌─────────────────────────────────────────────────────────────┐
│                     JARVIS Architecture                      │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  🎤 Voice Input → Speech-to-Text (Vosk)                    │
│         ↓                                                    │
│  🧠 LLM Processing (Ollama)                                 │
│         ↓                                                    │
│  🔧 Tool Discovery (SuperMCP)                               │
│         ↓                                                    │
│  ⚙️  Command Execution                                       │
│         ↓                                                    │
│  🔊 Voice Output ← Text-to-Speech (Piper)                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### **System Components**

1. **Base System**: Arch Linux with KDE Plasma Wayland
2. **AI Engine**: Ollama for local LLM inference
3. **Voice Input**: Vosk for speech recognition
4. **Voice Output**: Piper for text-to-speech
5. **Tool System**: SuperMCP for dynamic capability discovery
6. **System Service**: systemd-managed JARVIS daemon
7. **Installer**: Calamares for easy installation

### **File Locations**

```
/usr/lib/jarvis/              # JARVIS code
/var/lib/jarvis/              # JARVIS data
  ├── venv/                   # Python virtual environment
  └── models/                 # AI models (Piper, Vosk)
/etc/jarvis/                  # Configuration files
/var/log/jarvis/              # Log files
/usr/bin/jarvis               # CLI wrapper
/usr/bin/jarvis-daemon        # System daemon
```

## 🛠️ **Build System Details**

### **Makefile Targets**

| Target | Description | Duration |
|--------|-------------|----------|
| `make help` | Show available targets | Instant |
| `make status` | Check build step status | Instant |
| `make step1` | Extract base ISO | 1-2 min |
| `make step2` | Extract SquashFS | 2-3 min |
| `make step3` | Install KDE Plasma | 15-25 min |
| `make step4` | Install JARVIS | 10-15 min |
| `make step5` | Install Calamares | 5-10 min |
| `make step6` | Rebuild SquashFS | 5-10 min |
| `make step7` | Create final ISO | 2-5 min |
| `make all` | Run all steps | 40-70 min |
| `make clean` | Remove build artifacts | 1 min |

### **What Each Script Does**

#### **01-extract-iso.sh**
- Mounts or extracts the base Arch Linux ISO
- Creates working directory structure
- Preserves ISO metadata for later rebuilding

#### **02-unsquash-fs.sh**
- Extracts the SquashFS compressed rootfs
- Creates `build/iso-rootfs/` for modifications
- Handles both legacy and modern Arch ISO structures

#### **03-bake-wayland.sh**
- Installs KDE Plasma desktop environment
- Configures Wayland display server
- Installs audio system (PipeWire)
- Sets up NetworkManager
- Configures SDDM display manager
- Installs essential GUI applications

#### **04-bake-jarvis.sh**
- Copies Project-JARVIS code to `/usr/lib/jarvis/`
- Creates Python virtual environment
- Installs Python dependencies
- Installs Ollama
- Creates jarvis user and directories
- Sets up systemd service
- Installs CLI wrapper scripts

#### **05-bake-calamares.sh**
- Installs Calamares installer framework
- Configures installation steps
- Sets up JARVIS branding
- Configures post-install scripts

#### **06-squash-fs.sh**
- Compresses modified rootfs back to SquashFS
- Optimizes compression for size
- Updates filesystem metadata

#### **07-rebuild-iso.sh**
- Rebuilds bootable ISO from modified files
- Updates bootloader configuration
- Signs ISO with checksums
- Creates timestamped final ISO file

## 🔍 **Troubleshooting**

### **Common Build Issues**

**"PROJECT_ROOT not set in build.config"**
```bash
# Edit scripts/build.config and set PROJECT_ROOT
nano scripts/build.config
# Set: PROJECT_ROOT="/absolute/path/to/jarvisos"
```

**"ISO file not found"**
```bash
# Verify ISO exists in build-deps/
ls -lh build-deps/
# Download if missing:
cd build-deps && wget https://mirror.rackspace.com/archlinux/iso/latest/archlinux-x86_64.iso
```

**"arch-chroot: command not found"**
```bash
# Install arch-install-scripts
sudo dnf install arch-install-scripts  # Fedora
sudo apt install arch-install-scripts  # Ubuntu
```

**"No space left on device"**
```bash
# Clean build artifacts
cd scripts && make clean
# Check disk space
df -h
```

**"Failed to mount/unmount rootfs"**
```bash
# Forcefully unmount
sudo umount -l build/iso-rootfs
# Kill processes using the directory
sudo lsof +D build/iso-rootfs
```

### **Runtime Issues**

**"JARVIS won't start"**
```bash
# Check service status
systemctl status jarvis

# Check for missing models
ls -la /var/lib/jarvis/models/

# View detailed logs
journalctl -u jarvis -e --no-pager

# Test manual start
sudo -u jarvis /usr/bin/jarvis-daemon
```

**"Ollama not responding"**
```bash
# Check Ollama service
systemctl status ollama

# Restart Ollama
systemctl restart ollama

# Pull a model if none exist
ollama pull llama3.2
```

**"No audio input/output"**
```bash
# Check audio devices
arecord -l  # Input devices
aplay -l    # Output devices

# Test PipeWire
pactl info

# Restart PipeWire
systemctl --user restart pipewire
```

## 📚 **Advanced Topics**

### **Customizing the Build**

#### **Adding Packages**

Edit `scripts/03-bake-wayland.sh` or `04-bake-jarvis.sh`:
```bash
# Add packages to the installation list
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -S --noconfirm \
    your-package-1 \
    your-package-2
```

#### **Changing Desktop Environment**

Replace KDE Plasma in `03-bake-wayland.sh`:
```bash
# For GNOME:
pacman -S --noconfirm gnome gnome-extra gdm

# For XFCE:
pacman -S --noconfirm xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
```

#### **Modifying JARVIS Configuration**

Edit `Project-JARVIS/jarvis/config.env.template` before building, or modify `/etc/jarvis/jarvis.conf.template` in the built ISO.

### **Development Workflow**

```bash
# 1. Make changes to Project-JARVIS
cd Project-JARVIS
git pull origin main
# Make your changes...

# 2. Rebuild only JARVIS (skip earlier steps)
cd ../scripts
make step4

# 3. Rebuild SquashFS and ISO
make step6 step7

# 4. Test in QEMU
./booter.sh
```

### **Creating Custom Variants**

You can create multiple build configurations:

```bash
# Create variant configs
cp build.config build.config.minimal
cp build.config build.config.development

# Edit each for different purposes
# Then build with:
source build.config.minimal && make all
```

## 🤝 **Contributing**

We welcome contributions! Here's how:

1. **Fork the repository**
2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes**
   - Follow existing code style
   - Test thoroughly with `make all`
   - Update documentation
4. **Commit your changes**
   ```bash
   git commit -m "Add: Description of your changes"
   ```
5. **Push and create Pull Request**
   ```bash
   git push origin feature/your-feature-name
   ```

### **Areas for Contribution**

- 🎨 UI/UX improvements for KDE theme
- 🔧 Additional MCP servers for SuperMCP
- 📦 Package optimizations
- 🌍 Internationalization support
- 📖 Documentation improvements
- 🐛 Bug fixes and testing

## 📄 **License**

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## 🎓 **Learning Resources**

### **Arch Linux & Linux System Building**
- [Arch Linux Wiki](https://wiki.archlinux.org/)
- [ArchISO Documentation](https://wiki.archlinux.org/title/Archiso)
- [Linux From Scratch](https://www.linuxfromscratch.org/)

### **JARVIS Development**
- [Project-JARVIS Documentation](Project-JARVIS/README.md)
- [SuperMCP Documentation](https://github.com/YourUsername/SuperMCP)
- [Ollama Documentation](https://ollama.com/docs)

### **Voice & AI**
- [Vosk Speech Recognition](https://alphacephei.com/vosk/)
- [Piper TTS](https://github.com/rhasspy/piper)
- [LLM Prompting Guide](https://www.promptingguide.ai/)

## 🎉 **What's Next?**

Once you have JARVIS OS running:

1. **🎤 Try Voice Commands**
   - "JARVIS, what's the weather like?"
   - "JARVIS, list my files"
   - "JARVIS, install Firefox"

2. **🔧 Customize JARVIS**
   - Add custom MCP servers for specialized tasks
   - Train custom wake words
   - Configure personality and response style

3. **📦 Build Applications**
   - Create AI-native applications
   - Integrate with JARVIS capabilities
   - Share with the community

4. **🌍 Contribute Back**
   - Report bugs and issues
   - Submit improvements
   - Help others in the community

---

## 📞 **Support & Community**

- **Issues**: [GitHub Issues](https://github.com/YourUsername/jarvisos/issues)
- **Discussions**: [GitHub Discussions](https://github.com/YourUsername/jarvisos/discussions)
- **Documentation**: [Project Wiki](https://github.com/YourUsername/jarvisos/wiki)

---

**Welcome to the future of computing! 🤖✨**

*JARVIS OS - Where AI meets the operating system*
