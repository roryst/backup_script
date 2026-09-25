# Automated Encrypted Backup & Disaster Recovery Suite

A robust, enterprise-grade Bash backup, verification, and disaster-recovery solution designed for personal Linux workstations and servers. It creates encrypted, high-ratio compressed archives of your home directory, captures a full system state snapshot (package manifests, repositories, desktop settings), and synchronizes with external drives and cloud remotes.

---

## Table of Contents

- [Features](#features)
- [Architecture & Workflow](#architecture--workflow)
- [Prerequisites & Dependencies](#prerequisites--dependencies)
- [Getting Started](#getting-started)
  - [1. Initial Setup](#1-initial-setup)
  - [2. Configure Encryption](#2-configure-encryption)
  - [3. Configure Storage Destinations](#3-configure-storage-destinations)
  - [4. Verify Environment](#4-verify-environment)
- [Command Reference & Examples](#command-reference--examples)
  - [Environment & Health Check (`check-config`)](#environment--health-check-check-config)
  - [Creating Backups (`backup`)](#creating-backups-backup)
  - [Listing Available Backups (`list`)](#listing-available-backups-list)
  - [Viewing Archive Files (`list-files`)](#viewing-archive-files-list-files)
  - [Searching Files Across Backups (`find-file`)](#searching-files-across-backups-find-file)
  - [Inspecting Backup Manifests (`manifest`)](#inspecting-backup-manifests-manifest)
  - [Historical Trends & Analytics (`stats`)](#historical-trends--analytics-stats)
  - [Integrity Verification (`verify`)](#integrity-verification-verify)
  - [Restoring Data (`restore`)](#restoring-data-restore)
  - [Automated Scheduling (`systemd` Timer)](#automated-scheduling-systemd-timer)
- [Retention Policies & GFS Pruning](#retention-policies--gfs-pruning)
- [Exclusion Rules](#exclusion-rules)
- [Disaster Recovery Bootstrapping](#disaster-recovery-bootstrapping)
- [Configuration Reference](#configuration-reference)
- [License](#license)

---

## Features

### 🛡️ Security & Encryption
- **Multi-Mode Encryption**: Supports symmetric AES-256 (`gpg`), asymmetric public-key encryption (ideal for headless servers with zero secret keys on disk), or hybrid encryption.
- **Strict Permission Enforcement**: Automatically ensures configuration files and passphrase secrets are locked to `chmod 700` and `600`.
- **Zero Temporary Secret Leakage**: Passphrases and encryption pipes are handled in memory and secure file descriptors.

### ⚡ Compression & Performance
- **Modern Zstandard (`zstd`)**: Tuned compression (default level 6) with **Long Distance Matching (`--long=27`)** to dramatically compress repetitive text, code repositories, and container structures.
- **Adaptive Cloud Streaming**: Restore directly from cloud storage via `rclone cat` without downloading full multi-gigabyte archives to local disk, falling back to local staging when disk permits.
- **Resource Aware**: Dynamically caps decompression memory and enforces scratch space checks before archiving to prevent disk exhaustion.

### 🔄 Dual-Destination Synchronization & Retention
- **Hybrid Storage**: Concurrently synchronizes to local external partitions (auto-discovered via filesystem UUID) and cloud remotes via `rclone` (Google Drive, Backblaze B2, AWS S3, etc.).
- **Flexible Retention (Count-Based or GFS Tiered)**:
  - **Count-based** (default): Retains the `N` newest archives on local drive and cloud remote (default: 10).
  - **Grandfather-Father-Son (GFS) Tiered Retention**: Automatically maintains a timeline of daily, weekly, monthly, and yearly archives (default: 7 daily, 4 weekly, 6 monthly, 1 yearly) for months or years of recovery coverage without extra storage bloat.
- **Preserved Archive Management**: If network or remote connectivity fails, encrypted archives can be preserved locally to avoid data loss and re-uploaded later using `manage-preserved`.

### 🔍 Verification & Integrity
- **SHA-256 Sidecar Checksums**: Companion `.sha256` files accompany every archive, allowing sub-10-second bit-rot validation without needing to decrypt multi-gigabyte archives.
- **Inline Single-Pass Verification**: Verifies checksums on-the-fly during cloud streaming via named pipes and `tee`.
- **Full Tar Stream Validation**: Thoroughly validates encryption integrity and tar archive block structure without writing files to disk.

### 📦 System State Snapshots, Manifests & File Indexing
- **OS Environment Capture**: Exports lists of installed system packages (APT or DNF), Flatpaks, Pipx packages, enabled systemd user units, desktop `dconf` configurations, crontabs, and repository/GPG keyrings into the backup.
- **Companion JSON Manifests (`.manifest.json`)**: Instantly inspect archive metadata, compression ratios, package counts, and checksums without downloading or decrypting the archive.
- **Zero-Bandwidth Companion File Indexes (`.files.gz`)**: Captures full file tables during archive creation (`tar -vv --index-file`) with zero extra disk passes, enabling instant file search (`find-file`) and zero-download archive exploration (`list-files`) across all local and remote snapshots.

### ⚙️ Reliability & Safety
- **Application Consistency Guard**: Detects running database-heavy applications (Vivaldi, Chrome, Firefox, Thunderbird) and gracefully terminates them with `SIGTERM` and filesystem `sync` before archiving.
- **Concurrency Locking**: Uses kernel `flock` to prevent overlapping runs.
- **Graceful Cleanup**: Traps `SIGINT`, `SIGTERM`, and script exit to clean up scratch paths and named pipes safely.
- **Failure & Success Alerts**: Dispatches email alerts on backup failure or success using local MTAs (`msmtp`, `mailx`).

---

## Prerequisites & Dependencies

### Core Utilities (Required)

Ensure the following tools are installed on your Linux system:

| Utility | Purpose | Minimum Recommended |
| :--- | :--- | :--- |
| `bash` | Shell execution engine | 4.3+ |
| `tar` | Archive bundling | GNU tar (with `--exclude-tag-all` support) |
| `zstd` | Ultra-fast compression | 1.4+ |
| `gpg` | Asymmetric & symmetric AES-256 encryption | GnuPG 2.x |
| `rclone` | Cloud storage transfer & streaming | Recent stable release |
| `sha256sum` | Cryptographic checksum generation & validation | GNU coreutils |
| `gzip` | Fast compression for companion `.files.gz` index sidecars | Any modern version |
| `flock` | Script execution locking | `util-linux` |
| `lsblk` / `blkid` | Local external drive UUID discovery | `util-linux` |

### Optional Helper Integrations

| Utility | Used For |
| :--- | :--- |
| `apt-mark` | Capturing manually installed APT packages on Debian/Ubuntu/Mint |
| `dnf` | Capturing user-installed RPM packages on Fedora/RHEL/CentOS/Rocky/Alma |
| `msmtp` / `mailx` | Email notification alerts on backup failure |
| `flatpak` | Capturing installed Flatpak apps and remotes |
| `pipx` | Capturing installed standalone Python CLI tools |
| `dconf` | Exporting GNOME/desktop settings snapshot |
| `crontab` | Exporting user scheduled jobs |
| `systemd` | Managing automated `--user` timers and services |

To install common dependencies on Debian/Ubuntu/Mint:
```bash
sudo apt update
sudo apt install -y bash tar zstd gnupg rclone coreutils util-linux gzip msmtp
```

To install common dependencies on Fedora/RHEL/CentOS Stream/Rocky/AlmaLinux:
```bash
sudo dnf install -y bash tar zstd gnupg2 rclone coreutils util-linux gzip msmtp
```

---

## Getting Started

### 1. Initial Setup

Place `backup_script.sh` into your PATH (e.g., `~/.local/bin/`) and ensure it is executable:
```bash
chmod +x ~/.local/bin/backup_script.sh
```

Generate the default configuration template:
```bash
./backup_script.sh init-config
```
This creates `~/.config/backup_script/config` with secure `700`/`600` permissions.

### 2. Configure Encryption

#### Symmetric Encryption (Default)
Store your backup passphrase securely in `~/.config/backup_script/passphrase`:
```bash
echo "YOUR_STRONG_PASSPHRASE" > ~/.config/backup_script/passphrase
chmod 600 ~/.config/backup_script/passphrase
```

#### Asymmetric / Public-Key Encryption (Optional)
If running on a server or automated host where you do not want secrets stored, configure GPG public-key encryption:
```bash
# In ~/.config/backup_script/config:
ENCRYPTION_MODE="asymmetric"
GPG_RECIPIENT="your_email@domain.com"
```

### 3. Configure Storage Destinations

#### Local External Drive
Locate the UUID of your backup partition using `lsblk -f` or `blkid`:
```bash
lsblk -f
```
Add the UUID to `~/.config/backup_script/config`:
```bash
LOCAL_DRIVE_UUID="bc3968af-d154-4167-b73c-5a172d2a25b8"
LOCAL_BACKUP_SUBDIR="Backups"
```

#### Cloud Storage (`rclone`)
Configure an `rclone` remote (e.g., Google Drive, S3, B2) using `rclone config`. Then point the script to your remote folder (with trailing slash):
```bash
# In ~/.config/backup_script/config:
BACKUP_DIR="googledrive:backup/"
```

### 4. Verify Environment

Run the pre-flight check to validate your configuration, dependencies, and credentials:
```bash
./backup_script.sh check-config
```

---

## Command Reference & Examples

### Environment & Health Check (`check-config`)

Validates file permissions, storage availability, cloud remotes, and external tools:

```bash
$ ./backup_script.sh check-config
```

```text
===============================================================================
  Backup Configuration & Environment Check
===============================================================================

Configuration & Excludes:
 [  OK  ]  Config Directory             /home/rory/.config/backup_script (permissions: 700)
 [  OK  ]  Config File Perms            /home/rory/.config/backup_script/config (permissions: 600)
 [  OK  ]  Config Syntax                Syntax validation passed for /home/rory/.config/backup_script/config
 [ INFO ]  Excludes File                No custom excludes file; built-in exclusions active (90 patterns)
 [  OK  ]  Exclude Tags (.nobackup)     Enabled (tag files: .nobackup)
 [  OK  ]  Root Exclusion Tag           Safe (no exclusion tag in root of /home/rory)
 [  OK  ]  Exclude Ignore Rules         Enabled (recursive files: .backupignore)

Encryption & Credentials:
 [  OK  ]  Encryption Mode              Configured mode: symmetric
 [  OK  ]  Passphrase Source            Configured via file (~/.config/backup_script/passphrase)
 [  OK  ]  Password File Perms          ~/.config/backup_script/passphrase (permissions: 600)
 [  OK  ]  GPG Symmetric Test           Symmetric AES-256 loopback encryption & decryption passed

Filesystem & Storage Paths:
 [  OK  ]  Source Directory             /home/rory exists and is readable
 [  OK  ]  Scratch Directory            /home/rory/.backup_scratch will be created in writable parent
 [  OK  ]  Scratch Free Space           1.1T available (minimum required: 15G)

Local Drive Destination:
 [  OK  ]  Local Drive Device           Partition detected at /dev/disk/by-uuid/bc3968af-...
 [  OK  ]  Local Drive Mount            Mounted at /media/rory/bc3968af-d154-4167-b73c-5a172d2a25b8
 [  OK  ]  Local Backup Subdir          /media/rory/.../Backups is writable (403G free)

Cloud Remote Destination (rclone):
 [  OK  ]  Cloud Path Format            BACKUP_DIR 'googledrive:backup/' has valid format
 [  OK  ]  Cloud Connectivity           Remote 'googledrive:backup/' is reachable and authenticated
 [  OK  ]  Rclone Chunk Size            256M (upload cutoff: 256M)

===============================================================================
  Diagnostic Summary
===============================================================================
  Total Checks : 38
  Passed       : 38
  Warnings     : 0
  Failures     : 0
-------------------------------------------------------------------------------
  Result: All checks passed! Configuration and environment are in excellent health.
===============================================================================
```

---

### Creating Backups (`backup`)

Execute a manual backup immediately:
```bash
./backup_script.sh backup
```

#### Common Options:
- `--no-close-apps`: Skip closing open browsers; flushes buffers via `sync`.
- `--verify-checksum`: Run fast SHA-256 bit-rot validation immediately after upload.
- `--no-verify`: Skip post-backup verification for faster completion.
- `--asymmetric [key]`: Encrypt with GPG public key.
- `--alert-email <email>`: Override failure notification address.
- `--email-on-success`: Send email notification upon successful backup completion.
- `--success-email <email>`: Specify recipient address for success notifications (enables success email).

---

### Listing Available Backups (`list`)

List all archives available on the local drive and cloud remote:

```bash
$ ./backup_script.sh list
```

```text
Available local backups (/media/rory/bc3968af-d154-4167-b73c-5a172d2a25b8/Backups):
  7.6GB     2026-09-21 00:53:31  rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg
  7.6GB     2026-09-20 01:01:36  rory_home_backup_hp_2026-09-20_005952.tar.zst.gpg
  7.6GB     2026-09-19 00:49:26  rory_home_backup_hp_2026-09-19_004752.tar.zst.gpg
  7.8GB     2026-09-18 01:00:21  rory_home_backup_hp_2026-09-18_005852.tar.zst.gpg

Available cloud backups for this host (hp) on googledrive:backup/:
  7.6GB     2026-09-21 00:53:31  rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg
  7.6GB     2026-09-20 01:01:36  rory_home_backup_hp_2026-09-20_005952.tar.zst.gpg
  7.6GB     2026-09-19 00:49:26  rory_home_backup_hp_2026-09-19_004752.tar.zst.gpg
  7.8GB     2026-09-18 01:00:21  rory_home_backup_hp_2026-09-18_005852.tar.zst.gpg
```

---

### Viewing Archive Files (`list-files`)

Explore file listings inside any local, cloud, or explicit archive snapshot without downloading the full archive payload or running decryption:

```bash
# View files in the latest backup
$ ./backup_script.sh list-files latest

# Filter files within a specific backup by pattern or path
$ ./backup_script.sh list-files latest "\.ssh/"

# Show full permissions, owner, file size, and timestamps
$ ./backup_script.sh list-files latest "Documents/" --long
```

```text
Querying companion file index: rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg.files.gz (instant/zero decryption)...
Listing contents of: rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg (local)...
Filtering for pattern: 'Documents/'
-------------------------------------------------------------------------------
home/rory/Documents/
home/rory/Documents/Projects/
home/rory/Documents/Projects/important_notes.txt
home/rory/Documents/taxes_2025.pdf
-------------------------------------------------------------------------------
```

---

### Searching & Restoring Files Across Backups (`find-file`)

Instantly locate any file across **all** historical backup archives (local external drive, cloud storage, or both) using lightweight `.files.gz` companion indexes—without downloading multi-gigabyte payloads or decrypting archives. Each search result is numbered, allowing direct one-step extraction:

```bash
# Search across all backups (auto-discovers local and cloud snapshots)
$ ./backup_script.sh find-file "important_notes.txt"

# Directly select and restore a matching file interactively
$ ./backup_script.sh find-file "important_notes.txt" --restore

# Restore directly to a specific destination directory
$ ./backup_script.sh find-file "important_notes.txt" --restore --dest /tmp/restored

# Search with regular expressions across both local and cloud
$ ./backup_script.sh find-file ".*\.kdbx" --source all

# Display detailed metadata (permissions, owner, size, timestamps)
$ ./backup_script.sh find-file "wireguard\.conf" --long

# Limit output to 5 matches per archive
$ ./backup_script.sh find-file "id_ed25519" --limit 5
```

```text
Searching for 'important_notes.txt' across 4 backup index(es)...
===============================================================================

-------------------------------------------------------------------------------
 Archive : rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg
 Source  : local (rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg.files.gz)
 Matches : 2 file(s)
-------------------------------------------------------------------------------
 [1] ./Documents/Projects/important_notes.txt
 [2] ./Work/Archive/important_notes.txt

-------------------------------------------------------------------------------
 Archive : rory_home_backup_hp_2026-09-20_005952.tar.zst.gpg
 Source  : cloud (rory_home_backup_hp_2026-09-20_005952.tar.zst.gpg.files.gz)
 Matches : 1 file(s)
-------------------------------------------------------------------------------
 [3] ./Documents/Projects/important_notes.txt

===============================================================================
Search complete: 3 match(es) across 2 archive(s) (scanned 4 index(es)).
===============================================================================

-------------------------------------------------------------------------------
  Restore Search Result
-------------------------------------------------------------------------------
Enter match number [1-3, or Enter to skip]: 1

Selected : [1] ./Documents/Projects/important_notes.txt
Archive  : rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg (local)

Choose restore destination:
  1) Current working directory (/home/rory)
  2) Original location (~/Documents/Projects/important_notes.txt)
  3) Custom directory
Please select destination [1-3, default: 1]: 1

Restoring './Documents/Projects/important_notes.txt' from rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg to /home/rory...
Selective restore complete!
```

---

### Inspecting Backup Manifests (`manifest`)

View archive metadata and package inventory without decrypting the archive:

```bash
$ ./backup_script.sh manifest latest
```

```text
===============================================================================
  Backup Manifest & Inventory
===============================================================================
  Manifest Source  : local drive (/media/rory/.../rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg.manifest.json)
  Created (UTC)    : 2026-09-21T05:53:37Z
  Host / User      : hp / rory
  Source Directory : /home/rory
  Script Version   : 9.35.0
  Duration         : 1m 46s (106s)
-------------------------------------------------------------------------------
  Archive Details
-------------------------------------------------------------------------------
  Filename         : rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg
  Archive Size     : 7.6GB (8,089,836,825 bytes)
  Uncompressed     : 16GB (16,403,712,000 bytes)
  Compression Ratio: 2.03x (50.7% space savings)
  SHA-256 Checksum : 077c0b1a63ea9ad493d91586fdb6e56eb7acf3c7d3bb10a16f426804b16666c3
  Compression      : zstd (level 6, long-matching: 27)
  Encryption       : Symmetric AES256 (gpg, SHA512)
-------------------------------------------------------------------------------
  System State Snapshot
-------------------------------------------------------------------------------
  APT Manual Pkgs  : 2296 packages recorded
  APT Repositories : Yes (sources & keyrings)
  DNF User Pkgs    : None / skipped
  DNF Repositories : No / skipped
  Flatpak Apps     : 34 apps (1 remotes)
  Pipx Packages    : Yes (spec exported)
  Systemd Units    : 28 enabled user units
  Desktop (Dconf)  : Yes
  Crontab Backup   : Yes
===============================================================================
```

To output raw JSON for automation:
```bash
./backup_script.sh manifest latest --json
```

---

### Historical Trends & Analytics (`stats`)

Analyze compression performance, storage deltas, and execution runtimes over time:

```bash
$ ./backup_script.sh stats -n 5
```

```text
================================================================================================
  Backup Trends & Historical Analytics (showing latest 5 of 6 backups)
================================================================================================
Date & Time (UTC)    Archive Size  Delta Archive       Uncompressed  Ratio    Duration   Destination
------------------------------------------------------------------------------------------------
2026-09-17 06:21:13  7.8GB         +52.7KB (+0.0%)     —             —        1m 45s     Local
2026-09-18 06:00:28  7.8GB         +28.60MB (+0.4%)    17GB          2.10x    1m 37s     Local
2026-09-19 05:49:32  7.6GB         -264.31MB (-3.3%)   16GB          2.02x    1m 41s     Local
2026-09-20 06:01:42  7.6GB         +5.51MB (+0.1%)     16GB          2.02x    1m 51s     Local
2026-09-21 05:53:37  7.6GB         +5.53MB (+0.1%)     16GB          2.03x    1m 46s     Local
------------------------------------------------------------------------------------------------
Summary Statistics:
  Total Backups Analyzed : 6 (span: 2026-09-17 06:19:09 to 2026-09-21 05:53:37)
  Archive Size Range     : 7.52GB min / 7.78GB max / 7.65GB avg
  Net Archive Growth     : -224.62MB (-2.8%)
  Avg Uncompressed Size  : 15.51GB
  Avg Compression Ratio  : 2.04x
  Avg Execution Duration : 1m 45s
================================================================================================
```

---

### Integrity Verification (`verify`)

#### Fast Bit-Rot Verification (`--checksum-only` / `-c`)
Checks the SHA-256 sidecar file to guarantee bit-for-bit storage integrity without decryption:

```bash
$ ./backup_script.sh verify latest local --checksum-only
```

```text
Finding available backups for verification...
Non-interactive verification selected: rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg (local)
Verifying SHA-256 sidecar checksum (rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg.sha256)...
SHA-256 checksum verified OK (no bit-rot detected).
SUCCESS: Archive 'rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg' passed SHA-256 checksum verification.
```

#### Full Decryption & Tar Structure Verification
Streams and decrypts the archive to test tar headers and block consistency without extracting files to disk:
```bash
./backup_script.sh verify latest local
```

---

### Restoring Data (`restore`)

The script supports both full and selective restores.

#### 1. Interactive Menu Restore
```bash
./backup_script.sh restore
```
Guides you through selecting local or cloud backups, confirms target directories, and verifies checksums prior to extraction.

#### 2. Selective Extraction (`--pattern`)
Restore a single configuration file, directory, or wildcard pattern into an alternate target:
```bash
# Restore specific .bashrc to current directory
./backup_script.sh restore latest --pattern ".bashrc" --dest ./recovered/

# Restore all PDFs from cloud backup without downloading the full archive
./backup_script.sh restore latest --pattern "*.pdf" --source cloud --stream
```

#### 3. Restoring to Alternate Directory
Always protect existing working trees by restoring to a staging directory first:
```bash
./backup_script.sh restore latest --dest /tmp/restore_test
```

---

### Automated Scheduling (`systemd` Timer)

The script includes built-in systemd user service and timer integration.

#### Install & Enable Daily Backup Timer
```bash
# Installs timer to run daily at 00:45:00
./backup_script.sh install-timer "daily"

# Or with custom OnCalendar schedule:
./backup_script.sh install-timer "*-*-* 02:00:00"
```

#### Check Timer Status
```bash
$ ./backup_script.sh status-timer
```

```text
===============================================================================
  Systemd User Backup Timer Status
===============================================================================
● backup-home.timer - Run automated home directory backup on schedule
     Loaded: loaded (~/.config/systemd/user/backup-home.timer; enabled; preset: enabled)
     Active: active (waiting) since Wed 2026-09-16 18:13:29 CDT; 4 days ago
    Trigger: Tue 2026-09-22 00:52:40 CDT; 12h left
   Triggers: ● backup-home.service

Service Status (Last Run):
○ backup-home.service - Automated Encrypted Home Directory Backup
     Loaded: loaded (~/.config/systemd/user/backup-home.service; static)
     Active: inactive (dead) since Mon 2026-09-21 01:54:25 CDT; 10h ago
    Process: 2005661 ExecStart=/home/rory/.local/bin/backup_script.sh backup (code=exited, status=0/SUCCESS)
```

#### View Recent Journal Logs
```bash
./backup_script.sh journal-timer 50
```

---

## Retention Policies & GFS Pruning

The backup suite supports two distinct pruning strategies for local external drives and cloud storage:

### 1. Count-Based Retention (Default)
Retains the most recent `N` backup archives on each destination and deletes older ones:
```bash
# In ~/.config/backup_script/config:
RETENTION_MODE="count"
CLOUD_KEEP_COUNT=10
LOCAL_KEEP_COUNT=10
```

### 2. Grandfather-Father-Son (GFS) Tiered Retention
Provides structured historical protection across days, weeks, months, and years without consuming massive storage:
- **Daily**: Retains the newest backup for each of the last `N` days (default: 7).
- **Weekly**: Retains the newest backup for each of the last `N` calendar weeks (default: 4).
- **Monthly**: Retains the newest backup for each of the last `N` months (default: 6).
- **Yearly**: Retains the newest backup for each of the last `N` years (default: 1).
- **Minimum Keep Floor (`RETENTION_MIN_KEEP`)**: Ensures the `N` most recent backups are never pruned, even if multiple backups were taken on the same day.

To activate GFS Tiered Retention, configure in `~/.config/backup_script/config`:
```bash
# Enable GFS tiered retention
RETENTION_MODE="tiered"       # or "gfs"

# Number of historical buckets to preserve
RETENTION_DAILY=7             # Last 7 days
RETENTION_WEEKLY=4            # Last 4 weeks
RETENTION_MONTHLY=6           # Last 6 months
RETENTION_YEARLY=1            # Last 1 year

# Optional safety floor (default: 0)
RETENTION_MIN_KEEP=0
```

---

## Exclusion Rules

To ensure compact archives and avoid backing up transient caches, sockets, and virtual disks, the suite employs three layers of exclusions:

1. **Built-in Exclusions (90+ patterns)**:
   - System and browser cache: `~/.cache`, `Crashpad`, `GPUCache`, `Code Cache`, `Service Worker`
   - Development dependencies: `node_modules`, `target`, `.venv`, `__pycache__`, `.cargo/registry`
   - Virtual machines & containers: `VirtualBox VMs`, `*.vdi`, `*.qcow2`, `~/.local/share/containers`
   - Trash & temporary files: `~/.local/share/Trash`, `*.tmp`, `*.bak`
2. **Per-Directory Tag Exclusion (`.nobackup`)**:
   - Place a file named `.nobackup` in any directory to completely exclude it and all its contents:
     ```bash
     touch ~/large_scratch_folder/.nobackup
     ```
3. **Recursive Ignore Files (`.backupignore`)**:
   - Works like `.gitignore` inside any directory to ignore specific subpaths.
4. **Custom Excludes File**:
   - Add custom patterns line-by-line to `~/.config/backup_script/excludes`.

---

## Disaster Recovery Bootstrapping

Every backup automatically mirrors:
1. `backup_script.sh` (the standalone script itself)
2. `RESTORE_README.txt` (a self-contained recovery cheatsheet)

both to your local drive (`Backups/`) and your cloud storage root.

### Restoring on a Bare Machine Without This Script

If you are on a completely clean machine with only stock GNU tools installed:

```bash
# 1. Download archive from cloud using rclone (or copy from external drive)
rclone copy "googledrive:backup/rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg" ./

# 2. Verify SHA-256 sidecar checksum
sha256sum -c "rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg.sha256"

# 3. Decrypt and decompress in a single pipeline
gpg --decrypt "rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg" \
  | zstd -d --memory=512MB \
  | tar -xvf - -C /target/restore/dir
```

#### Replaying Package Managers & System State

After archive extraction, the root of the restored directory contains exported system manifests:

- **APT (Debian / Ubuntu / Mint)**:
  ```bash
  sudo tar -xzvf apt_repos_keys.tar.gz -C /etc/apt/
  sudo apt update
  xargs -a apt_packages_manual.txt sudo apt install -y
  ```

- **DNF (Fedora / RHEL / Rocky / AlmaLinux)**:
  ```bash
  sudo tar -xzvf dnf_repos_keys.tar.gz -C /etc/
  sudo dnf clean all && sudo dnf makecache
  xargs -a dnf_packages_userinstalled.txt sudo dnf install -y --skip-broken
  ```

- **Desktop (dconf)**:
  ```bash
  dconf load / < dconf_settings.ini
  ```

---

## Configuration Reference

Key variables configurable in `~/.config/backup_script/config`:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `BACKUP_DIR` | `googledrive:backup/` | `rclone` remote path for cloud backups |
| `LOCAL_DRIVE_UUID` | *(none)* | Filesystem UUID of external backup drive partition |
| `LOCAL_BACKUP_SUBDIR` | `Backups` | Subdirectory on external partition for archives |
| `ENCRYPTION_MODE` | `symmetric` | Encryption method: `symmetric`, `asymmetric`, or `hybrid` |
| `PASSWORD_FILE` | `~/.config/backup_script/passphrase` | Path to symmetric encryption passphrase file |
| `GPG_RECIPIENT` | `""` | Recipient email or fingerprint for asymmetric GPG |
| `CLOUD_KEEP_COUNT` | `10` | Number of recent archives to keep on cloud remote (in `count` mode) |
| `LOCAL_KEEP_COUNT` | `10` | Number of recent archives to keep on local drive (in `count` mode) |
| `RETENTION_MODE` | `count` | Retention mode: `count` (fixed count) or `tiered` / `gfs` (Grandfather-Father-Son) |
| `RETENTION_DAILY` | `7` | Number of daily archives to retain in `tiered` mode |
| `RETENTION_WEEKLY` | `4` | Number of weekly archives to retain in `tiered` mode |
| `RETENTION_MONTHLY` | `6` | Number of monthly archives to retain in `tiered` mode |
| `RETENTION_YEARLY` | `1` | Number of yearly archives to retain in `tiered` mode |
| `RETENTION_MIN_KEEP` | `0` | Minimum newest archives to always preserve regardless of buckets |
| `ZSTD_LEVEL` | `6` | Zstd compression level (1-19, or up to 22 with ultra) |
| `ZSTD_LONG` | `27` | Long-distance matching window log (128MB window) |
| `RUNNING_APPS_ACTION` | `close` | Policy for running apps (`close`, `prompt`, `sync`, `ignore`) |
| `STREAM_CLOUD_RESTORE`| `auto` | Cloud restore streaming policy (`auto`, `true`, `false`) |
| `RESTORE_VERIFY_CHECKSUM`| `true` | Verify SHA-256 sidecar checksum before restoring |
| `GENERATE_MANIFEST` | `true` | Generate companion JSON manifest (`.manifest.json`) with metadata and inventory |
| `GENERATE_FILE_INDEX` | `true` | Generate companion file index (`.files.gz`) for fast zero-download search & listing |
| `ALERT_EMAIL` | `""` | Destination email address for failure alerts |
| `ALERT_ON_SUCCESS` | `false` | Send email notification on successful backup completion (`true`/`false`) |
| `SUCCESS_EMAIL` | `""` | Optional dedicated recipient email address for success notifications |
| `APT_PACKAGES_FILE` | `apt_packages_manual.txt` | Filename for exported manual APT packages |
| `APT_REPOS_FILE` | `apt_repos_keys.tar.gz` | Archive for APT repository sources and keyrings |
| `DNF_PACKAGES_FILE` | `dnf_packages_userinstalled.txt` | Filename for exported user-installed DNF packages |
| `DNF_REPOS_FILE` | `dnf_repos_keys.tar.gz` | Archive for DNF repository configurations and RPM GPG keys |

---

## License

Distributed under the terms of the [GNU General Public License v3.0](https://www.gnu.org/licenses/gpl-3.0.html).
Copyright (C) 2025–2026 Rory Mobley.
