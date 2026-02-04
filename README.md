# Fedora Boot Backup

Backup and restore scripts for Fedora boot partitions on USB drives, plus a complete guide for encrypted Fedora installation with Ventoy.

## What's Included

| File | Description |
|------|-------------|
| `backup-boot.sh` | Backup /boot and /boot/efi to encrypted partition |
| `restore-boot.sh` | Restore boot partitions to a new USB drive |
| `ventoy.json` | Ventoy auto-boot configuration |
| `ventoy_grub.cfg` | Ventoy F6 menu entry for Fedora |

---

## Quick Start

**Create a backup (run on working Fedora):**
```bash
sudo ./backup-boot.sh
```

**Restore to new USB (run from Fedora Live):**
```bash
sudo ./restore-boot.sh
```

**Preview without making changes (dry-run):**
```bash
sudo ./backup-boot.sh --dry-run    # See what would be backed up
sudo ./restore-boot.sh --dry-run   # Preview restore (still unlocks LUKS to verify backup)
```

See [Boot Backup & Restore Scripts](#boot-backup--restore-scripts) for detailed documentation.

---

# Installation Guide: Fedora 42 Encrypted with Ventoy Boot

This guide installs Fedora with an encrypted root partition on your internal drive, with the bootloader on a USB stick that also functions as a Ventoy multi-boot drive.

---

## Overview

| Component | Location |
|-----------|----------|
| Ventoy (boot ISOs) | USB partition 1 |
| Ventoy EFI | USB partition 2 |
| Fedora EFI (`/boot/efi`) | USB partition 3 |
| Fedora boot (`/boot`) | USB partition 4 |
| Fedora root (`/`) | Internal drive, LUKS2 encrypted |
| Windows | Untouched |

---

## Current Setup Details

### USB Drive Partitions (28.9G total)

| Partition | Size   | Filesystem | Label       | UUID                                   | Purpose              |
|-----------|--------|------------|-------------|----------------------------------------|----------------------|
| sda1      | 26.9G  | exfat      | Ventoy      | 4E21-0000                              | ISO storage          |
| sda2      | 32M    | vfat       | VTOYEFI     | E039-AD96                              | Ventoy EFI           |
| sda3      | 488M   | vfat       | -           | **99DA-D916**                          | Fedora /boot/efi     |
| sda4      | 1.5G   | ext4       | FEDORA_BOOT | a6c7d653-8b70-412e-9076-e7a0ab51c4ed   | Fedora /boot         |

### NVMe SSD Partitions (nvme0n1 - 465.8G)

| Partition    | Size   | Filesystem  | Label  | UUID                                   | Purpose               |
|--------------|--------|-------------|--------|----------------------------------------|-----------------------|
| nvme0n1p1    | 200M   | vfat        | -      | 046E-7286                              | Windows EFI           |
| nvme0n1p2    | 16M    | -           | -      | -                                      | Windows Reserved      |
| nvme0n1p3    | 386.7G | ntfs        | -      | F8046EF9046EB9F0                       | Windows C:            |
| nvme0n1p4    | 763M   | ntfs        | -      | 044E4B854E4B6F0C                       | Windows Recovery      |
| nvme0n1p5    | 78.1G  | LUKS2       | -      | d05281e8-0d75-4b31-b101-4096f2891e96   | Fedora encrypted root |

**Inside LUKS container (nvme0n1p5):**
- Filesystem: btrfs
- Label: FEDORA
- UUID: 5c05e27a-9802-48f2-857b-5085aca653ad

### Critical UUIDs Reference

| Component           | UUID                                   |
|---------------------|----------------------------------------|
| Fedora EFI (sda3)   | 99DA-D916                              |
| Fedora /boot (sda4) | a6c7d653-8b70-412e-9076-e7a0ab51c4ed   |
| LUKS container      | d05281e8-0d75-4b31-b101-4096f2891e96   |
| Fedora btrfs root   | 5c05e27a-9802-48f2-857b-5085aca653ad   |

---

## Phase 1: Prepare the USB Drive

**Requirements:**
- USB drive (16GB minimum, 32GB+ recommended)
- Ventoy from [ventoy.net](https://www.ventoy.net)
- Fedora Workstation ISO

**On Windows:**

1. Run **Ventoy2Disk.exe**

2. Before installing, configure:
   - **Option → Partition Style → GPT**
   - **Option → Partition Configuration** → check "Preserve some space at the end of the disk" → enter **2048 MB**

3. Select your USB drive and click **Install**

4. Open **Disk Management** (right-click Start → Disk Management)

5. Find the 2GB unallocated space on your USB and create:
   - **512 MB** partition → FAT32 → label: `FEDORA_EFI`
   - **~1.5 GB** partition → NTFS (temporary) → label: `FEDORA_BOOT`

6. Copy the **Fedora ISO** to the main Ventoy partition (the large exFAT one)

**On Linux:**

1. Download and extract Ventoy

2. Install with reserved space:
   ```bash
   sudo ./Ventoy2Disk.sh -i -r 2048 /dev/sdX
   ```
   - `-i`: Install mode
   - `-r 2048`: Reserve 2048MB at the end for boot partitions

3. Create boot partitions in the reserved space:
   ```bash
   sudo parted /dev/sdX
   # Create partition 3 (EFI) - ~500MB FAT32
   mkpart primary fat32 26.9GiB 27.4GiB
   set 3 esp on
   # Create partition 4 (boot) - remaining space
   mkpart primary ext4 27.4GiB 100%
   ```

4. Format the partitions:
   ```bash
   sudo mkfs.vfat -F 32 /dev/sdX3
   sudo mkfs.ext4 -L FEDORA_BOOT /dev/sdX4
   ```

**USB layout after this step:**
```
/dev/sda1 - Ventoy data (exFAT, ~26GB) - holds ISOs
/dev/sda2 - VTOYEFI (FAT16, 32MB) - Ventoy bootloader
/dev/sda3 - FEDORA_EFI (FAT32, 512MB) - will be /boot/efi
/dev/sda4 - FEDORA_BOOT (~1.5GB) - will be /boot
```

---

## Phase 2: Boot into Fedora Live

1. Reboot with USB inserted

2. Enter BIOS boot menu (F12, F8, Esc — varies by machine)

3. Select USB drive → Ventoy menu appears

4. Select Fedora ISO → boot into live desktop

5. Click **"Not Now"** on the welcome screen to go to desktop

---

## Phase 3: Set Partition Flags with GParted

The FEDORA_EFI partition needs proper EFI flags.

1. Open **GParted** from applications

2. Select your USB drive (`/dev/sda`) from the dropdown

3. Right-click **sda3** (FEDORA_EFI) → **Manage Flags**

4. Check **`boot`** and **`esp`**

5. Verify sda2 (VTOYEFI) does NOT have `esp` flag — uncheck if present

6. If sda3 isn't FAT32, right-click → Format to → fat32

7. Click the **green checkmark** to apply

8. Close GParted

---

## Phase 4: Install Fedora

1. Open **"Install Fedora"** from the desktop

2. Select **Language** and **Keyboard**, click Next

3. At the **Storage** screen, click the **three-dot menu (⋮)** in the top-right corner

4. Select **"Launch storage editor"**

---

## Phase 5: Configure Storage Editor

The Storage Editor opens (Cockpit-based interface).

### Set up USB boot partitions:

**sda3 (FEDORA_EFI, 512MB):**
1. Click on sda3
2. Click three-dot menu → **Edit**
3. Set mount point: `/boot/efi`
4. Filesystem: Keep as FAT32 (EFI System Partition)

**sda4 (FEDORA_BOOT, ~1.5GB):**
1. Click on sda4
2. Click three-dot menu → **Format** or **Edit**
3. Set mount point: `/boot`
4. Filesystem: **ext4**

### Create encrypted root partition:

1. Find your **internal partition** (e.g., nvme0n1p5)

2. Click the three-dot menu → **Format** (or Create partition if unallocated)

3. Configure:
   - **Name**: (optional, leave blank)
   - **Mount point**: leave blank for now
   - **Type**: **Btrfs**
   - **Encryption**: **LUKS2**
   - **Passphrase**: enter strong passphrase
   - **Store passphrase**: check this box

4. Click **Create**

### Create Btrfs subvolumes:

1. The encrypted Btrfs volume appears — expand it

2. Click the **top-level** row's three-dot menu → **Create subvolume**

3. Create root subvolume:
   - **Name**: `root`
   - **Mount point**: `/`
   - Click **Create**

4. Click top-level three-dot menu again → **Create subvolume**

5. Create home subvolume:
   - **Name**: `home`
   - **Mount point**: `/home`
   - Click **Create**

### Return to installer:

1. Click **"Return to installation"** at the top

2. Verify mount points are listed correctly

3. Click **Next**

4. Review and click **Install**

5. Wait for installation to complete

---

## Phase 6: Configure Ventoy Menu (F6 Extension)

After installation, before rebooting, add Fedora to Ventoy's F6 extension menu with auto-boot.

1. Open **Files** and mount the Ventoy data partition (large exFAT partition with ISOs)

2. Open **Terminal** and create config directory:

```bash
# Find where Ventoy is mounted
lsblk

# Create config directory (adjust path if different)
sudo mkdir -p /run/media/liveuser/Ventoy/ventoy
```

3. Get the UUID of your FEDORA_EFI partition:

```bash
sudo blkid | grep sda3
```

Output example:
```
/dev/sda3: UUID="99DA-D916" TYPE="vfat"
```

4. Create the Ventoy grub config file:

```bash
sudo nano /run/media/liveuser/Ventoy/ventoy/ventoy_grub.cfg
```

5. Paste this content (replace UUID with your actual value):

```grub
menuentry "Fedora encrypted" --class fedora --class gnu-linux {
    search --no-floppy --fs-uuid --set=root 99DA-D916
    chainloader /EFI/fedora/shimx64.efi
}
```

6. Create the Ventoy control config for auto-boot:

```bash
sudo nano /run/media/liveuser/Ventoy/ventoy/ventoy.json
```

7. Paste this content:

```json
{
    "control": [
        { "VTOY_MENU_TIMEOUT": "5" },
        { "VTOY_DEFAULT_IMAGE": "F6>0" }
    ]
}
```

**How it works:**
- `VTOY_MENU_TIMEOUT`: 5 seconds before auto-boot (adjust as desired)
- `VTOY_DEFAULT_IMAGE`: `F6>0` navigates to F6 (extension menu) and selects item 0 (Fedora entry)
- Press any key during countdown to interrupt and stay in Ventoy menu

8. Save and exit (Ctrl+O, Enter, Ctrl+X)

**Ventoy config files after this step:**
```
/ventoy/
├── ventoy.json          (auto-boot config)
└── ventoy_grub.cfg      (F6 menu entry)
```

---

## Phase 7: First Boot

1. Reboot the computer

2. Enter BIOS boot menu → select USB drive

3. Ventoy menu appears with 5-second countdown

4. Auto-boots to F6 menu → selects "Fedora encrypted"
   - Or interrupt with any key to select manually or boot an ISO

5. GRUB loads → LUKS passphrase prompt appears

6. Enter your encryption passphrase

7. Fedora boots and presents first-time setup

---

## Boot Process Flow

```
Power on
    ↓
BIOS loads Ventoy from USB
    ↓
Ventoy menu appears (5-second countdown)
    ↓
Auto-selects F6 > item 0 (Fedora encrypted)
    ↓
Chainloads Fedora GRUB from /boot/efi
    ↓
GRUB loads kernel/initramfs from /boot
    ↓
LUKS passphrase prompt
    ↓
Encrypted root unlocks
    ↓
Fedora boots
```

---

## System Updates (dnf upgrade)

The kernel and initramfs live on this USB drive (`/boot` = sda4). When you run `dnf upgrade`:

1. New kernel installs to `/boot` → writes to USB automatically
2. New initramfs generates → writes to USB automatically
3. GRUB config updates → writes to USB automatically

**The USB must be plugged in during updates.** If `/boot` isn't mounted, kernel updates will fail.

You don't need to manually update any USB files - it all happens automatically as long as the USB is connected.

Current fstab mounts (from `/etc/fstab`):
```
UUID=a6c7d653-8b70-412e-9076-e7a0ab51c4ed /boot      ext4  defaults  1 2
UUID=99DA-D916                            /boot/efi  vfat  umask=0077,shortname=winnt 0 2
```

---

## Recovering a Lost Boot USB

If you lose or damage your boot USB, Fedora is still intact on the encrypted internal partition. You just need to recreate the bootloader.

### What you need:
- New USB drive
- Any Linux live ISO (Fedora, Ubuntu, etc.)

### Option A: Recreate the Exact Setup

1. **Prepare new USB with Ventoy** (follow Phase 1)

2. **Boot any Linux live USB**

3. **Install required tools:**

```bash
# On Fedora live:
sudo dnf install cryptsetup btrfs-progs

# On Ubuntu live:
sudo apt install cryptsetup btrfs-progs
```

4. **Unlock and mount your encrypted partition:**

```bash
# Find your encrypted partition
lsblk

# Unlock it (replace nvme0n1p5 with your partition)
sudo cryptsetup open /dev/nvme0n1p5 cryptroot

# Create mount points
sudo mkdir -p /mnt/fedora

# Mount root subvolume
sudo mount -o subvol=root /dev/mapper/cryptroot /mnt/fedora

# Mount other partitions
sudo mount /dev/sda3 /mnt/fedora/boot/efi
sudo mount /dev/sda4 /mnt/fedora/boot
```

5. **Chroot into your Fedora installation:**

```bash
# Mount system directories
sudo mount --bind /dev /mnt/fedora/dev
sudo mount --bind /proc /mnt/fedora/proc
sudo mount --bind /sys /mnt/fedora/sys
sudo mount --bind /run /mnt/fedora/run

# Chroot
sudo chroot /mnt/fedora
```

6. **Update /etc/fstab with new UUIDs:**

```bash
# Get new UUIDs
blkid /dev/sda3 /dev/sda4

# Edit fstab
nano /etc/fstab
# Update the /boot and /boot/efi lines with new UUIDs
```

7. **Reinstall GRUB:**

```bash
# Reinstall GRUB to USB
grub2-install --target=x86_64-efi --efi-directory=/boot/efi --boot-directory=/boot --removable

# Regenerate GRUB config
grub2-mkconfig -o /boot/grub2/grub.cfg

# Rebuild initramfs
dracut -f --regenerate-all

# Exit chroot
exit
```

8. **Unmount everything:**

```bash
sudo umount -R /mnt/fedora
sudo cryptsetup close cryptroot
```

9. **Create Ventoy config files** (follow Phase 6 - update UUID to match new sda3)

10. **Reboot** — your system should work again

---

### Option B: Quick Recovery with Fedora Live

If you just need to boot once to backup data or fix things:

1. Boot Fedora live USB

2. Open terminal:

```bash
# Unlock encrypted partition
sudo cryptsetup open /dev/nvme0n1p5 cryptroot

# Mount it
sudo mkdir /mnt/fedora
sudo mount -o subvol=root /dev/mapper/cryptroot /mnt/fedora
sudo mount -o subvol=home /dev/mapper/cryptroot /mnt/fedora/home
```

3. Access your files at `/mnt/fedora`

---

### Option C: Minimal USB (No Ventoy)

If you just want a simple boot USB without Ventoy:

1. **Format a USB drive with GPT** using GParted

2. **Create two partitions:**
   - 512MB FAT32 with `boot` and `esp` flags
   - 1.5GB ext4

3. **Follow steps 4-8 from Option A** to install GRUB

This creates a dedicated Fedora boot USB without Ventoy functionality.

---

## Troubleshooting

**"No such device" error:**
- UUID in ventoy_grub.cfg doesn't match EFI partition
- Run `lsblk -f` to find correct UUID

**LUKS password not accepted:**
- Keyboard layout might be wrong in initramfs
- Try US layout password

**Kernel panic / can't find root:**
- /etc/fstab has wrong UUIDs
- LUKS UUID in GRUB config might be wrong

**Ventoy menu not appearing:**
- Secure Boot might be enabled
- Try disabling Secure Boot or using Ventoy's secure boot workaround

**Auto-boot not working:**
- Verify `ventoy.json` is in `/ventoy/` directory (not root)
- Check JSON syntax is valid
- `F6>0` means first item (index 0) in F6 menu

---

## Important Notes

- **Keep your USB safe** — without it, you cannot boot Fedora (but recovery is possible)
- **Remember your LUKS passphrase** — without it, your data is permanently inaccessible
- **Backup the USB** — consider creating a second boot USB as backup
- **Windows remains untouched** — boot Windows directly from BIOS boot menu
- **USB must be plugged in for updates** — kernel updates write to /boot on USB

---

## Boot Backup & Restore Scripts

Two scripts are provided to backup your boot partitions and restore them to a new USB if needed.

### backup-boot.sh

**Purpose:** Creates a complete backup of `/boot` and `/boot/efi` to your encrypted partition.

**When to run:**
- After initial setup
- After kernel updates (`dnf upgrade`)
- Periodically as a precaution

**Usage:**

```bash
sudo ./backup-boot.sh            # Create backup
sudo ./backup-boot.sh --dry-run  # Preview what would be backed up
sudo ./backup-boot.sh --help     # Show full help
```

**What it does:**
1. Validates USB is connected (`/boot` and `/boot/efi` mounted)
2. Copies `/boot` and `/boot/efi` to `/root/boot-backup/`
3. Backs up Ventoy config files (`ventoy.json`, `ventoy_grub.cfg`)
4. Saves metadata with UUIDs needed for restore

**Backup location:**
```
/root/boot-backup/
├── boot/                    # Mirror of /boot
├── efi/                     # Mirror of /boot/efi
├── ventoy/                  # Ventoy config files
└── metadata.txt             # UUIDs and partition info
```

### restore-boot.sh

**Purpose:** Restores boot partitions from backup to a new USB drive.

**When to run:** From a Fedora Live USB when your original boot USB is lost or damaged.

**Prerequisites:**
- Fedora Live USB (or any Linux live environment)
- Target USB drive (with or without Ventoy already installed)
- Backup exists at `/root/boot-backup/` on encrypted partition

**Usage:**

```bash
# Boot from Fedora Live USB, then:
sudo ./restore-boot.sh            # Start restore process
sudo ./restore-boot.sh --dry-run  # Preview restore (verifies backup exists)
sudo ./restore-boot.sh --help     # Show full help
```

**What it does:**
1. Unlocks your encrypted Fedora partition
2. Locates backup and loads original UUIDs
3. Detects USB layout (Ventoy or empty)
4. Creates and formats EFI + boot partitions
5. Restores files from backup
6. Updates UUIDs in:
   - `/etc/fstab`
   - `/boot/grub2/grub.cfg`
   - `/boot/loader/entries/*.conf`
   - `ventoy_grub.cfg`

**Two modes:**

| Mode | When Used | Partitions Created |
|------|-----------|-------------------|
| **Ventoy** | USB already has Ventoy installed | 3 (EFI) + 4 (boot) |
| **Minimal** | Empty USB or non-Ventoy USB | 1 (EFI) + 2 (boot) |

**Ventoy mode:** If your target USB already has Ventoy installed (with reserved space), the script creates partitions 3 and 4 in that reserved space, preserving Ventoy functionality.

**Minimal mode:** Creates a simple boot-only USB without Ventoy. You can boot Fedora but won't have the Ventoy ISO menu.

### Dry-Run Mode

Both scripts support `--dry-run` (`-n`) to preview operations without making changes.

**backup-boot.sh --dry-run:**
```bash
sudo ./backup-boot.sh --dry-run
```
- Shows what files would be copied
- Displays file counts and sizes
- Shows metadata that would be saved
- **No files are written or modified**

**restore-boot.sh --dry-run:**
```bash
sudo ./restore-boot.sh --dry-run
```
- **Does unlock LUKS and mount fedora partition** (read-only, to verify backup exists)
- Shows backup metadata and original UUIDs
- Detects target USB layout (Ventoy vs minimal mode)
- Shows what partitions would be created
- Shows what UUID replacements would occur
- **No partitions created, no files copied, no configs modified**
- Properly cleans up (unmounts, closes LUKS) before exiting

**Why restore's dry-run unlocks LUKS:**

The restore script unlocks your encrypted partition even in dry-run mode because:
1. It verifies the backup actually exists before you commit to a restore
2. It shows the real UUID mapping that will be used
3. It can check which config files need UUID updates
4. In a recovery scenario, you want to confirm everything is in place

This makes the dry-run a true "preflight check" rather than just showing generic steps.

**Example dry-run output (restore):**
```
==> Recording new partition UUIDs
UUID Mapping (old -> new):
  EFI:  99DA-D916  ->  <new-efi-uuid> (placeholder - actual UUID generated at format time)
  Boot: a6c7d653-...  ->  <new-boot-uuid> (placeholder - actual UUID generated at format time)

═══════════════════════════════════════════════════════════════════════════
  DRY RUN COMPLETE - No changes were made
═══════════════════════════════════════════════════════════════════════════

  What WOULD happen:
    - Create EFI partition (/dev/sdb3) formatted as FAT32
    - Create boot partition (/dev/sdb4) formatted as ext4
    - Copy EFI files from /mnt/fedora/root/boot-backup/efi/
    - Copy boot files from /mnt/fedora/root/boot-backup/boot/
    - Update UUIDs in /etc/fstab, grub.cfg, BLS entries
    - Copy Ventoy config files with updated EFI UUID

  To perform the actual restore, run without --dry-run:
    sudo ./restore-boot.sh
```

### Quick Recovery Workflow

#### Step 0: Preparation (DO THIS NOW while system works!)

```bash
# Run on your working Fedora system with USB plugged in
sudo ./backup-boot.sh

# Verify backup was created
ls -la /root/boot-backup/
```

Keep a copy of `restore-boot.sh` somewhere accessible (cloud, email to yourself, another USB).

---

#### Emergency Recovery Steps (when USB is lost)

**What you need:**
- Any Fedora Live USB (or Ubuntu, etc.)
- A new USB drive (8GB+ recommended)
- Your LUKS encryption passphrase
- The `restore-boot.sh` script

**Option A: Minimal Recovery (fastest - no Ventoy)**

```bash
# 1. Boot from Fedora Live USB
#    - Download Fedora ISO, write to USB with Fedora Media Writer
#    - Boot from it, select "Try Fedora"

# 2. Open terminal and get the restore script
#    (download from repo, copy from cloud, or type it out)
curl -O https://raw.githubusercontent.com/YOUR_USER/fedora-boot-backup/main/restore-boot.sh
chmod +x restore-boot.sh

# 3. Insert your NEW USB drive (the one that will become your boot drive)

# 4. Run the restore
sudo ./restore-boot.sh

# 5. Follow prompts:
#    - Select target USB (e.g., "sdb") - NOT the live USB!
#    - Enter LUKS passphrase when asked
#    - Confirm "minimal" mode (creates boot-only USB)
#    - Wait for restore to complete

# 6. Shutdown, remove live USB, boot from restored USB
```

**Option B: Full Ventoy Recovery (keeps ISO boot menu)**

```bash
# 1. Boot from Fedora Live USB (same as above)

# 2. Download and install Ventoy on the NEW USB first
#    Get Ventoy from: https://www.ventoy.net/en/download.html
wget https://github.com/ventoy/Ventoy/releases/download/v1.0.99/ventoy-1.0.99-linux.tar.gz
tar -xzf ventoy-1.0.99-linux.tar.gz
cd ventoy-1.0.99

# 3. Install Ventoy WITH reserved space (critical!)
#    Replace sdX with your new USB device
sudo ./Ventoy2Disk.sh -i -r 2048 /dev/sdX
#    -i = install
#    -r 2048 = reserve 2GB at end for boot partitions

# 4. Now run restore script
cd ~
curl -O https://raw.githubusercontent.com/YOUR_USER/fedora-boot-backup/main/restore-boot.sh
chmod +x restore-boot.sh
sudo ./restore-boot.sh

# 5. Script will detect Ventoy and use "ventoy" mode
#    - Creates partitions 3 and 4 in reserved space
#    - Preserves Ventoy functionality

# 6. Shutdown, remove live USB, boot from restored USB
#    - Ventoy menu appears first
#    - Auto-boots to Fedora after 5 seconds
```

---

#### What the restore script does (step by step)

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

#### Troubleshooting Recovery

| Problem | Solution |
|---------|----------|
| "Backup not found" | You didn't run `backup-boot.sh` before losing USB. You'll need to do manual recovery (see Option A in main README) |
| "No LUKS partitions found" | Internal drive not detected. Check BIOS settings, try different USB port |
| "Cannot select live USB" | Good! This is safety. Pick the OTHER USB |
| Script hangs at LUKS | Wrong passphrase, or keyboard layout issue. Try US layout |
| Boot fails after restore | UUIDs might not have updated. Boot live USB, mount partitions, check `/etc/fstab` matches `blkid` output |

3. **For full Ventoy functionality on new USB:**
   - Install Ventoy first with reserved space (`-r 2048`)
   - Then run `restore-boot.sh` (it will detect Ventoy)

---

## Optional: Auto-Unlock with Keyfile

Skip typing the passphrase when USB is present:

```bash
# Generate keyfile on USB
sudo dd if=/dev/urandom of=/boot/crypto_keyfile.bin bs=512 count=4
sudo chmod 400 /boot/crypto_keyfile.bin

# Add keyfile to LUKS (enter existing passphrase when prompted)
sudo cryptsetup luksAddKey /dev/nvme0n1p5 /boot/crypto_keyfile.bin

# Edit crypttab to use keyfile
sudo nano /etc/crypttab
# Change the line to include keyfile path:
# luks-xxxxx UUID=xxxxx /boot/crypto_keyfile.bin luks

# Rebuild initramfs
sudo dracut -f --regenerate-all
```

Now: USB present = auto-unlock. USB missing = system won't boot (extra security).

---

## References

- [Ventoy Official Site](https://www.ventoy.net/)
- [Ventoy Control Plugin](https://www.ventoy.net/en/plugin_control.html) - VTOY_MENU_TIMEOUT, VTOY_DEFAULT_IMAGE
- [Ventoy Menu Extension Plugin](https://www.ventoy.net/en/plugin_grubmenu.html) - ventoy_grub.cfg format

---

*Last updated: 2026-02-04*
*Fedora version: 42 (Adams)*
