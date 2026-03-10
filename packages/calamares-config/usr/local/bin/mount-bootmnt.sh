#!/bin/bash
# Mount the archiso boot medium at /run/archiso/bootmnt
# Required by Calamares unpackfs to access airootfs.sfs
#
# In some archiso configurations, bootmnt is not kept mounted after
# the live rootfs overlay is set up. This script re-mounts it.

set -e

BOOTMNT="/run/archiso/bootmnt"

# Already mounted? Nothing to do.
if mountpoint -q "${BOOTMNT}" 2>/dev/null; then
    echo "bootmnt already mounted at ${BOOTMNT}"
    exit 0
fi

# Get the archisolabel from kernel command line
LABEL=""
for param in $(cat /proc/cmdline); do
    case "${param}" in
        archisolabel=*)
            LABEL="${param#archisolabel=}"
            ;;
        archisodevice=*)
            DEVICE="${param#archisodevice=}"
            ;;
    esac
done

if [ -z "${LABEL}" ]; then
    # Fallback: try common JARVISOS labels
    LABEL=$(blkid -o value -s LABEL | grep -m1 "^JARVISOS" || true)
fi

if [ -z "${LABEL}" ]; then
    echo "ERROR: Cannot determine archiso volume label from kernel cmdline or blkid" >&2
    exit 1
fi

echo "Archiso volume label: ${LABEL}"

mkdir -p "${BOOTMNT}"

# Find the device by label
DEV=$(blkid -L "${LABEL}" 2>/dev/null || true)

if [ -z "${DEV}" ]; then
    # Fallback: scan for device with matching label
    for dev in /dev/sr0 /dev/sr1 /dev/sd??* /dev/nvme*p* /dev/loop*; do
        [ -b "$dev" ] || continue
        dev_label=$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)
        if [ "${dev_label}" = "${LABEL}" ]; then
            DEV="$dev"
            break
        fi
    done
fi

if [ -z "${DEV}" ]; then
    echo "ERROR: No device found with label '${LABEL}'" >&2
    exit 1
fi

echo "Mounting ${DEV} at ${BOOTMNT}"
mount -o ro "${DEV}" "${BOOTMNT}"

# Verify airootfs.sfs is accessible
BASEDIR="arch"
for param in $(cat /proc/cmdline); do
    case "${param}" in
        archisobasedir=*)
            BASEDIR="${param#archisobasedir=}"
            ;;
    esac
done

SFS="${BOOTMNT}/${BASEDIR}/x86_64/airootfs.sfs"
if [ -f "${SFS}" ]; then
    echo "SUCCESS: ${SFS} is accessible"
else
    echo "WARNING: ${SFS} not found after mount" >&2
    echo "Contents of ${BOOTMNT}:" >&2
    ls -la "${BOOTMNT}/" 2>&1 || true
    ls -la "${BOOTMNT}/${BASEDIR}/" 2>&1 || true
fi

exit 0
