#!/bin/bash
# ============================================================================
# jarvis-install — JARVIS OS TUI Installer
# ============================================================================
# Launches automatically on TTY1 when booting the live ISO.
# Run as root:  jarvis-install
#
# Requirements: dialog, parted, dosfstools, arch-install-scripts, gptfdisk, rsync
# ============================================================================

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── State variables ────────────────────────────────────────────────────────
TARGET_DISK=""
BOOT_LOADER=""   # "grub" or "systemd-boot"
FS_TYPE=""       # "ext4" or "btrfs"
SWAP_SIZE=""     # in MiB, "0" = none, "file" = swapfile
TIMEZONE="UTC"
KEYMAP="us"
LOCALE="en_US.UTF-8"
HOSTNAME_VAL=""
NEW_USER=""
USER_PASS=""
ROOT_PASS=""
IS_EFI=false
MOUNT_ROOT="/mnt/jarvis-install"

# ── Helpers ────────────────────────────────────────────────────────────────
die() { clear; echo -e "${RED}FATAL: $*${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}=>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Must run as root. Use: sudo jarvis-install"
}

check_deps() {
    local missing=()
    for cmd in dialog parted mkfs.fat arch-chroot genfstab rsync blkid lsblk sgdisk wipefs; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        clear
        echo "Installing missing tools: ${missing[*]}"
        pacman -S --noconfirm --needed arch-install-scripts parted dosfstools \
            dialog rsync gptfdisk 2>/dev/null || true
    fi
}

detect_uefi() {
    if [ -d /sys/firmware/efi/efivars ]; then
        IS_EFI=true
    else
        IS_EFI=false
    fi
}

# ── Dialog wrappers ────────────────────────────────────────────────────────
d_menu() {
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
           --yesno "${msg}" 10 65
}

d_msgbox() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "$1" \
           --msgbox "$2" 10 65
}

d_infobox() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "$1" \
           --infobox "$2" 7 65
}

# ── Step 1: Welcome ────────────────────────────────────────────────────────
step_welcome() {
    dialog --clear --backtitle "JARVIS OS Installer" \
           --title "Welcome to JARVIS OS" \
           --msgbox "\
JARVIS OS — AI-Powered Arch Linux\n\
\n\
This installer will:\n\
  1. Partition your chosen disk\n\
  2. Install the JARVIS OS system\n\
  3. Configure bootloader, user, and services\n\
  4. Set up the JARVIS AI assistant (model downloads on first boot)\n\
\n\
Boot mode: $(${IS_EFI} && echo 'UEFI' || echo 'BIOS (Legacy)')\n\
\n\
WARNING: All data on the target disk will be erased.\n\
Ensure you have backups before continuing.\n\
\n\
Press OK to begin." \
           16 68 || { clear; echo "Aborted."; exit 0; }
}

# ── Step 2: Disk selection ─────────────────────────────────────────────────
step_select_disk() {
    local items=()
    while IFS= read -r line; do
        local dev size model
        dev=$(echo "${line}" | awk '{print $1}')
        size=$(echo "${line}" | awk '{print $2}')
        model=$(echo "${line}" | awk '{$1=$2=""; print $0}' | sed 's/^ *//')
        [ -z "${model}" ] && model="Unknown"
        items+=("${dev}" "${size}  ${model}")
    done < <(lsblk -d -o NAME,SIZE,MODEL --noheadings -e 7,11 2>/dev/null | grep -v "^loop")

    if [ ${#items[@]} -eq 0 ]; then
        die "No suitable disks found."
    fi

    TARGET_DISK=$(d_menu "Select Target Disk" 16 68 "${items[@]}") || { clear; exit 0; }
    TARGET_DISK="/dev/${TARGET_DISK}"

    d_yesno "Confirm Disk" \
        "ALL DATA on ${TARGET_DISK} will be permanently erased.\n\nAre you sure?" \
        || { clear; echo "Aborted."; exit 0; }
}

# ── Step 3: Bootloader ─────────────────────────────────────────────────────
step_select_bootloader() {
    if $IS_EFI; then
        BOOT_LOADER=$(d_menu "Bootloader" 12 68 \
            "systemd-boot" "Fast, lightweight — UEFI only (recommended)" \
            "grub"         "Full-featured — UEFI + dual-boot support") || { clear; exit 0; }
    else
        BOOT_LOADER="grub"
        d_msgbox "Bootloader" "BIOS system detected.\nGRUB will be installed (systemd-boot requires UEFI)."
    fi
}

# ── Step 4: Filesystem ─────────────────────────────────────────────────────
step_select_fs() {
    FS_TYPE=$(d_menu "Root Filesystem" 10 68 \
        "ext4"  "Stable, widely supported (recommended)" \
        "btrfs" "Copy-on-write, snapshots, compression") || { clear; exit 0; }
}

# ── Step 5: Swap ───────────────────────────────────────────────────────────
step_select_swap() {
    local ram_mb
    ram_mb=$(awk '/MemTotal/ {printf "%.0f\n", $2/1024}' /proc/meminfo)

    local choice
    choice=$(d_menu "Swap Space" 14 68 \
        "0"     "None" \
        "2048"  "2 GiB" \
        "4096"  "4 GiB (system RAM: ${ram_mb} MiB)" \
        "8192"  "8 GiB" \
        "16384" "16 GiB" \
        "file"  "Swap file (4 GiB, created after install)") || { clear; exit 0; }
    SWAP_SIZE="${choice}"
}

# ── Step 6: Timezone ───────────────────────────────────────────────────────
step_timezone() {
    # Build region list from zoneinfo
    local region_items=()
    while IFS= read -r region; do
        region_items+=("${region}" "")
    done < <(find /usr/share/zoneinfo -mindepth 1 -maxdepth 1 -type d \
             2>/dev/null | sed 's|/usr/share/zoneinfo/||' | sort | \
             grep -xE 'Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|Europe|Indian|Pacific|US')
    region_items+=("UTC" "Coordinated Universal Time")

    local region
    region=$(dialog --clear --backtitle "JARVIS OS Installer" \
                    --title "Timezone — Region" \
                    --menu "Select your region:" 22 60 15 \
                    "${region_items[@]}" \
                    3>&1 1>&2 2>&3) || { clear; exit 0; }

    if [ "${region}" = "UTC" ]; then
        TIMEZONE="UTC"
        return
    fi

    # Build city list for chosen region
    local city_items=()
    while IFS= read -r city; do
        city_items+=("${city}" "")
    done < <(find "/usr/share/zoneinfo/${region}" -type f 2>/dev/null \
             | sed "s|/usr/share/zoneinfo/${region}/||" | sort)

    if [ ${#city_items[@]} -eq 0 ]; then
        TIMEZONE="${region}"
        return
    fi

    local city
    city=$(dialog --clear --backtitle "JARVIS OS Installer" \
                  --title "Timezone — City" \
                  --menu "Select your city:" 22 60 15 \
                  "${city_items[@]}" \
                  3>&1 1>&2 2>&3) || { clear; exit 0; }

    TIMEZONE="${region}/${city}"
}

# ── Step 7: Keyboard layout ────────────────────────────────────────────────
step_keyboard() {
    local choice
    choice=$(d_menu "Keyboard Layout" 20 68 \
        "us"     "US English (default)" \
        "gb"     "British English" \
        "de"     "German" \
        "fr"     "French" \
        "es"     "Spanish" \
        "it"     "Italian" \
        "pt"     "Portuguese" \
        "ru"     "Russian" \
        "pl"     "Polish" \
        "nl"     "Dutch" \
        "sv"     "Swedish" \
        "no"     "Norwegian" \
        "dk"     "Danish" \
        "tr"     "Turkish" \
        "custom" "Other (enter manually)") || { clear; exit 0; }

    if [ "${choice}" = "custom" ]; then
        KEYMAP=$(d_input "Custom Keymap" \
            "Enter keymap name (e.g. dvorak, colemak-dh):" "us") || { clear; exit 0; }
        KEYMAP="${KEYMAP:-us}"
    else
        KEYMAP="${choice}"
    fi
}

# ── Step 8: Locale ─────────────────────────────────────────────────────────
step_locale() {
    local choice
    choice=$(d_menu "System Locale" 18 68 \
        "en_US.UTF-8"  "English — United States" \
        "en_GB.UTF-8"  "English — United Kingdom" \
        "en_AU.UTF-8"  "English — Australia" \
        "en_CA.UTF-8"  "English — Canada" \
        "de_DE.UTF-8"  "German — Germany" \
        "fr_FR.UTF-8"  "French — France" \
        "es_ES.UTF-8"  "Spanish — Spain" \
        "es_MX.UTF-8"  "Spanish — Mexico" \
        "it_IT.UTF-8"  "Italian — Italy" \
        "pt_PT.UTF-8"  "Portuguese — Portugal" \
        "pt_BR.UTF-8"  "Portuguese — Brazil" \
        "ru_RU.UTF-8"  "Russian — Russia" \
        "pl_PL.UTF-8"  "Polish — Poland" \
        "nl_NL.UTF-8"  "Dutch — Netherlands" \
        "sv_SE.UTF-8"  "Swedish — Sweden") || { clear; exit 0; }
    LOCALE="${choice}"
}

# ── Step 9: Hostname ───────────────────────────────────────────────────────
step_hostname() {
    HOSTNAME_VAL=$(d_input "Hostname" "Enter the system hostname:" "jarvisos") || { clear; exit 0; }
    HOSTNAME_VAL="${HOSTNAME_VAL:-jarvisos}"
    HOSTNAME_VAL=$(echo "${HOSTNAME_VAL}" | tr -cd '[:alnum:]-' | head -c 63)
    [ -z "${HOSTNAME_VAL}" ] && HOSTNAME_VAL="jarvisos"
}

# ── Step 10: User ──────────────────────────────────────────────────────────
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

# ── Step 11: Summary ───────────────────────────────────────────────────────
step_summary() {
    local swap_label="${SWAP_SIZE} MiB"
    [ "${SWAP_SIZE}" = "0" ]    && swap_label="None"
    [ "${SWAP_SIZE}" = "file" ] && swap_label="4 GiB swapfile"

    d_yesno "Installation Summary" \
"Disk:        ${TARGET_DISK}
Bootloader:  ${BOOT_LOADER}
Filesystem:  ${FS_TYPE}
Swap:        ${swap_label}
Timezone:    ${TIMEZONE}
Keyboard:    ${KEYMAP}
Locale:      ${LOCALE}
Hostname:    ${HOSTNAME_VAL}
User:        ${NEW_USER}

ALL DATA on ${TARGET_DISK} will be erased.
Proceed with installation?" || { clear; echo "Aborted."; exit 0; }
}

# ── Partitioning ───────────────────────────────────────────────────────────
partition_disk() {
    wipefs -af "${TARGET_DISK}" >/dev/null 2>&1 || true
    sgdisk --zap-all "${TARGET_DISK}" >/dev/null 2>&1 || true

    if $IS_EFI; then
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

# Derive partition names (handles nvme0n1p1, mmcblk0p1, sda1)
part() {
    local disk="$1" num="$2"
    if echo "${disk}" | grep -qE '(nvme|mmcblk)'; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

format_and_mount() {
    mkdir -p "${MOUNT_ROOT}"

    if $IS_EFI; then
        local esp_dev
        esp_dev=$(part "${TARGET_DISK}" 1)
        mkfs.fat -F32 -n JARVISOS-EFI "${esp_dev}" >/dev/null

        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_dev root_dev
            swap_dev=$(part "${TARGET_DISK}" 2)
            root_dev=$(part "${TARGET_DISK}" 3)
            mkswap "${swap_dev}" && swapon "${swap_dev}"
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
        if [ "${SWAP_SIZE}" != "0" ] && [ "${SWAP_SIZE}" != "file" ]; then
            local swap_dev root_dev
            swap_dev=$(part "${TARGET_DISK}" 2)
            root_dev=$(part "${TARGET_DISK}" 3)
            mkswap "${swap_dev}" && swapon "${swap_dev}"
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
        ext4)
            mkfs.ext4 -L JARVISOS-ROOT "${dev}" >/dev/null
            ;;
        btrfs)
            mkfs.btrfs -L JARVISOS-ROOT -f "${dev}" >/dev/null
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
            return
            ;;
        *)
            die "Unknown filesystem: ${FS_TYPE}"
            ;;
    esac
}

# ── Mount live medium ──────────────────────────────────────────────────────
ensure_bootmnt() {
    local BOOTMNT="/run/archiso/bootmnt"
    if mountpoint -q "${BOOTMNT}" 2>/dev/null; then
        return 0
    fi
    # Try to find and mount the live medium
    local LIVE_DEV
    LIVE_DEV=$(blkid -o device -t TYPE="iso9660" 2>/dev/null | head -1 || true)
    if [ -z "${LIVE_DEV}" ]; then
        LIVE_DEV=$(blkid -o device -t TYPE="squashfs" 2>/dev/null | head -1 || true)
    fi
    if [ -n "${LIVE_DEV}" ]; then
        mkdir -p "${BOOTMNT}"
        mount -r "${LIVE_DEV}" "${BOOTMNT}" 2>/dev/null || true
    fi
}

# ── Install system ─────────────────────────────────────────────────────────
install_system() {
    local BOOTMNT="/run/archiso/bootmnt"
    local SQUASH_MNT="/mnt/jarvis-squash"
    local SFS_SRC=""

    ensure_bootmnt

    # Find squashfs on the live medium
    if mountpoint -q "${BOOTMNT}" 2>/dev/null; then
        SFS_SRC=$(find "${BOOTMNT}" -name "airootfs.sfs" 2>/dev/null | head -1 || true)
    fi

    clear
    echo ""
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}  ║      Installing JARVIS OS                    ║${NC}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════╝${NC}"
    echo ""

    if [ -n "${SFS_SRC}" ] && [ -f "${SFS_SRC}" ]; then
        info "Source: squashfs (${SFS_SRC})"
        mkdir -p "${SQUASH_MNT}"
        mount -o loop,ro "${SFS_SRC}" "${SQUASH_MNT}"

        info "Copying system files (this takes several minutes)..."
        echo ""
        rsync -aHAXx --info=progress2 \
            --exclude='/boot/grub/grubenv' \
            --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
            --exclude='/run/*' --exclude='/tmp/*' \
            "${SQUASH_MNT}/" "${MOUNT_ROOT}/" 2>&1 \
            | while IFS= read -r line; do printf '  %s\r' "${line}"; done

        umount "${SQUASH_MNT}"
        rmdir "${SQUASH_MNT}" 2>/dev/null || true
    else
        info "Source: live overlay (squashfs not found, using rsync from /)"
        echo ""
        rsync -aHAXx --info=progress2 \
            --exclude='/boot/grub/grubenv' \
            --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
            --exclude='/run/*' --exclude='/tmp/*' \
            --exclude='/mnt/*' --exclude='/lost+found' \
            / "${MOUNT_ROOT}/" 2>&1 \
            | while IFS= read -r line; do printf '  %s\r' "${line}"; done
    fi

    echo ""
    echo ""
    ok "System files installed"
}

# ── Kernel files ───────────────────────────────────────────────────────────
ensure_kernel() {
    local BOOTMNT="/run/archiso/bootmnt"
    local ARCH_BOOT="${BOOTMNT}/arch/boot/x86_64"

    ensure_bootmnt

    # Copy linux-jarvisos kernel if available on the live medium
    if [ -f "${ARCH_BOOT}/vmlinuz-linux-jarvisos" ]; then
        cp -f "${ARCH_BOOT}/vmlinuz-linux-jarvisos" \
              "${MOUNT_ROOT}/boot/vmlinuz-linux-jarvisos" 2>/dev/null || true
        cp -f "${ARCH_BOOT}/initramfs-linux-jarvisos.img" \
              "${MOUNT_ROOT}/boot/initramfs-linux-jarvisos.img" 2>/dev/null || true
        cp -f "${ARCH_BOOT}/initramfs-linux-jarvisos-fallback.img" \
              "${MOUNT_ROOT}/boot/initramfs-linux-jarvisos-fallback.img" 2>/dev/null || true
        ok "linux-jarvisos kernel files copied"
        KERNEL_PKG="linux-jarvisos"
    else
        info "linux-jarvisos not found on live medium — using stock linux kernel"
        KERNEL_PKG="linux"
    fi
}

# ── fstab ──────────────────────────────────────────────────────────────────
generate_fstab() {
    mkdir -p "${MOUNT_ROOT}/etc"
    genfstab -U "${MOUNT_ROOT}" > "${MOUNT_ROOT}/etc/fstab"
    ok "fstab generated"
}

# ── Configure installed system ─────────────────────────────────────────────
configure_system() {
    arch-chroot "${MOUNT_ROOT}" /bin/bash -s \
        "${HOSTNAME_VAL}" "${NEW_USER}" "${USER_PASS}" "${ROOT_PASS}" \
        "${BOOT_LOADER}" "${FS_TYPE}" "${TIMEZONE}" "${KEYMAP}" "${LOCALE}" \
        "${KERNEL_PKG:-linux}" <<'CHROOT_EOF'
set -euo pipefail

HOSTNAME_VAL="$1"
NEW_USER="$2"
USER_PASS="$3"
ROOT_PASS="$4"
BOOT_LOADER="$5"
FS_TYPE="$6"
TIMEZONE="$7"
KEYMAP="$8"
LOCALE="$9"
KERNEL_PKG="${10:-linux}"

warn() { echo "WARNING: $*" >&2; }

# Timezone
if [ "${TIMEZONE}" = "UTC" ]; then
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
elif [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
else
    warn "Timezone ${TIMEZONE} not found — defaulting to UTC"
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
fi
hwclock --systohc

# Locale
LOCALE_BASE=$(echo "${LOCALE}" | cut -d' ' -f1)
sed -i "s/^#\(${LOCALE_BASE}\)/\1/" /etc/locale.gen 2>/dev/null || true
# Also ensure en_US is generated if a different locale is chosen
grep -q "^en_US.UTF-8" /etc/locale.gen 2>/dev/null || \
    sed -i 's/^#\(en_US.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
locale-gen
echo "LANG=${LOCALE_BASE}" > /etc/locale.conf

# Keyboard
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# Hostname
echo "${HOSTNAME_VAL}" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_VAL}.localdomain ${HOSTNAME_VAL}
EOF

# Root password
echo "root:${ROOT_PASS}" | chpasswd

# User setup
for grp in wheel audio video storage optical network power lp sys scanner input; do
    getent group "${grp}" >/dev/null 2>&1 || groupadd --system "${grp}" 2>/dev/null || true
done

useradd -m -G wheel,audio,video,storage,optical,network,power -s /bin/bash "${NEW_USER}" 2>/dev/null || \
    useradd -m -s /bin/bash "${NEW_USER}"

for grp in wheel audio video storage optical network power lp sys scanner input; do
    usermod -aG "${grp}" "${NEW_USER}" 2>/dev/null || true
done

echo "${NEW_USER}:${USER_PASS}" | chpasswd

# sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers 2>/dev/null || \
    sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/'     /etc/sudoers 2>/dev/null || true
chmod 440 /etc/sudoers

# Remove live autologin config and TTY1 override
rm -f /etc/sddm.conf.d/autologin.conf 2>/dev/null || true
rm -rf /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
rm -f /root/.bash_profile 2>/dev/null || true

# SDDM config for installed system
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/jarvisos.conf << SDDM
[General]
DisplayServer=wayland
Numlock=on

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions
SDDM

# Remove liveuser account
userdel -r liveuser 2>/dev/null || true
rm -rf /home/liveuser 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-liveuser.rules 2>/dev/null || true

# Fix mkinitcpio.conf for installed system
# Remove archiso/memdisk live hooks; add block+filesystems for real boot
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap block filesystems)/' \
    /etc/mkinitcpio.conf

# Remove live linux kernel files (linux-jarvisos is the installed kernel)
rm -f /boot/vmlinuz-linux /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img
rm -f /etc/mkinitcpio.d/linux.preset 2>/dev/null || true

# mkinitcpio
if [ "${KERNEL_PKG}" = "linux-jarvisos" ]; then
    if [ -f /etc/mkinitcpio.d/linux-jarvisos.preset ]; then
        mkinitcpio -p linux-jarvisos || warn "mkinitcpio failed — check manually after install"
    elif [ -f /boot/initramfs-linux-jarvisos.img ]; then
        echo "linux-jarvisos initramfs already present"
    else
        warn "No linux-jarvisos preset found — bootloader may not work"
    fi
else
    # Fallback: build initramfs for stock linux kernel
    if [ -f /etc/mkinitcpio.d/linux.preset ]; then
        mkinitcpio -p linux || warn "mkinitcpio failed"
    fi
fi

# Enable services
systemctl enable NetworkManager.service              2>/dev/null || true
systemctl enable systemd-resolved.service            2>/dev/null || true
systemctl enable sddm.service                        2>/dev/null || true
systemctl enable bluetooth.service                   2>/dev/null || true
systemctl enable rtkit-daemon.service                2>/dev/null || true
systemctl enable ollama.service                      2>/dev/null || true
systemctl enable jarvis.service                      2>/dev/null || true
systemctl enable jarvis-setup.service                2>/dev/null || true
systemctl disable iwd.service                        2>/dev/null || true
systemctl mask    iwd.service                        2>/dev/null || true
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true

# resolv.conf
rm -f /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# XDG user dirs
if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    runuser -u "${NEW_USER}" -- xdg-user-dirs-update 2>/dev/null || true
fi

# JARVIS welcome autostart for new user (runs on first login)
AUTOSTART_DIR="/home/${NEW_USER}/.config/autostart"
mkdir -p "${AUTOSTART_DIR}"
cat > "${AUTOSTART_DIR}/jarvis-welcome.desktop" << JDESKTOP
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

# btrfs fstab options
if [ "${FS_TYPE}" = "btrfs" ]; then
    sed -i 's|subvol=@,|compress=zstd,noatime,subvol=@,|' /etc/fstab 2>/dev/null || true
fi

echo "System configuration complete."
CHROOT_EOF

    ok "System configured"
}

# ── Bootloader ─────────────────────────────────────────────────────────────
install_bootloader() {
    info "Installing ${BOOT_LOADER}..."

    # Determine which kernel to boot
    local KERN_VMLINUZ KERN_INITRD KERN_INITRD_FB
    if [ -f "${MOUNT_ROOT}/boot/vmlinuz-linux-jarvisos" ]; then
        KERN_VMLINUZ="vmlinuz-linux-jarvisos"
        KERN_INITRD="initramfs-linux-jarvisos.img"
        KERN_INITRD_FB="initramfs-linux-jarvisos-fallback.img"
    else
        KERN_VMLINUZ="vmlinuz-linux"
        KERN_INITRD="initramfs-linux.img"
        KERN_INITRD_FB="initramfs-linux-fallback.img"
    fi

    if [ "${BOOT_LOADER}" = "systemd-boot" ]; then
        arch-chroot "${MOUNT_ROOT}" bootctl --esp-path=/boot install

        cat > "${MOUNT_ROOT}/boot/loader/loader.conf" << 'LCONF'
default jarvisos.conf
timeout 5
console-mode max
editor no
LCONF

        mkdir -p "${MOUNT_ROOT}/boot/loader/entries"
        local ROOT_UUID
        ROOT_UUID=$(blkid -s UUID -o value \
            "$(findmnt -n -o SOURCE "${MOUNT_ROOT}" 2>/dev/null)" 2>/dev/null || \
            blkid -s UUID -o value \
            "$(mount | grep " ${MOUNT_ROOT} " | awk '{print $1}')" 2>/dev/null || true)

        local FS_OPTS="rw quiet splash"
        [ "${FS_TYPE}" = "btrfs" ] && FS_OPTS="rw quiet splash rootflags=subvol=@"

        local UCODE_LINES=""
        [ -f "${MOUNT_ROOT}/boot/intel-ucode.img" ] && UCODE_LINES+="initrd  /intel-ucode.img\n"
        [ -f "${MOUNT_ROOT}/boot/amd-ucode.img"   ] && UCODE_LINES+="initrd  /amd-ucode.img\n"

        printf "title   JARVIS OS\nlinux   /%s\n%sinitrd  /%s\noptions root=UUID=%s %s\n" \
            "${KERN_VMLINUZ}" "${UCODE_LINES}" "${KERN_INITRD}" "${ROOT_UUID}" "${FS_OPTS}" \
            > "${MOUNT_ROOT}/boot/loader/entries/jarvisos.conf"

        printf "title   JARVIS OS (fallback)\nlinux   /%s\n%sinitrd  /%s\noptions root=UUID=%s %s\n" \
            "${KERN_VMLINUZ}" "${UCODE_LINES}" "${KERN_INITRD_FB}" "${ROOT_UUID}" "${FS_OPTS}" \
            > "${MOUNT_ROOT}/boot/loader/entries/jarvisos-fallback.conf"

        ok "systemd-boot installed"
    else
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

        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' \
            "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null || true
        sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' \
            "${MOUNT_ROOT}/etc/default/grub" 2>/dev/null || true

        arch-chroot "${MOUNT_ROOT}" grub-mkconfig -o /boot/grub/grub.cfg

        ok "GRUB installed"
    fi
}

# ── Swap file ──────────────────────────────────────────────────────────────
create_swapfile() {
    if [ "${SWAP_SIZE}" = "file" ]; then
        info "Creating 4 GiB swap file..."
        arch-chroot "${MOUNT_ROOT}" /bin/bash -c "
            dd if=/dev/zero of=/swapfile bs=1M count=4096 status=progress 2>&1 || true
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

# ── Detect Arch-based distro ───────────────────────────────────────────────
detect_arch_based() {
    local id="" id_like=""
    if [ -f /etc/os-release ]; then
        id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
        id_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    case "${id}" in
        arch|manjaro|endeavouros|garuda|cachyos|artix|parabola|arcolinux) return 0 ;;
    esac
    [[ "${id_like}" == *arch* ]] && return 0
    die "Not an Arch-based system (ID=${id:-unknown}, ID_LIKE=${id_like:-unknown}).\nRun on Arch Linux or an Arch-based distro."
}

# ── Find JARVIS source code ────────────────────────────────────────────────
find_jarvis_source() {
    [ -f /usr/lib/jarvis/main.py ] && echo "installed" && return 0
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local try="${script_dir}/../../Project-JARVIS"
    [ -f "${try}/jarvis/main.py" ] && echo "$(realpath "${try}")" && return 0
    echo ""
    return 1
}

# ── Install JARVIS OS components on existing Arch system ───────────────────
install_packages_mode() {
    need_root
    detect_arch_based

    local distro_name
    distro_name=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null \
        | cut -d= -f2 | tr -d '"' || echo "Arch Linux")

    dialog --clear --backtitle "JARVIS OS Package Installer" \
           --title "Install JARVIS OS on ${distro_name}" \
           --yesno "\
Install JARVIS OS components on: ${distro_name}

This will install (existing packages kept):
  • KDE Plasma Wayland desktop + SDDM
  • PipeWire audio ecosystem
  • NetworkManager + WiFi (wpa_supplicant backend)
  • GPU drivers: Mesa, Vulkan, Intel VA-API, AMD
  • Fonts: Noto, Liberation, DejaVu, CJK
  • linux + linux-headers kernel packages
  • Ollama AI engine
  • JARVIS Python code + venv + dependencies
  • Vosk speech recognition model (~50 MB)
  • Piper TTS model (~65 MB)
  • JARVIS systemd services (enabled)
  • SDDM enabled as display manager

No disk will be wiped. No partitioning.

Proceed?" 28 70 || { clear; echo "Aborted."; exit 0; }

    clear
    echo ""
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}  ║    Installing JARVIS OS Components               ║${NC}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    # ── Sync DB ──────────────────────────────────────────────────────────
    info "Syncing package database..."
    pacman -Sy --noconfirm 2>&1 || warn "pacman -Sy had issues — continuing"
    ok "Package database synced"

    # ── Base utilities ───────────────────────────────────────────────────
    info "Installing base utilities..."
    pacman -S --noconfirm --needed \
        sudo less nano vim wget curl git openssh man-db man-pages \
        unzip zip p7zip rsync tzdata bash-completion which lsof htop neofetch \
        || warn "Some base packages failed"
    ok "Base utilities installed"

    # ── Kernel packages ──────────────────────────────────────────────────
    info "Installing kernel packages..."
    pacman -S --noconfirm --needed linux linux-headers linux-firmware \
        || warn "Kernel packages had issues"
    ok "Kernel packages installed"

    # ── KDE Plasma Wayland ───────────────────────────────────────────────
    info "Installing KDE Plasma Wayland..."
    pacman -S --noconfirm --needed \
        plasma-desktop plasma-workspace plasma-wayland-session \
        kwin plasma-nm plasma-pa kscreen powerdevil bluedevil \
        kinfocenter polkit-kde-agent kdeplasma-addons plasma-systemmonitor \
        sddm sddm-kcm breeze breeze-gtk kde-gtk-config oxygen-sounds \
        kwalletmanager kwallet-pam \
        qt5-wayland qt6-wayland xorg-xwayland \
        dolphin konsole kate ark spectacle gwenview okular kcalc \
        filelight kdeconnect \
        xdg-user-dirs xdg-desktop-portal xdg-desktop-portal-kde \
        || warn "Some KDE packages failed"
    ok "KDE Plasma installed"

    # ── PipeWire ─────────────────────────────────────────────────────────
    info "Installing PipeWire audio..."
    pacman -S --noconfirm --needed \
        pipewire pipewire-alsa pipewire-jack pipewire-pulse wireplumber \
        gst-plugin-pipewire gst-plugins-good gst-plugins-bad gst-plugins-ugly \
        sof-firmware alsa-firmware alsa-utils alsa-plugins \
        rtkit pavucontrol \
        || warn "Some audio packages failed"
    ok "PipeWire installed"

    # ── Bluetooth ────────────────────────────────────────────────────────
    info "Installing Bluetooth..."
    pacman -S --noconfirm --needed bluez bluez-utils \
        || warn "Bluetooth packages failed"

    # ── Network ──────────────────────────────────────────────────────────
    info "Installing network tools..."
    pacman -S --noconfirm --needed \
        networkmanager nm-connection-editor network-manager-applet \
        wpa_supplicant wireless-regdb iw modemmanager dhcpcd \
        || warn "Some network packages failed"
    ok "Network tools installed"

    # ── GPU drivers ──────────────────────────────────────────────────────
    info "Installing GPU drivers..."
    pacman -S --noconfirm --needed \
        mesa vulkan-intel vulkan-radeon vulkan-swrast \
        libva-intel-driver intel-media-driver xf86-video-amdgpu \
        || warn "Some GPU packages failed"
    ok "GPU drivers installed"

    # ── Input + fonts + filesystem tools ─────────────────────────────────
    info "Installing input drivers, fonts, filesystem tools..."
    pacman -S --noconfirm --needed \
        libinput xf86-input-libinput xf86-input-evdev libevdev \
        noto-fonts noto-fonts-emoji ttf-liberation ttf-dejavu noto-fonts-cjk \
        e2fsprogs btrfs-progs dosfstools exfatprogs ntfs-3g \
        parted gptfdisk grub efibootmgr arch-install-scripts \
        || warn "Some packages failed"
    ok "Drivers, fonts, filesystem tools installed"

    # ── Python + JARVIS system deps ───────────────────────────────────────
    info "Installing Python + JARVIS system dependencies..."
    pacman -S --noconfirm --needed \
        python python-pip python-setuptools python-wheel python-virtualenv \
        gcc make pkg-config dialog portaudio python-pyaudio \
        || warn "Some Python packages failed"
    ok "Python dependencies installed"

    # ── JARVIS OS branding ────────────────────────────────────────────────
    info "Applying JARVIS OS branding..."
    cat > /etc/os-release << 'EOF'
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
    ok "JARVIS OS branding applied"

    # ── Ollama ────────────────────────────────────────────────────────────
    info "Installing Ollama..."
    if command -v ollama >/dev/null 2>&1; then
        ok "Ollama already installed ($(ollama --version 2>/dev/null || echo unknown))"
    else
        if curl -fsSL https://ollama.com/install.sh | OLLAMA_NO_SYSTEM_SERVICE=1 sh 2>/dev/null; then
            ok "Ollama installed"
        else
            warn "Ollama install.sh failed — trying direct binary download..."
            local _arch; _arch=$(uname -m)
            local _url="https://ollama.com/download/ollama-linux-amd64"
            [ "${_arch}" = "aarch64" ] && _url="https://ollama.com/download/ollama-linux-arm64"
            if curl -fsSL -o /usr/local/bin/ollama "${_url}"; then
                chmod +x /usr/local/bin/ollama
                ok "Ollama binary installed"
            else
                warn "Ollama download failed — install manually: curl -fsSL https://ollama.com/install.sh | sh"
            fi
        fi
    fi

    # Ollama systemd service
    if [ ! -f /usr/lib/systemd/system/ollama.service ]; then
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
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="HOME=/usr/share/ollama"
Environment="OLLAMA_HOST=0.0.0.0"

[Install]
WantedBy=default.target
OLLAMAEOF
    fi
    getent group  ollama >/dev/null 2>&1 || groupadd -r ollama
    getent passwd ollama >/dev/null 2>&1 || \
        useradd -r -g ollama -d /usr/share/ollama -s /bin/false -c 'Ollama Service' ollama
    mkdir -p /usr/share/ollama && chown -R ollama:ollama /usr/share/ollama

    # ── JARVIS user + directories ─────────────────────────────────────────
    info "Setting up JARVIS user and directories..."
    getent group  jarvis >/dev/null 2>&1 || groupadd -r jarvis
    getent passwd jarvis >/dev/null 2>&1 || \
        useradd -r -g jarvis -d /var/lib/jarvis -s /sbin/nologin \
                -c 'JARVIS AI Assistant' jarvis
    for grp in audio video network systemd-journal storage optical; do
        getent group "${grp}" >/dev/null 2>&1 && \
            usermod -aG "${grp}" jarvis 2>/dev/null || true
    done
    mkdir -p /usr/lib/jarvis /etc/jarvis \
             /var/lib/jarvis/models/piper \
             /var/lib/jarvis/models/vosk \
             /var/log/jarvis
    chown -R jarvis:jarvis /var/lib/jarvis /var/log/jarvis
    ok "JARVIS user and directories configured"

    # ── JARVIS code ───────────────────────────────────────────────────────
    info "Installing JARVIS code..."
    local _jarvis_src
    _jarvis_src=$(find_jarvis_source)

    if [ "${_jarvis_src}" = "installed" ]; then
        ok "JARVIS code already at /usr/lib/jarvis"
    elif [ -n "${_jarvis_src}" ]; then
        cp -r "${_jarvis_src}/jarvis/"* /usr/lib/jarvis/
        [ -f "${_jarvis_src}/jarvis/.env.example" ] && \
            cp "${_jarvis_src}/jarvis/.env.example" /usr/lib/jarvis/.env.example
        [ -f "${_jarvis_src}/requirements.txt" ] && \
            cp "${_jarvis_src}/requirements.txt" /usr/lib/jarvis/requirements.txt
        chown -R jarvis:jarvis /usr/lib/jarvis
        ok "JARVIS code installed from ${_jarvis_src}"
    else
        warn "JARVIS source not found locally — cloning from GitHub..."
        if git clone --depth=1 \
                https://github.com/YakupAtahanov/Project-JARVIS \
                /tmp/Project-JARVIS-pkginstall 2>&1; then
            cp -r /tmp/Project-JARVIS-pkginstall/jarvis/* /usr/lib/jarvis/
            [ -f /tmp/Project-JARVIS-pkginstall/jarvis/.env.example ] && \
                cp /tmp/Project-JARVIS-pkginstall/jarvis/.env.example /usr/lib/jarvis/.env.example
            [ -f /tmp/Project-JARVIS-pkginstall/requirements.txt ] && \
                cp /tmp/Project-JARVIS-pkginstall/requirements.txt /usr/lib/jarvis/requirements.txt
            chown -R jarvis:jarvis /usr/lib/jarvis
            rm -rf /tmp/Project-JARVIS-pkginstall
            ok "JARVIS code cloned and installed"
        else
            warn "Could not clone Project-JARVIS — install JARVIS code manually:"
            warn "  git clone https://github.com/YakupAtahanov/Project-JARVIS /tmp/jarvis"
            warn "  sudo cp -r /tmp/jarvis/jarvis/* /usr/lib/jarvis/"
        fi
    fi

    # ── Python venv ───────────────────────────────────────────────────────
    if [ -f /usr/lib/jarvis/requirements.txt ]; then
        if [ ! -d /var/lib/jarvis/venv ]; then
            info "Creating Python virtual environment..."
            python3 -m venv /var/lib/jarvis/venv
            /var/lib/jarvis/venv/bin/pip install --upgrade pip
            /var/lib/jarvis/venv/bin/pip install -r /usr/lib/jarvis/requirements.txt \
                || warn "Some Python deps failed — check /var/lib/jarvis/venv manually"
            chown -R jarvis:jarvis /var/lib/jarvis/venv
            ok "Python venv created"
        else
            ok "Python venv already exists"
        fi
    else
        warn "requirements.txt missing — skipping venv setup"
    fi

    # ── .env defaults ─────────────────────────────────────────────────────
    if [ -f /usr/lib/jarvis/.env.example ] && [ ! -f /usr/lib/jarvis/.env ]; then
        cp /usr/lib/jarvis/.env.example /usr/lib/jarvis/.env
        chown jarvis:jarvis /usr/lib/jarvis/.env
    fi
    if [ -f /usr/lib/jarvis/.env ]; then
        _set_env() {
            local k="$1" v="$2" f="/usr/lib/jarvis/.env"
            grep -q "^${k}=" "${f}" \
                && sed -i "s|^${k}=.*|${k}=${v}|" "${f}" \
                || echo "${k}=${v}" >> "${f}"
        }
        _set_env LLM_AUTO_PULL     true
        _set_env LLM_MODEL         qwen3:4b
        _set_env VOSK_MODEL_PATH   /var/lib/jarvis/models/vosk/vosk-model-small-en-us-0.15
        _set_env TTS_MODEL_ONNX    /var/lib/jarvis/models/piper/en_US-amy-medium.onnx
        _set_env TTS_MODEL_JSON    /var/lib/jarvis/models/piper/en_US-amy-medium.onnx.json
        _set_env OUTPUT_MODE       voice
        _set_env CONTEXTOR_ENABLED true
        _set_env DATA_CONSENT      true
        chown jarvis:jarvis /usr/lib/jarvis/.env
        ok ".env defaults applied"
    fi

    # ── CLI wrappers ──────────────────────────────────────────────────────
    info "Installing CLI wrappers..."
    cat > /usr/bin/jarvis << 'JCLI'
#!/bin/bash
VENV_PATH="/var/lib/jarvis/venv"
[ -f "${VENV_PATH}/bin/activate" ] && source "${VENV_PATH}/bin/activate"
export PYTHONPATH="/usr/lib:${PYTHONPATH:-}"
cd /usr/lib/jarvis
python -m jarvis.cli "$@"
JCLI
    chmod +x /usr/bin/jarvis

    cat > /usr/bin/jarvis-daemon << 'JD'
#!/bin/bash
VENV_PATH="/var/lib/jarvis/venv"
[ -f "${VENV_PATH}/bin/activate" ] && source "${VENV_PATH}/bin/activate"
export PYTHONPATH="/usr/lib:${PYTHONPATH:-}"
cd /usr/lib/jarvis
exec python -m jarvis.cli run "$@"
JD
    chmod +x /usr/bin/jarvis-daemon
    ok "CLI wrappers installed"

    # ── sudoers + polkit ──────────────────────────────────────────────────
    cat > /etc/sudoers.d/10-jarvis << 'SUDOERS_EOF'
Defaults:jarvis !requiretty, !lecture, passwd_tries=0
jarvis ALL=(ALL) NOPASSWD: \
    /usr/bin/pacman,        \
    /usr/bin/systemctl,     \
    /usr/bin/journalctl,    \
    /usr/bin/nmcli,         \
    /usr/bin/timedatectl,   \
    /usr/bin/localectl,     \
    /usr/bin/hostnamectl,   \
    /usr/bin/modprobe,      \
    /usr/bin/sysctl,        \
    /usr/bin/chmod,         \
    /usr/bin/chown,         \
    /usr/bin/mkdir,         \
    /usr/bin/tee,           \
    /usr/bin/cp,            \
    /usr/bin/mv,            \
    /usr/bin/rm
SUDOERS_EOF
    chmod 440 /etc/sudoers.d/10-jarvis

    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/49-jarvis.rules << 'POLKIT_EOF'
polkit.addRule(function(action, subject) {
    if (subject.user === "jarvis") {
        var allowed = [
            "org.freedesktop.systemd1",
            "org.freedesktop.NetworkManager",
            "org.freedesktop.timedate1",
            "org.freedesktop.locale1",
            "org.freedesktop.hostname1",
            "org.freedesktop.login1",
        ];
        for (var i = 0; i < allowed.length; i++) {
            if (action.id.indexOf(allowed[i]) === 0) { return polkit.Result.YES; }
        }
    }
});
POLKIT_EOF
    chmod 644 /etc/polkit-1/rules.d/49-jarvis.rules
    ok "sudoers + polkit rules installed"

    # ── Systemd service units ─────────────────────────────────────────────
    info "Installing systemd service units..."
    cat > /usr/lib/systemd/system/jarvis.service << 'JARVISSVC'
[Unit]
Description=JARVIS AI Voice Assistant
After=network.target sound.target ollama.service
Wants=network.target ollama.service

[Service]
Type=simple
User=jarvis
Group=jarvis
SupplementaryGroups=audio video network systemd-journal storage
WorkingDirectory=/usr/lib/jarvis
RuntimeDirectory=jarvis
RuntimeDirectoryMode=0775
ExecStart=/usr/bin/jarvis-daemon
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30
AmbientCapabilities=CAP_SYS_ADMIN CAP_NET_ADMIN CAP_SYS_NICE
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_NET_ADMIN CAP_SYS_NICE
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictRealtime=yes
LimitNOFILE=65536
LimitNPROC=4096
Environment=JARVIS_CONFIG_DIR=/etc/jarvis
Environment=JARVIS_DATA_DIR=/var/lib/jarvis
Environment=JARVIS_INPUT_SOCKET=/run/jarvis/input.sock
Environment=JARVIS_LOG_DIR=/var/log/jarvis
Environment=JARVIS_MODELS_DIR=/var/lib/jarvis/models
Environment=PYTHONPATH=/usr/lib/jarvis
Environment=OLLAMA_HOST=127.0.0.1:11434
Environment=XDG_RUNTIME_DIR=/run/user/0
StandardOutput=journal
StandardError=journal
SyslogIdentifier=jarvis

[Install]
WantedBy=multi-user.target
JARVISSVC

    cat > /usr/lib/systemd/system/jarvis-setup.service << 'SETUPSVC'
[Unit]
Description=JARVIS First-Boot Setup (pull LLM model)
After=network-online.target ollama.service
Wants=network-online.target
Requires=ollama.service
ConditionPathExists=!/var/lib/jarvis/.setup-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/jarvis-first-boot.sh
RemainAfterExit=yes
TimeoutStartSec=600
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SETUPSVC

    cat > /usr/local/bin/jarvis-first-boot.sh << 'FIRSTBOOT'
#!/bin/bash
MARKER="/var/lib/jarvis/.setup-done"
LOG="/var/log/jarvis/first-boot.log"
mkdir -p /var/log/jarvis
exec > >(tee -a "$LOG") 2>&1
echo "=== JARVIS first-boot $(date) ==="
[ -f "$MARKER" ] && echo "Already done." && exit 0
MODEL="qwen3:4b"
[ -f /usr/lib/jarvis/.env ] && \
    _m=$(grep -E '^LLM_MODEL=' /usr/lib/jarvis/.env | cut -d= -f2-) && \
    [ -n "$_m" ] && MODEL="$_m"
echo "Waiting for Ollama..."
for i in $(seq 1 60); do
    curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break; sleep 2
done
ollama list 2>/dev/null | grep -q "${MODEL%%:*}" || ollama pull "$MODEL" || exit 1
touch "$MARKER"
systemctl disable jarvis-setup.service 2>/dev/null || true
echo "First-boot complete."
FIRSTBOOT
    chmod 755 /usr/local/bin/jarvis-first-boot.sh
    ok "Systemd service units installed"

    # ── Vosk STT model ────────────────────────────────────────────────────
    local _vosk_model="vosk-model-small-en-us-0.15"
    local _vosk_dest="/var/lib/jarvis/models/vosk"
    if [ -d "${_vosk_dest}/${_vosk_model}" ]; then
        ok "Vosk model already present"
    else
        info "Downloading Vosk STT model (~50 MB)..."
        local _vtmp; _vtmp=$(mktemp -d)
        if curl -fSL -o "${_vtmp}/${_vosk_model}.zip" \
                "https://alphacephei.com/vosk/models/${_vosk_model}.zip"; then
            unzip -qo "${_vtmp}/${_vosk_model}.zip" -d "${_vosk_dest}/"
            chown -R jarvis:jarvis "${_vosk_dest}"
            ok "Vosk model installed"
        else
            warn "Vosk download failed — voice recognition disabled until installed manually"
        fi
        rm -rf "${_vtmp}"
    fi

    # ── Piper TTS model ───────────────────────────────────────────────────
    local _piper_model="en_US-amy-medium"
    local _piper_dest="/var/lib/jarvis/models/piper"
    local _piper_base="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/amy/medium"
    mkdir -p "${_piper_dest}"
    if [ -f "${_piper_dest}/${_piper_model}.onnx" ]; then
        ok "Piper TTS model already present"
    else
        info "Downloading Piper TTS model (~65 MB)..."
        if curl -fSL -o "${_piper_dest}/${_piper_model}.onnx" \
                    "${_piper_base}/${_piper_model}.onnx" && \
           curl -fSL -o "${_piper_dest}/${_piper_model}.onnx.json" \
                    "${_piper_base}/${_piper_model}.onnx.json"; then
            chown -R jarvis:jarvis "${_piper_dest}"
            ok "Piper TTS model installed"
        else
            warn "Piper download failed — TTS disabled until installed manually"
        fi
    fi

    # ── XDG autostart + desktop launcher ─────────────────────────────────
    mkdir -p /etc/xdg/autostart /usr/share/applications
    cat > /etc/xdg/autostart/ollama.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Ollama Service
Exec=/usr/local/bin/ollama serve
Terminal=false
StartupNotify=false
NoDisplay=true
EOF
    cat > /etc/xdg/autostart/jarvis.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=JARVIS AI Assistant
Exec=/usr/bin/jarvis-daemon
Terminal=false
StartupNotify=false
NoDisplay=true
X-KDE-autostart-phase=2
EOF
    cat > /usr/share/applications/jarvis.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=JARVIS AI
GenericName=AI Assistant
Comment=Chat with your JARVIS AI assistant
Exec=konsole -e jarvis chat
Icon=utilities-terminal
Terminal=false
Categories=Utility;System;
Keywords=jarvis;ai;assistant;chat;voice;
StartupNotify=true
EOF

    # ── SDDM ─────────────────────────────────────────────────────────────
    info "Configuring SDDM..."
    mkdir -p /etc/sddm.conf.d
    cat > /etc/sddm.conf.d/jarvisos.conf << 'SDDM'
[General]
DisplayServer=wayland
Numlock=on

[Wayland]
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionDir=/usr/share/wayland-sessions
SDDM

    # ── NetworkManager backend ────────────────────────────────────────────
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/wifi-backend.conf << 'EOF'
[device]
wifi.backend=wpa_supplicant
EOF

    # ── Enable / disable services ─────────────────────────────────────────
    info "Enabling systemd services..."
    systemctl daemon-reload
    systemctl enable NetworkManager.service              2>/dev/null || true
    systemctl enable systemd-resolved.service            2>/dev/null || true
    systemctl enable sddm.service                        2>/dev/null || true
    systemctl enable bluetooth.service                   2>/dev/null || true
    systemctl enable rtkit-daemon.service                2>/dev/null || true
    systemctl enable ollama.service                      2>/dev/null || true
    systemctl enable jarvis.service                      2>/dev/null || true
    systemctl enable jarvis-setup.service                2>/dev/null || true
    systemctl disable iwd.service                        2>/dev/null || true
    systemctl mask    iwd.service                        2>/dev/null || true
    systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
    ok "Services enabled"

    # ── Done ──────────────────────────────────────────────────────────────
    clear
    echo ""
    echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║     JARVIS OS Components Installed!              ║${NC}"
    echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Installed:${NC}"
    echo -e "    ✓ KDE Plasma Wayland + SDDM (enabled)"
    echo -e "    ✓ PipeWire audio + Bluetooth"
    echo -e "    ✓ NetworkManager + WiFi (wpa_supplicant)"
    echo -e "    ✓ GPU drivers (Mesa / Vulkan / Intel / AMD)"
    echo -e "    ✓ Ollama AI engine"
    echo -e "    ✓ JARVIS AI assistant + Python venv"
    echo -e "    ✓ Vosk STT + Piper TTS models"
    echo -e "    ✓ All systemd services enabled"
    echo ""
    echo -e "  ${CYAN}Next steps:${NC}"
    echo -e "    Reboot to start KDE Plasma Wayland + JARVIS"
    echo -e "    AI model (qwen3:4b) downloads on first boot (internet required)"
    echo ""
    echo -e "    ${BOLD}reboot${NC}"
    echo ""
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    # Overlay-install mode: add JarvisOS components to existing Arch system
    if [[ "${1:-}" == "--install-packages" || "${1:-}" == "--overlay" ]]; then
        install_packages_mode
        exit 0
    fi

    need_root
    check_deps
    detect_uefi

    # Load keymap if set
    [ -f /etc/vconsole.conf ] && source /etc/vconsole.conf 2>/dev/null || true
    [ -n "${KEYMAP:-}" ] && loadkeys "${KEYMAP}" 2>/dev/null || true

    step_welcome
    step_select_disk
    step_select_bootloader
    step_select_fs
    step_select_swap
    step_timezone
    step_keyboard
    step_locale
    step_hostname
    step_user
    step_summary

    clear
    echo ""
    echo -e "${BOLD}${CYAN}  JARVIS OS Installation${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    trap cleanup_mounts EXIT

    info "Partitioning ${TARGET_DISK}..."
    partition_disk

    info "Formatting partitions..."
    format_and_mount

    install_system

    info "Copying kernel files..."
    ensure_kernel

    info "Generating fstab..."
    generate_fstab

    info "Configuring system..."
    configure_system

    info "Installing bootloader..."
    install_bootloader

    create_swapfile

    trap - EXIT
    cleanup_mounts

    clear
    echo ""
    echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║         JARVIS OS Installation Complete!         ║${NC}"
    echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo -e "    Disk:        ${TARGET_DISK}"
    echo -e "    Bootloader:  ${BOOT_LOADER}"
    echo -e "    Filesystem:  ${FS_TYPE}"
    echo -e "    Timezone:    ${TIMEZONE}"
    echo -e "    Keyboard:    ${KEYMAP}"
    echo -e "    Locale:      ${LOCALE}"
    echo -e "    Hostname:    ${HOSTNAME_VAL}"
    echo -e "    User:        ${NEW_USER}"
    echo ""
    echo -e "  ${CYAN}JARVIS AI:${NC} The AI model downloads on first login."
    echo -e "  A setup wizard will run automatically after you log in."
    echo ""
    echo -e "  ${YELLOW}Remove the installation medium, then reboot:${NC}"
    echo -e "    ${BOLD}reboot${NC}"
    echo ""
}

main "$@"
