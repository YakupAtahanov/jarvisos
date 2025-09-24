#!/bin/bash
# JARVIS OS - Initramfs Creation Script
# Creates a minimal initramfs with JARVIS for booting

set -e

ISO_ROOT="$1"
if [ -z "$ISO_ROOT" ]; then
    echo "Usage: $0 <iso-root-directory>"
    exit 1
fi

echo "🔧 Creating initramfs for JARVIS OS..."

# Create initramfs directory
INITRAMFS_DIR="/tmp/jarvis-initramfs"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,run,tmp,var/lib/jarvis}

# Copy essential binaries (we'll create a minimal set)
cat > "$INITRAMFS_DIR/init" << 'EOF'
#!/bin/sh

# JARVIS OS Init Script
echo "🤖 Starting JARVIS OS..."

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Create device nodes
mknod /dev/null c 1 3
mknod /dev/zero c 1 5
mknod /dev/console c 5 1

# Set up environment
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

echo "🎤 Initializing JARVIS AI Assistant..."

# Start JARVIS
if [ -x /usr/lib/jarvis/main.py ]; then
    echo "Starting JARVIS voice interface..."
    cd /usr/lib/jarvis
    python3 main.py
else
    echo "JARVIS not found, starting shell..."
    exec /bin/sh
fi
EOF

chmod +x "$INITRAMFS_DIR/init"

# Create a minimal busybox-style setup
cat > "$INITRAMFS_DIR/bin/sh" << 'EOF'
#!/bin/sh
# Minimal shell for initramfs
exec /bin/busybox sh "$@"
EOF

# Create essential directories and files
mkdir -p "$INITRAMFS_DIR/usr/lib/jarvis"
mkdir -p "$INITRAMFS_DIR/usr/bin"

# Copy JARVIS (we'll do this in the build process)
if [ -d "Project-JARVIS/jarvis" ]; then
    cp -r Project-JARVIS/jarvis/* "$INITRAMFS_DIR/usr/lib/jarvis/"
    chmod +x "$INITRAMFS_DIR/usr/lib/jarvis/main.py"
fi

# Create a simple busybox binary (placeholder)
cat > "$INITRAMFS_DIR/bin/busybox" << 'EOF'
#!/bin/sh
# Placeholder busybox - in real implementation, you'd copy the actual busybox binary
case "$1" in
    sh) exec /bin/sh ;;
    mount) echo "mount: placeholder" ;;
    *) echo "busybox: applet not found" ;;
esac
EOF

chmod +x "$INITRAMFS_DIR/bin/busybox"

# Create the initramfs archive
cd "$INITRAMFS_DIR"
find . | cpio -o -H newc | gzip > "$ISO_ROOT/initramfs.img"

echo "✅ Initramfs created: $ISO_ROOT/initramfs.img"

# Cleanup
rm -rf "$INITRAMFS_DIR"




