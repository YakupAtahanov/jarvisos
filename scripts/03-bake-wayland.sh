#!/bin/bash
# Step 3: CachyOS → JARVIS OS transformation
#
# CachyOS KDE already ships KDE Plasma, NetworkManager, PipeWire, all drivers,
# and a working Calamares binary.  This script removes CachyOS-specific
# packages/branding and stamps JARVIS OS identity onto the rootfs.
#
# linux-jarvisos is built and installed by the NEXT step (03b-build-kernel.sh).
# linux-cachyos is KEPT in the squashfs as a fallback boot kernel.

set -eo pipefail

source build.config
source "$(dirname "${BASH_SOURCE[0]}")/build-utils.sh"

if [ -z "${SCRIPTS_DIR}" ]; then
    echo "Error: SCRIPTS_DIR not set in build.config" >&2; exit 1
fi
if [ -z "${PROJECT_ROOT}" ]; then
    echo "Error: PROJECT_ROOT not set in build.config" >&2; exit 1
fi

SCRIPTS_DIR="${PROJECT_ROOT}${SCRIPTS_DIR}"
BUILD_DIR="${PROJECT_ROOT}${BUILD_DIR}"
SQUASHFS_ROOTFS="${BUILD_DIR}/iso-rootfs"
BUILD_DEPS_DIR="${PROJECT_ROOT}${BUILD_DEPS_DIR}"
KERNEL_BACKUP_DIR="${BUILD_DIR}/kernel-files"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ ! -d "${SQUASHFS_ROOTFS}" ] || [ -z "$(ls -A "${SQUASHFS_ROOTFS}" 2>/dev/null)" ]; then
    echo -e "${RED}Error: Rootfs not extracted. Run step 2 first.${NC}" >&2; exit 1
fi
if [ ! -d "${SQUASHFS_ROOTFS}/usr/bin" ] && [ ! -d "${SQUASHFS_ROOTFS}/bin" ]; then
    echo -e "${RED}Error: Rootfs invalid — /usr/bin missing.${NC}" >&2; exit 1
fi

detect_chroot_cmd

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Step 3: CachyOS → JARVIS OS transformation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Rootfs: ${SQUASHFS_ROOTFS}${NC}"

# ── Step 1: DNS ───────────────────────────────────────────────────────────────
echo -e "${BLUE}Setting up DNS...${NC}"
if [ -f "${BUILD_DEPS_DIR}/resolv.conf" ]; then
    sudo cp "${BUILD_DEPS_DIR}/resolv.conf" "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
elif [ -f /etc/resolv.conf ]; then
    sudo cp /etc/resolv.conf "${SQUASHFS_ROOTFS}/etc/resolv.conf" 2>/dev/null || true
fi
if [ ! -s "${SQUASHFS_ROOTFS}/etc/resolv.conf" ]; then
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' \
        | sudo tee "${SQUASHFS_ROOTFS}/etc/resolv.conf" > /dev/null
fi

# ── Step 2: Bind mount + cleanup trap ────────────────────────────────────────
echo -e "${BLUE}Bind mounting rootfs...${NC}"
sudo mount --bind "${SQUASHFS_ROOTFS}" "${SQUASHFS_ROOTFS}" || {
    echo -e "${RED}Error: Failed to bind mount rootfs${NC}" >&2; exit 1
}
cleanup() {
    echo -e "${BLUE}Cleaning up mounts...${NC}"
    sudo umount "${SQUASHFS_ROOTFS}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Step 3: Pacman tuning ─────────────────────────────────────────────────────
# CachyOS ships its own mirrorlist — leave it in place (includes cachyos repos).
# Just ensure parallel downloads and no timeout are set.
echo -e "${BLUE}Tuning pacman...${NC}"
sudo sed -i -e 's/^#\?\(ParallelDownloads\).*/ParallelDownloads = 5/' \
    "${SQUASHFS_ROOTFS}/etc/pacman.conf"
sudo grep -q '^DisableDownloadTimeout' "${SQUASHFS_ROOTFS}/etc/pacman.conf" || \
    sudo sed -i '/^ParallelDownloads/a DisableDownloadTimeout' \
        "${SQUASHFS_ROOTFS}/etc/pacman.conf"
echo -e "${GREEN}✓ pacman tuned${NC}"

# ── Step 4: Keyrings ─────────────────────────────────────────────────────────
echo -e "${BLUE}Populating keyrings (archlinux + cachyos)...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman-key --populate archlinux cachyos 2>&1 || {
    echo -e "${YELLOW}Warning: keyring populate had issues — continuing${NC}"
}
echo -e "${GREEN}✓ Keyrings populated${NC}"

# ── Step 5: Sync DB ───────────────────────────────────────────────────────────
echo -e "${BLUE}Syncing package database...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Sy --noconfirm 2>&1 || {
    echo -e "${YELLOW}Warning: pacman -Sy had issues — continuing${NC}"
}

# ── Step 6: Remove CachyOS-specific packages ─────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Removing CachyOS-specific packages...${NC}"

# These are CachyOS branding / tooling that have no place in JARVIS OS.
# The calamares binary itself is intentionally kept — we replace only the config.
REMOVE_PKGS=(
    cachyos-hello
    cachyos-rate-mirrors
    cachyos-calamares-config
    cachyos-packageinstaller
    cachyos-fish-config
)

for pkg in "${REMOVE_PKGS[@]}"; do
    if sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q "${pkg}" >/dev/null 2>&1; then
        echo -e "${BLUE}  Removing: ${pkg}${NC}"
        sudo arch-chroot "${SQUASHFS_ROOTFS}" \
            pacman -R --noconfirm --nodeps "${pkg}" 2>&1 || {
            echo -e "${YELLOW}  Warning: could not remove ${pkg} — continuing${NC}"
        }
    else
        echo -e "${BLUE}  Not present: ${pkg}${NC}"
    fi
done
echo -e "${GREEN}✓ CachyOS packages removed${NC}"

# ── Step 7: JARVIS OS branding ────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Applying JARVIS OS branding...${NC}"

sudo tee "${SQUASHFS_ROOTFS}/etc/os-release" > /dev/null << 'EOF'
NAME="JARVIS OS"
PRETTY_NAME="JARVIS OS"
ID=jarvisos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://github.com/YOUR_ORG/jarvisos"
DOCUMENTATION_URL="https://github.com/YOUR_ORG/jarvisos/wiki"
LOGO=distributor-logo-jarvisos
EOF

echo "jarvisos" | sudo tee "${SQUASHFS_ROOTFS}/etc/hostname" > /dev/null

sudo tee "${SQUASHFS_ROOTFS}/etc/hosts" > /dev/null << 'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   jarvisos.localdomain jarvisos
EOF

echo -e "${GREEN}✓ JARVIS OS branding applied${NC}"

# ── Step 8: Ensure archiso package is present ─────────────────────────────────
# Provides mkinitcpio archiso and memdisk hooks — required for live boot.
echo -e "${BLUE}Ensuring archiso package is installed...${NC}"
if ! sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Q archiso >/dev/null 2>&1; then
    echo -e "${YELLOW}archiso not found — installing...${NC}"
    sudo arch-chroot "${SQUASHFS_ROOTFS}" \
        pacman -S --noconfirm --needed archiso 2>&1 || {
        echo -e "${YELLOW}Warning: could not install archiso package${NC}"
    }
else
    echo -e "${GREEN}✓ archiso already installed${NC}"
fi

# ── Step 8b: Configure mkinitcpio.conf for live-boot ─────────────────────────
# CachyOS ships a standard system mkinitcpio.conf (without archiso/memdisk hooks).
# linux-jarvisos initramfs (built in step 3b) must use these hooks to mount the
# squashfs root on live boot.  Set them explicitly rather than relying on whatever
# CachyOS packaged.
echo -e "${BLUE}Configuring mkinitcpio.conf for live-boot (archiso/memdisk hooks)...${NC}"
MKINIT_CONF="${SQUASHFS_ROOTFS}/etc/mkinitcpio.conf"
if [ -f "${MKINIT_CONF}" ]; then
    # MODULES: squashfs+overlay+loop to mount the rootfs; USB host controllers for
    # broad hardware coverage on the live environment.
    sudo sed -i \
        's/^MODULES=.*/MODULES=(squashfs overlay loop xhci_hcd xhci_pci ehci_hcd ehci_pci ohci_hcd)/' \
        "${MKINIT_CONF}"
    # HOOKS: archiso hook mounts the squashfs; memdisk supports in-memory boot.
    sudo sed -i \
        's/^HOOKS=.*/HOOKS=(base udev archiso memdisk modconf kms keyboard keymap)/' \
        "${MKINIT_CONF}"
    echo -e "${GREEN}✓ mkinitcpio.conf set (MODULES + archiso/memdisk HOOKS)${NC}"
else
    echo -e "${YELLOW}Warning: /etc/mkinitcpio.conf not found in rootfs — skipping${NC}"
fi

# ── Step 9: liveuser ──────────────────────────────────────────────────────────
# CachyOS live already ships a liveuser with autologin.
# We normalise it: ensure passwordless sudo, correct groups, and SDDM autologin.
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Configuring liveuser...${NC}"

sudo arch-chroot "${SQUASHFS_ROOTFS}" bash << 'LIVEUSER_EOF'
set -e

# Create liveuser if CachyOS used a different username
if ! id liveuser >/dev/null 2>&1; then
    echo "liveuser not found — creating..."
    for grp in wheel audio video storage optical network power scanner input; do
        getent group "${grp}" >/dev/null 2>&1 || groupadd --system "${grp}" 2>/dev/null || true
    done
    useradd -m -G wheel,audio,video,storage,optical,network,power \
            -s /bin/bash liveuser 2>/dev/null || true
else
    echo "liveuser already exists"
fi

# Passwordless login
passwd -d liveuser 2>/dev/null || true

# Ensure wheel group exists and liveuser is in it
getent group wheel >/dev/null 2>&1 || groupadd --system wheel 2>/dev/null || true
usermod -aG wheel liveuser 2>/dev/null || true

# NOPASSWD sudo for wheel — check if already set
if grep -q "^%wheel.*NOPASSWD" /etc/sudoers 2>/dev/null; then
    echo "NOPASSWD sudoers entry already present"
else
    # Remove any existing non-NOPASSWD wheel rule first
    sed -i '/^%wheel.*ALL=(ALL.*) ALL$/d' /etc/sudoers 2>/dev/null || true
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
fi
chmod 440 /etc/sudoers

# SDDM autologin — overwrite CachyOS's autologin entry with liveuser
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << 'SDDMEOF'
[Autologin]
User=liveuser
Session=plasma.desktop
SDDMEOF

# XDG user dirs
mkdir -p /home/liveuser/{Desktop,Downloads,Documents,Pictures,Music,Videos}
chown -R liveuser:liveuser /home/liveuser

echo "liveuser configured"
LIVEUSER_EOF

echo -e "${GREEN}✓ liveuser configured${NC}"

# ── Step 10: Locale ───────────────────────────────────────────────────────────
echo -e "${BLUE}Ensuring en_US.UTF-8 locale...${NC}"
sudo sed -i 's/^#\(en_US.UTF-8\)/\1/' "${SQUASHFS_ROOTFS}/etc/locale.gen" 2>/dev/null || true
sudo arch-chroot "${SQUASHFS_ROOTFS}" locale-gen 2>&1 || true
echo -e "${GREEN}✓ Locale generated${NC}"

# ── Step 11: resolv.conf — runtime symlink ───────────────────────────────────
# systemd-resolved creates /run/systemd/resolve/stub-resolv.conf at boot.
# Remove any static file and replace with the runtime symlink.
sudo rm -f "${SQUASHFS_ROOTFS}/etc/resolv.conf"
sudo ln -sf /run/systemd/resolve/stub-resolv.conf \
    "${SQUASHFS_ROOTFS}/etc/resolv.conf"
echo -e "${GREEN}✓ resolv.conf → systemd-resolved stub${NC}"

# ── Step 12: Clean package cache ─────────────────────────────────────────────
echo -e "${BLUE}Cleaning package cache...${NC}"
sudo arch-chroot "${SQUASHFS_ROOTFS}" pacman -Scc --noconfirm 2>/dev/null || true
sudo rm -rf "${SQUASHFS_ROOTFS}/var/cache/pacman/pkg/"* 2>/dev/null || true
echo -e "${GREEN}✓ Package cache cleaned${NC}"

# ── Step 13: Backup linux-cachyos kernel files for step 07 ───────────────────
# Step 07 (ISO rebuild) looks for vmlinuz-linux + initramfs-linux.img in
# kernel-files/.  We provide linux-cachyos under those standard names so step 07
# works unchanged, while also keeping the -cachyos-suffixed copies so step 07
# can add a fallback boot entry pointing to them.
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Backing up linux-cachyos kernel files for ISO rebuild (step 7)...${NC}"
mkdir -p "${KERNEL_BACKUP_DIR}"

VMLINUZ_CACHYOS=$(sudo find "${SQUASHFS_ROOTFS}/boot" \
    -name "vmlinuz-linux-cachyos" 2>/dev/null | head -1)
INITRAMFS_CACHYOS=$(sudo find "${SQUASHFS_ROOTFS}/boot" \
    -name "initramfs-linux-cachyos.img" 2>/dev/null | head -1)
INITRAMFS_CACHYOS_FALLBACK=$(sudo find "${SQUASHFS_ROOTFS}/boot" \
    -name "initramfs-linux-cachyos-fallback.img" 2>/dev/null | head -1)

if [ -z "${VMLINUZ_CACHYOS}" ]; then
    echo -e "${RED}FATAL: vmlinuz-linux-cachyos not found in rootfs/boot/${NC}" >&2
    sudo ls -la "${SQUASHFS_ROOTFS}/boot/" || true
    exit 1
fi

# Standard names (for step 07 backward compatibility — live kernel slot)
sudo cp "${VMLINUZ_CACHYOS}"   "${KERNEL_BACKUP_DIR}/vmlinuz-linux"
echo -e "${GREEN}  ✓ vmlinuz-linux (linux-cachyos) backed up${NC}"

if [ -n "${INITRAMFS_CACHYOS}" ]; then
    sudo cp "${INITRAMFS_CACHYOS}" "${KERNEL_BACKUP_DIR}/initramfs-linux.img"
    echo -e "${GREEN}  ✓ initramfs-linux.img (linux-cachyos) backed up${NC}"
fi
if [ -n "${INITRAMFS_CACHYOS_FALLBACK}" ]; then
    sudo cp "${INITRAMFS_CACHYOS_FALLBACK}" \
        "${KERNEL_BACKUP_DIR}/initramfs-linux-fallback.img"
    echo -e "${GREEN}  ✓ initramfs-linux-fallback.img backed up${NC}"
fi

# Also keep -cachyos-suffixed copies so step 07 can add a fallback boot entry
sudo cp "${VMLINUZ_CACHYOS}"   "${KERNEL_BACKUP_DIR}/vmlinuz-linux-cachyos"
[ -n "${INITRAMFS_CACHYOS}" ] && \
    sudo cp "${INITRAMFS_CACHYOS}" \
        "${KERNEL_BACKUP_DIR}/initramfs-linux-cachyos.img"

sudo chown -R "$(id -u):$(id -g)" "${KERNEL_BACKUP_DIR}" 2>/dev/null || true
sudo chmod 644 "${KERNEL_BACKUP_DIR}"/vmlinuz-linux* \
               "${KERNEL_BACKUP_DIR}"/initramfs-linux* 2>/dev/null || true

echo -e "${GREEN}✓ linux-cachyos kernel files backed up${NC}"

# ── Done ─────────────────────────────────────────────────────────────────────
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Step 3 complete: CachyOS → JARVIS OS transformation done${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Preserved : linux-cachyos (live fallback kernel)${NC}"
echo -e "${BLUE}Removed   : cachyos-hello, cachyos-calamares-config, cachyos-rate-mirrors${NC}"
echo -e "${BLUE}Applied   : JARVIS OS branding, hostname=jarvisos, liveuser${NC}"
echo -e "${BLUE}Next      : Run step 3b to build + install linux-jarvisos${NC}"
