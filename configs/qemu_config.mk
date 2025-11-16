# QEMU VM configuration (edit as needed). All values are safe defaults.
# You can override at runtime too, e.g.:
#   QEMU_RAM=8192 QEMU_CPUS=4 make boot-arch
#
# Binary / architecture
QEMU_BIN            ?= qemu-system-x86_64   # QEMU system binary
QEMU_MACHINE        ?=                      # e.g., q35, pc-q35-9.0, virt (for aarch64)
QEMU_ENABLE_KVM     ?= 1                    # 1 enables KVM accel (Linux hosts), 0 disables
QEMU_CPU            ?=                      # e.g., host, max, or a specific model (Skylake-Client-IBRS)

# Core resources
QEMU_RAM            ?= 2048                 # Guest RAM in MB
QEMU_CPUS           ?= 2                    # vCPUs

# Disk (primary root image)
QEMU_DISK_GB        ?= 20                   # QCOW2 disk size in GB for build target
QEMU_DISK_IF        ?= virtio               # Disk interface: virtio | ide | scsi | nvme
QEMU_DISK_CACHE     ?= none                 # Cache mode: none | writeback | unsafe | directsync

# Networking (user-mode with host forwarding)
# Example forwards (uncomment as needed). Format: -netdev user,id=n1,hostfwd=tcp::2222-:22
QEMU_NET_OPTS       ?= -netdev user,id=n1 -device virtio-net-pci,netdev=n1
# To enable SSH forwarding on host port 2222 → guest 22:
# QEMU_NET_OPTS     ?= -netdev user,id=n1,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n1

# Display and graphics
QEMU_DISPLAY_OPTS   ?= -nographic           # Headless by default; alternatives:
# QEMU_DISPLAY_OPTS ?= -display sdl -vga std
# QEMU_DISPLAY_OPTS ?= -spice port=5930,disable-ticketing=on -vga qxl

# Audio (example for PulseAudio)
# QEMU_AUDIO_OPTS   ?= -audiodev pa,id=pa,server=/run/user/1000/pulse/native -device ich9-intel-hda -device hda-duplex,audiodev=pa
QEMU_AUDIO_OPTS     ?=

# USB input and tablet (useful with graphical display)
# QEMU_USB_OPTS     ?= -device qemu-xhci -device usb-tablet
QEMU_USB_OPTS       ?=

# Serial / console
QEMU_SERIAL_OPTS    ?=                      # e.g., -serial mon:stdio or -serial null

# Name / SMBIOS / Firmware
QEMU_NAME_OPTS      ?= -name jarvisos,process=jarvisos
QEMU_SMBIOS_OPTS    ?=
# For UEFI boot (if/when you add OVMF): set to paths of OVMF vars/code
QEMU_FIRMWARE_OPTS  ?=                      # e.g., -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd

# Extra passthrough or devices (GPU, USB, etc.)
QEMU_PASSTHROUGH    ?=                      # e.g., -device vfio-pci,host=0000:01:00.0

# Catch-all
QEMU_EXTRA          ?=                      # Any additional flags appended at the end


