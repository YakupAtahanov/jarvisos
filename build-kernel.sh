#!/usr/bin/env bash
# build-kernel.sh — Build linux-jarvisos and linux-jarvisos-headers on the host system
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC="${REPO_ROOT}/linux"
PKGBUILD_DIR="${REPO_ROOT}/packages/linux-jarvisos"
PKG_DEST="${REPO_ROOT}/kernel-pkg"

# ── Sanity checks ────────────────────────────────────────────────────────────

if [[ ! -d "${KERNEL_SRC}/.git" && ! -f "${KERNEL_SRC}/Makefile" ]]; then
    echo "ERROR: linux submodule not found or not populated at ${KERNEL_SRC}"
    echo "       Run: git submodule update --init linux"
    exit 1
fi

if [[ ! -f "${PKGBUILD_DIR}/PKGBUILD" ]]; then
    echo "ERROR: PKGBUILD not found at ${PKGBUILD_DIR}/PKGBUILD"
    exit 1
fi

# Check makedepends are installed
MISSING=()
for pkg in bc cpio gettext libelf pahole perl python tar xz zstd; do
    if ! pacman -Q "$pkg" &>/dev/null; then
        MISSING+=("$pkg")
    fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "ERROR: Missing build dependencies: ${MISSING[*]}"
    echo "       Run: sudo pacman -S --needed ${MISSING[*]}"
    exit 1
fi

# ── Build ────────────────────────────────────────────────────────────────────

mkdir -p "${PKG_DEST}"

echo "==> Building linux-jarvisos..."
echo "    KERNEL_SRC : ${KERNEL_SRC}"
echo "    PKG_DEST   : ${PKG_DEST}"
echo ""

export KERNEL_SRC

FORCE_FLAG=""
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
    FORCE_FLAG="--force"
    echo "    Mode       : forced rebuild (--force)"
fi

cd "${PKGBUILD_DIR}"
PKGDEST="${PKG_DEST}" makepkg --nodeps --nocheck --skipinteg ${FORCE_FLAG}

echo ""
echo "==> Build complete. Packages:"
ls -lh "${PKG_DEST}"/*.pkg.tar.zst

echo ""
echo "==> To install:"
echo "    sudo pacman -U ${PKG_DEST}/linux-jarvisos-*.pkg.tar.zst \\"
echo "                   ${PKG_DEST}/linux-jarvisos-headers-*.pkg.tar.zst"
