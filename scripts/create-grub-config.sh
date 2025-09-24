#!/bin/bash
# JARVIS OS - GRUB Configuration Script
# Creates GRUB configuration for booting JARVIS OS

set -e

GRUB_CONFIG="$1"
if [ -z "$GRUB_CONFIG" ]; then
    echo "Usage: $0 <grub-config-file>"
    exit 1
fi

echo "🔧 Creating GRUB configuration for JARVIS OS..."

# Create GRUB configuration
cat > "$GRUB_CONFIG" << 'EOF'
# JARVIS OS - GRUB Configuration
# Boot configuration for AI-Native Operating System

set timeout=10
set default=0

menuentry "JARVIS OS - AI Voice Assistant" {
    echo "🤖 Loading JARVIS OS..."
    linux /boot/vmlinuz-6.16.5 root=/dev/ram0 rw quiet
    initrd /boot/initramfs.img
}

menuentry "JARVIS OS - Safe Mode" {
    echo "🔧 Loading JARVIS OS (Safe Mode)..."
    linux /boot/vmlinuz-6.16.5 root=/dev/ram0 rw quiet single
    initrd /boot/initramfs.img
}

menuentry "JARVIS OS - Debug Mode" {
    echo "🐛 Loading JARVIS OS (Debug Mode)..."
    linux /boot/vmlinuz-6.16.5 root=/dev/ram0 rw debug verbose
    initrd /boot/initramfs.img
}

menuentry "Memory Test" {
    echo "🧪 Running memory test..."
    linux /boot/memtest86+
}

menuentry "Reboot" {
    echo "🔄 Rebooting system..."
    reboot
}

menuentry "Shutdown" {
    echo "⏹️  Shutting down system..."
    halt
}
EOF

echo "✅ GRUB configuration created: $GRUB_CONFIG"


