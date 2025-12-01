#!/bin/sh
qemu-system-x86_64 -cdrom "${1:-build/jarvisos-20251130-x86_64.iso}" -boot d -m 4096 -enable-kvm
