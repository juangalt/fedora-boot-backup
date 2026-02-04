#!/bin/bash
# restore-boot.sh - Restore boot partitions from backup to a new USB
# Run from Fedora Live USB (or any Linux live environment)
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; cleanup; exit "${2:-1}"; }
step() { echo -e "\n${CYAN}${BOLD}==> $1${NC}"; }

# Cleanup function for error handling
CRYPTROOT_OPEN=false
FEDORA_MOUNTED=false
EFI_MOUNTED=false
BOOT_MOUNTED=false
VENTOY_MOUNTED=false

cleanup() {
    echo ""
    warn "Cleaning up..."

    [[ "$VENTOY_MOUNTED" == true ]] && umount /mnt/ventoy 2>/dev/null || true
    [[ "$BOOT_MOUNTED" == true ]] && umount /mnt/new-boot 2>/dev/null || true
    [[ "$EFI_MOUNTED" == true ]] && umount /mnt/new-efi 2>/dev/null || true
    [[ "$FEDORA_MOUNTED" == true ]] && umount /mnt/fedora 2>/dev/null || true
    [[ "$CRYPTROOT_OPEN" == true ]] && cryptsetup close cryptroot 2>/dev/null || true

    rmdir /mnt/ventoy /mnt/new-boot /mnt/new-efi /mnt/fedora 2>/dev/null || true
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1. Display Warning and Get Confirmation
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: Must run as root (use sudo)${NC}"
    exit 1
fi

cat << 'EOF'

╔══════════════════════════════════════════════════════════════════╗
║           FEDORA BOOT PARTITION RESTORE SCRIPT                   ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  This script will:                                               ║
║    1. Unlock your encrypted Fedora partition                     ║
║    2. Create EFI and boot partitions on target USB               ║
║    3. Restore boot files from backup                             ║
║    4. Update UUIDs in configuration files                        ║
║                                                                  ║
║  WARNING: This will OVERWRITE partitions on target USB!          ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝

EOF

read -p "Continue? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# -----------------------------------------------------------------------------
# 2. Install Required Tools
# -----------------------------------------------------------------------------

step "Checking required tools"

REQUIRED_TOOLS="cryptsetup parted rsync blkid findmnt"
MISSING=""

for tool in $REQUIRED_TOOLS; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING="$MISSING $tool"
    fi
done

if [[ -n "$MISSING" ]]; then
    info "Installing required tools:$MISSING"
    if command -v dnf &>/dev/null; then
        dnf install -y $MISSING
    elif command -v apt &>/dev/null; then
        apt update && apt install -y $MISSING
    else
        error "Cannot install tools - unknown package manager" 2
    fi
fi

info "All required tools available"

# -----------------------------------------------------------------------------
# 3. List Available Disks and Select Target
# -----------------------------------------------------------------------------

step "Select target USB device"

echo ""
echo "Available disks:"
echo "----------------"
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "^loop\|^NAME" | while read line; do
    echo "  $line"
done
echo ""

read -p "Enter target USB device name (e.g., sdb): " TARGET_DISK_NAME
TARGET_DISK="/dev/$TARGET_DISK_NAME"

# Validate device exists
if [[ ! -b "$TARGET_DISK" ]]; then
    error "$TARGET_DISK is not a valid block device" 3
fi

# Show device details for confirmation
echo ""
echo "Selected device: $TARGET_DISK"
echo ""
lsblk "$TARGET_DISK" -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
echo ""
read -p "Is this the correct device? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# -----------------------------------------------------------------------------
# 4. Detect Encrypted Partition and Unlock
# -----------------------------------------------------------------------------

step "Unlock encrypted Fedora partition"

LUKS_PARTS=$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null || true)

if [[ -z "$LUKS_PARTS" ]]; then
    error "No LUKS encrypted partitions found. Is the internal drive connected?" 4
fi

LUKS_COUNT=$(echo "$LUKS_PARTS" | wc -l)

if [[ "$LUKS_COUNT" -gt 1 ]]; then
    echo "Found multiple encrypted partitions:"
    echo "$LUKS_PARTS" | while read part; do
        echo "  $part"
    done
    echo ""
    read -p "Enter partition to unlock: " LUKS_PART
else
    LUKS_PART="$LUKS_PARTS"
    info "Found encrypted partition: $LUKS_PART"
fi

# Check if already unlocked
if [[ -e /dev/mapper/cryptroot ]]; then
    warn "cryptroot already open - using existing mapping"
    CRYPTROOT_OPEN=true
else
    info "Unlocking $LUKS_PART (enter your LUKS passphrase)..."
    cryptsetup open "$LUKS_PART" cryptroot
    CRYPTROOT_OPEN=true
fi

# -----------------------------------------------------------------------------
# 5. Mount Encrypted Partition and Locate Backup
# -----------------------------------------------------------------------------

step "Locate backup on encrypted partition"

mkdir -p /mnt/fedora
mount -o subvol=root /dev/mapper/cryptroot /mnt/fedora
FEDORA_MOUNTED=true

BACKUP_DIR="/mnt/fedora/root/boot-backup"

if [[ ! -d "$BACKUP_DIR" ]]; then
    error "Backup not found at $BACKUP_DIR\nRun backup-boot.sh on your working system first." 5
fi

info "Found backup at $BACKUP_DIR"
echo ""
echo "Backup metadata:"
echo "----------------"
cat "$BACKUP_DIR/metadata.txt" | grep -E "^[A-Z_]|Created:|KERNEL"
echo ""

# Load original UUIDs from metadata
eval "$(grep "^BOOT_UUID=" "$BACKUP_DIR/metadata.txt")"
eval "$(grep "^EFI_UUID=" "$BACKUP_DIR/metadata.txt")"

if [[ -z "${BOOT_UUID:-}" ]] || [[ -z "${EFI_UUID:-}" ]]; then
    error "Could not read UUIDs from metadata file" 5
fi

info "Original UUIDs loaded from backup"

# -----------------------------------------------------------------------------
# 6. Determine Partition Layout Mode
# -----------------------------------------------------------------------------

step "Detecting USB layout"

# Check if USB already has Ventoy (partition 1 is exfat with Ventoy label or large exfat)
PART1="${TARGET_DISK}1"
if [[ -e "$PART1" ]]; then
    PART1_INFO=$(blkid "$PART1" 2>/dev/null || echo "")
    if echo "$PART1_INFO" | grep -qiE "exfat.*ventoy|ventoy.*exfat|TYPE=\"exfat\""; then
        info "Detected existing Ventoy installation"
        echo "Will create partitions 3 and 4 in reserved space"
        MODE="ventoy"

        # Get end of partition 2
        PART2_END=$(parted -s "$TARGET_DISK" unit MiB print 2>/dev/null | grep "^ 2" | awk '{print $3}' | tr -d 'MiB')
        if [[ -z "$PART2_END" ]]; then
            error "Could not determine end of Ventoy partition 2" 6
        fi
        info "Ventoy partition 2 ends at ${PART2_END}MiB"
    else
        info "Partition 1 exists but is not Ventoy"
        echo "Will create minimal boot-only USB (overwrites entire disk)"
        MODE="minimal"
    fi
else
    info "Empty/unpartitioned USB detected"
    echo "Will create minimal boot-only USB"
    MODE="minimal"
fi

echo ""
read -p "Proceed with $MODE mode? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# -----------------------------------------------------------------------------
# 7. Create Partitions
# -----------------------------------------------------------------------------

step "Creating partitions on $TARGET_DISK"

if [[ "$MODE" == "ventoy" ]]; then
    # Check if partitions 3 and 4 already exist
    if [[ -e "${TARGET_DISK}3" ]] || [[ -e "${TARGET_DISK}4" ]]; then
        warn "Partitions 3 and/or 4 already exist - removing them"
        parted -s "$TARGET_DISK" rm 4 2>/dev/null || true
        parted -s "$TARGET_DISK" rm 3 2>/dev/null || true
        sleep 1
    fi

    # Calculate partition positions
    EFI_START="$PART2_END"
    EFI_END=$((EFI_START + 512))
    BOOT_START="$EFI_END"

    info "Creating EFI partition (${EFI_START}MiB - ${EFI_END}MiB)"
    parted -s "$TARGET_DISK" mkpart primary fat32 ${EFI_START}MiB ${EFI_END}MiB

    info "Creating boot partition (${BOOT_START}MiB - end)"
    parted -s "$TARGET_DISK" mkpart primary ext4 ${BOOT_START}MiB 100%

    info "Setting ESP flags on partition 3"
    parted -s "$TARGET_DISK" set 3 esp on
    parted -s "$TARGET_DISK" set 3 boot on

    EFI_PART="${TARGET_DISK}3"
    BOOT_PART="${TARGET_DISK}4"

else
    # Minimal mode - create new GPT with partitions 1 and 2
    warn "This will erase all data on $TARGET_DISK"
    read -p "Final confirmation - erase $TARGET_DISK? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi

    info "Creating GPT partition table"
    parted -s "$TARGET_DISK" mklabel gpt

    info "Creating EFI partition (1MiB - 513MiB)"
    parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$TARGET_DISK" set 1 esp on
    parted -s "$TARGET_DISK" set 1 boot on

    info "Creating boot partition (513MiB - 2049MiB)"
    parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 2049MiB

    EFI_PART="${TARGET_DISK}1"
    BOOT_PART="${TARGET_DISK}2"
fi

# Wait for kernel to recognize new partitions
info "Waiting for partitions to be recognized..."
sleep 2
partprobe "$TARGET_DISK"
sleep 1

# Verify partitions exist
if [[ ! -b "$EFI_PART" ]] || [[ ! -b "$BOOT_PART" ]]; then
    error "Partitions were not created successfully" 6
fi

# -----------------------------------------------------------------------------
# 8. Format Partitions
# -----------------------------------------------------------------------------

step "Formatting partitions"

info "Formatting $EFI_PART as FAT32"
mkfs.vfat -F 32 "$EFI_PART"

info "Formatting $BOOT_PART as ext4"
mkfs.ext4 -L FEDORA_BOOT "$BOOT_PART"

# -----------------------------------------------------------------------------
# 9. Get New UUIDs
# -----------------------------------------------------------------------------

step "Recording new UUIDs"

# Force re-read of partition table
sleep 1

NEW_EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
NEW_BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")

echo ""
echo "UUID Mapping:"
echo "  EFI:  $EFI_UUID  ->  $NEW_EFI_UUID"
echo "  Boot: $BOOT_UUID  ->  $NEW_BOOT_UUID"
echo ""

# -----------------------------------------------------------------------------
# 10. Mount and Restore Files
# -----------------------------------------------------------------------------

step "Restoring boot files"

mkdir -p /mnt/new-efi /mnt/new-boot

mount "$EFI_PART" /mnt/new-efi
EFI_MOUNTED=true

mount "$BOOT_PART" /mnt/new-boot
BOOT_MOUNTED=true

info "Restoring /boot/efi files..."
rsync -av "$BACKUP_DIR/efi/" /mnt/new-efi/ || error "Failed to restore EFI files" 7

info "Restoring /boot files..."
rsync -av "$BACKUP_DIR/boot/" /mnt/new-boot/ || error "Failed to restore boot files" 7

# -----------------------------------------------------------------------------
# 11. Update UUIDs in Configuration Files
# -----------------------------------------------------------------------------

step "Updating UUIDs in configuration files"

# Update /etc/fstab on encrypted root
FSTAB="/mnt/fedora/etc/fstab"
if [[ -f "$FSTAB" ]]; then
    info "Updating $FSTAB"
    sed -i "s/$EFI_UUID/$NEW_EFI_UUID/g" "$FSTAB"
    sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" "$FSTAB"
    echo "  Updated fstab entries:"
    grep -E "/boot" "$FSTAB" | sed 's/^/    /'
else
    warn "fstab not found at $FSTAB"
fi

# Update GRUB config if it contains boot UUID
GRUB_CFG="/mnt/new-boot/grub2/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
    if grep -q "$BOOT_UUID" "$GRUB_CFG"; then
        info "Updating $GRUB_CFG"
        sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" "$GRUB_CFG"
    else
        info "grub.cfg does not contain boot UUID - no changes needed"
    fi
fi

# Update BLS (Boot Loader Spec) entries
BLS_DIR="/mnt/new-boot/loader/entries"
if [[ -d "$BLS_DIR" ]]; then
    BLS_UPDATED=0
    for entry in "$BLS_DIR"/*.conf; do
        if [[ -f "$entry" ]]; then
            if grep -q "$BOOT_UUID" "$entry"; then
                sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" "$entry"
                ((BLS_UPDATED++))
            fi
        fi
    done
    if [[ $BLS_UPDATED -gt 0 ]]; then
        info "Updated $BLS_UPDATED BLS entry file(s)"
    else
        info "BLS entries do not contain boot UUID - no changes needed"
    fi
fi

# -----------------------------------------------------------------------------
# 12. Restore Ventoy Configuration (if Ventoy mode)
# -----------------------------------------------------------------------------

if [[ "$MODE" == "ventoy" ]] && [[ -d "$BACKUP_DIR/ventoy" ]]; then
    step "Restoring Ventoy configuration"

    VENTOY_PART="${TARGET_DISK}1"
    mkdir -p /mnt/ventoy

    if mount "$VENTOY_PART" /mnt/ventoy 2>/dev/null; then
        VENTOY_MOUNTED=true
        mkdir -p /mnt/ventoy/ventoy

        # Copy and update ventoy_grub.cfg with new EFI UUID
        if [[ -f "$BACKUP_DIR/ventoy/ventoy_grub.cfg" ]]; then
            info "Updating and copying ventoy_grub.cfg"
            sed "s/$EFI_UUID/$NEW_EFI_UUID/g" \
                "$BACKUP_DIR/ventoy/ventoy_grub.cfg" > /mnt/ventoy/ventoy/ventoy_grub.cfg
            echo "  Updated EFI UUID in ventoy_grub.cfg"
        fi

        # Copy ventoy.json as-is (no UUIDs in it)
        if [[ -f "$BACKUP_DIR/ventoy/ventoy.json" ]]; then
            info "Copying ventoy.json"
            cp "$BACKUP_DIR/ventoy/ventoy.json" /mnt/ventoy/ventoy/
        fi

        umount /mnt/ventoy
        VENTOY_MOUNTED=false
    else
        warn "Could not mount Ventoy partition - skipping Ventoy config restore"
    fi
fi

# -----------------------------------------------------------------------------
# 13. Cleanup and Summary
# -----------------------------------------------------------------------------

step "Finalizing"

# Unmount in reverse order
umount /mnt/new-boot
BOOT_MOUNTED=false

umount /mnt/new-efi
EFI_MOUNTED=false

umount /mnt/fedora
FEDORA_MOUNTED=false

cryptsetup close cryptroot
CRYPTROOT_OPEN=false

rmdir /mnt/new-efi /mnt/new-boot /mnt/fedora 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo -e "  ${GREEN}${BOLD}RESTORE COMPLETE${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Target device: $TARGET_DISK"
echo "  Mode:          $MODE"
echo ""
echo "  New partition UUIDs:"
echo "    EFI partition ($EFI_PART):  $NEW_EFI_UUID"
echo "    Boot partition ($BOOT_PART): $NEW_BOOT_UUID"
echo ""
echo "  Next steps:"
if [[ "$MODE" == "ventoy" ]]; then
    echo "    1. Remove this live USB"
    echo "    2. Insert the restored USB and reboot"
    echo "    3. Select USB in BIOS boot menu"
    echo "    4. Ventoy should auto-boot to Fedora"
else
    echo "    1. Remove this live USB"
    echo "    2. Insert the restored USB and reboot"
    echo "    3. Select USB in BIOS boot menu"
    echo "    4. GRUB will load directly (no Ventoy menu)"
fi
echo ""

# Disable the trap since we cleaned up successfully
trap - EXIT
