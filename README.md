# JARVIS OS - AI-Native Linux Distribution

**The world's first operating system designed around AI voice interaction.**

JARVIS OS combines a custom Linux kernel with an AI voice assistant (JARVIS) as the primary interface, creating a revolutionary computing experience where users interact with their system through natural language.

## 🎯 **What is JARVIS OS?**

JARVIS OS is a custom Linux distribution where:
- **Voice is the primary interface** - Users talk to their computer instead of using mouse/keyboard
- **AI handles system administration** - JARVIS manages files, installs software, and controls the system
- **Dynamic capability discovery** - The system automatically learns new tools and capabilities
- **Privacy-first design** - All AI processing happens locally on your device

## 🏗️ **Project Structure**

```
jarvisos/
├── linux/                    # Custom Linux kernel (submodule)
├── Project-JARVIS/           # AI voice assistant (submodule)
├── configs/                  # Kernel and system configurations
├── scripts/                  # Build and setup scripts
├── Makefile                  # Main build system
└── README.md                 # This file
```

## 🚀 **Quick Start**

### **Prerequisites**
- Linux system (Fedora/Ubuntu recommended)
- 16GB+ RAM (for building)
- 50GB+ free disk space
- Internet connection
- Root/sudo access for package installation

### **Complete Build Process (Arch Linux Rootfs)**

This is the recommended way to build JARVIS OS with a full Arch Linux userspace:

```bash
# 1. Clone repository with submodules
git clone --recursive https://github.com/YakupAtahanov/jarvisos.git
cd jarvisos

# 2. Install build dependencies (one-time setup)
make build-deps

# 3. Generate build configuration from TOML config
# Optional: Use a profile (minimal or desktop)
make configure
# Or: PROFILE=desktop make configure

# 4. Build Arch Linux root filesystem
# This creates build/arch-rootfs/ with base Arch + extra packages from config
make rootfs-arch

# 5. Install JARVIS into the rootfs
# Creates venv, copies code, installs wrapper, sets up systemd service
make jarvis-install-arch

# 6. Install Python dependencies into JARVIS venv
make jarvis-deps-arch

# 7. Convert rootfs to QCOW2 disk image
# Uses QEMU_DISK_GB from configs/qemu_config.mk (default: 20GB)
USE_LOOP=1 make rootfs-qcow2

# 8. Boot JARVIS OS in QEMU
make boot-arch
```

**Login credentials:**
- Username: `root`
- Password: `jarvis123`

**Inside the VM:**
```bash
# Test JARVIS CLI
jarvis --help
jarvis text
jarvis ask "hello"

# Check service status
systemctl status jarvis

# View logs
journalctl -u jarvis -f
```

### **Optional: Download AI Models**

If your profile has models configured:
```bash
# Download Vosk and Piper models into rootfs
sudo make models

# Then rebuild QCOW2 to include them
USE_LOOP=1 make rootfs-qcow2
```

### **Customization**

**Change VM resources:** Edit `configs/qemu_config.mk`
- `QEMU_RAM` - RAM in MB (default: 2048)
- `QEMU_CPUS` - CPU cores (default: 2)
- `QEMU_DISK_GB` - Disk size (default: 20)

**Change packages:** Edit `configs/builder.toml`
- Add packages to `rootfs_extra_packages` in your profile
- Run `make configure` to regenerate config
- Rebuild rootfs: `make rootfs-arch`

### **Quick Updates (Without Full Rebuild)**

**Update Project-JARVIS code:**
```bash
git submodule update --remote Project-JARVIS
make inject-jarvis
make boot-arch
```

**Update Python dependencies:**
```bash
make inject-jarvis-deps
make boot-arch
```

### **Legacy Build (Kernel + ISO)**

For building custom kernel and ISO (not recommended for development):
```bash
make kernel      # Build custom kernel (30-60 min)
make packages    # Build JARVIS packages
make iso         # Create bootable ISO
```

## 🔧 **Understanding the Linux Kernel**

Since you're new to kernel development, here's what you need to know:

### **What is the Linux Kernel?**
The kernel is the core of any Linux system. It's the bridge between your hardware and software. Think of it as the "brain" that:
- Manages memory and CPU
- Handles input/output (keyboard, mouse, network, etc.)
- Manages processes and security
- Provides services to applications

### **Why a Custom Kernel for JARVIS OS?**
We're optimizing the kernel for AI workloads:
- **Real-time responsiveness** - JARVIS needs to respond quickly to voice commands
- **Audio optimization** - Better support for microphones and speakers
- **AI acceleration** - Support for GPU acceleration and specialized AI chips
- **Security hardening** - Protect AI processing from interference

### **Kernel Building Process**
1. **Configuration** - Choose which features to include
2. **Compilation** - Convert source code to machine code
3. **Installation** - Place kernel files in the right locations

## 📦 **Build System Explained**

### **Main Makefile Targets**

| Target | Purpose | Time Required |
|--------|---------|---------------|
| `make setup` | Create build directories | 30 seconds |
| `make kernel` | Build custom kernel | 30-60 minutes |
| `make packages` | Build JARVIS packages | 5-10 minutes |
| `make iso` | Create bootable ISO | 2-5 minutes |
| `make all` | Build everything | 45-75 minutes |

### **Build Dependencies**
The system will automatically install:
- **Development tools** - gcc, make, etc.
- **Kernel tools** - bc, bison, flex
- **Package tools** - rpm-build, createrepo
- **ISO tools** - genisoimage, xorriso

## 🎤 **JARVIS Integration**

### **How JARVIS Works**
For detailed information about JARVIS's architecture and voice processing pipeline, see the [Project-JARVIS README](Project-JARVIS/README.md).

**High-level flow:**
1. **Voice Input** - Microphone captures your speech
2. **Speech Recognition** - Converts speech to text
3. **AI Processing** - LLM understands your request
4. **Tool Discovery** - SuperMCP finds the right tools
5. **Execution** - Commands are executed
6. **Voice Output** - Text-to-speech responds back to you

### **System Integration**
- **Auto-start on boot** - JARVIS starts automatically
- **Systemd service** - Managed like any system service
- **Security hardening** - Runs in sandboxed environment
- **Resource management** - CPU and memory limits

## 🔍 **Troubleshooting**

### **Common Issues**

**"make: command not found"**
```bash
# Install build tools
sudo dnf groupinstall "Development Tools"  # Fedora
sudo apt-get install build-essential       # Ubuntu
```

**"No space left on device"**
```bash
# Clean build artifacts
make clean
# Or clean just kernel
cd linux && make clean
```

**"Kernel build fails"**
```bash
# Check dependencies
make build-deps
# Check kernel configuration
cd linux && make menuconfig
```

**"JARVIS won't start"**
```bash
# Check service status
sudo systemctl status jarvis
# Check logs
sudo journalctl -u jarvis -f
```

### **Getting Help**
1. Check the logs: `sudo journalctl -u jarvis -f`
2. Test components individually: `make test`
3. Verify dependencies: `make build-deps`

## 🚀 **Advanced Usage**

### **Custom Kernel Configuration**
```bash
# Edit kernel configuration
cd linux
make menuconfig

# Apply your changes
make -j$(nproc)
```

### **Adding Custom MCP Servers**
```bash
# Add to Project-JARVIS/jarvis/SuperMCP/
# JARVIS will automatically discover them
```

### **Building for Different Architectures**
```bash
# Edit Makefile
ARCH = arm64  # or x86_64
make kernel
```

## 📚 **Learning Resources**

### **Linux Kernel**
- [Linux Kernel Documentation](https://www.kernel.org/doc/html/latest/)
- [Kernel Newbies](https://kernelnewbies.org/)
- [Linux From Scratch](https://www.linuxfromscratch.org/)

### **JARVIS Development**
- [Project-JARVIS README](Project-JARVIS/README.md)
- [SuperMCP Documentation](Project-JARVIS/jarvis/SuperMCP/)
- [Kernel Integration Guide](Project-JARVIS/packaging/kernel-integration-guide.md)

## 🤝 **Contributing**

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with `make test`
5. Submit a pull request

## 📄 **License**

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🎉 **What's Next?**

Once you have JARVIS OS running:
1. **Customize JARVIS** - Add your own MCP servers
2. **Optimize the kernel** - Tune for your hardware
3. **Create distributions** - Share with others
4. **Develop applications** - Build AI-native apps

---

**Welcome to the future of computing! 🤖✨**

*JARVIS OS - Where AI meets the operating system*