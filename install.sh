#!/bin/bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(uname -r)"
DRIVER="$BASE/driver/snd-soc-pcm5102a.ko"
DEST="/lib/modules/$KERNEL/updates/snd-soc-pcm5102a.ko"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run this installer as root."
    exit 1
fi

if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: This package is for aarch64 Rock Pi S systems."
    exit 1
fi

if [ ! -f "$DRIVER" ]; then
    echo "ERROR: Modified PCM5102A driver is missing."
    exit 1
fi

DRIVER_KERNEL="$(modinfo -F vermagic "$DRIVER" | awk '{print $1}')"
if [ "$DRIVER_KERNEL" != "$KERNEL" ]; then
    echo "ERROR: Kernel mismatch."
    echo "Running kernel: $KERNEL"
    echo "Driver kernel:  $DRIVER_KERNEL"
    echo "Install the matching kernel before proceeding."
    exit 1
fi

if ! ldconfig -p | grep -q 'libasound.so.2'; then
    echo "ERROR: ALSA runtime library libasound.so.2 is missing."
    echo "Install the appropriate libasound runtime package first."
    exit 1
fi

if ldd "$BASE/crossover/crossoverd_auto" | grep -q 'not found'; then
    echo "ERROR: The crossover executable has missing libraries."
    ldd "$BASE/crossover/crossoverd_auto"
    exit 1
fi

echo "Installing Rock Pi S audio system for kernel $KERNEL"

# Preserve any existing driver before replacing it.
mkdir -p "$(dirname "$DEST")"
if [ -f "$DEST" ]; then
    BACKUP="/root/snd-soc-pcm5102a.ko.before-rockpi-audio"
    if ! cmp -s "$DEST" "$DRIVER"; then
        if [ ! -f "$BACKUP" ]; then
            cp -a "$DEST" "$BACKUP"
            echo "Previous driver backed up to $BACKUP"
        else
            echo "Existing backup retained at $BACKUP"
        fi
    fi
fi

# Install application and source.
mkdir -p /root/crossover
install -m 0644 "$BASE/crossover/crossover.c" /root/crossover/
install -m 0644 "$BASE/crossover/crossoverd_auto.c" /root/crossover/
install -m 0755 "$BASE/crossover/crossoverd_auto" /root/crossover/
install -m 0755 "$BASE/crossover/audio-control.sh" /root/crossover/

# Create default configuration files without overwriting existing settings.
if [ ! -f /root/crossover/crossover_freq.conf ]; then
    install -m 0644 "$BASE/crossover/crossover_freq.conf" /root/crossover/
fi

if [ ! -f /root/crossover/tweeter_gain.conf ]; then
    install -m 0644 "$BASE/crossover/tweeter_gain.conf" /root/crossover/
fi

# Install the matching kernel module.
install -m 0644 "$DRIVER" "$DEST"
depmod -a "$KERNEL"

# Install systemd service.
install -m 0644 "$BASE/systemd/crossoverd.service" \
    /etc/systemd/system/crossoverd.service

systemctl daemon-reload
systemctl enable crossoverd.service

# Update initramfs if this system uses one.
if command -v update-initramfs >/dev/null 2>&1 &&
   [ -e "/boot/initrd.img-$KERNEL" ]; then
    update-initramfs -u -k "$KERNEL"
fi

echo
echo "Installation files are in place."
echo "The running driver has NOT been unloaded or replaced."
echo "The crossover service has been enabled but NOT started."
echo
echo "Reboot to load the modified driver and start the crossover."
