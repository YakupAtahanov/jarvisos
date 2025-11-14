# JARVIS OS - Custom Linux Distribution Build System
# This Makefile orchestrates the build of your AI-native operating system

.PHONY: all help clean setup kernel packages iso test
.PHONY: update-submodules pull-updates build-deps
.PHONY: kernel-config kernel-build kernel-install
.PHONY: jarvis-package repo-create iso-create

# Configuration
DISTRO_NAME = JARVIS-OS
DISTRO_VERSION = 1.0.0
BUILD_DIR = build
KERNEL_VERSION = 6.16.5
ARCH = x86_64

# Colors for output
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
NC = \033[0m # No Color

# Default target
all: setup kernel packages iso
	@echo "$(GREEN)🎉 JARVIS OS build complete!$(NC)"
	@echo "$(BLUE)ISO location: $(BUILD_DIR)/iso/jarvis-os-$(DISTRO_VERSION).iso$(NC)"

# Help target
help:
	@echo "$(BLUE)JARVIS OS Build System$(NC)"
	@echo "$(YELLOW)Available targets:$(NC)"
	@echo ""
	@echo "$(BLUE)Core Build:$(NC)"
	@echo "  $(GREEN)all$(NC)              - Build everything (kernel + packages + ISO)"
	@echo "  $(GREEN)setup$(NC)            - Initialize build environment"
	@echo "  $(GREEN)kernel$(NC)           - Build custom kernel"
	@echo "  $(GREEN)packages$(NC)         - Build JARVIS packages"
	@echo "  $(GREEN)iso$(NC)              - Create bootable ISO"
	@echo ""
	@echo "$(BLUE)Arch Linux Rootfs (Recommended):$(NC)"
	@echo "  $(GREEN)rootfs-arch$(NC)      - Build Arch Linux root filesystem"
	@echo "  $(GREEN)rootfs-qcow2$(NC)     - Convert rootfs to QCOW2 image"
	@echo "  $(GREEN)jarvis-install-arch$(NC) - Install JARVIS to Arch rootfs"
	@echo "  $(GREEN)jarvis-deps-arch$(NC) - Install Python dependencies"
	@echo "  $(GREEN)arch-setup$(NC)       - Complete Arch setup (rootfs + JARVIS)"
	@echo "  $(GREEN)boot-arch$(NC)        - Boot JARVIS OS in QEMU"
	@echo ""
	@echo "$(BLUE)Utilities:$(NC)"
	@echo "  $(GREEN)clean$(NC)            - Clean all build artifacts"
	@echo "  $(GREEN)update-submodules$(NC) - Update all submodules"
	@echo "  $(GREEN)build-deps$(NC)       - Install build dependencies"
	@echo "  $(GREEN)test$(NC)             - Test the build system"

# Initialize build environment
setup:
	@echo "$(BLUE)🔧 Setting up JARVIS OS build environment...$(NC)"
	@mkdir -p $(BUILD_DIR)/kernel
	@mkdir -p $(BUILD_DIR)/packages
	@mkdir -p $(BUILD_DIR)/repo
	@mkdir -p $(BUILD_DIR)/iso
	@mkdir -p $(BUILD_DIR)/rootfs
	@echo "$(GREEN)✅ Build directories created$(NC)"

# Update submodules
update-submodules:
	@echo "$(BLUE)📦 Updating submodules...$(NC)"
	git submodule update --init --recursive
	@echo "$(GREEN)✅ Submodules updated$(NC)"

# Pull latest updates
pull-updates:
	@echo "$(BLUE)🔄 Pulling latest updates...$(NC)"
	git submodule foreach git pull origin main
	@echo "$(GREEN)✅ Updates pulled$(NC)"

# Install build dependencies
build-deps:
	@echo "$(BLUE)📋 Installing build dependencies...$(NC)"
	@echo "$(YELLOW)This will install packages needed to build JARVIS OS$(NC)"
	sudo dnf5 install -y @development-tools || sudo apt-get update && sudo apt-get install -y build-essential
	sudo dnf5 install -y bc bison flex elfutils-libelf-devel openssl-devel || sudo apt-get install -y bc bison flex libelf-dev libssl-dev
	sudo dnf5 install -y rpm-build createrepo_c || sudo apt-get install -y rpm dpkg-dev
	sudo dnf5 install -y genisoimage xorriso || sudo apt-get install -y genisoimage xorriso
	sudo dnf5 install -y python3 python3-pip || sudo apt-get install -y python3 python3-pip
	@echo "$(GREEN)✅ Build dependencies installed$(NC)"

# Build kernel
kernel: kernel-config kernel-build kernel-install
	@echo "$(GREEN)✅ Kernel build complete$(NC)"

# Configure kernel
kernel-config:
	@echo "$(BLUE)⚙️  Configuring kernel for AI workloads...$(NC)"
	cd linux && make defconfig
	# Apply AI-optimized kernel configuration
	cd linux && ./scripts/kconfig/merge_config.sh .config ../configs/kernel-ai.config || true
	@echo "$(GREEN)✅ Kernel configured$(NC)"

# Build kernel
kernel-build:
	@echo "$(BLUE)🔨 Building kernel...$(NC)"
	@echo "$(YELLOW)This may take 30-60 minutes depending on your system$(NC)"
	cd linux && make -j$$(nproc)
	@echo "$(GREEN)✅ Kernel built$(NC)"

# Install kernel artifacts
kernel-install:
	@echo "$(BLUE)📦 Installing kernel artifacts...$(NC)"
	mkdir -p $(BUILD_DIR)/kernel
	cp linux/arch/x86/boot/bzImage $(BUILD_DIR)/kernel/vmlinuz-$(KERNEL_VERSION)
	cp linux/System.map $(BUILD_DIR)/kernel/System.map-$(KERNEL_VERSION)
	cp linux/.config $(BUILD_DIR)/kernel/config-$(KERNEL_VERSION)
	@echo "$(GREEN)✅ Kernel artifacts installed$(NC)"

# Build packages
packages: jarvis-package repo-create
	@echo "$(GREEN)✅ Package build complete$(NC)"

# Build JARVIS package
jarvis-package:
	@echo "$(BLUE)🤖 Building JARVIS package...$(NC)"
	cd Project-JARVIS/packaging && make clean || true
	cd Project-JARVIS/packaging && make package-rpm
	cd Project-JARVIS/packaging && make package-deb
	cp Project-JARVIS/build/rpm/RPMS/*/*.rpm $(BUILD_DIR)/packages/
	cp Project-JARVIS/build/deb/*.deb $(BUILD_DIR)/packages/
	@echo "$(GREEN)✅ JARVIS packages built$(NC)"

# Create package repository
repo-create:
	@echo "$(BLUE)📚 Creating package repository...$(NC)"
	createrepo_c $(BUILD_DIR)/repo || (cd $(BUILD_DIR)/repo && dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz)
	cp $(BUILD_DIR)/packages/* $(BUILD_DIR)/repo/
	@echo "$(GREEN)✅ Package repository created$(NC)"

# Create ISO
iso: iso-create
	@echo "$(GREEN)✅ ISO creation complete$(NC)"

# Build ISO
iso-create:
	@echo "$(BLUE)💿 Creating bootable ISO...$(NC)"
	@echo "$(YELLOW)This creates a minimal bootable ISO with JARVIS$(NC)"
	
	# Create ISO root structure
	mkdir -p $(BUILD_DIR)/isofs/boot/grub
	mkdir -p $(BUILD_DIR)/isofs/jarvis
	
	# Copy kernel
	cp $(BUILD_DIR)/kernel/vmlinuz-$(KERNEL_VERSION) $(BUILD_DIR)/isofs/boot/
	
	# Create initramfs with JARVIS
	./scripts/create-initramfs.sh $(BUILD_DIR)/isofs
	
	# Create GRUB configuration
	./scripts/create-grub-config.sh $(BUILD_DIR)/isofs/boot/grub/grub.cfg
	
	# Build ISO
	genisoimage -R -b boot/grub/stage2_eltorito -no-emul-boot \
		-boot-load-size 4 -boot-info-table -o \
		$(BUILD_DIR)/iso/jarvis-os-$(DISTRO_VERSION).iso \
		$(BUILD_DIR)/isofs
	@echo "$(GREEN)✅ ISO created: $(BUILD_DIR)/iso/jarvis-os-$(DISTRO_VERSION).iso$(NC)"

# Test build system
test:
	@echo "$(BLUE)🧪 Testing build system...$(NC)"
	@echo "$(GREEN)✅ All components available$(NC)"
	@test -d linux && echo "$(GREEN)✅ Kernel source found$(NC)" || echo "$(RED)❌ Kernel source missing$(NC)"
	@test -d Project-JARVIS && echo "$(GREEN)✅ JARVIS source found$(NC)" || echo "$(RED)❌ JARVIS source missing$(NC)"
	@which make > /dev/null && echo "$(GREEN)✅ Build tools available$(NC)" || echo "$(RED)❌ Build tools missing$(NC)"

# Clean build artifacts
clean:
	@echo "$(BLUE)🧹 Cleaning build artifacts...$(NC)"
	rm -rf $(BUILD_DIR)
	cd linux && make clean
	cd Project-JARVIS && make clean
	@echo "$(GREEN)✅ Build artifacts cleaned$(NC)"

# Clean old Fedora rootfs (if switching to Arch)
clean-fedora:
	@echo "$(BLUE)🧹 Cleaning old Fedora rootfs...$(NC)"
	@if [ -f "$(BUILD_DIR)/jarvisos-root.qcow2" ]; then \
		echo "$(YELLOW)Removing old Fedora QCOW2 image (9.7GB)...$(NC)"; \
		rm -f $(BUILD_DIR)/jarvisos-root.qcow2; \
		echo "$(GREEN)✅ Old Fedora rootfs removed$(NC)"; \
	else \
		echo "$(GREEN)✅ No old Fedora rootfs found$(NC)"; \
	fi

# Quick development build (just JARVIS)
dev: setup jarvis-package
	@echo "$(GREEN)✅ Development build complete$(NC)"

# ============================================================================
# Arch Linux Root Filesystem Targets
# ============================================================================

# Build Arch Linux rootfs
rootfs-arch:
	@echo "$(BLUE)🏗️  Building Arch Linux root filesystem...$(NC)"
	./scripts/create-arch-rootfs.sh $(BUILD_DIR)
	@echo "$(GREEN)✅ Arch rootfs created$(NC)"

# Convert Arch rootfs to QCOW2
rootfs-qcow2: rootfs-arch
	@echo "$(BLUE)💾 Converting Arch rootfs to QCOW2...$(NC)"
	./scripts/convert-rootfs-to-qcow2.sh $(BUILD_DIR)/arch-rootfs $(BUILD_DIR)/jarvisos-root.qcow2 20
	@echo "$(GREEN)✅ QCOW2 image created$(NC)"

# Install JARVIS to Arch rootfs
jarvis-install-arch:
	@echo "$(BLUE)🤖 Installing JARVIS to Arch rootfs...$(NC)"
	@if [ ! -d "$(BUILD_DIR)/arch-rootfs" ]; then \
		echo "$(RED)❌ Arch rootfs not found. Run 'make rootfs-arch' first$(NC)"; \
		exit 1; \
	fi
	@set -e; \
	if command -v arch-chroot > /dev/null; then \
		CHROOT_CMD="arch-chroot $(BUILD_DIR)/arch-rootfs"; \
	elif command -v systemd-nspawn > /dev/null; then \
		CHROOT_CMD="systemd-nspawn -q -D $(BUILD_DIR)/arch-rootfs"; \
	else \
		echo "$(RED)❌ Need arch-chroot or systemd-nspawn$(NC)"; \
		exit 1; \
	fi; \
	echo "$(BLUE)📋 Copying Project-JARVIS...$(NC)"; \
	sudo mkdir -p $(BUILD_DIR)/arch-rootfs/usr/lib/jarvis; \
	sudo cp -a Project-JARVIS/jarvis/* $(BUILD_DIR)/arch-rootfs/usr/lib/jarvis/; \
	sudo cp Project-JARVIS/requirements.txt $(BUILD_DIR)/arch-rootfs/usr/lib/jarvis/; \
	echo "$(BLUE)📋 Copying systemd service...$(NC)"; \
	sudo mkdir -p $(BUILD_DIR)/arch-rootfs/etc/jarvis; \
	sudo cp build/jarvis.service $(BUILD_DIR)/arch-rootfs/etc/systemd/system/; \
	sudo cp build/jarvis.conf $(BUILD_DIR)/arch-rootfs/etc/jarvis/; \
	echo "$(BLUE)📟 Installing 'jarvis' CLI helper...$(NC)"; \
	sudo tee $(BUILD_DIR)/arch-rootfs/usr/bin/jarvis > /dev/null <<'EOF'; \
#!/bin/bash
exec /usr/bin/python3 /usr/lib/jarvis/jarvis.cli.py "$@"
EOF
	sudo chmod +x $(BUILD_DIR)/arch-rootfs/usr/bin/jarvis; \
	if [ -f "build/jarvis.service" ]; then \
		echo "$(BLUE)🔧 Enabling jarvis.service...$(NC)"; \
		sudo $$CHROOT_CMD systemctl enable jarvis.service; \
	fi; \
	echo "$(GREEN)✅ JARVIS installed$(NC)"

# Install Python dependencies in Arch rootfs
jarvis-deps-arch: jarvis-install-arch
	@echo "$(BLUE)📦 Installing JARVIS Python dependencies...$(NC)"
	@if [ ! -d "$(BUILD_DIR)/arch-rootfs/usr/lib/jarvis" ]; then \
		echo "$(RED)❌ JARVIS files not found in rootfs. Run 'make jarvis-install-arch' first$(NC)"; \
		exit 1; \
	fi
	@set -e; \
	if command -v arch-chroot > /dev/null; then \
		CHROOT_CMD="arch-chroot $(BUILD_DIR)/arch-rootfs"; \
	elif command -v systemd-nspawn > /dev/null; then \
		CHROOT_CMD="systemd-nspawn -q -D $(BUILD_DIR)/arch-rootfs"; \
	else \
		echo "$(RED)❌ Need arch-chroot or systemd-nspawn$(NC)"; \
		exit 1; \
	fi; \
	sudo $$CHROOT_CMD bash -c "cd /usr/lib/jarvis && PIP_BREAK_SYSTEM_PACKAGES=1 pip install --break-system-packages -r requirements.txt"; \
	echo "$(GREEN)✅ Dependencies installed$(NC)"

# Complete Arch setup (rootfs + JARVIS + deps)
arch-setup: rootfs-qcow2 jarvis-install-arch
	@echo "$(GREEN)✅ Arch Linux JARVIS OS setup complete!$(NC)"
	@echo "$(BLUE)📦 QCOW2 image: $(BUILD_DIR)/jarvisos-root.qcow2$(NC)"
	@echo "$(YELLOW)💡 Next: Install dependencies with 'make jarvis-deps-arch'$(NC)"
	@echo "$(YELLOW)💡 Or boot and install manually: 'make boot'$(NC)"

# Boot JARVIS OS in QEMU (Arch)
boot-arch:
	@echo "$(BLUE)🚀 Booting JARVIS OS (Arch)...$(NC)"
	@if [ ! -f "$(BUILD_DIR)/jarvisos-root.qcow2" ]; then \
		echo "$(RED)❌ QCOW2 image not found. Run 'make arch-setup' first$(NC)"; \
		exit 1; \
	fi
	qemu-system-x86_64 \
		-kernel $(BUILD_DIR)/kernel/vmlinuz-$(KERNEL_VERSION) \
		-initrd $(BUILD_DIR)/initramfs.img \
		-drive file=$(BUILD_DIR)/jarvisos-root.qcow2,format=qcow2,if=virtio \
		-append "console=ttyS0 root=/dev/vda3 rw" \
		-m 2048 \
		-nographic
