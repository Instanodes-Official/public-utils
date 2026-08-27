#!/bin/bash

set -e

DISK="/dev/sdb"
PART="/dev/sdb1"
MOUNT_POINT="/data"

echo "========================================="
echo "Preparing $DISK for $MOUNT_POINT"
echo "ALL DATA ON $DISK WILL BE DELETED"
echo "========================================="

# Make sure disk exists
if [ ! -b "$DISK" ]; then
    echo "ERROR: $DISK does not exist."
    exit 1
fi

# Unmount existing filesystem
echo "[1/7] Unmounting existing filesystem..."
umount "$PART" 2>/dev/null || true
umount /mnt/disk1 2>/dev/null || true

# Remove old fstab entry
echo "[2/7] Removing old /mnt/disk1 fstab entry..."
sed -i '\#/mnt/disk1#d' /etc/fstab

# Wipe existing filesystem signatures
echo "[3/7] Wiping $DISK..."
wipefs -a "$DISK"

# Create GPT partition table
echo "[4/7] Creating GPT partition table..."
parted -s "$DISK" mklabel gpt

# Create one partition using entire disk
echo "[5/7] Creating partition..."
parted -s "$DISK" mkpart primary ext4 0% 100%

# Tell kernel about partition table
partprobe "$DISK"

# Wait for device
sleep 2

# Format
echo "[6/7] Formatting $PART as ext4..."
mkfs.ext4 -F "$PART"

# Create mount point
mkdir -p "$MOUNT_POINT"

# Get UUID
UUID=$(blkid -s UUID -o value "$PART")

if [ -z "$UUID" ]; then
    echo "ERROR: Could not determine UUID."
    exit 1
fi

# Remove existing /data fstab entry
sed -i '\#/data#d' /etc/fstab

# Add persistent mount
echo "UUID=$UUID $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab

# Mount
echo "[7/7] Mounting $MOUNT_POINT..."
mount -a

echo
echo "========================================="
echo "SUCCESS"
echo "========================================="

echo
echo "Disk:"
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINTS "$DISK"

echo
echo "Filesystem:"
df -h "$MOUNT_POINT"

echo
echo "fstab entry:"
grep "$MOUNT_POINT" /etc/fstab
