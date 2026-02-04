#!/bin/bash
# backup-boot.sh - Backup boot partitions to encrypted root
# Run this periodically (especially after kernel updates) to maintain a current backup
set -euo pipefail

BACKUP_DIR="/root/boot-backup"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit "${2:-1}"; }

# -----------------------------------------------------------------------------
# 1. Validate Environment
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    error "Must run as root (use sudo)" 1
fi

if ! mountpoint -q /boot; then
    error "/boot is not a mounted partition. Is USB connected?" 2
fi

if ! mountpoint -q /boot/efi; then
    error "/boot/efi is not a mounted partition. Is USB connected?" 3
fi

# -----------------------------------------------------------------------------
# 2. Identify Source Partitions
# -----------------------------------------------------------------------------

info "Identifying boot partitions..."

BOOT_DEV=$(findmnt -n -o SOURCE /boot)
EFI_DEV=$(findmnt -n -o SOURCE /boot/efi)

BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV")
EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV")

# Get the parent disk (USB device)
USB_DISK=$(lsblk -no PKNAME "$BOOT_DEV" | head -1)

if [[ -z "$USB_DISK" ]]; then
    error "Could not determine parent disk for $BOOT_DEV" 4
fi

info "Boot partition: $BOOT_DEV (UUID: $BOOT_UUID)"
info "EFI partition:  $EFI_DEV (UUID: $EFI_UUID)"
info "USB disk:       /dev/$USB_DISK"

# -----------------------------------------------------------------------------
# 3. Create Backup Directory Structure
# -----------------------------------------------------------------------------

info "Creating backup directory..."

if [[ -d "$BACKUP_DIR" ]]; then
    OLD_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    warn "Removing previous backup ($OLD_SIZE)"
    rm -rf "$BACKUP_DIR"
fi

mkdir -p "$BACKUP_DIR"/{boot,efi,ventoy}

# -----------------------------------------------------------------------------
# 4. Copy Boot Files
# -----------------------------------------------------------------------------

info "Copying /boot files..."
rsync -av --exclude='efi' /boot/ "$BACKUP_DIR/boot/" || error "Failed to copy /boot" 4

info "Copying /boot/efi files..."
rsync -av /boot/efi/ "$BACKUP_DIR/efi/" || error "Failed to copy /boot/efi" 4

# -----------------------------------------------------------------------------
# 5. Backup Ventoy Configuration
# -----------------------------------------------------------------------------

# Handle NVMe vs regular device naming (nvme0n1p1 vs sda1)
if [[ "$USB_DISK" == nvme* ]]; then
    VENTOY_PART="/dev/${USB_DISK}p1"
else
    VENTOY_PART="/dev/${USB_DISK}1"
fi

if [[ -b "$VENTOY_PART" ]]; then
    # Check if it's a Ventoy partition (exfat or has Ventoy label)
    if blkid "$VENTOY_PART" | grep -qiE "exfat|ventoy"; then
        info "Backing up Ventoy configuration..."

        VENTOY_MNT=$(mktemp -d)

        if mount "$VENTOY_PART" "$VENTOY_MNT" 2>/dev/null; then
            if [[ -d "$VENTOY_MNT/ventoy" ]]; then
                cp "$VENTOY_MNT/ventoy/ventoy.json" "$BACKUP_DIR/ventoy/" 2>/dev/null && \
                    info "  - ventoy.json copied" || warn "  - ventoy.json not found"
                cp "$VENTOY_MNT/ventoy/ventoy_grub.cfg" "$BACKUP_DIR/ventoy/" 2>/dev/null && \
                    info "  - ventoy_grub.cfg copied" || warn "  - ventoy_grub.cfg not found"
            else
                warn "No /ventoy directory found on Ventoy partition"
            fi
            umount "$VENTOY_MNT"
        else
            warn "Could not mount Ventoy partition - skipping Ventoy config backup"
        fi

        rmdir "$VENTOY_MNT" 2>/dev/null || true
    else
        info "Partition 1 is not a Ventoy partition - skipping Ventoy config"
    fi
else
    warn "Could not find Ventoy partition at $VENTOY_PART"
fi

# -----------------------------------------------------------------------------
# 6. Save Metadata
# -----------------------------------------------------------------------------

info "Saving metadata..."

# Get LUKS UUID if present
LUKS_UUID=$(blkid -t TYPE=crypto_LUKS -o value -s UUID 2>/dev/null | head -1 || echo "not found")

cat > "$BACKUP_DIR/metadata.txt" << EOF
# Boot Backup Metadata
# Created: $(date)
# Hostname: $(hostname)

[Original UUIDs]
BOOT_UUID=$BOOT_UUID
EFI_UUID=$EFI_UUID

[Source Devices]
BOOT_DEV=$BOOT_DEV
EFI_DEV=$EFI_DEV
USB_DISK=/dev/$USB_DISK

[Partition Sizes]
BOOT_SIZE=$(lsblk -bno SIZE "$BOOT_DEV")
EFI_SIZE=$(lsblk -bno SIZE "$EFI_DEV")

[LUKS Info]
LUKS_UUID=$LUKS_UUID

[Backup Info]
BACKUP_DATE=$(date +%Y-%m-%d_%H:%M:%S)
KERNEL_VERSION=$(uname -r)
EOF

# -----------------------------------------------------------------------------
# 7. Verification & Summary
# -----------------------------------------------------------------------------

BOOT_SIZE=$(du -sh "$BACKUP_DIR/boot" | cut -f1)
EFI_SIZE=$(du -sh "$BACKUP_DIR/efi" | cut -f1)
BOOT_FILES=$(find "$BACKUP_DIR/boot" -type f | wc -l)
EFI_FILES=$(find "$BACKUP_DIR/efi" -type f | wc -l)

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "  ${GREEN}BACKUP COMPLETE${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Location:    $BACKUP_DIR"
echo "  Boot files:  $BOOT_FILES files ($BOOT_SIZE)"
echo "  EFI files:   $EFI_FILES files ($EFI_SIZE)"
echo ""
echo "  Original UUIDs (needed for restore):"
echo "    /boot/efi: $EFI_UUID"
echo "    /boot:     $BOOT_UUID"
echo ""
echo "  Run this script again after kernel updates to keep backup current."
echo ""
