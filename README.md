# Fedora Boot Backup

Backup and restore scripts for Fedora boot partitions on USB drives.

These scripts are designed for setups where Fedora's `/boot` and `/boot/efi` live on a USB drive (such as a Ventoy multi-boot USB), with the encrypted root on an internal drive. If you lose the USB, these scripts let you restore to a new one.

**New to this setup?** See [FEDORA_ENCRYPTED_USB_INSTALL.md](FEDORA_ENCRYPTED_USB_INSTALL.md) for the full installation guide.

---

## Quick Start

**Create a backup** (run on working Fedora with USB plugged in):
```bash
sudo ./backup-boot.sh
```

**Restore to new USB** (run from Fedora Live USB):
```bash
sudo ./restore-boot.sh
```

**Preview without making changes:**
```bash
sudo ./backup-boot.sh --dry-run
sudo ./restore-boot.sh --dry-run
```

---

## What's Included

| File | Description |
|------|-------------|
| `backup-boot.sh` | Backup /boot and /boot/efi to encrypted partition |
| `restore-boot.sh` | Restore boot partitions to a new USB drive |
| `ventoy.json` | Example Ventoy auto-boot configuration |
| `ventoy_grub.cfg` | Example Ventoy F6 menu entry for Fedora |
| `FEDORA_ENCRYPTED_USB_INSTALL.md` | Full installation guide |

---

## backup-boot.sh

Creates a complete backup of `/boot` and `/boot/efi` to your encrypted root partition.

### When to Run

- After initial Fedora setup
- After kernel updates (`dnf upgrade`)
- Periodically as a precaution (monthly recommended)

### Usage

```bash
sudo ./backup-boot.sh            # Create backup
sudo ./backup-boot.sh --dry-run  # Preview what would be backed up
sudo ./backup-boot.sh --help     # Show full help
```

### What It Does

1. Validates USB is connected (`/boot` and `/boot/efi` mounted)
2. Checks available disk space
3. Copies `/boot` and `/boot/efi` to `/root/boot-backup/`
4. Backs up Ventoy config files (`ventoy.json`, `ventoy_grub.cfg`)
5. Saves metadata with UUIDs needed for restore
6. Generates SHA256 checksums for verification

### Backup Location

```
/root/boot-backup/
├── boot/                    # Mirror of /boot (kernels, initramfs, grub)
├── efi/                     # Mirror of /boot/efi (EFI bootloader)
├── ventoy/                  # Ventoy config files
├── metadata.txt             # UUIDs and partition info (critical for restore)
└── checksums.sha256         # File integrity verification
```

---

## restore-boot.sh

Restores boot partitions from backup to a new USB drive.

### When to Run

From a Fedora Live USB (or any Linux live environment) when your original boot USB is lost or damaged.

### Prerequisites

- Boot from any Linux live USB
- Have a target USB drive ready (separate from the live USB)
- Backup exists at `/root/boot-backup/` on your encrypted partition
- Know your LUKS encryption passphrase

### Usage

```bash
sudo ./restore-boot.sh            # Start restore process
sudo ./restore-boot.sh --dry-run  # Preview restore (verifies backup exists)
sudo ./restore-boot.sh --help     # Show full help
```

### What It Does

1. Detects and excludes the live USB you booted from (safety)
2. Unlocks your encrypted Fedora partition
3. Locates backup and loads original UUIDs
4. Detects target USB layout (Ventoy or empty)
5. Creates and formats EFI + boot partitions
6. Restores all files from backup
7. Updates UUIDs in all config files:
   - `/etc/fstab`
   - `/boot/grub2/grub.cfg`
   - `/boot/loader/entries/*.conf` (BLS entries)
   - `ventoy_grub.cfg` (if Ventoy mode)

### Two Restore Modes

| Mode | When Used | Partitions Created |
|------|-----------|-------------------|
| **Ventoy** | USB already has Ventoy installed | 3 (EFI) + 4 (boot) |
| **Minimal** | Empty USB or non-Ventoy USB | 1 (EFI) + 2 (boot) |

**Ventoy mode:** Preserves Ventoy functionality - you can still boot ISOs.

**Minimal mode:** Creates a simple boot-only USB without Ventoy ISO menu.

---

## Dry-Run Mode

Both scripts support `--dry-run` (`-n`) to preview operations without making changes.

### backup-boot.sh --dry-run

- Shows what files would be copied
- Displays file counts and sizes
- Shows metadata that would be saved
- **No files are written or modified**

### restore-boot.sh --dry-run

- **Does unlock LUKS** (read-only, to verify backup exists)
- Shows backup metadata and original UUIDs
- Detects target USB layout (Ventoy vs minimal mode)
- Shows what partitions would be created
- Shows what UUID replacements would occur
- **No partitions created, no files copied, no configs modified**
- Properly cleans up (unmounts, closes LUKS) before exiting

### Why Restore's Dry-Run Unlocks LUKS

The restore script unlocks your encrypted partition even in dry-run mode because:
1. It verifies the backup actually exists before you commit
2. It shows the real UUID mapping that will be used
3. It checks which config files need UUID updates
4. In a recovery scenario, you want to confirm everything is in place

This makes dry-run a true "preflight check" rather than just showing generic steps.

---

## Quick Recovery Workflow

### Step 0: Preparation (DO THIS NOW!)

Run this on your working system to create a backup:

```bash
sudo ./backup-boot.sh

# Verify backup was created
ls -la /root/boot-backup/
```

Keep a copy of `restore-boot.sh` somewhere accessible (cloud, email, another USB).

---

### Emergency Recovery (when USB is lost)

**What you need:**
- Any Fedora Live USB (or Ubuntu, etc.)
- A new USB drive (8GB+ recommended)
- Your LUKS encryption passphrase
- The `restore-boot.sh` script

**Option A: Minimal Recovery (fastest)**

```bash
# 1. Boot from Fedora Live USB
#    - Download Fedora ISO, write to USB with Fedora Media Writer
#    - Boot from it, select "Try Fedora"

# 2. Get the restore script
curl -O https://raw.githubusercontent.com/YOUR_USER/fedora-boot-backup/main/restore-boot.sh
chmod +x restore-boot.sh

# 3. Insert your NEW USB drive

# 4. Run the restore
sudo ./restore-boot.sh

# 5. Follow prompts:
#    - Select target USB (NOT the live USB!)
#    - Enter LUKS passphrase
#    - Confirm "minimal" mode
#    - Wait for restore

# 6. Shutdown, remove live USB, boot from restored USB
```

**Option B: Full Ventoy Recovery**

```bash
# 1. Boot from Fedora Live USB

# 2. Install Ventoy on the NEW USB first (with reserved space)
wget https://github.com/ventoy/Ventoy/releases/download/v1.0.99/ventoy-1.0.99-linux.tar.gz
tar -xzf ventoy-1.0.99-linux.tar.gz
cd ventoy-1.0.99
sudo ./Ventoy2Disk.sh -i -r 2048 /dev/sdX  # -r 2048 = reserve 2GB

# 3. Run restore script
cd ~
curl -O https://raw.githubusercontent.com/YOUR_USER/fedora-boot-backup/main/restore-boot.sh
chmod +x restore-boot.sh
sudo ./restore-boot.sh

# 4. Script detects Ventoy and uses "ventoy" mode
#    - Creates partitions 3 and 4 in reserved space
#    - Preserves Ventoy functionality

# 5. Shutdown, remove live USB, boot from restored USB
```

---

### What the Restore Script Does

```
┌─────────────────────────────────────────────────────────────┐
│  1. Detects and excludes the live USB (safety)              │
│  2. You select target USB device                            │
│  3. Unlocks your encrypted partition (needs passphrase)     │
│  4. Finds backup at /root/boot-backup/                      │
│  5. Detects if target has Ventoy (ventoy vs minimal mode)   │
│  6. Creates partitions (512MB EFI + 1.5GB boot)             │
│  7. Formats partitions (FAT32 + ext4)                       │
│  8. Copies all boot files from backup                       │
│  9. Updates UUIDs in fstab, grub.cfg, BLS entries           │
│ 10. Updates ventoy_grub.cfg with new EFI UUID (if Ventoy)   │
│ 11. Unmounts everything and shows success message           │
└─────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Backup not found" | Run `backup-boot.sh` on your working system first |
| "No LUKS partitions found" | Internal drive not detected. Check BIOS settings |
| "Cannot select live USB" | Good! This is safety. Pick the OTHER USB |
| Script hangs at LUKS | Wrong passphrase, or keyboard layout issue. Try US layout |
| Boot fails after restore | UUIDs might not match. Boot live, check `/etc/fstab` matches `blkid` output |

---

## More Information

- **Full installation guide:** [FEDORA_ENCRYPTED_USB_INSTALL.md](FEDORA_ENCRYPTED_USB_INSTALL.md)
- **Manual recovery without scripts:** See "Manual Recovery" section in the installation guide

---

*Last updated: 2026-02-04*
