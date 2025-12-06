# JARVIS OS ISO Build Orchestrator
# Simple Makefile to orchestrate the step-by-step ISO build process
include build.config

# Validate required variables
ifeq ($(strip $(SCRIPTS_DIR)),)
    $(error SCRIPTS_DIR not set in build.config)
endif
ifeq ($(strip $(PROJECT_ROOT)),)
    $(error PROJECT_ROOT not set in build.config)
endif

# Resolve SCRIPTS_DIR relative to PROJECT_ROOT (if not absolute)
SCRIPTS_DIR := $(PROJECT_ROOT)$(SCRIPTS_DIR)

# Use config values if set and non-empty, otherwise use defaults
BUILD_DIR := $(PROJECT_ROOT)$(BUILD_DIR)
BUILD_DEPS_DIR := $(PROJECT_ROOT)$(BUILD_DEPS_DIR)
ISO_FILE := $(BUILD_DEPS_DIR)/$(ISO_FILE)
ISO_EXTRACT_DIR := $(PROJECT_ROOT)$(ISO_EXTRACT_DIR)

# Colors
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m

.PHONY: help list status step1 step2 step3 step4 step5 step6 step7 all clean

# Default target
help:
	@echo "$(BLUE)JARVIS OS ISO Build Steps$(NC)"
	@echo ""
	@echo "Available steps:"
	@echo "  $(GREEN)make step1$(NC)  - Extract ISO"
	@echo "  $(GREEN)make step2$(NC)  - Unsquash filesystem"
	@echo "  $(GREEN)make step3$(NC)  - Bake Wayland"
	@echo "  $(GREEN)make step4$(NC)  - Bake JARVIS"
	@echo "  $(GREEN)make step5$(NC)  - Bake Calamares (optional, not implemented yet)"
	@echo "  $(GREEN)make step6$(NC)  - Rebuild SquashFS"
	@echo "  $(GREEN)make step7$(NC)  - Rebuild ISO"
	@echo ""
	@echo "Other targets:"
	@echo "  $(GREEN)make all$(NC)    - Run all steps"
	@echo "  $(GREEN)make status$(NC) - Show build status"
	@echo "  $(GREEN)make list$(NC)   - List available scripts"
	@echo "  $(GREEN)make clean$(NC)  - Clean build artifacts"
	@echo ""

# List available scripts
list:
	@echo "$(BLUE)Available build scripts:$(NC)"
	@for script in 01-extract-iso.sh 02-unsquash-fs.sh 03-bake-wayland.sh \
	               04-bake-calamares.sh 05-bake-jarvis.sh 06-squash-fs.sh \
	               07-rebuild-iso.sh; do \
		if [ -f "$(SCRIPTS_DIR)/$$script" ]; then \
			echo "  $(GREEN)✓$(NC) $$script"; \
		else \
			echo "  $(RED)✗$(NC) $$script (not found)"; \
		fi; \
	done

# Check status of build steps
status:
	@echo "$(BLUE)Build step status:$(NC)"
	@echo ""
	@if [ -d "$(ISO_EXTRACT_DIR)" ] && [ -n "$$(ls -A $(ISO_EXTRACT_DIR) 2>/dev/null)" ]; then \
		echo "  $(GREEN)✓$(NC) Step 1: ISO extracted"; \
	else \
		echo "  $(RED)✗$(NC) Step 1: ISO not extracted"; \
	fi
	@if [ -d "$(BUILD_DIR)/iso-rootfs" ] && [ -n "$$(ls -A $(BUILD_DIR)/iso-rootfs 2>/dev/null)" ]; then \
		echo "  $(GREEN)✓$(NC) Step 2: SquashFS extracted"; \
	else \
		echo "  $(RED)✗$(NC) Step 2: SquashFS not extracted"; \
	fi
	@SQUASHFS=$$(find $(ISO_EXTRACT_DIR) -type f -iname "airootfs.sfs" 2>/dev/null | head -1); \
	if [ -n "$$SQUASHFS" ]; then \
		SIZE=$$(du -h "$$SQUASHFS" 2>/dev/null | cut -f1); \
		echo "  $(GREEN)✓$(NC) Step 6: SquashFS exists ($$SIZE)"; \
	else \
		echo "  $(RED)✗$(NC) Step 6: SquashFS not found"; \
	fi
	@FINAL_ISO=$$(find $(BUILD_DIR) -name "jarvisos-*-x86_64.iso" -type f 2>/dev/null | head -1); \
	if [ -n "$$FINAL_ISO" ]; then \
		SIZE=$$(du -h "$$FINAL_ISO" 2>/dev/null | cut -f1); \
		echo "  $(GREEN)✓$(NC) Step 7: Final ISO exists ($$SIZE)"; \
	else \
		echo "  $(RED)✗$(NC) Step 7: Final ISO not found"; \
	fi
	@echo ""

# Step 1: Extract ISO
step1:
	@echo "$(BLUE)Step 1: Extracting ISO...$(NC)"
	@bash $(SCRIPTS_DIR)/01-extract-iso.sh $(ISO_FILE) $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 1 complete$(NC)"

# Step 2: Unsquash filesystem
step2:
	@echo "$(BLUE)Step 2: Unsquashing filesystem...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/02-unsquash-fs.sh" ]; then \
		echo "$(RED)Error: Script not found: 02-unsquash-fs.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/02-unsquash-fs.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 2 complete$(NC)"

# Step 3: Bake Wayland
step3:
	@echo "$(BLUE)Step 3: Baking Wayland...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/03-bake-wayland.sh" ]; then \
		echo "$(RED)Error: Script not found: 03-bake-wayland.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/03-bake-wayland.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 3 complete$(NC)"

# Step 4: Bake JARVIS
step4:
	@echo "$(BLUE)Step 4: Baking JARVIS...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/04-bake-jarvis.sh" ]; then \
		echo "$(RED)Error: Script not found: 04-bake-jarvis.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/04-bake-jarvis.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 4 complete$(NC)"

# Step 5: Bake Calamares
step5:
	@echo "$(BLUE)Step 5: Baking Calamares...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/05-bake-calamares.sh" ]; then \
		echo "$(RED)Error: Script not found: 05-bake-calamares.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/05-bake-calamares.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 5 complete$(NC)"

# Step 6: Rebuild SquashFS
step6:
	@echo "$(BLUE)Step 6: Rebuilding SquashFS...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/06-squash-fs.sh" ]; then \
		echo "$(RED)Error: Script not found: 06-squash-fs.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/06-squash-fs.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 6 complete$(NC)"

# Step 7: Rebuild ISO
step7:
	@echo "$(BLUE)Step 7: Rebuilding ISO...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/07-rebuild-iso.sh" ]; then \
		echo "$(RED)Error: Script not found: 07-rebuild-iso.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/07-rebuild-iso.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 7 complete$(NC)"

# Run all steps in sequence
all: step1 step2 step3 step4 step5 step6 step7
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)All build steps completed!$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"

# Clean build artifacts
clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	@sudo rm -rf $(ISO_EXTRACT_DIR) $(BUILD_DIR)/iso-rootfs 2>/dev/null || true
	@echo "$(GREEN)✓ Clean complete$(NC)"

