#!/bin/bash
# ============================================================================
# install-jarvisos.sh — JARVIS OS Backup CLI Installer
# ============================================================================
#
# Use this if Calamares fails or you prefer a text-based installer.
# Run as root from the live environment:
#
#   sudo install-jarvisos.sh
#
# Requirements: dialog (for TUI), parted, dosfstools, arch-install-scripts
# ============================================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# ── State variables ────────────────────────────────────────────────────────
TARGET_DISK=""
BOOT_LOADER=""   # "grub" or "systemd-boot"
FS_TYPE=""       # "ext4" or "btrfs"
SWAP_SIZE=""     # in MiB, or "0" for none
HOSTNAME_VAL=""
NEW_USER=""
USER_PASS=""
ROOT_PASS=""
IS_EFI=false
MOUNT_ROOT="/mnt/jarvis-install"

# ── Helpers ────────────────────────────────────────────────────────────────
die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}=>${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root (sudo install-jarvisos.sh)"
}

check_deps() {
    local missing=()
    for cmd in dialog parted mkfs.fat arch-chroot genfstab rsync blkid lsblk sgdisk wipefs; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Installing missing tools: ${missing[*]}"
        pacman -S --noconfirm --needed arch-install-scripts parted dosfstools dialog rsync gptfdisk 2>/dev/null || true
    fi
}

detect_uefi() {
    if [ -d /sys/firmware/efi/efivars ]; then
        IS_EFI=true
        info "Boot mode: UEFI"
    else
        IS_EFI=false
        info "Boot mode: BIOS (Legacy)"
    fi
}

# ── Dialog wrappers ────────────────────────────────────────────────────────
d_menu() {
    # d_menu title height width items...
    local title="$1" h="$2" w="$3"; shift 3
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "${title}" \
           --menu "" "${h}" "${w}" $# "$@" \
           3>&1 1>&2 2>&3
}

d_input() {
    local title="$1" prompt="$2" default="$3"
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "${title}" \
           --inputbox "${prompt}" 8 60 "${default}" \
           3>&1 1>&2 2>&3
}

d_password() {
    local title="$1" prompt="$2"
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "${title}" \
           --passwordbox "${prompt}" 8 60 \
           3>&1 1>&2 2>&3
}

d_yesno() {
    local title="$1" msg="$2"
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "${title}" \
           --yesno "${msg}" 8 60
}

d_msgbox() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "$1" \
           --msgbox "$2" 10 65
}

d_infobox() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "$1" \
           --infobox "$2" 6 60
}

# ── Step 1: Welcome ────────────────────────────────────────────────────────
step_welcome() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "Welcome to JARVIS OS" \
           --msgbox "\
JARVIS OS — AI-Powered Arch Linux\n\
Backup CLI Installer\n\
\n\
This installer will:\n\
  1. Partition your chosen disk\n\
  2. Install the JARVIS OS system\n\
  3. Configure bootloader, user, and services\n\
\n\
WARNING: All data on the target disk will be erased.\n\
Ensure you have backups before continuing.\n\
\n\
Press OK to begin." \
           14 65 || { clear; echo "Aborted."; exit 0; }
}

# ── Step 2: Disk selection ─────────────────────────────────────────────────
step_select_disk() {
    # Build list from lsblk
    local items=()
    while IFS= read -r line; do
        local dev size model
        dev=$(echo "${line}" | awk '{print $1}')
        size=$(echo "${line}" | awk '{print $2}')
        model=$(echo "${line}" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')
        [ -z "${model}" ] && model="Unknown"
        items+=("${dev}" "${size} — ${model}")
    done < <(lsblk -d -o NAME,SIZE,MODEL --noheadings -e 7,11 2>/dev/null | grep -v "^loop")

    if [ ${#items[@]} -eq 0 ]; then
        die "No suitable disks found."
    fi

    TARGET_DISK=$(d_menu "Select Target Disk" 16 65 "${items[@]}") || { clear; exit 0; }
    TARGET_DISK="/dev/${TARGET_DISK}"

    # Confirm destructive action
    d_yesno "Confirm Disk" \
        "ALL DATA on ${TARGET_DISK} will be permanently erased.\n\nAre you sure?" \
        || { clear; echo "Aborted."; exit 0; }
}

# ── Step 3: Bootloader ─────────────────────────────────────────────────────
step_select_bootloader() {
    if $IS_EFI; then
        BOOT_LOADER=$(d_menu "Bootloader" 12 65 \
            "systemd-boot" "Fast, lightweight — UEFI only (recommended)" \
            "grub"         "Full-featured — UEFI + dual-boot support") || { clear; exit 0; }
    else
        BOOT_LOADER="grub"
        d_msgbox "Bootloader" "BIOS system detected.\nGRUB will be installed (systemd-boot requires UEFI)."
    fi
}

# ── Step 4: Filesystem ─────────────────────────────────────────────────────
step_select_fs() {
    FS_TYPE=$(d_menu "Root Filesystem" 10 65 \
        "ext4"  "Stable, widely supported (recommended)" \
        "btrfs" "Copy-on-write, snapshots, compression") || { clear; exit 0; }
}

# ── Step 5: Swap ───────────────────────────────────────────────────────────
step_select_swap() {
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {printf "%.0f\n", $2/1024}' /proc/meminfo)

    local choice
    choice=$(d_menu "Swap Space" 12 65 \
        "0"     "None (not recommended on low-RAM systems)" \
        "2048"  "2 GiB" \
        "4096"  "4 GiB (recommended, ~= RAM: ${ram_mb} MiB)" \
        "8192"  "8 GiB" \
        "file"  "Swap file (created after install)") || { clear; exit 0; }

    SWAP_SIZE="${choice}"
}

# ── Step 6: Hostname ───────────────────────────────────────────────────────
step_hostname() {
    HOSTNAME_VAL=$(d_input "Hostname" "Enter the system hostname:" "jarvisos") || { clear; exit 0; }
    HOSTNAME_VAL="${HOSTNAME_VAL:-jarvisos}"
    # Sanitise
    HOSTNAME_VAL=$(echo "${HOSTNAME_VAL}" | tr -cd '[:alnum:]-' | head -c 63)
    [ -z "${HOSTNAME_VAL}" ] && HOSTNAME_VAL="jarvisos"
}

# ── Step 7: User ───────────────────────────────────────────────────────────
step_user() {
    NEW_USER=$(d_input "Create User" "Enter username for the new account:" "user") || { clear; exit 0; }
    NEW_USER="${NEW_USER:-user}"
    NEW_USER=$(echo "${NEW_USER}" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')

    local pass1 pass2
    while true; do
        pass1=$(d_password "User Password" "Password for ${NEW_USER}:") || { clear; exit 0; }
        pass2=$(d_password "Confirm Password" "Confirm password:") || { clear; exit 0; }
        [ "${pass1}" = "${pass2}" ] && break
        d_msgbox "Mismatch" "Passwords do not match. Try again."
    done
    USER_PASS="${pass1}"

    local rp1 rp2
    while true; do
        rp1=$(d_password "Root Password" "Set the root password:") || { clear; exit 0; }
        rp2=$(d_password "Confirm Root Password" "Confirm root password:") || { clear; exit 0; }
        [ "${rp1}" = "${rp2}" ] && break
        d_msgbox "Mismatch" "Passwords do not match. Try again."
    done
    ROOT_PASS="${rp1}"
}

# ── Step 8: Summary ────────────────────────────────────────────────────────
step_summary() {
    local swap_label="${SWAP_SIZE} MiB"
    [ "${SWAP_SIZE}" = "0" ]    && swap_label="None"
    [ "${SWAP_SIZE}" = "file" ] && swap_label="Swap file"

    d_yesno "Installation Summary" \
"Disk:        ${TARGET_DISK}
Bootloader:  ${BOOT_LOADER}
Filesystem:  ${FS_TYPE}
Swap:        ${swap_label}
Hostname:    ${HOSTNAME_VAL}
User:        ${NEW_USER}

ALL DATA on ${TARGET_DISK} will be erased.
Proceed with installation?" || { clear; echo "Aborted."; exit 0; }
}

# ── Partitioning ───────────────────────────────────────────────────────────
partition_disk() {
    d_infobox "Partitioning" "Wiping and partitioning ${TARGET_DISK}..."

    # Wipe existing signatures
    wipefs -af "${TARGET_DISK}" >/dev/null 2>&1 || true
    sgdisk --zap-all "${TARGET_DISK}" >/dev/null 2>&1 || true

    if $IS_EFI; then
        # GPT: ESP (1 GiB) + optional swap + root
        parted -s "${TARGET_DISK}" mklabel gpt
        parted -s "${TARGET_DISK}" mkpart ESP fat32 1MiB 1025MiB
        parted -s "${TARGET_DISK}" set 1 esp on

        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_end=$(( 1025 + SWAP_SIZE ))
            parted -s "${TARGET_DISK}" mkpart swap linux-swap 1025MiB "${swap_end}MiB"
            parted -s "${TARGET_DISK}" mkpart root "${FS_TYPE}" "${swap_end}MiB" 100%
        else
            parted -s "${TARGET_DISK}" mkpart root "${FS_TYPE}" 1025MiB 100%
        fi
    else
        # MBR (BIOS): BIOS-boot partition + optional swap + root
        parted -s "${TARGET_DISK}" mklabel msdos
        parted -s "${TARGET_DISK}" mkpart primary 1MiB 3MiB
        parted -s "${TARGET_DISK}" set 1 bios_grub on

        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_end=$(( 3 + SWAP_SIZE ))
            parted -s "${TARGET_DISK}" mkpart primary linux-swap 3MiB "${swap_end}MiB"
            parted -s "${TARGET_DISK}" mkpart primary ext4 "${swap_end}MiB" 100%
            parted -s "${TARGET_DISK}" set 3 boot on
        else
            parted -s "${TARGET_DISK}" mkpart primary ext4 3MiB 100%
            parted -s "${TARGET_DISK}" set 2 boot on
        fi
    fi

    partprobe "${TARGET_DISK}" 2>/dev/null || true
    sleep 2
    ok "Disk partitioned"
}

# Derive partition device names (handles nvme0n1p1 vs sda1)
part() {
    local disk="$1" num="$2"
    if echo "${disk}" | grep -qE '(nvme|mmcblk)'; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

format_and_mount() {
    d_infobox "Formatting" "Formatting partitions..."

    mkdir -p "${MOUNT_ROOT}"

    if $IS_EFI; then
        local esp_dev
        esp_dev=$(part "${TARGET_DISK}" 1)
        mkfs.fat -F32 -n JARVISOS-EFI "${esp_dev}" >/dev/null

        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_dev root_dev
            swap_dev=$(part "${TARGET_DISK}" 2)
            root_dev=$(part "${TARGET_DISK}" 3)
            mkswap "${swap_dev}"
            swapon "${swap_dev}"
            format_root "${root_dev}"
            mount "${root_dev}" "${MOUNT_ROOT}"
            mkdir -p "${MOUNT_ROOT}/boot"
            mount "${esp_dev}" "${MOUNT_ROOT}/boot"
        else
            local root_dev
            root_dev=$(part "${TARGET_DISK}" 2)
            format_root "${root_dev}"
            mount "${root_dev}" "${MOUNT_ROOT}"
            mkdir -p "${MOUNT_ROOT}/boot"
            mount "${esp_dev}" "${MOUNT_ROOT}/boot"
        fi
    else
        # BIOS: partition 1 = bios_grub (no format), 2/3 = swap/root
        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_dev root_dev
            swap_dev=$(part "${TARGET_DISK}" 2)
            root_dev=$(part "${TARGET_DISK}" 3)
            mkswap "${swap_dev}"
            swapon "${swap_dev}"
            format_root "${root_dev}"
            mount "${root_dev}" "${MOUNT_ROOT}"
        else
            local root_dev
            root_dev=$(part "${TARGET_DISK}" 2)
            format_root "${root_dev}"
            mount "${root_dev}" "${MOUNT_ROOT}"
        fi
    fi

    ok "Partitions formatted and mounted"
}

format_root() {
    local dev="$1"
    case "${FS_TYPE}" in
        ext4)  mkfs.ext4 -L JARVISOS-ROOT "${dev}" >/dev/null ;;
        btrfs) mkfs.btrfs -L JARVISOS-ROOT -f "${dev}" >/dev/null
               # Create standard subvolumes
               mount "${dev}" "${MOUNT_ROOT}"
               btrfs subvolume create "${MOUNT_ROOT}/@"
               btrfs subvolume create "${MOUNT_ROOT}/@home"
               btrfs subvolume create "${MOUNT_ROOT}/@var"
               btrfs subvolume create "${MOUNT_ROOT}/@snapshots"
               umount "${MOUNT_ROOT}"
               mount -o compress=zstd,noatime,subvol=@ "${dev}" "${MOUNT_ROOT}"
               mkdir -p "${MOUNT_ROOT}"/{home,var,.snapshots}
               mount -o compress=zstd,noatime,subvol=@home "${dev}" "${MOUNT_ROOT}/home"
               mount -o compress=zstd,noatime,subvol=@var  "${dev}" "${MOUNT_ROOT}/var"
               mount -o compress=zstd,noatime,subvol=@snapshots "${dev}" "${MOUNT_ROOT}/.snapshots"
               return ;;
        *)     die "Unknown filesystem: ${FS_TYPE}" ;;
    esac
}

# ── Install system ─────────────────────────────────────────────────────────
install_system() {
    d_infobox "Installing" "Copying JARVIS OS to disk (this takes a few minutes)..."

    # Prefer copying from the squashfs source for a clean install.
    # Fall back to rsync from the live overlay if squashfs isn't mounted.
    local SFS_SRC=""
    local BOOTMNT="/run/archiso/bootmnt"

    if mountpoint -q "${BOOTMNT}" 2>/dev/null; then
        SFS_SRC="${BOOTMNT}/arch/x86_64/airootfs.sfs"
    fi

    if [ -f "${SFS_SRC}" ]; then
        local SQUASH_MNT="/mnt/jarvis-squash"
        mkdir -p "${SQUASH_MNT}"
        mount -o loop,ro "${SFS_SRC}" "${SQUASH_MNT}"
        rsync -aHAXx --info=progress2 \
            --exclude='/boot/grub/grubenv' \
            --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
            --exclude='/run/*' --exclude='/tmp/*' \
            "${SQUASH_MNT}/" "${MOUNT_ROOT}/"
        umount "${SQUASH_MNT}"
    else
        # Live overlay rsync fallback
        rsync -aHAXx --info=progress2 \
            --exclude='/boot/grub/grubenv' \
            --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
            --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
            --exclude='/lost+found' \
            / "${MOUNT_ROOT}/"
    fi

    ok "System files installed"
}

# ── Kernel files ───────────────────────────────────────────────────────────
ensure_kernel() {
    # If linux-jarvisos kernel files are in the ISO boot dir, copy them to /boot
    local BOOTMNT="/run/archiso/bootmnt"
    local ARCH_BOOT="${BOOTMNT}/arch/boot/x86_64"

    if [ -f "${ARCH_BOOT}/vmlinuz-linux-jarvisos" ]; then
        cp -f "${ARCH_BOOT}/vmlinuz-linux-jarvisos" \
              "${MOUNT_ROOT}/boot/vmlinuz-linux-jarvisos" 2>/dev/null || true
        cp -f "${ARCH_BOOT}/initramfs-linux-jarvisos.img" \
              "${MOUNT_ROOT}/boot/initramfs-linux-jarvisos.img" 2>/dev/null || true
        cp -f "${ARCH_BOOT}/initramfs-linux-jarvisos-fallback.img" \
              "${MOUNT_ROOT}/boot/initramfs-linux-jarvisos-fallback.img" 2>/dev/null || true
        ok "linux-jarvisos kernel files copied to /boot"
    fi
}

# ── fstab ──────────────────────────────────────────────────────────────────
generate_fstab() {
    d_infobox "fstab" "Generating /etc/fstab..."
    mkdir -p "${MOUNT_ROOT}/etc"
    # Use > not >> — rsync already copied the live system's fstab; overwrite it
    genfstab -U "${MOUNT_ROOT}" > "${MOUNT_ROOT}/etc/fstab"
    ok "fstab generated"
}

# ── chroot configuration ───────────────────────────────────────────────────
configure_system() {
    d_infobox "Configuring" "Configuring installed system..."

    arch-chroot "${MOUNT_ROOT}" /bin/bash -s "${HOSTNAME_VAL}" "${NEW_USER}" \
                                              "${USER_PASS}" "${ROOT_PASS}" \
                                              "${BOOT_LOADER}" "${FS_TYPE}" <<'CHROOT_EOF'
set -euo pipefail

HOSTNAME_VAL="$1"
NEW_USER="$2"
USER_PASS="$3"
ROOT_PASS="$4"
BOOT_LOADER="$5"
FS_TYPE="$6"

warn() { echo "WARNING: $*" >&2; }

# ── Timezone / locale ──────────────────────────────────────────────────────
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# ── Hostname / hosts ───────────────────────────────────────────────────────
echo "${HOSTNAME_VAL}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_VAL}.localdomain ${HOSTNAME_VAL}
EOF

# ── Root password ──────────────────────────────────────────────────────────
echo "root:${ROOT_PASS}" | chpasswd

# ── Create user ────────────────────────────────────────────────────────────
# Ensure supplementary groups exist
for grp in wheel audio video storage optical network power lp sys scanner input; do
    getent group "${grp}" >/dev/null 2>&1 || groupadd --system "${grp}" 2>/dev/null || true
done

useradd -m -G wheel,audio,video,storage,optical,network,power -s /bin/bash "${NEW_USER}" 2>/dev/null || \
useradd -m -s /bin/bash "${NEW_USER}"

for grp in wheel audio video storage optical network power lp sys scanner input; do
    usermod -aG "${grp}" "${NEW_USER}" 2>/dev/null || true
done

echo "${NEW_USER}:${USER_PASS}" | chpasswd

# ── sudoers ────────────────────────────────────────────────────────────────
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || \
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers 2>/dev/null || true
chmod 440 /etc/sudoers

# ── Remove live autologin ──────────────────────────────────────────────────
rm -f /etc/sddm.conf.d/autologin.conf 2>/dev/null || true
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/jarvisos.conf <<SDDM
[General]
DisplayServer=wayland
Numlock=on

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions
SDDM

# ── Remove liveuser account ────────────────────────────────────────────────
userdel -r liveuser 2>/dev/null || true
rm -rf /home/liveuser 2>/dev/null || true
# Remove liveuser autologin polkit rule
rm -f /etc/polkit-1/rules.d/50-liveuser.rules 2>/dev/null || true

# ── Remove stock linux kernel (linux-jarvisos is the installed kernel) ─────
rm -f /boot/vmlinuz-linux /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img
rm -f /etc/mkinitcpio.d/linux.preset 2>/dev/null || true

# ── Fix mkinitcpio.conf for installed system ───────────────────────────────
# The live ISO's mkinitcpio.conf has archiso/memdisk hooks (live boot only)
# and is MISSING block + filesystems hooks. Without block+filesystems the
# installed system cannot find or mount its root partition → kernel panic.
# Replace with a clean installed-system hook set.
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap block filesystems)/' \
    /etc/mkinitcpio.conf

# ── mkinitcpio ────────────────────────────────────────────────────────────
if [ -f /etc/mkinitcpio.d/linux-jarvisos.preset ]; then
    mkinitcpio -p linux-jarvisos || warn "mkinitcpio failed — boot may require manual fix"
elif [ -f /boot/initramfs-linux-jarvisos.img ]; then
    echo "linux-jarvisos initramfs already present, skipping rebuild"
else
    warn "No linux-jarvisos preset or initramfs found — bootloader may not work"
fi

# ── Enable required services ───────────────────────────────────────────────
systemctl enable NetworkManager.service
systemctl enable systemd-resolved.service
systemctl enable sddm.service
systemctl enable bluetooth.service 2>/dev/null || true
systemctl enable rtkit-daemon.service 2>/dev/null || true
systemctl enable ollama.service 2>/dev/null || true
systemctl enable jarvis.service 2>/dev/null || true
systemctl disable iwd.service 2>/dev/null || true
systemctl mask    iwd.service 2>/dev/null || true
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true

# ── resolv.conf ────────────────────────────────────────────────────────────
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# ── XDG user dirs for new user ─────────────────────────────────────────────
if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    runuser -u "${NEW_USER}" -- xdg-user-dirs-update 2>/dev/null || true
fi

# ── JARVIS welcome autostart for new user ─────────────────────────────────
AUTOSTART_DIR="/home/${NEW_USER}/.config/autostart"
mkdir -p "${AUTOSTART_DIR}"
cat > "${AUTOSTART_DIR}/jarvis-welcome.desktop" <<JDESKTOP
[Desktop Entry]
Type=Application
Name=JARVIS Setup
Comment=First-boot JARVIS AI setup wizard
Exec=konsole -e /usr/local/bin/jarvis-welcome.sh
Icon=utilities-terminal
Terminal=false
StartupNotify=true
X-KDE-autostart-phase=2
JDESKTOP
chmod 644 "${AUTOSTART_DIR}/jarvis-welcome.desktop"
chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.config" 2>/dev/null || true

# ── btrfs fstab options ────────────────────────────────────────────────────
if [ "${FS_TYPE}" = "btrfs" ]; then
    sed -i 's|subvol=@,|compress=zstd,noatime,subvol=@,|' /etc/fstab 2>/dev/null || true
fi

echo "System configuration complete."
CHROOT_EOF

    ok "System configured"
}

# ── Bootloader installation ────────────────────────────────────────────────
install_bootloader() {
    d_infobox "Bootloader" "Installing ${BOOT_LOADER}..."

    if [ "${BOOT_LOADER}" = "systemd-boot" ]; then
        # systemd-boot
        arch-chroot "${MOUNT_ROOT}" bootctl --esp-path=/boot install

        # loader.conf
        cat > "${MOUNT_ROOT}/boot/loader/loader.conf" <<'LCONF'
default jarvisos.conf
timeout 5
console-mode max
editor no
LCONF

        # loader entry
        mkdir -p "${MOUNT_ROOT}/boot/loader/entries"
        local ROOT_UUID
        ROOT_UUID=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE "${MOUNT_ROOT}")" 2>/dev/null || \
                    blkid -s UUID -o value "$(mount | grep " ${MOUNT_ROOT} " | awk '{print $1}')" 2>/dev/null)

        local FS_OPTS="rw quiet splash"
        [ "${FS_TYPE}" = "btrfs" ] && FS_OPTS="rw quiet splash rootflags=subvol=@"

        # Build microcode initrd lines — only include files that actually exist
        local UCODE_LINES=""
        [ -f "${MOUNT_ROOT}/boot/intel-ucode.img" ] && UCODE_LINES+="initrd  /intel-ucode.img\n"
        [ -f "${MOUNT_ROOT}/boot/amd-ucode.img" ]   && UCODE_LINES+="initrd  /amd-ucode.img\n"

        printf "title   JARVIS OS\nlinux   /vmlinuz-linux-jarvisos\n%sinitrd  /initramfs-linux-jarvisos.img\noptions root=UUID=%s %s\n" \
            "${UCODE_LINES}" "${ROOT_UUID}" "${FS_OPTS}" \
            > "${MOUNT_ROOT}/boot/loader/entries/jarvisos.conf"

        printf "title   JARVIS OS (fallback initramfs)\nlinux   /vmlinuz-linux-jarvisos\n%sinitrd  /initramfs-linux-jarvisos-fallback.img\noptions root=UUID=%s %s\n" \
            "${UCODE_LINES}" "${ROOT_UUID}" "${FS_OPTS}" \
            > "${MOUNT_ROOT}/boot/loader/entries/jarvisos-fallback.conf"

        ok "systemd-boot installed"

    else
        # GRUB
        arch-chroot "${MOUNT_ROOT}" pacman -S --noconfirm --needed grub efibootmgr os-prober 2>/dev/null || true

        if $IS_EFI; then
            arch-chroot "${MOUNT_ROOT}" grub-install \
                --target=x86_64-efi \
                --efi-directory=/boot \
                --bootloader-id=JARVISOS \
                --recheck
        else
            arch-chroot "${MOUNT_ROOT}" grub-install \
                --target=i386-pc \
                --recheck \
                "${TARGET_DISK}"
        fi

        # GRUB defaults
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/'           "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null || true
        sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null || true
        # Point GRUB at linux-jarvisos if it's the only kernel
        if grep -q 'GRUB_DEFAULT=saved' "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null; then
            sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' "${MOUNT_ROOT}/etc/default/grub"
        fi

        arch-chroot "${MOUNT_ROOT}" grub-mkconfig -o /boot/grub/grub.cfg

        ok "GRUB installed"
    fi
}

# ── Swap file (post-install) ───────────────────────────────────────────────
create_swapfile() {
    if [ "${SWAP_SIZE}" = "file" ]; then
        d_infobox "Swap File" "Creating swap file..."
        arch-chroot "${MOUNT_ROOT}" /bin/bash -c "
            dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress 2>/dev/null
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
        "
        echo "/swapfile none swap defaults 0 0" >> "${MOUNT_ROOT}/etc/fstab"
        ok "Swap file created"
    fi
}

# ── Cleanup ────────────────────────────────────────────────────────────────
cleanup_mounts() {
    sync
    umount -R "${MOUNT_ROOT}" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    need_root
    check_deps
    detect_uefi

    step_welcome
    step_select_disk
    step_select_bootloader
    step_select_fs
    step_select_swap
    step_hostname
    step_user
    step_summary

    clear
    echo ""
    echo -e "${BOLD}${BLUE}Installing JARVIS OS...${NC}"
    echo ""

    trap cleanup_mounts EXIT

    partition_disk
    format_and_mount
    install_system
    ensure_kernel
    generate_fstab
    configure_system
    install_bootloader
    create_swapfile

    trap - EXIT
    cleanup_mounts

    clear
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║   JARVIS OS installation complete!       ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Bootloader: ${BOLD}${BOOT_LOADER}${NC}"
    echo -e "  Disk:       ${BOLD}${TARGET_DISK}${NC}"
    echo -e "  Hostname:   ${BOLD}${HOSTNAME_VAL}${NC}"
    echo -e "  User:       ${BOLD}${NEW_USER}${NC}"
    echo ""
    echo -e "  ${YELLOW}Remove the installation medium and reboot:${NC}"
    echo -e "    ${BOLD}reboot${NC}"
    echo ""
}

main "$@"
