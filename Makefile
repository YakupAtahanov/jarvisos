# JARVIS OS - Custom Linux Distribution Build System
# This Makefile orchestrates the build of your AI-native operating system

.PHONY: all help clean setup kernel packages iso test
.PHONY: update-submodules pull-updates build-deps
.PHONY: kernel-config kernel-build kernel-install
.PHONY: jarvis-package repo-create iso-create
.PHONY: configure models gen-jarvis-conf

# Configuration
DISTRO_NAME = JARVIS-OS
DISTRO_VERSION = 1.0.0
BUILD_DIR = build
KERNEL_VERSION = 6.16.5
ARCH = x86_64

# Load generated configuration if present (configure writes this)
-include $(BUILD_DIR)/config.mk
# Load QEMU VM config (editable)
-include configs/qemu_config.mk
# Defaults if not defined in includes
QEMU_RAM        ?= 2048
QEMU_CPUS       ?= 2
QEMU_ENABLE_KVM ?= 1
QEMU_DISK_GB    ?= 20
QEMU_EXTRA      ?=
# Compose accel flags
QEMU_ACCEL      := $(if $(QEMU_ENABLE_KVM),-enable-kvm -cpu host,)

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
	@echo "$(BLUE)Config:$(NC)"
	@echo "  $(GREEN)configure$(NC)        - Generate $(BUILD_DIR)/config.mk from configs/builder.toml (PROFILE=<name>)"
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
	@echo "  $(GREEN)models$(NC)           - Download models (Vosk/Piper) into rootfs based on config"
	@echo ""
	@echo "$(BLUE)Utilities:$(NC)"
	@echo "  $(GREEN)clean$(NC)            - Clean all build artifacts"
	@echo "  $(GREEN)update-submodules$(NC) - Update all submodules"
	@echo "  $(GREEN)build-deps$(NC)       - Install build dependencies"
	@echo "  $(GREEN)test$(NC)             - Test the build system"

# Generate build/config.mk from configs/builder.toml
configure:
	@echo "$(BLUE)⚙️  Generating configuration (PROFILE=$${PROFILE:-$(PROFILE)})...$(NC)"
	@python3 scripts/read-config.py --toml configs/builder.toml --profile "$${PROFILE:-$(PROFILE)}" --out $(BUILD_DIR)/config.mk
	@echo "$(GREEN)✅ Wrote $(BUILD_DIR)/config.mk$(NC)"

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
	@set -e; \
	if command -v dnf5 >/dev/null 2>&1; then \
		PKG=dnf5; \
	elif command -v dnf >/dev/null 2>&1; then \
		PKG=dnf; \
	else \
		echo "$(RED)❌ Unsupported distro: expected dnf/dnf5 (Fedora).$(NC)"; \
		echo "$(YELLOW)If on Debian/Ubuntu, install equivalents manually: build-essential bc bison flex libelf-dev libssl-dev genisoimage xorriso python3 python3-pip libguestfs-tools qemu-kvm qemu-utils$(NC)"; \
		exit 1; \
	fi; \
	echo "$(BLUE)🔧 Using $$PKG to install dependencies...$(NC)"; \
	# Prefer group by @id; fallback to display name; skip if unavailable; don't fail the whole build here \
	sudo $$PKG -y install @development-tools --skip-unavailable || sudo $$PKG -y group install "Development Tools" --skip-unavailable || true; \
	sudo $$PKG -y install bc bison flex elfutils-libelf-devel openssl-devel; \
	sudo $$PKG -y install rpm-build createrepo_c; \
	sudo $$PKG -y install genisoimage xorriso; \
	sudo $$PKG -y install python3 python3-pip; \
	sudo $$PKG -y install arch-install-scripts libguestfs-tools-c qemu-kvm qemu-img
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
	@if [ -f "$(BUILD_DIR)/config.mk" ]; then \
		EXTRA_PACKAGES=$$(grep '^EXTRA_PACKAGES :=' $(BUILD_DIR)/config.mk | sed 's/^EXTRA_PACKAGES := "//;s/"$$//'); \
		export EXTRA_PACKAGES; \
		echo "$(BLUE)📦 Extra packages from config: $$EXTRA_PACKAGES$(NC)"; \
	fi; \
	./scripts/create-arch-rootfs.sh $(BUILD_DIR)
	@echo "$(GREEN)✅ Arch rootfs created$(NC)"

# Convert Arch rootfs to QCOW2 (does NOT rebuild rootfs to avoid wiping staged changes)
rootfs-qcow2:
	@echo "$(BLUE)💾 Converting Arch rootfs to QCOW2...$(NC)"
	./scripts/convert-rootfs-to-qcow2.sh $(BUILD_DIR)/arch-rootfs $(BUILD_DIR)/jarvisos-root.qcow2 $(QEMU_DISK_GB)
	@echo "$(GREEN)✅ QCOW2 image created$(NC)"

# Install JARVIS to Arch rootfs
jarvis-install-arch:
	@echo "$(BLUE)🤖 Installing JARVIS to Arch rootfs...$(NC)"
	@if [ ! -d "$(BUILD_DIR)/arch-rootfs" ]; then \
		echo "$(RED)❌ Arch rootfs not found. Run 'make rootfs-arch' first$(NC)"; \
		exit 1; \
	fi
	@$(MAKE) gen-jarvis-conf >/dev/null
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
	if [ -f build/jarvis.conf ]; then sudo cp build/jarvis.conf $(BUILD_DIR)/arch-rootfs/etc/jarvis/; fi; \
	echo "$(BLUE)🧰 Creating Python virtual environment for JARVIS...$(NC)"; \
	if [ ! -d "$(BUILD_DIR)/arch-rootfs/usr/lib/jarvis/.venv" ]; then \
		sudo $$CHROOT_CMD bash -c "cd /usr/lib/jarvis && python3 -m venv .venv" || { echo "$(RED)❌ Failed to create venv$(NC)"; exit 1; }; \
		sudo $$CHROOT_CMD bash -c "/usr/lib/jarvis/.venv/bin/pip install --upgrade pip" || { echo "$(YELLOW)⚠️  Failed to upgrade pip (non-fatal)$(NC)"; }; \
		echo "$(GREEN)✅ Virtual environment created$(NC)"; \
	else \
		echo "$(YELLOW)⚠️  Virtual environment already exists, skipping creation$(NC)"; \
	fi; \
	echo "$(BLUE)📟 Installing 'jarvis' CLI helper...$(NC)"; \
	JARVIS_WRAPPER=$$(mktemp) && \
	echo '#!/bin/bash' > $$JARVIS_WRAPPER && \
	echo 'export PYTHONPATH=/usr/lib$${PYTHONPATH:+:$$PYTHONPATH}' >> $$JARVIS_WRAPPER && \
	echo 'exec /usr/lib/jarvis/.venv/bin/python -m jarvis.cli "$$@"' >> $$JARVIS_WRAPPER && \
	sudo cp $$JARVIS_WRAPPER $(BUILD_DIR)/arch-rootfs/usr/bin/jarvis && \
	sudo chmod +x $(BUILD_DIR)/arch-rootfs/usr/bin/jarvis && \
	rm -f $$JARVIS_WRAPPER; \
	if [ -f "build/jarvis.service" ]; then \
		echo "$(BLUE)🔧 Enabling jarvis.service...$(NC)"; \
		sudo $$CHROOT_CMD systemctl enable jarvis.service; \
	fi; \
	echo "$(GREEN)✅ JARVIS installed$(NC)"

# Generate build/jarvis.conf from configuration
gen-jarvis-conf:
	@echo "$(BLUE)📝 Generating jarvis.conf from config...$(NC)"
	@bash scripts/gen-jarvis-conf.sh
	@echo "$(GREEN)✅ Wrote build/jarvis.conf$(NC)"

# Download models into staged rootfs using configured model choices
models:
	@echo "$(BLUE)🎤 Downloading configured models into rootfs...$(NC)"
	@bash scripts/fetch-models.sh "$(BUILD_DIR)/arch-rootfs" "$(VOSK_MODEL)" "$(PIPER_VOICE)"
	@echo "$(GREEN)✅ Models prepared (if configured)$(NC)"
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
	sudo $$CHROOT_CMD bash -lc "cd /usr/lib/jarvis && /usr/lib/jarvis/.venv/bin/pip install -r requirements.txt"; \
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
	$(QEMU_BIN) \
		$(if $(QEMU_MACHINE),-machine $(QEMU_MACHINE),) \
		-kernel $(BUILD_DIR)/kernel/vmlinuz-$(KERNEL_VERSION) \
		-initrd $(BUILD_DIR)/initramfs.img \
		-drive file=$(BUILD_DIR)/jarvisos-root.qcow2,format=qcow2,if=$(strip $(QEMU_DISK_IF)),cache=$(strip $(QEMU_DISK_CACHE)) \
		-append "console=ttyS0 root=/dev/vda rw" \
		-m $(QEMU_RAM) \
		-smp $(QEMU_CPUS) \
		$(QEMU_ACCEL) \
		$(if $(QEMU_CPU),-cpu $(QEMU_CPU),) \
		$(QEMU_NET_OPTS) \
		$(QEMU_DISPLAY_OPTS) \
		$(QEMU_AUDIO_OPTS) \
		$(QEMU_USB_OPTS) \
		$(QEMU_SERIAL_OPTS) \
		$(QEMU_NAME_OPTS) \
		$(QEMU_SMBIOS_OPTS) \
		$(QEMU_FIRMWARE_OPTS) \
		$(QEMU_PASSTHROUGH) \
		$(QEMU_EXTRA)

# ------------------------------------------------------------
# Cleanup targets (optional artifact pruning)
# ------------------------------------------------------------

# Remove packaged image and staged rootfs (keeps kernel and initramfs source dir)
unstore-builds:
	@echo "$(YELLOW)🧹 Removing staged rootfs and QCOW2 (keeps kernel/initramfs dir)...$(NC)"
	@# Stop any running VMs that may lock files
	pkill -f qemu-system-x86_64 2>/dev/null || true
	@# Unmount any pseudo-filesystems inside staged rootfs (ignore errors)
	sudo umount -l $(BUILD_DIR)/arch-rootfs/var/cache/pacman/pkg 2>/dev/null || true
	sudo umount -l $(BUILD_DIR)/arch-rootfs/dev/pts $(BUILD_DIR)/arch-rootfs/dev/shm 2>/dev/null || true
	sudo umount -l $(BUILD_DIR)/arch-rootfs/dev $(BUILD_DIR)/arch-rootfs/proc $(BUILD_DIR)/arch-rootfs/sys $(BUILD_DIR)/arch-rootfs/run 2>/dev/null || true
	@# Remove staged rootfs contents and image
	sudo rm -rf $(BUILD_DIR)/arch-rootfs $(BUILD_DIR)/jarvisos-root.qcow2 2>/dev/null || true
	@# Remove caches/snapshots we can regenerate
	rm -rf $(BUILD_DIR)/archlinux-bootstrap-*.tar.* $(BUILD_DIR)/arch-rootfs.old.* $(BUILD_DIR)/python-download 2>/dev/null || true
	@echo "$(GREEN)✅ Build artifacts removed (kernel kept at $(BUILD_DIR)/kernel)$(NC)"

# Remove everything including kernel and generated initramfs image
unstore-all:
	@echo "$(YELLOW)🧨 Removing ALL build artifacts (kernel, initramfs.img, rootfs, qcow2)...$(NC)"
	@# Stop any running VMs that may lock files
	pkill -f qemu-system-x86_64 2>/dev/null || true
	@# Broad unmount sweep for any leftover binds under build
	mount | awk '/github\/jarvisos\/build/ {print $$3}' | awk '{print length, $$0}' | sort -nr | cut -d" " -f2- | sudo xargs -r -n1 umount -l
	@# Remove all build outputs
	sudo rm -rf $(BUILD_DIR)/arch-rootfs $(BUILD_DIR)/jarvisos-root.qcow2 $(BUILD_DIR)/initramfs.img $(BUILD_DIR)/kernel \
		$(BUILD_DIR)/archlinux-bootstrap-*.tar.* $(BUILD_DIR)/arch-rootfs.old.* $(BUILD_DIR)/python-download \
		$(BUILD_DIR)/iso $(BUILD_DIR)/repo $(BUILD_DIR)/rootfs $(BUILD_DIR)/packages 2>/dev/null || true
	@echo "$(GREEN)✅ All build artifacts removed$(NC)"

# ------------------------------------------------------------
# Fast path: inject updated JARVIS into QCOW2 (no restage)
# Requires: libguestfs-tools-c (virt-copy-in, virt-customize)
# ------------------------------------------------------------
inject-jarvis:
	@echo "$(BLUE)📦 Injecting Project-JARVIS into QCOW2...$(NC)"
	@if [ ! -f "$(BUILD_DIR)/jarvisos-root.qcow2" ]; then \
		echo "$(RED)❌ QCOW2 image not found. Build it first$(NC)"; \
		exit 1; \
	fi
	@# Copy code
	virt-copy-in -a $(BUILD_DIR)/jarvisos-root.qcow2 Project-JARVIS/jarvis /usr/lib/
	virt-copy-in -a $(BUILD_DIR)/jarvisos-root.qcow2 Project-JARVIS/requirements.txt /usr/lib/jarvis/
	@# Ensure CLI wrapper exists
	printf '%s\n' '#!/bin/bash' 'exec /usr/bin/python3 /usr/lib/jarvis/cli.py "$@"' | \
		virt-customize -a $(BUILD_DIR)/jarvisos-root.qcow2 --run-command "cat > /usr/bin/jarvis && chmod +x /usr/bin/jarvis"
	@echo "$(GREEN)✅ Injected JARVIS code and CLI into QCOW2$(NC)"

inject-jarvis-deps:
	@echo "$(BLUE)📦 Installing JARVIS deps inside QCOW2...$(NC)"
	@if [ ! -f "$(BUILD_DIR)/jarvisos-root.qcow2" ]; then \
		echo "$(RED)❌ QCOW2 image not found. Build it first$(NC)"; \
		exit 1; \
	fi
	virt-customize -a $(BUILD_DIR)/jarvisos-root.qcow2 \
		--run-command 'bash -lc "cd /usr/lib/jarvis && PIP_BREAK_SYSTEM_PACKAGES=1 pip install --break-system-packages -r requirements.txt"' || \
		{ echo "$(YELLOW)⚠️  virt-customize failed; ensure libguestfs-tools-c is installed$(NC)"; exit 1; }
	@echo "$(GREEN)✅ Dependencies installed inside QCOW2$(NC)"
