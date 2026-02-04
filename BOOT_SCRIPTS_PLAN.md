# Boot Backup & Restore Scripts Plan

This document details the implementation plan for two scripts that enable boot partition backup and recovery.

---

## Overview

| Script | Purpose | Run From | Complexity |
|--------|---------|----------|------------|
| `backup-boot.sh` | Backup /boot and /boot/efi to encrypted partition | Working Fedora | Low |
| `restore-boot.sh` | Restore boot files to a new USB | Fedora Live USB | Medium |

---

## Script 1: backup-boot.sh

### Purpose
Creates a complete backup of boot partitions and metadata, stored on the encrypted root partition so it survives USB loss.

### Prerequisites
- Running from installed Fedora (not live)
- USB boot partitions mounted at /boot and /boot/efi
- Root privileges

### Backup Location
```
/root/boot-backup/
├── boot/                    # Mirror of /boot
│   ├── grub2/
│   ├── loader/
│   ├── efi/                 # Symlink (skip)
│   ├── vmlinuz-*
│   ├── initramfs-*
│   └── ...
├── efi/                     # Mirror of /boot/efi
│   └── EFI/
│       ├── BOOT/
│       └── fedora/
├── ventoy/                  # Ventoy config files
│   ├── ventoy.json
│   └── ventoy_grub.cfg
└── metadata.txt             # UUIDs and partition info
```

### Implementation Steps

#### 1. Validate Environment
```bash
# Check running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root"
    exit 1
fi

# Check /boot is mounted and is a separate partition
if ! mountpoint -q /boot; then
    echo "Error: /boot is not a mounted partition"
    exit 1
fi

# Check /boot/efi is mounted
if ! mountpoint -q /boot/efi; then
    echo "Error: /boot/efi is not a mounted partition"
    exit 1
fi
```

#### 2. Identify Source Partitions
```bash
# Get device names from mount points
BOOT_DEV=$(findmnt -n -o SOURCE /boot)      # e.g., /dev/sda4
EFI_DEV=$(findmnt -n -o SOURCE /boot/efi)   # e.g., /dev/sda3

# Get UUIDs
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV")
EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV")

# Get the parent disk (USB device)
USB_DISK=$(lsblk -no PKNAME "$BOOT_DEV" | head -1)  # e.g., sda
```

#### 3. Create Backup Directory Structure
```bash
BACKUP_DIR="/root/boot-backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Remove old backup (or keep versioned backups)
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"/{boot,efi,ventoy}
```

#### 4. Copy Boot Files
```bash
# Copy /boot (excluding efi symlink if present)
rsync -av --exclude='efi' /boot/ "$BACKUP_DIR/boot/"

# Copy /boot/efi
rsync -av /boot/efi/ "$BACKUP_DIR/efi/"
```

#### 5. Backup Ventoy Configuration
```bash
# Find Ventoy partition (usually partition 1 on same USB)
VENTOY_PART="/dev/${USB_DISK}1"

# Create temp mount point
VENTOY_MNT=$(mktemp -d)
mount "$VENTOY_PART" "$VENTOY_MNT" 2>/dev/null

if [[ -d "$VENTOY_MNT/ventoy" ]]; then
    cp "$VENTOY_MNT/ventoy/ventoy.json" "$BACKUP_DIR/ventoy/" 2>/dev/null
    cp "$VENTOY_MNT/ventoy/ventoy_grub.cfg" "$BACKUP_DIR/ventoy/" 2>/dev/null
fi

umount "$VENTOY_MNT" 2>/dev/null
rmdir "$VENTOY_MNT"
```

#### 6. Save Metadata
```bash
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
LUKS_UUID=$(blkid -t TYPE=crypto_LUKS -o value -s UUID | head -1)

[Backup Contents]
BOOT_FILES=$(find "$BACKUP_DIR/boot" -type f | wc -l)
EFI_FILES=$(find "$BACKUP_DIR/efi" -type f | wc -l)
EOF
```

#### 7. Verification & Summary
```bash
echo "Backup complete!"
echo "Location: $BACKUP_DIR"
echo "Boot files: $(du -sh "$BACKUP_DIR/boot" | cut -f1)"
echo "EFI files: $(du -sh "$BACKUP_DIR/efi" | cut -f1)"
echo ""
echo "Original UUIDs (for reference):"
echo "  /boot/efi: $EFI_UUID"
echo "  /boot:     $BOOT_UUID"
```

### Full Script Outline

```bash
#!/bin/bash
# backup-boot.sh - Backup boot partitions to encrypted root
set -euo pipefail

BACKUP_DIR="/root/boot-backup"

# 1. Validate environment (root, mounts)
# 2. Identify source partitions and UUIDs
# 3. Create backup directory
# 4. Copy /boot and /boot/efi with rsync
# 5. Backup Ventoy config if accessible
# 6. Save metadata file
# 7. Print summary
```

### Exit Codes
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Not running as root |
| 2 | /boot not mounted |
| 3 | /boot/efi not mounted |
| 4 | Rsync failed |

---

## Script 2: restore-boot.sh

### Purpose
Formats a new USB with boot partitions and restores backup, updating UUIDs throughout.

### Prerequisites
- Running from Fedora Live USB (or any Linux live environment)
- Target USB drive inserted (will be PARTIALLY MODIFIED)
- Backup exists on encrypted partition
- Root privileges

### Important Design Decision: No Ventoy Installation

The restore script will **NOT** install Ventoy. Reasons:
1. Ventoy installation is complex and version-dependent
2. User may want different Ventoy settings
3. Keeps the script simpler and more reliable
4. User can install Ventoy first, then run restore

The script assumes the USB either:
- Already has Ventoy installed with reserved space, OR
- Is being set up as a minimal boot-only USB (Option C from README)

### Implementation Steps

#### 1. Display Warning and Get Confirmation
```bash
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║           FEDORA BOOT PARTITION RESTORE SCRIPT               ║
╠══════════════════════════════════════════════════════════════╣
║  This script will:                                           ║
║  1. Unlock your encrypted Fedora partition                   ║
║  2. Create EFI and boot partitions on target USB             ║
║  3. Restore boot files from backup                           ║
║  4. Update UUIDs in configuration files                      ║
║                                                              ║
║  WARNING: This will OVERWRITE partitions on target USB!      ║
╚══════════════════════════════════════════════════════════════╝
EOF

read -p "Continue? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0
```

#### 2. Install Required Tools
```bash
# Check for and install required tools
REQUIRED_TOOLS="cryptsetup parted rsync"
MISSING=""

for tool in $REQUIRED_TOOLS; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING="$MISSING $tool"
    fi
done

if [[ -n "$MISSING" ]]; then
    echo "Installing required tools:$MISSING"
    dnf install -y $MISSING || apt install -y $MISSING
fi
```

#### 3. List Available Disks and Select Target
```bash
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "^loop"
echo ""

read -p "Enter target USB device (e.g., sdb): " TARGET_DISK
TARGET_DISK="/dev/$TARGET_DISK"

# Validate it's a removable device
if [[ ! -b "$TARGET_DISK" ]]; then
    echo "Error: $TARGET_DISK is not a valid block device"
    exit 1
fi

# Extra safety: confirm device
echo ""
echo "Selected device: $TARGET_DISK"
lsblk "$TARGET_DISK"
echo ""
read -p "Is this correct? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0
```

#### 4. Detect Encrypted Partition and Unlock
```bash
echo "Detecting encrypted partitions..."
LUKS_PARTS=$(blkid -t TYPE=crypto_LUKS -o device)

if [[ -z "$LUKS_PARTS" ]]; then
    echo "Error: No LUKS encrypted partitions found"
    exit 1
fi

echo "Found encrypted partitions:"
echo "$LUKS_PARTS"
echo ""

# If multiple, let user choose; otherwise use the one found
if [[ $(echo "$LUKS_PARTS" | wc -l) -gt 1 ]]; then
    read -p "Enter partition to unlock: " LUKS_PART
else
    LUKS_PART="$LUKS_PARTS"
fi

# Unlock
echo "Unlocking $LUKS_PART..."
cryptsetup open "$LUKS_PART" cryptroot
```

#### 5. Mount Encrypted Partition and Locate Backup
```bash
mkdir -p /mnt/fedora
mount -o subvol=root /dev/mapper/cryptroot /mnt/fedora

BACKUP_DIR="/mnt/fedora/root/boot-backup"

if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "Error: Backup not found at $BACKUP_DIR"
    echo "Run backup-boot.sh on your working system first"
    umount /mnt/fedora
    cryptsetup close cryptroot
    exit 1
fi

echo "Found backup at $BACKUP_DIR"
cat "$BACKUP_DIR/metadata.txt"
```

#### 6. Determine Partition Layout Mode
```bash
# Check if USB already has Ventoy
if [[ -e "${TARGET_DISK}1" ]] && blkid "${TARGET_DISK}1" | grep -q "exfat\|VTOY"; then
    echo ""
    echo "Detected existing Ventoy installation on $TARGET_DISK"
    echo "Will create partitions 3 and 4 in reserved space"
    MODE="ventoy"

    # Get end of partition 2 for our start point
    PART2_END=$(parted -s "$TARGET_DISK" unit MiB print | grep "^ 2" | awk '{print $3}' | tr -d 'MiB')
else
    echo ""
    echo "No Ventoy detected. Creating minimal boot-only USB."
    MODE="minimal"
fi
```

#### 7. Create Partitions

**For Ventoy mode (partitions 3 and 4):**
```bash
if [[ "$MODE" == "ventoy" ]]; then
    # Calculate partition positions
    # Partition 3: 512MB FAT32 for EFI
    # Partition 4: Rest of space (up to 1.5GB) for /boot

    EFI_START="$PART2_END"
    EFI_END=$((EFI_START + 512))
    BOOT_START="$EFI_END"

    echo "Creating partitions..."
    parted -s "$TARGET_DISK" mkpart primary fat32 ${EFI_START}MiB ${EFI_END}MiB
    parted -s "$TARGET_DISK" mkpart primary ext4 ${BOOT_START}MiB 100%
    parted -s "$TARGET_DISK" set 3 esp on
    parted -s "$TARGET_DISK" set 3 boot on

    EFI_PART="${TARGET_DISK}3"
    BOOT_PART="${TARGET_DISK}4"
fi
```

**For minimal mode (partitions 1 and 2):**
```bash
if [[ "$MODE" == "minimal" ]]; then
    echo "Creating GPT partition table..."
    parted -s "$TARGET_DISK" mklabel gpt

    # Partition 1: 512MB FAT32 for EFI
    parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$TARGET_DISK" set 1 esp on
    parted -s "$TARGET_DISK" set 1 boot on

    # Partition 2: 1.5GB ext4 for /boot
    parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 2049MiB

    EFI_PART="${TARGET_DISK}1"
    BOOT_PART="${TARGET_DISK}2"
fi
```

#### 8. Format Partitions
```bash
echo "Formatting partitions..."

# Wait for kernel to recognize new partitions
sleep 2
partprobe "$TARGET_DISK"
sleep 1

# Format EFI partition
mkfs.vfat -F 32 "$EFI_PART"

# Format boot partition
mkfs.ext4 -L FEDORA_BOOT "$BOOT_PART"
```

#### 9. Get New UUIDs
```bash
# Get new UUIDs
NEW_EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
NEW_BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")

# Get original UUIDs from metadata
source <(grep "^[A-Z_]*UUID=" "$BACKUP_DIR/metadata.txt")
# Now we have: $BOOT_UUID, $EFI_UUID, $LUKS_UUID (original values)

echo ""
echo "UUID Mapping:"
echo "  EFI:  $EFI_UUID -> $NEW_EFI_UUID"
echo "  Boot: $BOOT_UUID -> $NEW_BOOT_UUID"
```

#### 10. Mount and Restore Files
```bash
mkdir -p /mnt/new-efi /mnt/new-boot

mount "$EFI_PART" /mnt/new-efi
mount "$BOOT_PART" /mnt/new-boot

echo "Restoring boot files..."
rsync -av "$BACKUP_DIR/efi/" /mnt/new-efi/
rsync -av "$BACKUP_DIR/boot/" /mnt/new-boot/
```

#### 11. Update UUIDs in Configuration Files

**Files that need UUID updates:**

| File | UUIDs Used |
|------|------------|
| `/mnt/fedora/etc/fstab` | BOOT_UUID, EFI_UUID |
| `/mnt/new-boot/grub2/grub.cfg` | BOOT_UUID (possibly) |
| `/mnt/new-boot/loader/entries/*.conf` | BOOT_UUID (BLS entries) |

```bash
echo "Updating UUIDs in configuration files..."

# Update /etc/fstab on encrypted root
sed -i "s/$EFI_UUID/$NEW_EFI_UUID/g" /mnt/fedora/etc/fstab
sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" /mnt/fedora/etc/fstab

# Update GRUB config if it contains boot UUID
if [[ -f /mnt/new-boot/grub2/grub.cfg ]]; then
    sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" /mnt/new-boot/grub2/grub.cfg
fi

# Update BLS entries
for entry in /mnt/new-boot/loader/entries/*.conf; do
    if [[ -f "$entry" ]]; then
        sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" "$entry"
    fi
done
```

#### 12. Restore Ventoy Configuration (if Ventoy mode)
```bash
if [[ "$MODE" == "ventoy" ]] && [[ -d "$BACKUP_DIR/ventoy" ]]; then
    echo "Restoring Ventoy configuration..."

    # Mount Ventoy partition
    VENTOY_PART="${TARGET_DISK}1"
    mkdir -p /mnt/ventoy
    mount "$VENTOY_PART" /mnt/ventoy

    mkdir -p /mnt/ventoy/ventoy

    # Copy and update ventoy_grub.cfg with new EFI UUID
    if [[ -f "$BACKUP_DIR/ventoy/ventoy_grub.cfg" ]]; then
        sed "s/$EFI_UUID/$NEW_EFI_UUID/g" \
            "$BACKUP_DIR/ventoy/ventoy_grub.cfg" > /mnt/ventoy/ventoy/ventoy_grub.cfg
    fi

    # Copy ventoy.json as-is (no UUIDs in it)
    if [[ -f "$BACKUP_DIR/ventoy/ventoy.json" ]]; then
        cp "$BACKUP_DIR/ventoy/ventoy.json" /mnt/ventoy/ventoy/
    fi

    umount /mnt/ventoy
fi
```

#### 13. Cleanup and Summary
```bash
echo "Cleaning up..."

# Unmount everything
umount /mnt/new-efi
umount /mnt/new-boot
umount /mnt/fedora
cryptsetup close cryptroot

rmdir /mnt/new-efi /mnt/new-boot /mnt/fedora 2>/dev/null

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  RESTORE COMPLETE"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "New partition UUIDs:"
echo "  EFI partition:  $NEW_EFI_UUID"
echo "  Boot partition: $NEW_BOOT_UUID"
echo ""
echo "Next steps:"
if [[ "$MODE" == "ventoy" ]]; then
    echo "  1. Remove USB and reboot"
    echo "  2. Select USB in BIOS boot menu"
    echo "  3. Ventoy should auto-boot to Fedora"
else
    echo "  1. Remove USB and reboot"
    echo "  2. Select USB in BIOS boot menu"
    echo "  3. GRUB will load directly (no Ventoy)"
fi
echo ""
```

### Full Script Outline

```bash
#!/bin/bash
# restore-boot.sh - Restore boot partitions from backup
set -euo pipefail

# 1.  Display warning, get confirmation
# 2.  Install required tools if missing
# 3.  List disks, select target USB
# 4.  Detect and unlock encrypted partition
# 5.  Mount encrypted partition, locate backup
# 6.  Determine mode (Ventoy or minimal)
# 7.  Create partitions (3+4 for Ventoy, 1+2 for minimal)
# 8.  Format partitions (FAT32 EFI, ext4 boot)
# 9.  Get new UUIDs, load original UUIDs from metadata
# 10. Mount new partitions, rsync backup files
# 11. Update UUIDs in fstab, grub.cfg, BLS entries
# 12. Restore Ventoy config with updated UUID (if Ventoy mode)
# 13. Unmount, cleanup, print summary
```

### Exit Codes
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Not running as root |
| 2 | User cancelled |
| 3 | Invalid target device |
| 4 | No LUKS partitions found |
| 5 | Backup not found |
| 6 | Partition creation failed |
| 7 | File restore failed |

---

## UUID Update Matrix

| File | Location | UUIDs to Update |
|------|----------|-----------------|
| fstab | /mnt/fedora/etc/fstab | EFI_UUID, BOOT_UUID |
| grub.cfg | /mnt/new-boot/grub2/grub.cfg | BOOT_UUID |
| BLS entries | /mnt/new-boot/loader/entries/*.conf | BOOT_UUID |
| ventoy_grub.cfg | /mnt/ventoy/ventoy/ventoy_grub.cfg | EFI_UUID |

**Note:** LUKS_UUID does NOT change (it's on the internal drive, not the USB).

---

## Testing Checklist

### backup-boot.sh
- [ ] Fails gracefully when not root
- [ ] Detects unmounted /boot or /boot/efi
- [ ] Creates complete backup structure
- [ ] Captures correct UUIDs in metadata
- [ ] Handles missing Ventoy config gracefully

### restore-boot.sh
- [ ] Warns user and requires confirmation
- [ ] Correctly identifies Ventoy vs minimal mode
- [ ] Creates properly aligned partitions
- [ ] Sets ESP flags correctly
- [ ] Updates all UUID references
- [ ] Handles multiple LUKS partitions
- [ ] Cleans up on error

---

## Future Enhancements (Not in Initial Version)

1. **Backup versioning** - Keep last N backups
2. **Compression** - Compress backup with tar/gzip
3. **Ventoy auto-install** - Download and install Ventoy automatically
4. **Verification** - Boot test in VM before finishing
5. **Encryption** - Encrypt the backup itself (defense in depth)

---

*Plan created: 2026-02-04*
