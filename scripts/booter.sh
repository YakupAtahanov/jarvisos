#!/bin/bash
source build.config
qemu-system-x86_64 -cdrom "${PROJECT_ROOT}${BUILD_DIR}/${JARVIS_ISO_FILE}" -boot d -m 4096 -enable-kvm
