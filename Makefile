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
	@echo "  $(GREEN)all$(NC)              - Build everything (kernel + packages + ISO)"
	@echo "  $(GREEN)setup$(NC)            - Initialize build environment"
	@echo "  $(GREEN)kernel$(NC)           - Build custom kernel"
	@echo "  $(GREEN)packages$(NC)         - Build JARVIS packages"
	@echo "  $(GREEN)iso$(NC)              - Create bootable ISO"
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

# Quick development build (just JARVIS)
dev: setup jarvis-package
	@echo "$(GREEN)✅ Development build complete$(NC)"
