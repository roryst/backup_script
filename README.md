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
  - [Archive Pinning & Retention Holds (`pin`, `unpin`, `pinned`)](#archive-pinning--retention-holds-pin-unpin-pinned)
  - [Viewing Archive Files (`list-files`)](#viewing-archive-files-list-files)
  - [Searching Files Across Backups (`find-file`)](#searching-files-across-backups-find-file)
  - [Inspecting Backup Manifests (`manifest`)](#inspecting-backup-manifests-manifest)
  - [Historical Trends & Analytics (`stats`)](#historical-trends--analytics-stats)
  - [Zero-Decryption Backup Drift Comparison (`diff-backups`)](#zero-decryption-backup-drift-comparison-diff-backups)
  - [Integrity Verification (`verify`)](#integrity-verification-verify)
  - [Restoring Data (`restore`)](#restoring-data-restore)
  - [System Packages & State Restore (`restore-system`)](#system-packages--state-restore-restore-system)
  - [Automated Scheduling (`systemd` Timer)](#automated-scheduling-systemd-timer)
  - [Testing Email Notifications (`test-email`)](#testing-email-notifications-test-email)
- [Retention Policies, GFS Pruning & Retention Holds](#retention-policies-gfs-pruning--retention-holds)
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
- **Resilient Network Streaming**: All `rclone cat` streaming operations (restores, verifications, index queries) incorporate multi-level retries (`--retries 3 --low-level-retries 10`), socket timeouts, and optional bandwidth throttling to resist transient socket drops.
- **Parallel Companion Uploads**: Companion sidecars (`.sha256`, `.manifest.json`, `.files.gz`, `.pinned`) and disaster recovery bootstrap files upload concurrently in parallel background threads, cutting round-trip API latency.
- **Resource Aware**: Dynamically caps decompression memory and enforces scratch space checks before archiving to prevent disk exhaustion.

### 🔄 Dual-Destination Synchronization & Retention
- **Hybrid Storage**: Concurrently synchronizes to local external partitions (auto-discovered via filesystem UUID) and cloud remotes via `rclone` (Google Drive, Backblaze B2, AWS S3, etc.).
- **Archive Pinning & Retention Holds**: Explicitly pin significant archives (e.g. prior to major system updates, migrations, or project milestones) locally and/or in the cloud with human-readable reason notes (`backup --pin "Pre-distro upgrade"` or `./backup_script.sh pin latest`). Pinned archives are completely immune from automated count-based pruning and GFS rotation, and do not consume regular retention quota slots.
- **Flexible Retention (Count-Based or GFS Tiered)**:
  - **Count-based** (default): Retains the `N` newest archives on local drive and cloud remote (default: 10).
  - **Grandfather-Father-Son (GFS) Tiered Retention**: Automatically maintains a timeline of daily, weekly, monthly, and yearly archives (default: 7 daily, 4 weekly, 6 monthly, 1 yearly) for months or years of recovery coverage without extra storage bloat.
- **Preserved Archive Management**: If network or remote connectivity fails, encrypted archives can be preserved locally to avoid data loss and re-uploaded later using `manage-preserved`.

### 🔍 Verification & Integrity
- **SHA-256 Sidecar Checksums**: Companion `.sha256` files accompany every archive, allowing sub-10-second bit-rot validation without needing to decrypt multi-gigabyte archives.
- **Inline Single-Pass Verification**: Verifies checksums on-the-fly during cloud streaming via named pipes and `tee`.
- **Full Tar Stream Validation**: Thoroughly validates encryption integrity and tar archive block structure without writing files to disk.

### 📦 System State Snapshots, Manifests & File Indexing
- **OS Environment Capture**: Exports lists of installed system packages (APT or DNF), package hold selections, Flatpaks, Pipx packages, enabled systemd user units, desktop `dconf` configurations, crontabs, and repository/GPG keyrings into the backup.
- **Modular System State Restore (`restore-system`)**: Dedicated subcommand that re-applies packages, repositories, desktop settings, systemd user units, and crontabs directly from unpacked directories or extracts manifests from an archive in a single pass without downloading or unpacking the entire home directory.
- **Interactive Archive File Browser**: Search and browse files inside archives using companion `.files.gz` indexes, multi-select items with number ranges (`1, 3-5`), and restore selectively without full downloads.
- **Companion JSON Manifests (`.manifest.json`)**: Instantly inspect archive metadata, compression ratios, package counts, and checksums without downloading or decrypting the archive.
- **Zero-Bandwidth Companion File Indexes (`.files.gz`)**: Captures full file tables during archive creation (`tar -vv --index-file`) with zero extra disk passes, enabling instant file search (`find-file`) and zero-download archive exploration (`list-files`) across all local and remote snapshots.
- **Zero-Decryption Backup Drift Comparison (`diff-backups`)**: Instantly diff any two backups (local or cloud) using companion index sidecars in seconds without decrypting or decompressing multi-gigabyte archives. Categorizes added, removed, and modified files with exact size deltas, net storage drift analytics, interactive filtering, and structured JSON/CSV exports.

### ⚙️ Reliability & Safety
- **Application Consistency Guard & Cgroup-Decoupled Relaunch**: Detects running database-heavy applications (Vivaldi, Chrome, Firefox, Thunderbird) and gracefully terminates them with `SIGTERM` and filesystem `sync` before archiving. When `RESTART_CLOSED_APPS=true` (or `--restart-apps`), the script automatically relaunches closed applications. Under systemd services, relaunches are prioritized into independent `app.slice` scopes via `systemd-run` alongside `KillMode=mixed`, preventing cgroup teardown crashes when the backup unit terminates.
- **Passphrase Memory Isolation**: Explicitly wipes plaintext passphrases from shell environment memory (`unset`) upon exit or signal interruption.
- **Pre-Restore Safety Backups**: Automatically generates a timestamped safety backup of the active user crontab (`~/.crontab.pre-restore.<timestamp>.bak`) prior to applying crontab restorations.
- **Concurrency Locking & Sleep Inhibition**: Uses kernel `flock` and `systemd-inhibit` to prevent overlapping runs and ensure systems do not suspend during backup or restoration.
- **Graceful Cleanup**: Traps `SIGINT`, `SIGTERM`, and script exit to clean up scratch paths, temporary statistics staging directories, and named pipes safely, and reliably relaunches any closed apps.
- **Standards-Compliant Failure, Success & Size Alerts**: Dispatches automated email alerts on backup failure, successful completion, or when an archive's size changes significantly (>= 15% increase or decrease by default) compared to the previous backup using local MTAs (`msmtp`, `mailx`), complete with `Message-ID` and MIME headers for optimal inbox deliverability.

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

#### Local External Drive (Optional)
If you wish to mirror backups to an external partition, locate its UUID using `lsblk -f` or `blkid`:
```bash
lsblk -f
```
Add the UUID to `~/.config/backup_script/config`:
```bash
LOCAL_DRIVE_UUID="your-drive-uuid-here"
LOCAL_BACKUP_SUBDIR="Backups"
```
*(Leave `LOCAL_DRIVE_UUID=""` to run in cloud-only mode).*

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

Compression & Applications:
 [  OK  ]  Apps Consistency             Auto-close mode (SIGTERM graceful termination with 10s timeout)
 [  OK  ]  Apps Relaunch                Enabled (closed applications will be automatically relaunched after archive creation)
 [ INFO ]  Active Applications          Currently running: vivaldi-bin
 [  OK  ]  Failure Email Alert          Configured: rorymobley5@gmail.com
 [  OK  ]  Mail Transport               MTA detected: msmtp (/usr/bin/msmtp)
 [  OK  ]  Email Sender                 rorymobley83@vivaldi.net (auto-detected from msmtp)
 [  OK  ]  Success Email Alert          Enabled: rorymobley5@gmail.com
 [  OK  ]  Size Change Alert            Enabled: rorymobley5@gmail.com (threshold: ±15%)

===============================================================================
  Diagnostic Summary
===============================================================================
  Total Checks : 41
  Passed       : 41
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
- `--pin [reason]`: Pin archive (retention hold) during backup creation, exempting it permanently from rotation.
- `--pin-reason, -pr <text>`: Specify custom explanation or tag when pinning an archive during backup (e.g. `--pin "Pre-distro upgrade"`).
- `--close-apps`: Gracefully terminate running target applications (default).
- `--prompt-apps`: Interactively prompt whether to close running applications.
- `--no-close-apps`: Skip closing open applications; flushes filesystem buffers via `sync`.
- `--restart-apps`, `-ra`: Automatically relaunch closed applications as soon as archive creation and checksum calculation complete (before cloud upload).
- `--no-restart-apps`, `-nra`: Do not relaunch closed applications after backup completes.
- `--verify-checksum`, `-vc`: Run fast SHA-256 bit-rot validation immediately after creation.
- `--no-verify`: Skip post-backup verification for faster completion.
- `--asymmetric [key]`: Encrypt with GPG public key.
- `--alert-email <email>`: Override failure and size alert notification address.
- `--alert-on-size-change`: Send email alert if backup size changes by >= threshold% compared to previous backup (default: on).
- `--no-alert-on-size-change`: Disable email alerts for backup size changes.
- `--size-change-threshold <pct>`: Percentage threshold for size change alerts (default: 15).
- `--email-on-success`: Send email notification upon successful backup completion.
- `--success-email <email>`: Specify recipient address for success notifications (enables success email).

---

### Listing Available Backups (`list`)

List all archives available on the local drive and cloud remote (pinned archives display with `[PINNED]` and their reason note):

```bash
$ ./backup_script.sh list
```

```text
Available local backups (/media/rory/bc3968af-d154-4167-b73c-5a172d2a25b8/Backups):
  7.6GB     2026-09-21 00:53:31  rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg [PINNED: Pre-Ubuntu 26.04 upgrade]
  7.6GB     2026-09-20 01:01:36  rory_home_backup_hp_2026-09-20_005952.tar.zst.gpg
  7.6GB     2026-09-19 00:49:26  rory_home_backup_hp_2026-09-19_004752.tar.zst.gpg
  7.8GB     2026-09-18 01:00:21  rory_home_backup_hp_2026-09-18_005852.tar.zst.gpg

Available cloud backups for this host (hp) on googledrive:backup/:
  7.6GB     2026-09-21 00:53:31  rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg [PINNED: Pre-Ubuntu 26.04 upgrade]
  7.6GB     2026-09-20 01:01:36  rory_home_backup_hp_2026-09-20_005952.tar.zst.gpg
  7.6GB     2026-09-19 00:49:26  rory_home_backup_hp_2026-09-19_004752.tar.zst.gpg
  7.8GB     2026-09-18 01:00:21  rory_home_backup_hp_2026-09-18_005852.tar.zst.gpg
```

---

### Archive Pinning & Retention Holds (`pin`, `unpin`, `pinned`)

Set a retention hold on an archive to prevent it from ever being pruned by automatic rotation (count-based or GFS tiered). Pinned archives remain permanently protected across local external drives and cloud remotes until explicitly unpinned.

#### Pinning an Archive (`pin`)
```bash
# Pin the latest backup across both local and cloud storage with default reason
$ ./backup_script.sh pin latest

# Pin the latest backup with an explanatory reason note
$ ./backup_script.sh pin latest --reason "Pre-Ubuntu 26.04 LTS upgrade snapshot"
# Or using positional syntax:
$ ./backup_script.sh pin latest "Milestone: v2.0 production release"

# Pin a specific historical archive
$ ./backup_script.sh pin rory_home_backup_hp_2026-09-18_005852.tar.zst.gpg --reason "Baseline configuration"

# Pin only to local storage (or only to cloud)
$ ./backup_script.sh pin latest --source local --reason "Offline cold storage"

# Interactively select an archive to pin (prompts with unpinned archives)
$ ./backup_script.sh pin

# Create a pinned backup directly during execution
$ ./backup_script.sh backup --pin "Pre-hardware replacement"
```

#### Releasing a Retention Hold (`unpin`)
```bash
# Interactively select and unpin an archive (lists all currently pinned archives)
$ ./backup_script.sh unpin

# Unpin a specific archive (prompts for confirmation)
$ ./backup_script.sh unpin rory_home_backup_hp_2026-09-18_005852.tar.zst.gpg

# Non-interactive / batch unpinning (auto-confirm)
$ ./backup_script.sh unpin rory_home_backup_hp_2026-09-18_005852.tar.zst.gpg --yes

# Unpin only on cloud remote (keeping local pin intact)
$ ./backup_script.sh unpin latest --source cloud --yes
```

#### Viewing Pinned Archives (`pinned` / `list-pinned`)
```bash
# Display a formatted table of all pinned archives, timestamps, and reasons
$ ./backup_script.sh pinned

# Output in JSON format for automated monitoring and reporting
$ ./backup_script.sh pinned --json
```

```text
===============================================================================
  Pinned Archives (Retention Hold Active)
===============================================================================
Local External Drive (/media/rory/bc3968af-d154-4167-b73c-5a172d2a25b8/Backups):
  7.6GB     rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg
            Pinned: 2026-10-04 16:30:00 | Reason: Pre-Ubuntu 26.04 LTS upgrade snapshot

Cloud Storage (googledrive:backup/):
  2026-10-04 16:30:00  rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg
            Status: Pinned on cloud remote
===============================================================================
Notice: Pinned archives are completely excluded from automatic rotation.
        Use './backup_script.sh unpin <archive>' to release a retention hold.
```

#### Interactive Management Menu (`manage-pinned`)
Launch the interactive pinning manager (also accessible from option 11 in the main menu):
```bash
$ ./backup_script.sh manage-pinned
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

# Search for literal text without evaluating regex metacharacters (e.g. brackets, dots)
$ ./backup_script.sh find-file "backup[1].log" -F
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

### Zero-Decryption Backup Drift Comparison (`diff-backups`)

Analyze differences, inspect storage growth, and detect file changes across any two backups **without downloading, decrypting, or decompressing multi-gigabyte archives**. By leveraging lightweight companion index sidecars (`.files.gz`), `diff-backups` parses 100,000+ files in under two seconds.

#### Command Syntax
```bash
./backup_script.sh diff-backups [archive1] [archive2] [options]
```
*(Aliases: `backup-diff`, `drift`)*

- If `[archive1]` and `[archive2]` are omitted, the script automatically compares the **two most recent backups**.
- The script automatically orders archives chronologically (oldest = baseline, newest = target).
- Companion indices are automatically discovered across local fast storage and cloud remotes (`rclone cat`).

#### Options & Flags

| Flag | Long Option | Description |
| :--- | :--- | :--- |
| `-s` | `--stat`, `--summary` | Display aggregate drift statistics and storage growth without file listing |
| `-a` | `--added` | Show only newly added files |
| `-d` | `--removed`, `--deleted` | Show only deleted / removed files |
| `-m` | `--modified` | Show only modified files |
| `-f` | `--filter <pattern>` | Filter file paths matching regex or substring pattern |
| | `--min-size <threshold>` | Only show files with size or delta $\ge$ threshold (e.g., `10M`, `500K`, `1G`) |
| | `--sort <path\|delta\|size>` | Sort file listing by path (default), size delta, or file size |
| | `--source <auto\|local\|cloud\|all>` | Select backup source locations |
| `-j` | `--json` | Output structured JSON for automation or auditing |
| | `--csv` | Output tabular CSV for spreadsheet analysis |
| `-i` | `--interactive` | Interactively select baseline and target archives from available snapshots |
| | `--no-pager` / `--pager` | Disable or force terminal pagination (`less -RFX`) |

---

#### 1. Quick Change Summary (`--stat`)
Compare the two newest backups to see high-level file count and storage deltas:

```bash
$ ./backup_script.sh diff-backups --stat
```

```text
===============================================================================
  BACKUP DRIFT & DIFFERENCE ANALYSIS
===============================================================================
  Baseline (Older) : rory_home_backup_hp_2026-10-04_005448.tar.zst.gpg (local)
  Target   (Newer) : rory_home_backup_hp_2026-10-05_004749.tar.zst.gpg (local)
-------------------------------------------------------------------------------
  Baseline Files   :     105844  (14.9 GB uncompressed)
  Target Files     :     105610  (14.8 GB uncompressed)
-------------------------------------------------------------------------------
  Summary of Changes:
    + Added Files    :       1556  (+579.9 MB)
    - Removed Files  :       1790  (-653.3 MB)
    ~ Modified Files :        554  (-228.3 KB net delta)
    = Unchanged Files:     103500  (13.8 GB)
  -----------------------------------------------------------------------------
    Net File Drift   :       -234 files
    Net Size Drift   :   -73.6 MB
===============================================================================
```

#### 2. Investigating Storage Spikes
Identify what files caused an unexpected backup size increase by isolating large size deltas:

```bash
# Show files whose size changed by at least 10MB, sorted by largest change
./backup_script.sh diff-backups --min-size 10M --sort delta
```

#### 3. Filtering by File Status & Path
Inspect specific configuration or document changes:

```bash
# List added files under ~/.config
./backup_script.sh diff-backups --added -f "\.config"

# List all removed files
./backup_script.sh diff-backups --removed
```

#### 4. Exporting Structured Reports for Automation
Export machine-readable drift metrics into JSON or CSV:

```bash
# JSON export
./backup_script.sh diff-backups --json > drift_report.json

# CSV export
./backup_script.sh diff-backups --csv > drift_report.csv
```

#### 5. Interactive Archive Selection
Interactively choose any two backups from local drive or cloud storage:

```bash
./backup_script.sh diff-backups -i
# Or pass specific snapshot dates or names:
./backup_script.sh diff-backups 2026-09-20 2026-10-05
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

The script supports full restores, granular pattern restores, and an interactive file browser powered by companion indexes.

#### 1. Interactive Menu Restore
```bash
./backup_script.sh restore
```
Guides you through selecting local or cloud backups, confirms target directories, and verifies checksums prior to extraction. When restoring, you can choose between full home restoration, manual pattern entry, or browsing files directly from the archive index.

#### 2. Interactive Archive File Browser (`--interactive` / `-i`)
Search, browse, and multi-select individual files or directories directly from the `.files.gz` companion index without downloading or decrypting multi-gigabyte archives:

```bash
# Launch interactive file browser on the latest backup
./backup_script.sh restore latest --interactive

# Specify custom restore destination with interactive browsing
./backup_script.sh restore latest -i --dest /tmp/restored
```

```text
===============================================================================
  Interactive Archive File Browser
===============================================================================
Archive : rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg (local)
Index   : rory_home_backup_hp_2026-09-21_005151.tar.zst.gpg.files.gz (187,421 files indexed)

Enter search pattern (wildcards/regex supported), or:
  'dirs'   to list top-level directories
  'list'   to show currently selected files
  'done'   to proceed with restoring selected files
  'cancel' to abort
Search query: *.pdf

Matching Files (showing 4 matches):
-------------------------------------------------------------------------------
  [1] Documents/Financial/taxes_2025.pdf (142KB)
  [2] Documents/Manuals/motherboard.pdf (4.2MB)
  [3] Downloads/receipt.pdf (48KB)
  [4] Work/Reports/quarterly_summary.pdf (1.8MB)
-------------------------------------------------------------------------------
Enter selection [numbers/ranges like '1, 3-4', 'all', or 'none']: 1, 4
Added 2 file(s) to selection (total selected: 2).
Search query: done
Restoring 2 selected file(s)...
```

#### 3. Selective Extraction via Pattern (`--pattern` / `-p`)
Restore specific files, directories, or wildcard patterns directly into the current directory or an alternate target:
```bash
# Restore specific .bashrc to current directory
./backup_script.sh restore latest --pattern ".bashrc" --dest ./recovered/

# Restore all PDFs from cloud backup without downloading the full archive
./backup_script.sh restore latest --pattern "*.pdf" --source cloud --stream
```

#### 4. Restoring to Alternate Directory
Always protect existing working trees by restoring to a staging directory first:
```bash
./backup_script.sh restore latest --dest /tmp/restore_test
```

---

### System Packages & State Restore (`restore-system`)

The standalone `restore-system` subcommand enables rapid recovery of your operating system configuration, package manifests, desktop settings, and scheduled tasks—either directly from an encrypted backup archive or from an existing directory.

When restoring from an archive, it performs a **fast, single-pass extraction of only the system state manifest files** into an isolated staging directory, eliminating the need to download or unpack full multi-gigabyte user data archives.

#### 1. Restore Directly from Backup Archive
```bash
# Restore system state from the latest available backup (interactive)
./backup_script.sh restore-system latest

# Non-interactive automated deployment from cloud archive
./backup_script.sh restore-system latest --source cloud --yes
```

#### 2. Restore from an Unpacked State Directory
If you have already restored your home directory or unpacked `~/.system_state`:
```bash
./backup_script.sh restore-system --dir ~/.system_state
```

#### 3. Subsystem-Targeted Restorations
You can selectively restore specific layers of the system:
```bash
# Reinstall only APT/DNF system packages and import repository GPG keys
./backup_script.sh restore-system latest --packages-only

# Reinstall only Flatpak remotes and user applications
./backup_script.sh restore-system latest --flatpaks-only

# Reinstall only Python CLI tools managed by pipx
./backup_script.sh restore-system latest --pipx-only

# Reload only GNOME / desktop dconf settings
./backup_script.sh restore-system latest --desktop-only

# Re-enable saved systemd user units
./backup_script.sh restore-system latest --systemd-only

# Restore user crontab jobs
./backup_script.sh restore-system latest --crontab-only
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

### Testing Email Notifications (`test-email`)

Verify mail delivery, sender reputation headers (`Message-ID`, `MIME-Version`), and recipient reachability directly from the command line or interactive menu:

```bash
# Send test notification to configured ALERT_EMAIL using auto-detected sender
$ ./backup_script.sh test-email

# Send test notification to an explicit recipient address
$ ./backup_script.sh test-email user@example.com

# Send test notification with custom recipient and sender addresses
$ ./backup_script.sh test-email user@example.com alerts@custom-domain.org
```

---

## Retention Policies, GFS Pruning & Retention Holds

The backup suite supports two distinct pruning strategies for local external drives and cloud storage, alongside an immutable retention hold system:

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

### 3. Archive Pinning & Retention Holds
Archive pinning allows you to place an explicit retention hold on any backup snapshot:
- **100% Rotation Immunity**: Pinned archives are detected via companion `<archive>.pinned` sidecars and are filtered out of candidate rotation pools *before* count or GFS calculations occur. Neither count-based rotation nor GFS tier pruning will ever delete a pinned archive.
- **Quota Preservation**: Pinned archives do not consume rotation slots (`LOCAL_KEEP_COUNT` or `CLOUD_KEEP_COUNT`). For example, if `CLOUD_KEEP_COUNT=10` and you pin 3 archives, you retain all 3 pinned archives plus your 10 newest rolling unpinned backups (13 total archives).
- **Companion Sidecar Metadata**: Pinned status is preserved alongside the archive via a lightweight companion file (`<archive>.pinned`):
  ```text
  Pinned: 2026-10-04 16:30:00
  User: rory
  Host: hp
  Reason: Pre-Ubuntu 26.04 upgrade snapshot
  ```
- **Dual-Destination Mirroring & Failure Preservation**: Pinned status mirrors concurrently across both local external drives and cloud storage. If a backup run cannot reach the cloud and is preserved in `~`, the `.pinned` companion is preserved locally and uploaded in parallel when connectivity is restored.
- **Hard Deletion Guard**: In addition to candidate pool filtering, both local and cloud rotation engines execute an explicit safety check immediately prior to any file deletion command (`rm` or `rclone deletefile`). If a companion `.pinned` sidecar exists, deletion is rejected.

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

> [!TIP]
> If `backup_script.sh` is mirrored or installed, you can replay all package manager manifests, Flatpaks, pipx packages, desktop settings, systemd user units, and crontabs automatically with a single command:
> ```bash
> # Restore state directly from an archive without unpacking the entire home directory:
> ./backup_script.sh restore-system latest
> 
> # Or point to an unpacked state directory:
> ./backup_script.sh restore-system --dir /target/restore/dir/.system_state
> ```

If performing manual bare-metal recovery without `backup_script.sh`, the exported manifests located in the archive root or `.system_state/` directory can be replayed manually:

- **APT (Debian / Ubuntu / Mint)**:
  ```bash
  sudo tar -xzvf apt_repos_keys.tar.gz -C /
  # Note: For legacy archives created with paths relative to /etc/apt, extract to -C /etc/apt/
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
| `RCLONE_DRIVE_CHUNK_SIZE` | `256M` | Chunk size and upload cutoff for cloud transfers (e.g. `64M`, `128M`, `256M`) |
| `RCLONE_BWLIMIT` | `""` | Optional bandwidth cap for cloud transfers (e.g. `10M`, `5M`, `500k`; empty = unlimited) |
| `RCLONE_STREAM_OPTS` | `(--retries 3 ...)` | Resilient transfer options for cloud streaming (`--retries 3 --low-level-retries 10 --contimeout 60s --timeout 30m`) |
| `LOCAL_DRIVE_UUID` | *(none)* | Filesystem UUID of external backup drive partition (leave empty for cloud-only mode) |
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
| `RESTART_CLOSED_APPS` | `false` | Automatically relaunch closed applications after archive creation completes (`true`/`false`) |
| `STREAM_CLOUD_RESTORE`| `auto` | Cloud restore streaming policy (`auto`, `true`, `false`) |
| `RESTORE_VERIFY_CHECKSUM`| `true` | Verify SHA-256 sidecar checksum before restoring |
| `ARCHIVE_LIST_PAGER` | `${PAGER:-less -FRX}` | Preferred pager command for viewing archive file listings |
| `GENERATE_MANIFEST` | `true` | Generate companion JSON manifest (`.manifest.json`) with metadata and inventory |
| `GENERATE_FILE_INDEX` | `true` | Generate companion file index (`.files.gz`) for fast zero-download search & listing |
| `ALERT_EMAIL` | `""` | Destination email address for failure and size change alerts |
| `ALERT_ON_SIZE_CHANGE` | `true` | Send email alert when backup size changes significantly compared to previous backup (`true`/`false`) |
| `SIZE_CHANGE_THRESHOLD` | `15` | Percentage threshold for triggering size change alerts (default: `15` for ±15%) |
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
