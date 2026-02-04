#!/bin/bash
#===============================================================================
# backup-boot.sh - Backup Fedora boot partitions from USB to encrypted root
#===============================================================================
#
# PURPOSE:
#   This script creates a complete backup of your Fedora boot partitions
#   (/boot and /boot/efi) which live on a USB drive. The backup is stored
#   on your encrypted root partition so it survives if the USB is lost.
#
# WHEN TO RUN:
#   - After initial Fedora installation
#   - After every kernel update (dnf upgrade)
#   - Before traveling or any time USB loss risk is high
#   - Periodically as a precaution (monthly recommended)
#
# WHAT IT BACKS UP:
#   /boot/          -> Kernels, initramfs, GRUB config, BLS entries
#   /boot/efi/      -> EFI bootloader files (shim, grub)
#   ventoy/         -> Ventoy config files (ventoy.json, ventoy_grub.cfg)
#   metadata.txt    -> UUIDs needed for restore (CRITICAL for UUID fixup)
#   checksums.sha256 -> SHA256 hashes to verify backup integrity
#
# REQUIREMENTS:
#   - Must run as root (sudo)
#   - USB boot drive must be plugged in (/boot and /boot/efi mounted)
#   - ~500MB free space on root partition (typically much less needed)
#
# RECOVERY:
#   If USB is lost, boot from any Linux live USB and run restore-boot.sh
#   See: restore-boot.sh --help
#
#===============================================================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

VERSION="1.0.0"
BACKUP_DIR="/root/boot-backup"  # Backup stored on encrypted root partition

#-------------------------------------------------------------------------------
# Terminal Colors
# Used for visual feedback - green=success, yellow=warning, red=error
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color - resets terminal color

#-------------------------------------------------------------------------------
# Output Functions
# Consistent formatting for all script messages
#-------------------------------------------------------------------------------
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit "${2:-1}"; }

#===============================================================================
# HELP AND USAGE
# Displayed when user runs: ./backup-boot.sh --help
#===============================================================================

show_help() {
    cat << 'EOF'
================================================================================
backup-boot.sh - Backup Fedora boot partitions from USB to encrypted root
================================================================================

USAGE:
    sudo ./backup-boot.sh [OPTIONS]

DESCRIPTION:
    Creates a complete backup of /boot and /boot/efi partitions to the
    encrypted root partition. The backup includes all files needed to
    restore your system to a new USB drive if the original is lost.

    This is essential because your boot files live on a USB drive - if
    that USB is lost or damaged, you need this backup to recover.

OPTIONS:
    -h, --help      Show this help message and exit
    -v, --version   Show version number and exit
    -n, --dry-run   Show what would be done without making changes
    -q, --quiet     Suppress non-essential output (not yet implemented)

BACKUP LOCATION:
    /root/boot-backup/
    ├── boot/             # Kernels, initramfs, GRUB config
    │   ├── grub2/        # GRUB bootloader configuration
    │   ├── loader/       # BLS (Boot Loader Spec) entries
    │   ├── vmlinuz-*     # Linux kernel images
    │   └── initramfs-*   # Initial RAM filesystems
    ├── efi/              # EFI System Partition contents
    │   └── EFI/
    │       ├── BOOT/     # Fallback bootloader
    │       └── fedora/   # Fedora's EFI bootloader (shim, grub)
    ├── ventoy/           # Ventoy configuration (if present)
    │   ├── ventoy.json   # Auto-boot settings
    │   └── ventoy_grub.cfg  # Custom GRUB menu entries
    ├── metadata.txt      # UUIDs and partition info (CRITICAL)
    └── checksums.sha256  # File integrity verification

WORKFLOW:
    1. Plug in your USB boot drive (should auto-mount /boot and /boot/efi)
    2. Run: sudo ./backup-boot.sh
    3. Verify the backup completed successfully
    4. Repeat after kernel updates

EXAMPLES:
    sudo ./backup-boot.sh              # Create/update backup
    sudo ./backup-boot.sh --dry-run    # Preview what would be backed up
    sudo ./backup-boot.sh --help       # Show this help

RECOVERY (if USB is lost):
    1. Boot from any Fedora Live USB
    2. Insert a new USB drive
    3. Run: sudo ./restore-boot.sh
    4. Follow the prompts

SEE ALSO:
    restore-boot.sh --help    # How to restore from backup
    /root/boot-backup/        # Backup location
    /etc/fstab                # Mount configuration (contains boot UUIDs)

================================================================================
EOF
    exit 0
}

show_version() {
    echo "backup-boot.sh version ${VERSION}"
    echo "Part of fedora-boot-backup"
    exit 0
}

#===============================================================================
# ARGUMENT PARSING
# Process command-line options before doing anything else
#===============================================================================

QUIET=false
DRY_RUN=false
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
        -q|--quiet)
            QUIET=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Helper function for dry-run mode
dryrun() {
    echo -e "${YELLOW}[DRY-RUN]${NC} Would execute: $1"
}

#===============================================================================
# STEP 1: VALIDATE ENVIRONMENT
# Ensure we have the permissions and mounts needed to proceed
#===============================================================================

echo ""
echo "========================================"
echo "  Fedora Boot Backup Script v${VERSION}"
if [[ "$DRY_RUN" == true ]]; then
echo -e "  ${YELLOW}*** DRY RUN MODE - No changes will be made ***${NC}"
fi
echo "========================================"
echo ""

# Must be root to read boot partitions and write to /root
if [[ $EUID -ne 0 ]]; then
    error "Must run as root (use sudo)" 1
fi

# /boot must be mounted - this is where kernels and initramfs live
# If not mounted, the USB drive is probably not plugged in
if ! mountpoint -q /boot; then
    error "/boot is not a mounted partition. Is USB connected?" 2
fi

# /boot/efi must be mounted - this is the EFI System Partition
# Contains the UEFI bootloader files
if ! mountpoint -q /boot/efi; then
    error "/boot/efi is not a mounted partition. Is USB connected?" 3
fi

info "Environment validated - USB boot drive is connected"

#===============================================================================
# STEP 2: CHECK DISK SPACE
# Ensure we have enough space on root partition before starting
# Failing mid-backup would leave us with an incomplete/corrupt backup
#===============================================================================

info "Checking available disk space..."

# Calculate how much space we need:
# - Size of /boot (kernels, initramfs - typically 200-400MB)
# - Size of /boot/efi (EFI files - typically 20-50MB)
# - Add 10% buffer for metadata and checksums
BOOT_USED=$(du -sm /boot 2>/dev/null | cut -f1)
EFI_USED=$(du -sm /boot/efi 2>/dev/null | cut -f1)
REQUIRED_MB=$(( (BOOT_USED + EFI_USED) * 110 / 100 ))

# Check available space on root partition (where /root lives)
ROOT_AVAIL_MB=$(df -m /root | tail -1 | awk '{print $4}')

if [[ $ROOT_AVAIL_MB -lt $REQUIRED_MB ]]; then
    error "Insufficient disk space. Need ${REQUIRED_MB}MB, have ${ROOT_AVAIL_MB}MB available" 4
fi

info "Disk space OK: need ${REQUIRED_MB}MB, have ${ROOT_AVAIL_MB}MB available"

#===============================================================================
# STEP 3: IDENTIFY SOURCE PARTITIONS
# Find out which devices are mounted at /boot and /boot/efi
# We need their UUIDs for the metadata file (used during restore)
#===============================================================================

info "Identifying boot partitions..."

# findmnt gives us the source device for a mount point
# Example: /dev/sda4 for /boot, /dev/sda3 for /boot/efi
BOOT_DEV=$(findmnt -n -o SOURCE /boot)
EFI_DEV=$(findmnt -n -o SOURCE /boot/efi)

# Get UUIDs - these are CRITICAL for restore
# The restore script needs to update fstab and grub.cfg with new UUIDs
# We store the OLD UUIDs so we know what to search-and-replace
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEV")
EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV")

# Find the parent disk (e.g., sda from sda4)
# This helps us find the Ventoy partition (partition 1)
USB_DISK=$(lsblk -no PKNAME "$BOOT_DEV" | head -1)

if [[ -z "$USB_DISK" ]]; then
    error "Could not determine parent disk for $BOOT_DEV" 4
fi

info "Boot partition: $BOOT_DEV (UUID: $BOOT_UUID)"
info "EFI partition:  $EFI_DEV (UUID: $EFI_UUID)"
info "USB disk:       /dev/$USB_DISK"

#===============================================================================
# STEP 4: CREATE BACKUP DIRECTORY
# Remove old backup (we only keep one) and create fresh directory structure
#===============================================================================

info "Creating backup directory at $BACKUP_DIR..."

# Remove previous backup if it exists
# We don't keep multiple versions to save space (boot files are large)
if [[ -d "$BACKUP_DIR" ]]; then
    OLD_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
    if [[ "$DRY_RUN" == true ]]; then
        dryrun "rm -rf $BACKUP_DIR (removing previous backup: $OLD_SIZE)"
    else
        warn "Removing previous backup ($OLD_SIZE)"
        rm -rf "$BACKUP_DIR"
    fi
fi

# Create directory structure:
# boot/   - will contain /boot files
# efi/    - will contain /boot/efi files
# ventoy/ - will contain Ventoy config (if present)
if [[ "$DRY_RUN" == true ]]; then
    dryrun "mkdir -p $BACKUP_DIR/{boot,efi,ventoy}"
else
    mkdir -p "$BACKUP_DIR"/{boot,efi,ventoy}
fi

info "Backup directory created"

#===============================================================================
# STEP 5: COPY BOOT FILES
# Use rsync to efficiently copy all boot files
# rsync preserves permissions, timestamps, and handles symlinks correctly
#===============================================================================

info "Copying /boot files (kernels, initramfs, GRUB config)..."

# Copy /boot contents, excluding the 'efi' symlink (we handle EFI separately)
# -a = archive mode (preserves everything)
# -v = verbose (shows what's being copied)
if [[ "$DRY_RUN" == true ]]; then
    dryrun "rsync -av --exclude='efi' /boot/ $BACKUP_DIR/boot/"
    info "  Files that would be copied from /boot:"
    find /boot -maxdepth 2 -type f | head -10 | sed 's/^/    /'
    BOOT_COUNT=$(find /boot -type f | wc -l)
    if [[ $BOOT_COUNT -gt 10 ]]; then
        info "  ... and $((BOOT_COUNT - 10)) more files (${BOOT_USED}MB total)"
    else
        info "  Total: $BOOT_COUNT files (${BOOT_USED}MB)"
    fi
else
    rsync -av --exclude='efi' /boot/ "$BACKUP_DIR/boot/" || error "Failed to copy /boot" 4
fi

info "Copying /boot/efi files (EFI bootloader)..."

# Copy EFI System Partition contents
if [[ "$DRY_RUN" == true ]]; then
    dryrun "rsync -av /boot/efi/ $BACKUP_DIR/efi/"
    info "  Files that would be copied from /boot/efi:"
    find /boot/efi -maxdepth 3 -type f | head -10 | sed 's/^/    /'
    EFI_COUNT=$(find /boot/efi -type f | wc -l)
    if [[ $EFI_COUNT -gt 10 ]]; then
        info "  ... and $((EFI_COUNT - 10)) more files (${EFI_USED}MB total)"
    else
        info "  Total: $EFI_COUNT files (${EFI_USED}MB)"
    fi
else
    rsync -av /boot/efi/ "$BACKUP_DIR/efi/" || error "Failed to copy /boot/efi" 4
fi

info "Boot files copied successfully"

#===============================================================================
# STEP 6: BACKUP VENTOY CONFIGURATION
# If this is a Ventoy USB, backup the config files from the Ventoy partition
# These files control auto-boot behavior and custom menu entries
#===============================================================================

info "Checking for Ventoy configuration..."

# Handle NVMe vs regular device naming:
# Regular: sda1, sda2, sda3
# NVMe:    nvme0n1p1, nvme0n1p2, nvme0n1p3
if [[ "$USB_DISK" == nvme* ]]; then
    VENTOY_PART="/dev/${USB_DISK}p1"
else
    VENTOY_PART="/dev/${USB_DISK}1"
fi

if [[ -b "$VENTOY_PART" ]]; then
    # Check if partition 1 is a Ventoy partition
    # Ventoy uses exFAT filesystem and typically has "Ventoy" label
    if blkid "$VENTOY_PART" | grep -qiE "exfat|ventoy"; then
        info "Found Ventoy partition at $VENTOY_PART - backing up config..."

        if [[ "$DRY_RUN" == true ]]; then
            dryrun "mount $VENTOY_PART (temporarily)"
            dryrun "cp ventoy/ventoy.json -> $BACKUP_DIR/ventoy/"
            dryrun "cp ventoy/ventoy_grub.cfg -> $BACKUP_DIR/ventoy/"
            dryrun "umount $VENTOY_PART"
        else
            # Mount Ventoy partition temporarily
            VENTOY_MNT=$(mktemp -d)

            if mount "$VENTOY_PART" "$VENTOY_MNT" 2>/dev/null; then
                if [[ -d "$VENTOY_MNT/ventoy" ]]; then
                    # ventoy.json - controls auto-boot timeout and default selection
                    cp "$VENTOY_MNT/ventoy/ventoy.json" "$BACKUP_DIR/ventoy/" 2>/dev/null && \
                        info "  Copied: ventoy.json (auto-boot config)" || warn "  Not found: ventoy.json"

                    # ventoy_grub.cfg - custom GRUB menu entries (like "Fedora encrypted")
                    cp "$VENTOY_MNT/ventoy/ventoy_grub.cfg" "$BACKUP_DIR/ventoy/" 2>/dev/null && \
                        info "  Copied: ventoy_grub.cfg (custom menu entries)" || warn "  Not found: ventoy_grub.cfg"
                else
                    warn "No /ventoy directory found on Ventoy partition"
                fi
                umount "$VENTOY_MNT"
            else
                warn "Could not mount Ventoy partition - skipping Ventoy config backup"
            fi

            rmdir "$VENTOY_MNT" 2>/dev/null || true
        fi
    else
        info "Partition 1 is not a Ventoy partition - skipping Ventoy config"
    fi
else
    warn "Could not find Ventoy partition at $VENTOY_PART"
fi

#===============================================================================
# STEP 7: SAVE METADATA
# This file contains all the information needed to restore to a new USB
# Most importantly: the original UUIDs that need to be replaced during restore
#===============================================================================

info "Saving metadata (UUIDs and partition info)..."

# Get LUKS UUID for reference (not used during restore, but helpful for debugging)
LUKS_UUID=$(blkid -t TYPE=crypto_LUKS -o value -s UUID 2>/dev/null | head -1 || echo "not found")

if [[ "$DRY_RUN" == true ]]; then
    dryrun "Write metadata.txt to $BACKUP_DIR/"
    info "  Metadata would contain:"
    echo "    BOOT_UUID=$BOOT_UUID"
    echo "    EFI_UUID=$EFI_UUID"
    echo "    LUKS_UUID=$LUKS_UUID"
    echo "    KERNEL_VERSION=$(uname -r)"
else
    # Write metadata file with all critical information
    cat > "$BACKUP_DIR/metadata.txt" << EOF
#===============================================================================
# Boot Backup Metadata
# Created: $(date)
# Hostname: $(hostname)
#===============================================================================
#
# This file contains the original UUIDs from your boot USB.
# During restore, the restore-boot.sh script uses these UUIDs to:
#   1. Find-and-replace old UUIDs with new UUIDs in /etc/fstab
#   2. Update GRUB configuration files
#   3. Update BLS (Boot Loader Spec) entries
#   4. Update ventoy_grub.cfg
#
# DO NOT EDIT THIS FILE - it's generated automatically by backup-boot.sh
#===============================================================================

[Original UUIDs]
# These are the UUIDs of your CURRENT boot partitions
# restore-boot.sh will search for these and replace with new UUIDs
BOOT_UUID=$BOOT_UUID
EFI_UUID=$EFI_UUID

[Source Devices]
# Device paths at backup time (may differ on restore)
BOOT_DEV=$BOOT_DEV
EFI_DEV=$EFI_DEV
USB_DISK=/dev/$USB_DISK

[Partition Sizes]
# Size in bytes - used to verify new USB has enough space
BOOT_SIZE=$(lsblk -bno SIZE "$BOOT_DEV")
EFI_SIZE=$(lsblk -bno SIZE "$EFI_DEV")

[LUKS Info]
# Your encrypted root partition (on internal drive, not USB)
# This UUID does NOT change during restore
LUKS_UUID=$LUKS_UUID

[Backup Info]
BACKUP_DATE=$(date +%Y-%m-%d_%H:%M:%S)
KERNEL_VERSION=$(uname -r)
BACKUP_SCRIPT_VERSION=$VERSION
EOF

    info "Metadata saved to $BACKUP_DIR/metadata.txt"
fi

#===============================================================================
# STEP 8: GENERATE CHECKSUMS
# Create SHA256 checksums of all backed up files
# Used to verify backup integrity before restore
#===============================================================================

info "Generating SHA256 checksums for backup verification..."

if [[ "$DRY_RUN" == true ]]; then
    CHECKSUM_COUNT=$(find /boot /boot/efi -type f 2>/dev/null | wc -l)
    dryrun "Generate SHA256 checksums for $CHECKSUM_COUNT files"
    dryrun "Write checksums to $BACKUP_DIR/checksums.sha256"
else
    CHECKSUM_FILE="$BACKUP_DIR/checksums.sha256"

    # Generate checksums for all files in boot/ and efi/ directories
    # We cd into BACKUP_DIR so paths in checksum file are relative
    (
        cd "$BACKUP_DIR"
        find boot efi -type f -exec sha256sum {} \; > checksums.sha256
    )

    CHECKSUM_COUNT=$(wc -l < "$CHECKSUM_FILE")
    info "Generated $CHECKSUM_COUNT checksums"
fi

#===============================================================================
# STEP 9: SUMMARY
# Display what was backed up and remind user of next steps
#===============================================================================

# Calculate final sizes
if [[ "$DRY_RUN" == true ]]; then
    BOOT_SIZE="${BOOT_USED}M"
    EFI_SIZE="${EFI_USED}M"
    BOOT_FILES=$(find /boot -type f 2>/dev/null | wc -l)
    EFI_FILES=$(find /boot/efi -type f 2>/dev/null | wc -l)
    TOTAL_SIZE="$((BOOT_USED + EFI_USED))M"
else
    BOOT_SIZE=$(du -sh "$BACKUP_DIR/boot" | cut -f1)
    EFI_SIZE=$(du -sh "$BACKUP_DIR/efi" | cut -f1)
    BOOT_FILES=$(find "$BACKUP_DIR/boot" -type f | wc -l)
    EFI_FILES=$(find "$BACKUP_DIR/efi" -type f | wc -l)
    TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
fi

echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}DRY RUN COMPLETE - No changes were made${NC}"
else
    echo -e "  ${GREEN}BACKUP COMPLETE${NC}"
fi
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Location:     $BACKUP_DIR"
echo "  Total size:   $TOTAL_SIZE"
echo ""
echo "  Contents:"
echo "    Boot files: $BOOT_FILES files ($BOOT_SIZE) - kernels, initramfs, GRUB"
echo "    EFI files:  $EFI_FILES files ($EFI_SIZE) - EFI bootloader"
echo "    Checksums:  $CHECKSUM_COUNT files verified"
echo ""
echo "  Original UUIDs (stored in metadata.txt):"
echo "    /boot/efi: $EFI_UUID"
echo "    /boot:     $BOOT_UUID"
echo ""
echo "  IMPORTANT:"
echo "    - Run this script again after kernel updates (dnf upgrade)"
echo "    - Keep your LUKS passphrase safe - without it, data is unrecoverable"
echo "    - To restore: boot any Linux live USB, run restore-boot.sh"
echo ""
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
