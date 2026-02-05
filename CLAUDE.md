# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Fedora Boot Backup is a recovery system for a specialized Fedora setup where:
- The **encrypted root partition** lives on an internal drive (LUKS2)
- The **boot partitions** (`/boot` and `/boot/efi`) live on a removable USB drive
- Optionally, the USB runs **Ventoy** for multi-boot ISO support

If the boot USB is lost or damaged, these scripts enable complete recovery to a new USB.

## Commands

```bash
# Create backup (run from working Fedora system)
sudo ./backup-boot.sh
sudo ./backup-boot.sh --dry-run    # Preview without changes

# Restore backup (run from Fedora Live USB - emergency recovery)
sudo ./restore-boot.sh
sudo ./restore-boot.sh --dry-run   # Preview without changes

# Create spare USB (run from working Fedora - proactive)
sudo ./restore-boot.sh --from-installed
sudo ./restore-boot.sh --from-installed --dry-run

# Verify existing backup
sha256sum -c /root/boot-backup/checksums.sha256
```

## Architecture

### Two Main Scripts

**backup-boot.sh** - Creates backup from running system:
1. Validates USB is mounted at `/boot` and `/boot/efi`
2. Copies boot files to `/root/boot-backup/` on encrypted partition
3. Saves metadata with original UUIDs (critical for restore)
4. Generates checksums for verification

**restore-boot.sh** - Restores to new USB (two modes):

*Default (Live USB mode):*
1. Detects and excludes the live USB (safety feature)
2. Unlocks encrypted partition (prompts for LUKS passphrase)
3. Detects Ventoy on target USB (determines partition layout)
4. Creates and formats EFI (FAT32) + boot (ext4) partitions
5. Copies files from backup
6. **Updates UUIDs** in fstab, grub.cfg, BLS entries, ventoy_grub.cfg

*--from-installed mode (create spare USB from running system):*
1. Detects and excludes current boot USB (safety)
2. Reads backup directly (no LUKS unlock - already mounted)
3. Same steps 3-6 as above

### Two Restore Modes

| Mode | Condition | Result |
|------|-----------|--------|
| **Ventoy** | Target USB has Ventoy installed | Creates partitions 3 & 4 in reserved space |
| **Minimal** | Empty or non-Ventoy USB | Creates partitions 1 & 2 (boot-only) |

### UUID Handling (Critical)

New partitions get new UUIDs. The restore script must replace old UUIDs with new ones in:
- `/etc/fstab` - mount points
- `/boot/grub2/grub.cfg` - if it references boot UUID
- `/boot/loader/entries/*.conf` - BLS boot entries (modern Fedora)
- `ventoy_grub.cfg` - Ventoy chainloader

### Backup Structure

```
/root/boot-backup/
├── boot/            # Mirror of /boot (kernels, initramfs, grub)
├── efi/             # Mirror of /boot/efi (EFI bootloader)
├── ventoy/          # Ventoy config files (if applicable)
├── metadata.txt     # Original UUIDs, kernel version
└── checksums.sha256 # File integrity verification
```

## Key Implementation Details

- Scripts use `trap cleanup EXIT` for automatic unmount/LUKS close on errors
- `get_partition()` helper handles NVMe vs regular device naming (nvme0n1p1 vs sda1)
- Dry-run in restore script still unlocks LUKS (to verify backup) but makes no disk changes
- Live USB detection uses multiple methods: initramfs mount, Fedora label, squashfs mount
- `--from-installed` mode uses `FSTAB_PATH` variable to handle different paths:
  - Live mode: `/mnt/fedora/etc/fstab` (mounted encrypted partition)
  - From-installed: `/etc/fstab` (direct access)
- `EXCLUDED_USB_DISK` tracks which USB to exclude (live USB or current boot USB)
