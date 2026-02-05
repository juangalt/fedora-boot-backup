#!/bin/bash
#===============================================================================
# restore-boot.sh - Restore Fedora boot partitions from backup to a new USB
#===============================================================================
#
# PURPOSE:
#   This script restores your Fedora boot partitions to a NEW USB drive when
#   your original boot USB is lost, stolen, or damaged. It reads the backup
#   created by backup-boot.sh and writes it to a fresh USB.
#
# WHEN TO RUN:
#   - Your boot USB is lost or damaged
#   - You want to create a spare boot USB
#   - You're migrating to a new USB drive
#
# WHERE TO RUN:
#   Option 1: From a Fedora Live USB (default) - for emergency recovery
#   Option 2: From your installed Fedora (--from-installed) - for creating spares
#
# HOW IT WORKS (from Live USB):
#   1. Boots from ANY Linux live USB (separate from target USB)
#   2. Unlocks your encrypted Fedora partition (to access the backup)
#   3. Creates EFI and boot partitions on the target USB
#   4. Copies all boot files from backup
#   5. Updates UUIDs everywhere (fstab, grub.cfg, BLS entries, ventoy_grub.cfg)
#
# HOW IT WORKS (--from-installed):
#   1. Run from your working Fedora system (backup already accessible)
#   2. Skip LUKS unlock (partition already mounted as /)
#   3. Create EFI and boot partitions on target USB (not current boot USB!)
#   4. Copy all boot files from backup
#   5. Update UUIDs everywhere
#
# TWO MODES:
#   Ventoy mode:  If target USB already has Ventoy installed (with reserved
#                 space), creates partitions 3 and 4 - keeps Ventoy working
#
#   Minimal mode: If target USB is empty, creates a simple boot-only USB
#                 (partitions 1 and 2) - no Ventoy ISO boot menu
#
# SAFETY FEATURES:
#   - Detects and EXCLUDES the live USB you booted from
#   - Multiple confirmation prompts before modifying anything
#   - Proper cleanup on errors (unmounts, closes LUKS)
#
# REQUIREMENTS (Live USB mode):
#   - Any Linux live USB to boot from
#   - Target USB drive (will be partially or fully overwritten)
#   - Backup at /root/boot-backup/ on your encrypted partition
#   - Your LUKS passphrase
#
# REQUIREMENTS (--from-installed mode):
#   - Running Fedora system with backup at /root/boot-backup/
#   - Target USB drive DIFFERENT from current boot USB
#   - No LUKS passphrase needed (already unlocked)
#
#===============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

VERSION="1.1.0"

#-------------------------------------------------------------------------------
# Terminal Colors
# Used for visual feedback throughout the script
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'  # No Color - resets terminal

#-------------------------------------------------------------------------------
# Output Functions
# Consistent formatting for all script messages
#-------------------------------------------------------------------------------
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error_noclean() { echo -e "${RED}[ERROR]${NC} $1"; exit "${2:-1}"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; cleanup; exit "${2:-1}"; }
step() { echo -e "\n${CYAN}${BOLD}==> $1${NC}"; }

#===============================================================================
# HELP AND USAGE
# Displayed when user runs: ./restore-boot.sh --help
#===============================================================================

show_help() {
    cat << 'EOF'
================================================================================
restore-boot.sh - Restore Fedora boot partitions from backup to a new USB
================================================================================

USAGE:
    sudo ./restore-boot.sh [OPTIONS]

DESCRIPTION:
    Restores boot partitions from backup to a new USB drive.

    Default mode: Run from a Fedora Live USB for emergency recovery when
    your boot USB is lost or damaged.

    --from-installed mode: Run from your working Fedora system to create
    a spare boot USB or migrate to a new USB proactively.

    The backup must have been previously created by backup-boot.sh and is
    stored on your encrypted root partition at /root/boot-backup/.

OPTIONS:
    -h, --help           Show this help message and exit
    -v, --version        Show version number and exit
    -n, --dry-run        Show what would be done without making changes
    --from-installed     Run from installed Fedora (not Live USB)

PREREQUISITES (Live USB mode - default):
    1. Boot from any Fedora Live USB (or other Linux live environment)
    2. Have your target USB drive inserted (separate from the live USB!)
    3. Have previously run backup-boot.sh on your working system
    4. Know your LUKS encryption passphrase

PREREQUISITES (--from-installed mode):
    1. Running your installed Fedora system normally
    2. Have a DIFFERENT USB drive inserted (not your current boot USB!)
    3. Have previously run backup-boot.sh

TWO MODES:

    Ventoy Mode (recommended):
        If your target USB already has Ventoy installed with reserved space,
        the script creates partitions 3 and 4 in that reserved space.
        Ventoy continues to work - you can still boot ISOs!

        To prepare a USB for Ventoy mode:
        1. Install Ventoy with: ./Ventoy2Disk.sh -i -r 2048 /dev/sdX
        2. The -r 2048 reserves 2GB at end for boot partitions

    Minimal Mode:
        If your target USB is empty or doesn't have Ventoy, the script
        creates a simple boot-only USB with partitions 1 and 2.
        No Ventoy functionality - just boots Fedora directly.

SAFETY FEATURES:
    - Automatically detects the live USB you booted from and EXCLUDES it
    - Shows live USB in red in the disk list so you don't accidentally select it
    - Multiple confirmation prompts before modifying any disk
    - Cleans up properly on errors (unmounts, closes LUKS)

WORKFLOW (Live USB mode):
    1. Boot from Fedora Live USB
    2. Open terminal
    3. Insert your new/target USB drive
    4. Run: sudo ./restore-boot.sh
    5. Select target USB when prompted
    6. Enter LUKS passphrase when prompted
    7. Confirm each step
    8. Remove live USB, reboot with restored USB

WORKFLOW (--from-installed mode):
    1. Boot your Fedora system normally
    2. Insert a NEW USB drive (different from current boot USB)
    3. Run: sudo ./restore-boot.sh --from-installed
    4. Select target USB when prompted (current boot USB excluded)
    5. Confirm each step
    6. New USB is ready as spare/replacement

UUID HANDLING:
    The script automatically updates UUIDs in:
    - /etc/fstab (so system mounts the new USB)
    - /boot/grub2/grub.cfg (if it references boot partition)
    - /boot/loader/entries/*.conf (BLS boot entries)
    - ventoy_grub.cfg (if Ventoy mode)

EXAMPLES:
    sudo ./restore-boot.sh                        # Restore from Live USB
    sudo ./restore-boot.sh --dry-run              # Preview from Live USB
    sudo ./restore-boot.sh --from-installed       # Create spare from running system
    sudo ./restore-boot.sh --from-installed -n    # Preview from running system
    sudo ./restore-boot.sh --help                 # Show this help

TROUBLESHOOTING:
    "Backup not found":
        - You need to run backup-boot.sh first on your working system
        - The backup should be at /root/boot-backup/ inside encrypted partition

    "No LUKS partitions found":
        - Make sure your internal drive (with encrypted Fedora) is connected
        - On laptops, this should always be present

    "Cannot select live USB":
        - Good! This is a safety feature. Pick a DIFFERENT USB.

SEE ALSO:
    backup-boot.sh --help     # How to create backups
    /root/boot-backup/        # Backup location (on encrypted partition)

================================================================================
EOF
    exit 0
}

show_version() {
    echo "restore-boot.sh version ${VERSION}"
    echo "Part of fedora-boot-backup"
    exit 0
}

#===============================================================================
# ARGUMENT PARSING
# Process command-line options BEFORE setting up cleanup trap
# This way --help doesn't trigger cleanup
#===============================================================================

DRY_RUN=false
FROM_INSTALLED=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -v|--version)
            show_version
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --from-installed)
            FROM_INSTALLED=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

# Helper function for dry-run mode
dryrun() {
    echo -e "${YELLOW}[DRY-RUN]${NC} Would execute: $1"
}

# get_partition - Handle NVMe vs regular device naming
# NVMe devices use 'p' before partition number: nvme0n1p1, nvme0n1p2
# Regular devices don't: sda1, sda2
# This function returns the correct partition device path
get_partition() {
    local disk="$1"
    local num="$2"
    if [[ "$disk" == *nvme* ]]; then
        echo "${disk}p${num}"
    else
        echo "${disk}${num}"
    fi
}

#===============================================================================
# CLEANUP FUNCTION
# Called automatically on exit (via trap) or on error
# Unmounts everything and closes LUKS in reverse order
#===============================================================================

# Track what we've mounted/opened so cleanup knows what to undo
CRYPTROOT_OPENED_BY_US=false  # Did WE open LUKS? (vs it was already open)
FEDORA_MOUNTED=false
EFI_MOUNTED=false
BOOT_MOUNTED=false
VENTOY_MOUNTED=false

cleanup() {
    echo ""
    warn "Cleaning up..."

    # Unmount in reverse order of mounting
    # Use || true so we don't fail if already unmounted
    [[ "$VENTOY_MOUNTED" == true ]] && umount /mnt/ventoy 2>/dev/null || true
    [[ "$BOOT_MOUNTED" == true ]] && umount /mnt/new-boot 2>/dev/null || true
    [[ "$EFI_MOUNTED" == true ]] && umount /mnt/new-efi 2>/dev/null || true
    [[ "$FEDORA_MOUNTED" == true ]] && umount /mnt/fedora 2>/dev/null || true

    # Only close LUKS if WE opened it (not if it was already open)
    [[ "$CRYPTROOT_OPENED_BY_US" == true ]] && cryptsetup close cryptroot 2>/dev/null || true

    # Remove mount point directories
    rmdir /mnt/ventoy /mnt/new-boot /mnt/new-efi /mnt/fedora 2>/dev/null || true
}

# Set trap to call cleanup on EXIT (normal or error)
trap cleanup EXIT

#===============================================================================
# STEP 1: INITIAL CHECKS AND WARNING
# Make sure we're root and user understands what this does
#===============================================================================

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: Must run as root (use sudo)${NC}"
    exit 1
fi

# Display appropriate banner based on mode
if [[ "$DRY_RUN" == true ]] && [[ "$FROM_INSTALLED" == true ]]; then
    cat << 'EOF'

╔══════════════════════════════════════════════════════════════════════════════╗
║                  FEDORA BOOT PARTITION RESTORE SCRIPT                        ║
║             *** DRY RUN + FROM-INSTALLED MODE - No changes ***               ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Running from installed Fedora system (not Live USB).                        ║
║  This is a DRY RUN - no changes will be made to your disks.                  ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

EOF
elif [[ "$DRY_RUN" == true ]]; then
    cat << 'EOF'

╔══════════════════════════════════════════════════════════════════════════════╗
║                  FEDORA BOOT PARTITION RESTORE SCRIPT                        ║
║                      *** DRY RUN MODE - No changes ***                       ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  This is a DRY RUN - the script will show what WOULD happen without          ║
║  actually making any changes to your disks or files.                         ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

EOF
elif [[ "$FROM_INSTALLED" == true ]]; then
    cat << 'EOF'

╔══════════════════════════════════════════════════════════════════════════════╗
║                  FEDORA BOOT PARTITION RESTORE SCRIPT                        ║
║                      *** FROM-INSTALLED MODE ***                             ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  Running from installed Fedora system (not Live USB).                        ║
║                                                                              ║
║  This script will:                                                           ║
║    1. Read backup from /root/boot-backup/ (no LUKS unlock needed)            ║
║    2. Create EFI and boot partitions on your target USB                      ║
║    3. Restore boot files from your backup                                    ║
║    4. Update UUIDs in fstab, grub.cfg, and other config files               ║
║                                                                              ║
║  REQUIREMENTS:                                                               ║
║    - Target USB must be DIFFERENT from your current boot USB                 ║
║    - You must have previously run backup-boot.sh                             ║
║                                                                              ║
║  WARNING: This will OVERWRITE partitions on your target USB!                 ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

EOF
else
    cat << 'EOF'

╔══════════════════════════════════════════════════════════════════════════════╗
║                  FEDORA BOOT PARTITION RESTORE SCRIPT                        ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║  This script will:                                                           ║
║    1. Unlock your encrypted Fedora partition (needs LUKS passphrase)         ║
║    2. Create EFI and boot partitions on your target USB                      ║
║    3. Restore boot files from your backup                                    ║
║    4. Update UUIDs in fstab, grub.cfg, and other config files               ║
║                                                                              ║
║  REQUIREMENTS:                                                               ║
║    - You must be booted from a LIVE USB (not your installed Fedora)          ║
║    - Target USB must be DIFFERENT from the live USB you booted from          ║
║    - You must have previously run backup-boot.sh                             ║
║                                                                              ║
║  WARNING: This will OVERWRITE partitions on your target USB!                 ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

EOF
fi

read -p "Continue? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

#===============================================================================
# STEP 2: INSTALL REQUIRED TOOLS
# Live environments might be missing some tools we need
#===============================================================================

step "Checking required tools"

# Tools we need:
# - cryptsetup: unlock LUKS encrypted partition
# - parted: create partitions on target USB
# - rsync: copy files efficiently
# - blkid: get partition UUIDs
# - findmnt: find mount points
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

#===============================================================================
# STEP 3: DETECT EXCLUDED USB
# Find which device to EXCLUDE from selection:
# - Live USB mode: exclude the live USB we booted from
# - From-installed mode: exclude the current boot USB (mounted at /boot)
#===============================================================================

EXCLUDED_USB_DISK=""
EXCLUDED_USB_REASON=""

if [[ "$FROM_INSTALLED" == true ]]; then
    step "Detecting current boot USB"

    EXCLUDED_USB_REASON="CURRENT BOOT USB"

    # Find the device mounted at /boot
    if mountpoint -q /boot 2>/dev/null; then
        BOOT_MOUNT_DEV=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
        if [[ -n "$BOOT_MOUNT_DEV" ]]; then
            EXCLUDED_USB_DISK=$(lsblk -no PKNAME "$BOOT_MOUNT_DEV" 2>/dev/null | head -1)
        fi
    fi

    if [[ -n "$EXCLUDED_USB_DISK" ]]; then
        info "Detected current boot USB: /dev/$EXCLUDED_USB_DISK (will be EXCLUDED)"
        info "You cannot restore to the USB you're currently booting from."
    else
        warn "Could not detect current boot USB - /boot may not be mounted on USB"
        warn "Please be VERY careful with device selection!"
    fi
else
    step "Detecting live USB boot device"

    # We try multiple methods because different live systems work differently

    # Method 1: Check /run/initramfs/live mount point (Fedora live uses this)
    # This is the most reliable method for Fedora live environments
    if mountpoint -q /run/initramfs/live 2>/dev/null; then
        LIVE_MOUNT_DEV=$(findmnt -n -o SOURCE /run/initramfs/live 2>/dev/null || true)
        if [[ -n "$LIVE_MOUNT_DEV" ]]; then
            # Get parent disk name (e.g., 'sda' from '/dev/sda1')
            EXCLUDED_USB_DISK=$(lsblk -no PKNAME "$LIVE_MOUNT_DEV" 2>/dev/null | head -1)
        fi
    fi

    # Method 2: Look for Fedora live USB label
    # Fedora live USBs are labeled "Fedora-*" (e.g., "Fedora-WS-Live-42")
    if [[ -z "$EXCLUDED_USB_DISK" ]]; then
        for label_link in /dev/disk/by-label/Fedora-*; do
            if [[ -L "$label_link" ]]; then
                LIVE_DEV=$(readlink -f "$label_link")
                EXCLUDED_USB_DISK=$(lsblk -no PKNAME "$LIVE_DEV" 2>/dev/null | head -1)
                break
            fi
        done
    fi

    # Method 3: Find squashfs mount (live systems use squashfs for the root filesystem)
    if [[ -z "$EXCLUDED_USB_DISK" ]]; then
        SQUASH_DEV=$(findmnt -t squashfs -n -o SOURCE 2>/dev/null | head -1 || true)
        if [[ -n "$SQUASH_DEV" ]] && [[ -b "$SQUASH_DEV" ]]; then
            EXCLUDED_USB_DISK=$(lsblk -no PKNAME "$SQUASH_DEV" 2>/dev/null | head -1)
        fi
    fi

    EXCLUDED_USB_REASON="LIVE USB"

    if [[ -n "$EXCLUDED_USB_DISK" ]]; then
        info "Detected live USB: /dev/$EXCLUDED_USB_DISK (will be EXCLUDED from selection)"
    else
        warn "Could not detect live USB device - please be VERY careful with selection!"
    fi
fi

#===============================================================================
# STEP 4: SELECT TARGET USB
# Show available disks and let user choose which one to restore to
# The excluded USB (live or current boot) is marked in red and cannot be selected
#===============================================================================

step "Select target USB device"

echo ""
echo "Available disks:"
echo "----------------"
# List all disks (not partitions, not loop devices)
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -v "^loop\|^NAME" | while read line; do
    disk_name=$(echo "$line" | awk '{print $1}')
    if [[ "$disk_name" == "$EXCLUDED_USB_DISK" ]]; then
        # Mark excluded USB in red so user knows not to select it
        echo -e "  $line  ${RED}<-- $EXCLUDED_USB_REASON (cannot select)${NC}"
    else
        echo "  $line"
    fi
done
echo ""

if [[ -n "$EXCLUDED_USB_DISK" ]]; then
    echo -e "${YELLOW}Note: /dev/$EXCLUDED_USB_DISK is your $EXCLUDED_USB_REASON and cannot be selected.${NC}"
    echo ""
fi

read -p "Enter target USB device name (e.g., sdb): " TARGET_DISK_NAME
TARGET_DISK="/dev/$TARGET_DISK_NAME"

# SAFETY: Block selection of the excluded USB
if [[ "$TARGET_DISK_NAME" == "$EXCLUDED_USB_DISK" ]]; then
    error "Cannot select /dev/$EXCLUDED_USB_DISK ($EXCLUDED_USB_REASON)! Choose a different device." 3
fi

# Validate the device exists and is a block device
if [[ ! -b "$TARGET_DISK" ]]; then
    error "$TARGET_DISK is not a valid block device" 3
fi

# Show device details for final confirmation
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

#===============================================================================
# STEP 5 & 6: ACCESS BACKUP
# Two different paths depending on mode:
# - Live USB mode: unlock LUKS, mount partition, access backup
# - From-installed mode: backup is already accessible at /root/boot-backup
#===============================================================================

if [[ "$FROM_INSTALLED" == true ]]; then
    #---------------------------------------------------------------------------
    # FROM-INSTALLED MODE: Backup is directly accessible
    #---------------------------------------------------------------------------
    step "Locate backup (from-installed mode)"

    BACKUP_DIR="/root/boot-backup"
    FSTAB_PATH="/etc/fstab"

    # Check if backup exists
    if [[ ! -d "$BACKUP_DIR" ]]; then
        error "Backup not found at $BACKUP_DIR\n\nYou need to run backup-boot.sh first!" 5
    fi

    info "Found backup at $BACKUP_DIR (direct access - no LUKS unlock needed)"

else
    #---------------------------------------------------------------------------
    # LIVE USB MODE: Need to unlock LUKS and mount partition
    #---------------------------------------------------------------------------
    step "Unlock encrypted Fedora partition"

    # Find all LUKS-encrypted partitions
    LUKS_PARTS=$(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null || true)

    if [[ -z "$LUKS_PARTS" ]]; then
        error "No LUKS encrypted partitions found. Is the internal drive connected?" 4
    fi

    LUKS_COUNT=$(echo "$LUKS_PARTS" | wc -l)

    # If multiple LUKS partitions, let user choose which one
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

    # Check if already unlocked (maybe user ran script before and it failed partway)
    if [[ -e /dev/mapper/cryptroot ]]; then
        warn "cryptroot already unlocked - using existing mapping"
        # Don't mark as opened by us - we won't close it in cleanup
    else
        info "Unlocking $LUKS_PART..."
        info "Enter your LUKS passphrase when prompted:"
        cryptsetup open "$LUKS_PART" cryptroot
        CRYPTROOT_OPENED_BY_US=true
    fi

    step "Locate backup on encrypted partition"

    mkdir -p /mnt/fedora

    # Mount the root subvolume (Fedora uses btrfs with subvolumes)
    mount -o subvol=root /dev/mapper/cryptroot /mnt/fedora
    FEDORA_MOUNTED=true

    BACKUP_DIR="/mnt/fedora/root/boot-backup"
    FSTAB_PATH="/mnt/fedora/etc/fstab"

    # Check if backup exists
    if [[ ! -d "$BACKUP_DIR" ]]; then
        error "Backup not found at $BACKUP_DIR\n\nYou need to run backup-boot.sh on your working Fedora system first!" 5
    fi

    info "Found backup at $BACKUP_DIR"
fi

echo ""
echo "Backup metadata:"
echo "----------------"
# Show key metadata lines
cat "$BACKUP_DIR/metadata.txt" | grep -E "^[A-Z_]|Created:|KERNEL"
echo ""

# Load original UUIDs from the metadata file
# These are the UUIDs from the OLD USB that we'll search-and-replace
eval "$(grep "^BOOT_UUID=" "$BACKUP_DIR/metadata.txt")"
eval "$(grep "^EFI_UUID=" "$BACKUP_DIR/metadata.txt")"

if [[ -z "${BOOT_UUID:-}" ]] || [[ -z "${EFI_UUID:-}" ]]; then
    error "Could not read UUIDs from metadata file - backup may be corrupted" 5
fi

info "Original UUIDs loaded from backup:"
info "  EFI:  $EFI_UUID"
info "  Boot: $BOOT_UUID"

#===============================================================================
# STEP 7: DETERMINE RESTORE MODE
# Check if target USB has Ventoy installed or is empty
# This determines whether we create partitions 3+4 or 1+2
#===============================================================================

step "Detecting target USB layout"

# Check partition 1 to see if it's a Ventoy partition
PART1=$(get_partition "$TARGET_DISK" 1)
if [[ -e "$PART1" ]]; then
    PART1_INFO=$(blkid "$PART1" 2>/dev/null || echo "")
    # Ventoy uses exFAT filesystem for the main partition
    if echo "$PART1_INFO" | grep -qiE "exfat.*ventoy|ventoy.*exfat|TYPE=\"exfat\""; then
        info "Detected existing Ventoy installation on $TARGET_DISK"
        echo ""
        echo "Will use VENTOY MODE:"
        echo "  - Keep Ventoy (partition 1) and VTOYEFI (partition 2)"
        echo "  - Create Fedora EFI at partition 3"
        echo "  - Create Fedora boot at partition 4"
        echo "  - You'll still be able to boot ISOs from Ventoy menu"
        MODE="ventoy"

        # Get where partition 2 ends - our partitions start there
        PART2_END_RAW=$(parted -s "$TARGET_DISK" unit MiB print 2>/dev/null | grep "^ 2" | awk '{print $3}' | tr -d 'MiB')
        if [[ -z "$PART2_END_RAW" ]]; then
            error "Could not determine end of Ventoy partition 2 - is this a valid Ventoy USB?" 6
        fi
        # Strip decimals for bash arithmetic (parted might output "27.4")
        PART2_END=${PART2_END_RAW%.*}
        info "Ventoy partition 2 ends at ${PART2_END}MiB - we'll start there"
    else
        info "Partition 1 exists but is NOT Ventoy"
        echo ""
        echo "Will use MINIMAL MODE:"
        echo "  - Erase entire USB and create new GPT partition table"
        echo "  - Create Fedora EFI at partition 1"
        echo "  - Create Fedora boot at partition 2"
        echo "  - No Ventoy - USB will ONLY boot Fedora"
        MODE="minimal"
    fi
else
    info "Target USB appears empty or unpartitioned"
    echo ""
    echo "Will use MINIMAL MODE:"
    echo "  - Create new GPT partition table"
    echo "  - Create Fedora EFI at partition 1"
    echo "  - Create Fedora boot at partition 2"
    echo "  - No Ventoy - USB will ONLY boot Fedora"
    MODE="minimal"
fi

echo ""
read -p "Proceed with $MODE mode? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

#===============================================================================
# STEP 8: CREATE PARTITIONS
# Create the EFI and boot partitions on the target USB
# Partition layout depends on mode (Ventoy vs minimal)
#===============================================================================

step "Creating partitions on $TARGET_DISK"

if [[ "$MODE" == "ventoy" ]]; then
    #---------------------------------------------------------------------------
    # VENTOY MODE: Create partitions 3 and 4 in reserved space
    #---------------------------------------------------------------------------

    # Check if partitions 3 and 4 already exist (maybe from previous attempt)
    PART3=$(get_partition "$TARGET_DISK" 3)
    PART4=$(get_partition "$TARGET_DISK" 4)
    if [[ -e "$PART3" ]] || [[ -e "$PART4" ]]; then
        warn "Partitions 3 and/or 4 already exist - removing them first"
        if [[ "$DRY_RUN" == true ]]; then
            dryrun "parted -s $TARGET_DISK rm 4"
            dryrun "parted -s $TARGET_DISK rm 3"
        else
            parted -s "$TARGET_DISK" rm 4 2>/dev/null || true
            parted -s "$TARGET_DISK" rm 3 2>/dev/null || true
            sleep 1
        fi
    fi

    # Calculate partition boundaries
    # EFI partition: 512MB starting at end of partition 2
    # Boot partition: Rest of disk (typically ~1.5GB)
    EFI_START="$PART2_END"
    EFI_END=$((EFI_START + 512))
    BOOT_START="$EFI_END"

    info "Creating EFI partition (partition 3): ${EFI_START}MiB - ${EFI_END}MiB (512MB)"
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "parted -s $TARGET_DISK mkpart primary fat32 ${EFI_START}MiB ${EFI_END}MiB"
    else
        parted -s "$TARGET_DISK" mkpart primary fat32 ${EFI_START}MiB ${EFI_END}MiB
    fi

    info "Creating boot partition (partition 4): ${BOOT_START}MiB - end of disk"
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "parted -s $TARGET_DISK mkpart primary ext4 ${BOOT_START}MiB 100%"
    else
        parted -s "$TARGET_DISK" mkpart primary ext4 ${BOOT_START}MiB 100%
    fi

    # Set EFI System Partition flags
    # These flags tell UEFI firmware this partition contains bootloaders
    info "Setting ESP (EFI System Partition) flags on partition 3"
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "parted -s $TARGET_DISK set 3 esp on"
        dryrun "parted -s $TARGET_DISK set 3 boot on"
    else
        parted -s "$TARGET_DISK" set 3 esp on
        parted -s "$TARGET_DISK" set 3 boot on
    fi

    EFI_PART=$(get_partition "$TARGET_DISK" 3)
    BOOT_PART=$(get_partition "$TARGET_DISK" 4)

else
    #---------------------------------------------------------------------------
    # MINIMAL MODE: Create new GPT with partitions 1 and 2
    #---------------------------------------------------------------------------

    warn "This will ERASE ALL DATA on $TARGET_DISK!"
    if [[ "$DRY_RUN" != true ]]; then
        read -p "Final confirmation - erase $TARGET_DISK? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 0
        fi
    fi

    info "Creating new GPT partition table (erases existing partitions)"
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "parted -s $TARGET_DISK mklabel gpt"
    else
        parted -s "$TARGET_DISK" mklabel gpt
    fi

    info "Creating EFI partition (partition 1): 1MiB - 513MiB (512MB)"
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "parted -s $TARGET_DISK mkpart primary fat32 1MiB 513MiB"
        dryrun "parted -s $TARGET_DISK set 1 esp on"
        dryrun "parted -s $TARGET_DISK set 1 boot on"
    else
        parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
        parted -s "$TARGET_DISK" set 1 esp on
        parted -s "$TARGET_DISK" set 1 boot on
    fi

    info "Creating boot partition (partition 2): 513MiB - 2049MiB (1.5GB)"
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "parted -s $TARGET_DISK mkpart primary ext4 513MiB 2049MiB"
    else
        parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 2049MiB
    fi

    EFI_PART=$(get_partition "$TARGET_DISK" 1)
    BOOT_PART=$(get_partition "$TARGET_DISK" 2)
fi

# Wait for kernel to recognize the new partitions
if [[ "$DRY_RUN" == true ]]; then
    info "Would wait for kernel to recognize new partitions..."
    dryrun "partprobe $TARGET_DISK"
else
    info "Waiting for kernel to recognize new partitions..."
    sleep 2
    partprobe "$TARGET_DISK"  # Tell kernel to re-read partition table
    sleep 1
fi

# Verify partitions were created (skip in dry-run mode)
if [[ "$DRY_RUN" != true ]]; then
    if [[ ! -b "$EFI_PART" ]] || [[ ! -b "$BOOT_PART" ]]; then
        error "Partitions were not created successfully - check dmesg for errors" 6
    fi
fi

info "Partitions created: EFI=$EFI_PART, Boot=$BOOT_PART"

#===============================================================================
# STEP 9: FORMAT PARTITIONS
# Create filesystems on the new partitions
# EFI must be FAT32, boot must be ext4
#===============================================================================

step "Formatting partitions"

info "Formatting $EFI_PART as FAT32 (required for EFI System Partition)"
if [[ "$DRY_RUN" == true ]]; then
    dryrun "mkfs.vfat -F 32 $EFI_PART"
else
    mkfs.vfat -F 32 "$EFI_PART"
fi

info "Formatting $BOOT_PART as ext4 with label FEDORA_BOOT"
if [[ "$DRY_RUN" == true ]]; then
    dryrun "mkfs.ext4 -L FEDORA_BOOT $BOOT_PART"
else
    mkfs.ext4 -L FEDORA_BOOT "$BOOT_PART"
fi

info "Partitions formatted successfully"

#===============================================================================
# STEP 10: GET NEW UUIDs
# After formatting, partitions have NEW UUIDs
# We need both old (from backup) and new (from fresh format) for replacement
#===============================================================================

step "Recording new partition UUIDs"

if [[ "$DRY_RUN" == true ]]; then
    # In dry-run mode, we can't get real UUIDs since partitions weren't formatted
    NEW_EFI_UUID="<new-efi-uuid>"
    NEW_BOOT_UUID="<new-boot-uuid>"
    echo ""
    echo "UUID Mapping (old -> new):"
    echo "  EFI:  $EFI_UUID  ->  $NEW_EFI_UUID (placeholder - actual UUID generated at format time)"
    echo "  Boot: $BOOT_UUID  ->  $NEW_BOOT_UUID (placeholder - actual UUID generated at format time)"
    echo ""
    info "UUIDs would be updated in fstab and boot configs"
else
    # Small delay to ensure blkid sees the new filesystems
    sleep 1

    NEW_EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    NEW_BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")

    echo ""
    echo "UUID Mapping (old -> new):"
    echo "  EFI:  $EFI_UUID  ->  $NEW_EFI_UUID"
    echo "  Boot: $BOOT_UUID  ->  $NEW_BOOT_UUID"
    echo ""
    info "These new UUIDs will be updated in fstab and boot configs"
fi

#===============================================================================
# STEP 11: RESTORE BOOT FILES
# Copy all files from backup to the new partitions
#===============================================================================

step "Restoring boot files from backup"

if [[ "$DRY_RUN" == true ]]; then
    dryrun "mkdir -p /mnt/new-efi /mnt/new-boot"
    dryrun "mount $EFI_PART /mnt/new-efi"
    dryrun "mount $BOOT_PART /mnt/new-boot"

    info "Restoring /boot/efi files (EFI bootloader)..."
    dryrun "rsync -av $BACKUP_DIR/efi/ /mnt/new-efi/"

    info "Restoring /boot files (kernels, initramfs, GRUB config)..."
    dryrun "rsync -av $BACKUP_DIR/boot/ /mnt/new-boot/"

    info "Boot files would be restored successfully"
else
    mkdir -p /mnt/new-efi /mnt/new-boot

    mount "$EFI_PART" /mnt/new-efi
    EFI_MOUNTED=true

    mount "$BOOT_PART" /mnt/new-boot
    BOOT_MOUNTED=true

    info "Restoring /boot/efi files (EFI bootloader)..."
    rsync -av "$BACKUP_DIR/efi/" /mnt/new-efi/ || error "Failed to restore EFI files" 7

    info "Restoring /boot files (kernels, initramfs, GRUB config)..."
    rsync -av "$BACKUP_DIR/boot/" /mnt/new-boot/ || error "Failed to restore boot files" 7

    info "Boot files restored successfully"
fi

#===============================================================================
# STEP 12: UPDATE UUIDs IN CONFIGURATION FILES
# The new partitions have different UUIDs than the original
# We must update all config files that reference the old UUIDs
#===============================================================================

step "Updating UUIDs in configuration files"

#---------------------------------------------------------------------------
# Update /etc/fstab
# This tells the system where to mount /boot and /boot/efi
# FSTAB_PATH is set earlier: /etc/fstab (from-installed) or /mnt/fedora/etc/fstab (live)
#---------------------------------------------------------------------------
if [[ -f "$FSTAB_PATH" ]]; then
    info "Updating $FSTAB_PATH..."
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "sed -i 's/$EFI_UUID/$NEW_EFI_UUID/g' $FSTAB_PATH"
        dryrun "sed -i 's/$BOOT_UUID/$NEW_BOOT_UUID/g' $FSTAB_PATH"
        echo "  Would update fstab entries containing boot partition UUIDs"
    else
        # Replace old EFI UUID with new one
        sed -i "s/$EFI_UUID/$NEW_EFI_UUID/g" "$FSTAB_PATH"
        # Replace old boot UUID with new one
        sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" "$FSTAB_PATH"
        echo "  Updated fstab entries:"
        grep -E "/boot" "$FSTAB_PATH" | sed 's/^/    /'
    fi
else
    warn "fstab not found at $FSTAB_PATH - this shouldn't happen!"
fi

#---------------------------------------------------------------------------
# Update GRUB config
# grub.cfg might reference the boot partition UUID
#---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
    GRUB_CFG="$BACKUP_DIR/boot/grub2/grub.cfg"
else
    GRUB_CFG="/mnt/new-boot/grub2/grub.cfg"
fi
if [[ -f "$GRUB_CFG" ]]; then
    if grep -q "$BOOT_UUID" "$GRUB_CFG"; then
        info "Updating /boot/grub2/grub.cfg..."
        if [[ "$DRY_RUN" == true ]]; then
            dryrun "sed -i 's/$BOOT_UUID/$NEW_BOOT_UUID/g' /mnt/new-boot/grub2/grub.cfg"
        else
            sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" "$GRUB_CFG"
        fi
    else
        info "grub.cfg does not contain boot UUID - no changes needed"
    fi
else
    info "No grub.cfg found (normal for BLS-only systems)"
fi

#---------------------------------------------------------------------------
# Update BLS (Boot Loader Spec) entries
# Modern Fedora uses BLS entries in /boot/loader/entries/
# Each kernel has a .conf file that might reference the boot UUID
#---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
    BLS_DIR="$BACKUP_DIR/boot/loader/entries"
else
    BLS_DIR="/mnt/new-boot/loader/entries"
fi
if [[ -d "$BLS_DIR" ]]; then
    BLS_UPDATED=0
    for entry in "$BLS_DIR"/*.conf; do
        if [[ -f "$entry" ]]; then
            if grep -q "$BOOT_UUID" "$entry"; then
                if [[ "$DRY_RUN" == true ]]; then
                    dryrun "sed -i 's/$BOOT_UUID/$NEW_BOOT_UUID/g' $(basename "$entry")"
                else
                    sed -i "s/$BOOT_UUID/$NEW_BOOT_UUID/g" "$entry"
                fi
                BLS_UPDATED=$((BLS_UPDATED + 1))
            fi
        fi
    done
    if [[ $BLS_UPDATED -gt 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            info "Would update $BLS_UPDATED BLS entry file(s) in /boot/loader/entries/"
        else
            info "Updated $BLS_UPDATED BLS entry file(s) in /boot/loader/entries/"
        fi
    else
        info "BLS entries do not contain boot UUID - no changes needed"
    fi
else
    info "No BLS entries directory found"
fi

info "UUID updates complete"

#===============================================================================
# STEP 13: RESTORE VENTOY CONFIGURATION (if Ventoy mode)
# If we're in Ventoy mode, restore the Ventoy config files
# The ventoy_grub.cfg file needs the EFI UUID updated
#===============================================================================

if [[ "$MODE" == "ventoy" ]] && [[ -d "$BACKUP_DIR/ventoy" ]]; then
    step "Restoring Ventoy configuration"

    VENTOY_PART=$(get_partition "$TARGET_DISK" 1)

    if [[ "$DRY_RUN" == true ]]; then
        dryrun "mkdir -p /mnt/ventoy"
        dryrun "mount $VENTOY_PART /mnt/ventoy"
        dryrun "mkdir -p /mnt/ventoy/ventoy"

        if [[ -f "$BACKUP_DIR/ventoy/ventoy_grub.cfg" ]]; then
            info "Copying ventoy_grub.cfg (with updated EFI UUID)..."
            dryrun "sed 's/$EFI_UUID/$NEW_EFI_UUID/g' $BACKUP_DIR/ventoy/ventoy_grub.cfg > /mnt/ventoy/ventoy/ventoy_grub.cfg"
            echo "  Would update: search --fs-uuid to use $NEW_EFI_UUID"
        fi

        if [[ -f "$BACKUP_DIR/ventoy/ventoy.json" ]]; then
            info "Copying ventoy.json (auto-boot config)..."
            dryrun "cp $BACKUP_DIR/ventoy/ventoy.json /mnt/ventoy/ventoy/"
        fi

        dryrun "umount /mnt/ventoy"
    else
        mkdir -p /mnt/ventoy

        if mount "$VENTOY_PART" /mnt/ventoy 2>/dev/null; then
            VENTOY_MOUNTED=true
            mkdir -p /mnt/ventoy/ventoy

            # ventoy_grub.cfg contains the EFI UUID for chainloading
            # We must update it to the new EFI UUID
            if [[ -f "$BACKUP_DIR/ventoy/ventoy_grub.cfg" ]]; then
                info "Copying ventoy_grub.cfg (with updated EFI UUID)..."
                sed "s/$EFI_UUID/$NEW_EFI_UUID/g" \
                    "$BACKUP_DIR/ventoy/ventoy_grub.cfg" > /mnt/ventoy/ventoy/ventoy_grub.cfg
                echo "  Updated: search --fs-uuid now uses $NEW_EFI_UUID"
            fi

            # ventoy.json doesn't contain UUIDs, just copy as-is
            if [[ -f "$BACKUP_DIR/ventoy/ventoy.json" ]]; then
                info "Copying ventoy.json (auto-boot config)..."
                cp "$BACKUP_DIR/ventoy/ventoy.json" /mnt/ventoy/ventoy/
            fi

            umount /mnt/ventoy
            VENTOY_MOUNTED=false
        else
            warn "Could not mount Ventoy partition - Ventoy config not restored"
            warn "You may need to manually create ventoy_grub.cfg"
        fi
    fi
fi

#===============================================================================
# STEP 14: CLEANUP AND SUCCESS SUMMARY
# Unmount everything, close LUKS, and show next steps
#===============================================================================

step "Finalizing"

if [[ "$DRY_RUN" == true ]]; then
    info "Would unmount partitions..."
    dryrun "umount /mnt/new-boot"
    dryrun "umount /mnt/new-efi"

    # In dry-run + live USB mode, we DID actually mount /mnt/fedora and open LUKS
    # (to read backup metadata), so we must actually clean those up
    # In dry-run + from-installed mode, we didn't mount anything
    if [[ "$FROM_INSTALLED" != true ]]; then
        info "Unmounting fedora partition (was mounted to read backup)..."
        umount /mnt/fedora
        FEDORA_MOUNTED=false

        if [[ "$CRYPTROOT_OPENED_BY_US" == true ]]; then
            info "Closing encrypted partition (was opened to read backup)..."
            cryptsetup close cryptroot
            CRYPTROOT_OPENED_BY_US=false
        fi

        rmdir /mnt/fedora 2>/dev/null || true
    fi
    dryrun "rmdir /mnt/new-efi /mnt/new-boot"
else
    info "Unmounting partitions..."

    # Unmount in reverse order
    umount /mnt/new-boot
    BOOT_MOUNTED=false

    umount /mnt/new-efi
    EFI_MOUNTED=false

    # Only unmount /mnt/fedora if we mounted it (live USB mode)
    if [[ "$FROM_INSTALLED" != true ]]; then
        umount /mnt/fedora
        FEDORA_MOUNTED=false

        # Only close LUKS if we opened it
        if [[ "$CRYPTROOT_OPENED_BY_US" == true ]]; then
            info "Closing encrypted partition..."
            cryptsetup close cryptroot
            CRYPTROOT_OPENED_BY_US=false
        fi

        rmdir /mnt/fedora 2>/dev/null || true
    fi

    rmdir /mnt/new-efi /mnt/new-boot 2>/dev/null || true
fi

echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo -e "  ${YELLOW}${BOLD}DRY RUN COMPLETE - No changes were made${NC}"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Target device: $TARGET_DISK"
    echo "  Mode:          $MODE"
    echo ""
    echo "  What WOULD happen:"
    echo "    - Create EFI partition ($EFI_PART) formatted as FAT32"
    echo "    - Create boot partition ($BOOT_PART) formatted as ext4"
    echo "    - Copy EFI files from $BACKUP_DIR/efi/"
    echo "    - Copy boot files from $BACKUP_DIR/boot/"
    echo "    - Update UUIDs in /etc/fstab, grub.cfg, BLS entries"
    if [[ "$MODE" == "ventoy" ]]; then
        echo "    - Copy Ventoy config files with updated EFI UUID"
    fi
    echo ""
    echo "  To perform the actual restore, run without --dry-run:"
    if [[ "$FROM_INSTALLED" == true ]]; then
        echo "    sudo ./restore-boot.sh --from-installed"
    else
        echo "    sudo ./restore-boot.sh"
    fi
    echo ""
else
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}${BOLD}RESTORE COMPLETE - SUCCESS!${NC}"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  Target device: $TARGET_DISK"
    echo "  Mode:          $MODE"
    echo ""
    echo "  New partition UUIDs:"
    echo "    EFI partition ($EFI_PART):   $NEW_EFI_UUID"
    echo "    Boot partition ($BOOT_PART):  $NEW_BOOT_UUID"
    echo ""
    echo "  Files updated:"
    echo "    - /etc/fstab (on encrypted partition)"
    echo "    - /boot/grub2/grub.cfg (if present)"
    echo "    - /boot/loader/entries/*.conf (BLS entries)"
    if [[ "$MODE" == "ventoy" ]]; then
        echo "    - /ventoy/ventoy_grub.cfg (Ventoy chainloader)"
    fi
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────────┐"
    echo "  │  NEXT STEPS:                                                        │"
    if [[ "$FROM_INSTALLED" == true ]]; then
        echo "  │                                                                     │"
        echo "  │    Your spare boot USB is ready!                                    │"
        echo "  │                                                                     │"
        echo "  │    To test it:                                                      │"
        echo "  │    1. Shut down your system                                         │"
        echo "  │    2. Remove current boot USB, insert the new one                   │"
        echo "  │    3. Power on and boot from the new USB                            │"
        echo "  │                                                                     │"
        echo "  │    Or keep it as a backup in case your current boot USB fails.      │"
        echo "  │                                                                     │"
    elif [[ "$MODE" == "ventoy" ]]; then
        echo "  │    1. Shut down this live system                                    │"
        echo "  │    2. Remove the LIVE USB you booted from                           │"
        echo "  │    3. Leave the RESTORED USB ($TARGET_DISK) plugged in                   │"
        echo "  │    4. Power on and select USB in BIOS boot menu                     │"
        echo "  │    5. Ventoy menu should appear -> auto-boots to Fedora             │"
        echo "  │    6. Enter your LUKS passphrase when prompted                      │"
    else
        echo "  │    1. Shut down this live system                                    │"
        echo "  │    2. Remove the LIVE USB you booted from                           │"
        echo "  │    3. Leave the RESTORED USB ($TARGET_DISK) plugged in                   │"
        echo "  │    4. Power on and select USB in BIOS boot menu                     │"
        echo "  │    5. GRUB menu should appear (no Ventoy)                           │"
        echo "  │    6. Enter your LUKS passphrase when prompted                      │"
    fi
    echo "  └─────────────────────────────────────────────────────────────────────┘"
    echo ""
fi

# Disable the trap since we cleaned up successfully
trap - EXIT
