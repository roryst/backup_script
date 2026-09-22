#!/bin/bash

#==============================================================================
#
#          FILE:  backup_script.sh
#
#   DESCRIPTION:  An interactive utility for creating encrypted backups of the
#                 home directory (and apt/dnf, crontab, pipx, flatpaks)to cloud storage 
#                 via rclone and restoring from them. Now includes support for 
#                 local backups to a specific UUID-identified drive.
#                 This program is free software: you can redistribute it and/or modify
#                 it under the terms of the GNU General Public License as published by
#                 the Free Software Foundation, either version 3 of the License, or
#                 (at your option) any later version.
#
#                 This program is distributed in the hope that it will be useful,
#                 but WITHOUT ANY WARRANTY; without even the implied warranty of
#                 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#                 GNU General Public License for more details.
#
#                 You should have received a copy of the GNU General Public License
#                 along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
#                 Usage: ./backup_script.sh [backup|restore|verify|list|stats|manifest|manage-preserved|init-config|check-config|help]
#
#        AUTHOR:  Rory Mobley, rorymobley5@gmail.com
#       VERSION:  10.0
#==============================================================================

#------------------------------------------------------------------------------
#  Variable Definitions
#------------------------------------------------------------------------------

# Path to optional user configuration directory and file (chmod 700 / 600)
CONFIG_DIR="${CONFIG_DIR:-${HOME}/.config/backup_script}"
if [ -d "$CONFIG_DIR" ]; then
    _dir_perms=$(stat -c "%a" "$CONFIG_DIR" 2>/dev/null)
    if [ "$_dir_perms" != "700" ]; then
        echo "WARNING: Configuration directory '${CONFIG_DIR}' permissions are ${_dir_perms} (expected 700). Tightening to 700..." >&2
        chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    fi
fi

CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config}"
if [ -f "$CONFIG_FILE" ]; then
    _cfg_perms=$(stat -c "%a" "$CONFIG_FILE" 2>/dev/null)
    if [ "$_cfg_perms" != "600" ] && [ "$_cfg_perms" != "400" ]; then
        echo "WARNING: Configuration file '${CONFIG_FILE}' permissions are ${_cfg_perms} (expected 600). Tightening to 600..." >&2
        chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# The rclone remote and path where the backup is stored (ensure trailing slash)
BACKUP_DIR="${BACKUP_DIR:-googledrive:backup/}"
[[ "$BACKUP_DIR" != */ ]] && BACKUP_DIR="${BACKUP_DIR}/"

# Encryption Settings
# Encryption mode: 'symmetric' (passphrase, default), 'asymmetric' (public key only), or 'hybrid' (both)
ENCRYPTION_MODE="${ENCRYPTION_MODE:-symmetric}"

# GPG recipient key ID, fingerprint, or email address for asymmetric/hybrid encryption (e.g. "user@example.com")
GPG_RECIPIENT="${GPG_RECIPIENT:-}"

# GPG recipients array (can specify multiple recipients)
if [ -z "${GPG_RECIPIENTS+x}" ]; then
    if [ -n "$GPG_RECIPIENT" ]; then
        read -ra GPG_RECIPIENTS <<< "$GPG_RECIPIENT"
    else
        GPG_RECIPIENTS=()
    fi
elif ! declare -p GPG_RECIPIENTS 2>/dev/null | grep -q 'declare -a'; then
    read -ra GPG_RECIPIENTS <<< "${GPG_RECIPIENTS[*]}"
fi

# Path to secure configuration file containing the encryption password (chmod 600)
PASSWORD_FILE="${PASSWORD_FILE:-${CONFIG_DIR}/passphrase}"

# Encryption password loaded dynamically via get_encryption_password()
# Priority: 1. Environment variable (ENCRYPTION_PASSWORD or BACKUP_ENCRYPTION_PASSWORD)
#           2. Secure config file ($PASSWORD_FILE)
#           3. Interactive prompt
ENCRYPTION_PASSWORD="${ENCRYPTION_PASSWORD:-${BACKUP_ENCRYPTION_PASSWORD:-}}"

# The local directory to be backed up / restored to
SOURCE_DIR="${SOURCE_DIR:-$HOME}"

# Retention Settings
# Retention mode: 'count' (retain N newest archives, default) or 'tiered' / 'gfs' (Grandfather-Father-Son retention)
RETENTION_MODE="${RETENTION_MODE:-count}"
CLOUD_KEEP_COUNT="${CLOUD_KEEP_COUNT:-10}"
LOCAL_KEEP_COUNT="${LOCAL_KEEP_COUNT:-10}"

# Tiered / GFS Retention Settings (evaluated when RETENTION_MODE is 'tiered' or 'gfs')
RETENTION_DAILY="${RETENTION_DAILY:-7}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-4}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-6}"
RETENTION_YEARLY="${RETENTION_YEARLY:-1}"
RETENTION_MIN_KEEP="${RETENTION_MIN_KEEP:-0}"

# Local Backup & Disaster Recovery Mirroring Settings
LOCAL_DRIVE_UUID="${LOCAL_DRIVE_UUID:-bc3968af-d154-4167-b73c-5a172d2a25b8}"
LOCAL_BACKUP_SUBDIR="${LOCAL_BACKUP_SUBDIR:-Backups}"
MIRROR_SCRIPT_TO_LOCAL="${MIRROR_SCRIPT_TO_LOCAL:-true}"
MIRROR_SCRIPT_TO_CLOUD="${MIRROR_SCRIPT_TO_CLOUD:-true}"

# Running user and hostname for backup naming
CURRENT_USER="${CURRENT_USER:-${USER:-$(id -un)}}"
HOSTNAME=$(hostname | tr -d '[:space:]')
TARBALL_BASENAME="${TARBALL_BASENAME:-${CURRENT_USER}_home_backup_${HOSTNAME}}"

# The name of the file to store the crontab backup
CRONTAB_BACKUP_FILE="${CRONTAB_BACKUP_FILE:-crontab_backup.txt}"

# The name of the file to store the pipx packages specification
PIPX_SPEC_FILE="${PIPX_SPEC_FILE:-pipx-spec.json}"

# The names of the files to store the flatpak remotes and packages
FLATPAK_REMOTES_FILE="${FLATPAK_REMOTES_FILE:-flatpak_remotes.txt}"
FLATPAK_PACKAGES_FILE="${FLATPAK_PACKAGES_FILE:-flatpak_packages.txt}"

# The name of the file to store the enabled systemd user units
SYSTEMD_USER_UNITS_FILE="${SYSTEMD_USER_UNITS_FILE:-systemd_user_enabled_units.txt}"

# The name of the file to store the desktop (dconf) settings backup
DCONF_SETTINGS_FILE="${DCONF_SETTINGS_FILE:-dconf_settings.ini}"

# The name of the file to store the list of manually installed APT packages
APT_PACKAGES_FILE="${APT_PACKAGES_FILE:-apt_packages_manual.txt}"

# The name of the archive to store APT repository sources and signing keyrings
APT_REPOS_FILE="${APT_REPOS_FILE:-apt_repos_keys.tar.gz}"

# The name of the file to store the list of user-installed DNF packages
DNF_PACKAGES_FILE="${DNF_PACKAGES_FILE:-dnf_packages_userinstalled.txt}"

# The name of the archive to store DNF repository sources and RPM GPG keys
DNF_REPOS_FILE="${DNF_REPOS_FILE:-dnf_repos_keys.tar.gz}"

# Dedicated scratch directory for staging temporary archives during backup/restore.
# Located in SOURCE_DIR to leverage the large filesystem, and excluded via EXCLUDE_PATTERNS.
SCRATCH_DIR="${SCRATCH_DIR:-${SOURCE_DIR}/.backup_scratch}"

# Minimum free disk space (in GB) required in SCRATCH_DIR before archiving (can be overridden via environment)
MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-15}"

# The log file for the backup/restore operation
LOG_FILE="${LOG_FILE:-${SOURCE_DIR}/backup_${CURRENT_USER}.log}"

# The lockfile to prevent multiple instances from running.
# Determines path dynamically: prefers /run/user/<UID> if present and writable, even if XDG_RUNTIME_DIR is not exported
_user_runtime="/run/user/$(id -u 2>/dev/null || echo 1000)"
if [ -d "$_user_runtime" ] && [ -w "$_user_runtime" ]; then
    _default_lock_dir="$_user_runtime"
else
    _default_lock_dir="${XDG_RUNTIME_DIR:-/tmp}"
fi
LOCK_FILE="${LOCK_FILE:-${_default_lock_dir}/backup_${CURRENT_USER}.lock}"

# Rclone chunk size and upload cutoff for cloud transfers (default: 256M)
RCLONE_DRIVE_CHUNK_SIZE="${RCLONE_DRIVE_CHUNK_SIZE:-256M}"

# Optional bandwidth limit for rclone cloud transfers (e.g. "10M", "5M", default: unlimited)
RCLONE_BWLIMIT="${RCLONE_BWLIMIT:-}"

# Zstandard compression level (default: 6, max: 22 with ultra)
ZSTD_LEVEL="${ZSTD_LEVEL:-6}"

# Enable Zstandard Long Distance Matching (LDM) for improved compression of large/repetitive files.
# Set to an integer window log (e.g. 27 for 128MB window), true (uses default 27), or false to disable.
ZSTD_LONG="${ZSTD_LONG:-27}"

# Zstandard decompression memory limit (default: 512MB).
# Automatically scaled if ZSTD_LONG window log requires more buffer memory.
ZSTD_DECOMPRESS_MEMORY="${ZSTD_DECOMPRESS_MEMORY:-512MB}"
if [[ "$ZSTD_LONG" =~ ^[0-9]+$ ]]; then
    if [ "$ZSTD_LONG" -ge 31 ] && [ "$ZSTD_DECOMPRESS_MEMORY" = "512MB" ]; then
        ZSTD_DECOMPRESS_MEMORY="4096MB"
    elif [ "$ZSTD_LONG" -ge 30 ] && [ "$ZSTD_DECOMPRESS_MEMORY" = "512MB" ]; then
        ZSTD_DECOMPRESS_MEMORY="2048MB"
    elif [ "$ZSTD_LONG" -ge 29 ] && [ "$ZSTD_DECOMPRESS_MEMORY" = "512MB" ]; then
        ZSTD_DECOMPRESS_MEMORY="1024MB"
    fi
fi

# Confine backup archiving to a single filesystem (tar --one-file-system).
# Set to false if you have subvolumes (e.g. Btrfs) or separate mount points within SOURCE_DIR that should be included.
TAR_ONE_FILE_SYSTEM="${TAR_ONE_FILE_SYSTEM:-true}"

# Continue backup archiving without fatal aborts if unreadable files or directories are encountered (tar --ignore-failed-read).
TAR_IGNORE_FAILED_READ="${TAR_IGNORE_FAILED_READ:-true}"

# Stream cloud archives directly during restore using rclone cat without staging to scratch space.
# Options: 'auto' (adaptive: stages when scratch space permits; streams directly with inline hash check when constrained; default),
#          'true' (force direct streaming), 'false' (force staging to scratch directory).
STREAM_CLOUD_RESTORE="${STREAM_CLOUD_RESTORE:-auto}"

# Verify SHA-256 sidecar checksum prior to restoring archive.
# When enabled ('true', '1', 'local', 'cloud', or 'all'), validates archive integrity
# against <archive>.sha256 sidecar before beginning decryption and extraction.
# Prevents corrupted archives or bit-rot from overwriting destination files.
# Can be overridden per-run via 'restore --verify-checksum' (-vc) or '--no-verify-checksum'.
RESTORE_VERIFY_CHECKSUM="${RESTORE_VERIFY_CHECKSUM:-true}"

# Automatically verify archive integrity immediately following a successful backup.
# When enabled ('checksum', 'quick', 'checksum-local', 'checksum-cloud', 'local', 'cloud', true, or 1),
# executes integrity verification on the newly created archive.
# Can also be triggered per-run via 'backup --verify [auto|local|cloud]' or 'backup --verify-checksum'.
AUTO_VERIFY_BACKUP="${AUTO_VERIFY_BACKUP:-local}"

# Preferred pager for viewing archive file listings in interactive terminals.
# Set to an empty string ("") to disable pagination by default.
ARCHIVE_LIST_PAGER="${ARCHIVE_LIST_PAGER:-${PAGER:-less -FRX}}"

# Generate lightweight companion JSON manifest (.manifest.json) alongside archive and checksum.
GENERATE_MANIFEST="${GENERATE_MANIFEST:-true}"

# Lifecycle hook commands and directory for pre/post backup triggers
# Supports executable scripts (${HOOKS_DIR}/pre-backup.sh, ${HOOKS_DIR}/post-backup.sh)
# and/or inline shell commands (PRE_BACKUP_COMMAND, POST_BACKUP_COMMAND).
HOOKS_DIR="${HOOKS_DIR:-${CONFIG_DIR}}"
PRE_BACKUP_COMMAND="${PRE_BACKUP_COMMAND:-}"
POST_BACKUP_COMMAND="${POST_BACKUP_COMMAND:-}"

# Action to take when applications with active databases (browsers, email clients)
# are running during backup pre-flight checks:
#   'close'   - Gracefully terminate running target applications (SIGTERM) and wait for settlement. (default)
#   'prompt'  - In interactive terminals, prompt user whether to close apps, sync & proceed, or abort.
#               In non-interactive runs (cron, systemd timer), falls back to 'sync'.
#   'sync'    - Do not terminate applications; log detected apps and flush OS/disk buffers with sync.
#   'ignore'  - Skip running application detection and buffer flushing entirely.
RUNNING_APPS_ACTION="${RUNNING_APPS_ACTION:-close}"

# List of process names considered sensitive to concurrent file modifications (browsers, email, etc.)
DEFAULT_TARGET_RUNNING_APPS=("chrome" "chromium" "google-chrome" "firefox" "firefox-bin" "vivaldi" "vivaldi-bin" "brave" "opera" "thunderbird")
if [ -z "${TARGET_RUNNING_APPS+x}" ]; then
    TARGET_RUNNING_APPS=("${DEFAULT_TARGET_RUNNING_APPS[@]}")
fi

# Timeout (in seconds) to wait for applications to gracefully exit after SIGTERM (when action is 'close')
RUNNING_APPS_SETTLE_TIMEOUT="${RUNNING_APPS_SETTLE_TIMEOUT:-10}"

# Configurable recipient email address to notify if backup operations fail.
# Leave empty or unset to disable failure email alerts.
ALERT_EMAIL="${ALERT_EMAIL:-${NOTIFICATION_EMAIL:-}}"

# Configurable sender email address for outgoing failure alert emails.
# If unset, auto-detects from msmtp account configuration or falls back to user@host.
ALERT_FROM="${ALERT_FROM:-${NOTIFICATION_FROM:-${MAIL_FROM:-}}}"

# Mail delivery agent command ('auto', 'msmtp', 'mailx', 'mail', or custom command path)
MAIL_COMMAND="${MAIL_COMMAND:-auto}"

# Flag to prevent duplicate email alerts during a single script run
EMAIL_ALERT_SENT=0

# Script version identifier
SCRIPT_VERSION="10.0.0"

# Path to this script for self-invocation
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"

# Staging directory for system state exports before archiving (inside SCRATCH_DIR)
SYSTEM_STATE_STAGING_DIR="${SCRATCH_DIR}/.system_state"

# Flags to manage lock ownership and temporary file tracking
LOCK_HELD=0
SCRATCH_FILES_CREATED=0
CURRENT_METADATA_STAGING_DIR=""
CURRENT_TEMP_ARCHIVE=""
CURRENT_ENCRYPTED_ARCHIVE=""
CURRENT_SHA256_FILE=""
CURRENT_MANIFEST_FILE=""
CURRENT_LOCAL_TEMP_ARCHIVE=""
CURRENT_LOCAL_TEMP_SHA256=""
CURRENT_LOCAL_TEMP_MANIFEST=""
CURRENT_VERIFY_TMP_DIR=""
CURRENT_BACKUP_TMP_DIR=""
CURRENT_RESTORE_TMP_DIR=""
EXPECTED_RESTORE_SHA256=""

# Flag to manage log file overwriting on the first log event.
LOG_INITIALIZED=0

# Flag to preserve the encrypted archive if upload fails
PRESERVE_ARCHIVE="${PRESERVE_ARCHIVE:-false}"

# Default list of directories and patterns to exclude from the backup, relative to SOURCE_DIR.
DEFAULT_EXCLUDE_PATTERNS=(
    "./.backup_scratch"
    "./tmp"
    "./cache"
    "./.cache"
    "./Downloads"
    "./external_drive"
    "./sensitive"
    "./googledrive"
    "./.config/google-chrome"
    "./.config/chromium"
    "./.config/vivaldi-snapshot"
    "./.mozilla"
    # Browser transient state, internal caches, and IPC/process locks (Vivaldi & Chromium)
    "SingletonLock"
    "*/SingletonLock"
    "SingletonCookie"
    "*/SingletonCookie"
    "SingletonSocket"
    "*/SingletonSocket"
    "Crashpad"
    "*/Crashpad"
    "GPUCache"
    "*/GPUCache"
    "Code Cache"
    "*/Code Cache"
    "*/Service Worker/CacheStorage"
    "*/Service Worker/ScriptCache"
    "./.var/app/*/cache"
    "./.local/share/Trash"
    "./.local/share/flatpak/app"
    "./.local/share/flatpak/runtime"
    "./.local/share/flatpak/repo"
    "./.local/share/flatpak/.changed"
    "./.var/app/*/data/tmp"
    "./.local/share/pipx/venvs"
    # Games and container runtimes
    "./.local/share/Steam"
    "./.steam"
    "./.local/share/containers"
    # Developer build artifacts and package caches
    # Rust
    "./.rustup"
    "./.cargo/registry"
    "./.cargo/git"
    "target"
    "*/target"
    # JavaScript / TypeScript / Node / Web
    "node_modules"
    "*/node_modules"
    "./.npm"
    "./.yarn/cache"
    "./.pnpm-store"
    ".next/cache"
    "*/.next/cache"
    ".nuxt"
    "*/.nuxt"
    ".turbo"
    "*/.turbo"
    # Python
    "__pycache__"
    "*.pyc"
    ".venv"
    "*/.venv"
    ".pytest_cache"
    "*/.pytest_cache"
    ".mypy_cache"
    "*/.mypy_cache"
    ".ruff_cache"
    "*/.ruff_cache"
    ".tox"
    # JVM (Gradle & Maven)
    "./.gradle/caches"
    "./.gradle/wrapper"
    "./.m2/repository"
    # Go
    "./go/pkg/mod"
    # C / C++ / CMake
    "./.ccache"
    "CMakeFiles"
    "*/CMakeFiles"
    "CMakeCache.txt"
    "./linsw"
    "./Videos"
    # Virtualization & VM Disk Images
    "./.local/share/gnome-boxes/images"
    "./VirtualBox VMs"
    "*.qcow2"
    "*.vdi"
    "*.vmdk"
    "*.raw"
    # Temporary files and external trash
    "*.tmp"
    "*.log"
    "*.bak"
    "*/.Trash-*"
    "./.Trash-*"
    # Exclude the backup files themselves
    "./${TARBALL_BASENAME}_*.tar.*"
    "./${TARBALL_BASENAME}_*.tar.*.gpg"
    "./${TARBALL_BASENAME}_*.sha256"
    "./${TARBALL_BASENAME}_*.manifest.json"
)

# Initialize EXCLUDE_PATTERNS with defaults if not already explicitly defined in config
if [ -z "${EXCLUDE_PATTERNS+x}" ]; then
    EXCLUDE_PATTERNS=("${DEFAULT_EXCLUDE_PATTERNS[@]}")
fi

# Append additional excludes if provided in config or environment
if [ -n "${ADDITIONAL_EXCLUDES+x}" ] && [ ${#ADDITIONAL_EXCLUDES[@]} -gt 0 ]; then
    EXCLUDE_PATTERNS+=("${ADDITIONAL_EXCLUDES[@]}")
fi

# Support an optional external exclude file (e.g. ~/.config/backup_script/excludes)
EXCLUDES_FILE="${EXCLUDES_FILE:-${CONFIG_DIR}/excludes}"
if [ -f "$EXCLUDES_FILE" ]; then
    while IFS= read -r _pattern || [ -n "$_pattern" ]; do
        [[ -z "$_pattern" || "$_pattern" =~ ^[[:space:]]*# ]] && continue
        EXCLUDE_PATTERNS+=("$_pattern")
    done < "$EXCLUDES_FILE"
fi

# Ensure that if a custom SCRATCH_DIR is inside SOURCE_DIR, its relative path is excluded
if [[ "${SCRATCH_DIR}" == "${SOURCE_DIR}/"* ]]; then
    _custom_scratch_rel="./${SCRATCH_DIR#"${SOURCE_DIR}/"}"
    EXCLUDE_PATTERNS+=("${_custom_scratch_rel}")
fi

# Per-directory exclusion tags (directories containing any of these files will be completely excluded from backup)
# Uses GNU tar's native --exclude-tag-all=<filename>
ENABLE_EXCLUDE_TAGS="${ENABLE_EXCLUDE_TAGS:-true}"
if [ -z "${EXCLUDE_TAG_FILES+x}" ]; then
    EXCLUDE_TAG_FILES=(".nobackup")
elif ! declare -p EXCLUDE_TAG_FILES 2>/dev/null | grep -q 'declare -a'; then
    read -ra EXCLUDE_TAG_FILES <<< "${EXCLUDE_TAG_FILES[*]}"
fi

# Per-directory recursive ignore pattern files (gitignore-style patterns evaluated recursively within directory)
# Uses GNU tar's native --exclude-ignore-recursive=<filename>
ENABLE_EXCLUDE_IGNORE="${ENABLE_EXCLUDE_IGNORE:-true}"
if [ -z "${EXCLUDE_IGNORE_FILES+x}" ]; then
    EXCLUDE_IGNORE_FILES=(".backupignore")
elif ! declare -p EXCLUDE_IGNORE_FILES 2>/dev/null | grep -q 'declare -a'; then
    read -ra EXCLUDE_IGNORE_FILES <<< "${EXCLUDE_IGNORE_FILES[*]}"
fi

#------------------------------------------------------------------------------
#  Function Definitions
#------------------------------------------------------------------------------

#---
#   FUNCTION:  get_encryption_password()
#  DESCRIPTION:  Loads the encryption password dynamically following fallback order:
#                1. Environment variable (ENCRYPTION_PASSWORD or BACKUP_ENCRYPTION_PASSWORD)
#                2. Systemd encrypted credentials ($CREDENTIALS_DIRECTORY)
#                3. Secret Service / GNOME Keyring via secret-tool
#                4. Secure config file (chmod 600, default: ~/.config/backup_script/passphrase)
#                5. Interactive prompt (with confirmation if creating a backup)
#---
get_encryption_password() {
    local action="${1:-}"

    # 1. Check environment variables
    if [ -n "${ENCRYPTION_PASSWORD:-}" ] && [ "$ENCRYPTION_PASSWORD" != "EnterPasswordHere" ]; then
        return 0
    elif [ -n "${BACKUP_ENCRYPTION_PASSWORD:-}" ] && [ "$BACKUP_ENCRYPTION_PASSWORD" != "EnterPasswordHere" ]; then
        ENCRYPTION_PASSWORD="$BACKUP_ENCRYPTION_PASSWORD"
        return 0
    fi

    # 2. Check systemd encrypted credentials if running under a systemd service
    if [ -n "${CREDENTIALS_DIRECTORY:-}" ]; then
        local _cred_candidate _cred_val
        for _cred_candidate in "backup_passphrase" "backup_password" "passphrase" "encryption_password"; do
            if [ -f "${CREDENTIALS_DIRECTORY}/${_cred_candidate}" ] && [ -r "${CREDENTIALS_DIRECTORY}/${_cred_candidate}" ]; then
                _cred_val=$(< "${CREDENTIALS_DIRECTORY}/${_cred_candidate}")
                if [ -n "$_cred_val" ] && [ "$_cred_val" != "EnterPasswordHere" ]; then
                    ENCRYPTION_PASSWORD="$_cred_val"
                    return 0
                fi
            fi
        done
    fi

    # 3. Check Secret Service / GNOME Keyring via secret-tool if installed
    if command -v secret-tool &>/dev/null; then
        local _sec_val
        _sec_val=$(secret-tool lookup service backup_script user "$CURRENT_USER" 2>/dev/null || true)
        if [ -n "$_sec_val" ] && [ "$_sec_val" != "EnterPasswordHere" ]; then
            ENCRYPTION_PASSWORD="$_sec_val"
            return 0
        fi
    fi

    # 4. Check secure config file
    if [ -f "$PASSWORD_FILE" ]; then
        local pwd_dir dir_perms file_perms
        pwd_dir=$(dirname "$PASSWORD_FILE")
        if [ -d "$pwd_dir" ] && [ "$pwd_dir" = "${CONFIG_DIR:-${HOME}/.config/backup_script}" ]; then
            dir_perms=$(stat -c "%a" "$pwd_dir" 2>/dev/null)
            if [ "$dir_perms" != "700" ]; then
                echo "WARNING: Configuration directory '${pwd_dir}' permissions are ${dir_perms} (expected 700). Tightening to 700..." >&2
                chmod 700 "$pwd_dir" 2>/dev/null || true
            fi
        fi
        file_perms=$(stat -c "%a" "$PASSWORD_FILE" 2>/dev/null)
        if [ "$file_perms" != "600" ] && [ "$file_perms" != "400" ]; then
            echo "WARNING: Password file '${PASSWORD_FILE}' permissions are ${file_perms} (expected 600). Tightening to 600..." >&2
            chmod 600 "$PASSWORD_FILE" 2>/dev/null || true
        fi
        ENCRYPTION_PASSWORD=$(< "$PASSWORD_FILE")
        if [ -n "$ENCRYPTION_PASSWORD" ] && [ "$ENCRYPTION_PASSWORD" != "EnterPasswordHere" ]; then
            return 0
        fi
    fi

    # 3. Interactive prompt fallback
    if [ -t 0 ]; then
        if [ "$action" = "backup" ]; then
            local pass1 pass2
            read -s -r -p "Enter backup encryption password: " pass1
            echo
            read -s -r -p "Confirm backup encryption password: " pass2
            echo
            if [ "$pass1" != "$pass2" ]; then
                echo "ERROR: Passwords do not match. Aborting backup." >&2
                return 1
            fi
            ENCRYPTION_PASSWORD="$pass1"
        else
            read -s -r -p "Enter backup encryption password: " ENCRYPTION_PASSWORD
            echo
        fi

        if [ -z "$ENCRYPTION_PASSWORD" ] || [ "$ENCRYPTION_PASSWORD" = "EnterPasswordHere" ]; then
            echo "ERROR: Password cannot be empty or default placeholder." >&2
            return 1
        fi
        return 0
    else
        echo "ERROR: Encryption password not found. Set ENCRYPTION_PASSWORD or store it in ${PASSWORD_FILE}." >&2
        log_message "ERROR: Encryption password not found in environment or ${PASSWORD_FILE} during non-interactive run."
        return 1
    fi
}

#---
#   FUNCTION:  validate_gpg_recipients()
#  DESCRIPTION:  Validates that configured GPG recipients exist in the public keyring
#                and have valid encryption capabilities.
#---
# shellcheck disable=SC2120
validate_gpg_recipients() {
    local -a recipients=("${@}")
    if [ ${#recipients[@]} -eq 0 ]; then
        if [ ${#GPG_RECIPIENTS[@]} -gt 0 ]; then
            recipients=("${GPG_RECIPIENTS[@]}")
        elif [ -n "$GPG_RECIPIENT" ]; then
            read -ra recipients <<< "$GPG_RECIPIENT"
        fi
    fi

    if [ ${#recipients[@]} -eq 0 ]; then
        local ERROR_MSG="ERROR: Asymmetric/hybrid encryption mode requires at least one GPG recipient (set GPG_RECIPIENT in config or use -r/--recipient)."
        log_message "$ERROR_MSG"
        echo "$ERROR_MSG" >&2
        return 1
    fi

    for r in "${recipients[@]}"; do
        [ -z "$r" ] && continue
        if ! gpg --batch --list-keys "$r" &>/dev/null; then
            local ERROR_MSG="ERROR: GPG recipient key '$r' not found in public keyring. Import with 'gpg --import' or check key ID."
            log_message "$ERROR_MSG"
            echo "$ERROR_MSG" >&2
            return 1
        fi
    done
    return 0
}

#---
#   FUNCTION:  detect_archive_encryption()
#  DESCRIPTION:  Inspects an encrypted archive file or stream to identify encryption type:
#                'asymmetric', 'symmetric', 'hybrid', or 'unknown'.
#---
detect_archive_encryption() {
    local source_type="$1"  # "file" or "cloud"
    local target="$2"       # file path or cloud object name
    local packet_info=""

    if [ "$source_type" = "file" ]; then
        if [ -f "$target" ]; then
            packet_info=$(head -c 65536 "$target" 2>/dev/null | gpg --batch --list-packets 2>&1 || true)
        fi
    elif [ "$source_type" = "cloud" ]; then
        packet_info=$(rclone cat --head 65536 "${BACKUP_DIR}${target}" 2>/dev/null | gpg --batch --list-packets 2>&1 || true)
    fi

    local has_sym=false has_pub=false
    if grep -q -E "(:symkey enc packet|encrypted with [0-9]+ passphrase)" <<< "$packet_info"; then
        has_sym=true
    fi
    if grep -q -E "(:pubkey enc packet|encrypted with .* key)" <<< "$packet_info"; then
        has_pub=true
    fi

    if [ "$has_sym" = true ] && [ "$has_pub" = true ]; then
        echo "hybrid"
    elif [ "$has_pub" = true ]; then
        echo "asymmetric"
    elif [ "$has_sym" = true ]; then
        echo "symmetric"
    else
        echo "unknown"
    fi
}

#---
#   FUNCTION:  log_message()
#  DESCRIPTION:  Logs a message. Overwrites the log on the first call of a
#                script run, and appends for all subsequent calls.
#---
log_message() {
    if [ "$LOG_INITIALIZED" -eq 0 ]; then
        if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
            mv -f "$LOG_FILE" "${LOG_FILE}.prev" 2>/dev/null || true
        fi
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" > "$LOG_FILE"
        LOG_INITIALIZED=1
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    fi
}

#---
#   FUNCTION:  format_duration()
#  DESCRIPTION:  Formats a duration in seconds into a human-readable string (e.g. 1h 23m 45s).
#---
format_duration() {
    local duration_secs="${1:-0}"
    local hours=$(( duration_secs / 3600 ))
    local minutes=$(( (duration_secs % 3600) / 60 ))
    local seconds=$(( duration_secs % 60 ))
    if [ "$hours" -gt 0 ]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [ "$minutes" -gt 0 ]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

#---
#   FUNCTION:  send_failure_email()
#  DESCRIPTION:  Dispatches an automated email notification with detailed failure context
#                and diagnostic log snippets to ALERT_EMAIL. Includes duplicate suppression.
#---
send_failure_email() {
    local error_title="${1:-Backup Operation Failed}"
    local error_msg="${2:-An unexpected error occurred during the backup process.}"
    local recipient="${ALERT_EMAIL:-${NOTIFICATION_EMAIL:-}}"

    if [ -z "$recipient" ]; then
        return 0
    fi

    if [ "${EMAIL_ALERT_SENT:-0}" -eq 1 ]; then
        log_message "Failure alert email already sent for this run. Suppressing duplicate."
        return 0
    fi

    log_message "Dispatching failure alert email to ${recipient}..."

    local timestamp_str
    timestamp_str=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local subject="[BACKUP FAILED] ${HOSTNAME}: ${error_title} (${timestamp_str})"

    # Resolve sender email address:
    # 1. Explicitly configured ALERT_FROM (or NOTIFICATION_FROM / MAIL_FROM)
    # 2. Auto-detect from msmtp account configuration (avoids SMTP 550 forged sender errors)
    # 3. Fallback to local user@hostname
    local sender="${ALERT_FROM:-${NOTIFICATION_FROM:-${MAIL_FROM:-}}}"
    if [ -z "$sender" ] && command -v msmtp &>/dev/null; then
        local detected_from
        detected_from=$(msmtp -P -a default </dev/null 2>/dev/null | awk -F' = ' '$1 == "from" && $2 != "(not set)" {print $2; exit}')
        if [ -n "$detected_from" ]; then
            sender="$detected_from"
        fi
    fi
    if [ -z "$sender" ]; then
        sender="${CURRENT_USER}@${HOSTNAME}"
    fi

    # Extract recent log entries (last 35 lines)
    local log_snippet=""
    if [ -f "$LOG_FILE" ]; then
        log_snippet=$(tail -n 35 "$LOG_FILE" 2>/dev/null)
    fi

    # Extract any rclone error entries if present
    local rclone_snippet=""
    local rclone_log="${LOG_FILE}.rclone"
    if [ -f "$rclone_log" ]; then
        rclone_snippet=$(grep -E "(ERROR|Failed to|fatal)" "$rclone_log" 2>/dev/null | tail -n 15)
        [ -z "$rclone_snippet" ] && rclone_snippet=$(tail -n 15 "$rclone_log" 2>/dev/null)
    fi

    # Build plain-text email message
    local email_body
    email_body=$(cat << EOF
================================================================================
  AUTOMATED BACKUP FAILURE NOTIFICATION
================================================================================
Host:             ${HOSTNAME}
User:             ${CURRENT_USER}
Date & Time:      ${timestamp_str}
Source Directory: ${SOURCE_DIR}
Cloud Remote:     ${BACKUP_DIR}
Script Version:   ${SCRIPT_VERSION}
Log File:         ${LOG_FILE}
================================================================================

FAILURE DETAILS:
  Event:   ${error_title}
  Message: ${error_msg}

===============================================================================
RECENT APPLICATION LOG (${LOG_FILE}):
===============================================================================
${log_snippet:-No log entries available.}
EOF
)

    if [ -n "$rclone_snippet" ]; then
        email_body="${email_body}

================================================================================
RECENT RCLONE TRANSFER LOG (${rclone_log}):
================================================================================
${rclone_snippet}"
    fi

    email_body="${email_body}

================================================================================
This notification was automatically generated by backup_script.sh on ${HOSTNAME}.
================================================================================
"

    local send_rc=0
    local mailer="${MAIL_COMMAND:-auto}"

    if [ "$mailer" = "auto" ]; then
        if command -v msmtp &>/dev/null; then
            mailer="msmtp"
        elif command -v mailx &>/dev/null; then
            mailer="mailx"
        elif command -v mail &>/dev/null; then
            mailer="mail"
        else
            mailer="none"
        fi
    fi

    case "$mailer" in
        msmtp)
            local msmtp_args=()
            if [ -n "$sender" ] && [[ "$sender" =~ @ ]]; then
                msmtp_args+=(-f "$sender")
            fi
            {
                printf "To: %s\n" "$recipient"
                printf "From: %s\n" "$sender"
                printf "Subject: %s\n" "$subject"
                printf "Date: %s\n" "$(date -R 2>/dev/null || date)"
                printf "Auto-Submitted: auto-generated\n"
                printf "Content-Type: text/plain; charset=UTF-8\n"
                printf "\n%s\n" "$email_body"
            } | msmtp "${msmtp_args[@]}" "$recipient" 2>> "$LOG_FILE" || send_rc=$?
            ;;
        mailx)
            if [ -n "$sender" ] && [[ "$sender" =~ @ ]]; then
                printf "%s\n" "$email_body" | mailx -s "$subject" -r "$sender" "$recipient" 2>> "$LOG_FILE" || send_rc=$?
            else
                printf "%s\n" "$email_body" | mailx -s "$subject" "$recipient" 2>> "$LOG_FILE" || send_rc=$?
            fi
            ;;
        mail)
            printf "%s\n" "$email_body" | mail -s "$subject" "$recipient" 2>> "$LOG_FILE" || send_rc=$?
            ;;
        none)
            log_message "WARNING: No mail agent found (msmtp, mailx, mail not installed). Failure email not sent."
            echo "WARNING: Could not send alert email: no mail agent found (msmtp, mailx, mail)." >&2
            return 1
            ;;
        *)
            printf "%s\n" "$email_body" | $mailer "$recipient" 2>> "$LOG_FILE" || send_rc=$?
            ;;
    esac

    if [ "$send_rc" -eq 0 ]; then
        log_message "Backup failure email alert successfully dispatched to ${recipient} via ${mailer}."
        EMAIL_ALERT_SENT=1
    else
        log_message "WARNING: Failed to send backup failure email to ${recipient} via ${mailer} (exit code ${send_rc})."
        echo "WARNING: Failed to send failure alert email to ${recipient} (mailer exit code ${send_rc})." >&2
    fi

    return "$send_rc"
}

#---
#   FUNCTION:  send_notification()
#  DESCRIPTION:  Sends a desktop notification using notify-send with application
#                branding and contextual icons, ensuring DBUS_SESSION_BUS_ADDRESS is set.
#                Also dispatches a failure alert email if urgency is critical and ALERT_EMAIL is set.
#---
send_notification() {
    local urgency="$1"
    local title="$2"
    local message="$3"
    local icon="${4:-}"

    # If this is a critical alert, dispatch failure email if configured
    if [ "$urgency" = "critical" ]; then
        send_failure_email "$title" "$message"
    fi

    # Export DBUS_SESSION_BUS_ADDRESS if not set, for non-interactive shells (e.g., cron)
    if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
        export DBUS_SESSION_BUS_ADDRESS
    fi
    export DISPLAY="${DISPLAY:-:0}"

    # Check if notify-send is available before trying to use it
    if command -v notify-send &> /dev/null; then
        local notify_args=("-u" "$urgency" "-a" "Backup Script")
        if [ -n "$icon" ]; then
            notify_args+=("-i" "$icon")
        else
            case "$urgency" in
                critical) notify_args+=("-i" "dialog-error") ;;
                warning)  notify_args+=("-i" "dialog-warning") ;;
                *)        notify_args+=("-i" "drive-harddisk") ;;
            esac
        fi
        notify-send "${notify_args[@]}" "$title" "$message"
    else
        log_message "WARNING: notify-send not found. Notification skipped: $title - $message"
    fi
}

#---
#   FUNCTION:  execute_lifecycle_hook()
#  DESCRIPTION:  Executes pre-backup or post-backup lifecycle hooks via executable scripts
#                in HOOKS_DIR and/or PRE_BACKUP_COMMAND / POST_BACKUP_COMMAND.
#                Populates rich context into the execution environment.
#---
execute_lifecycle_hook() {
    local hook_type="$1"
    shift
    local hook_script="${HOOKS_DIR}/${hook_type}-backup.sh"
    local hook_cmd=""
    if [ "$hook_type" = "pre" ]; then
        hook_cmd="${PRE_BACKUP_COMMAND:-}"
    elif [ "$hook_type" = "post" ]; then
        hook_cmd="${POST_BACKUP_COMMAND:-}"
    fi

    if [ ! -f "$hook_script" ] && [ -z "$hook_cmd" ]; then
        return 0
    fi

    log_message "Executing ${hook_type}-backup lifecycle hook..."

    # Export contextual environment variables for hooks
    export BACKUP_HOOK_TYPE="$hook_type"
    export BACKUP_SOURCE_DIR="${SOURCE_DIR}"
    export BACKUP_DEST_DIR="${BACKUP_DIR}"
    export BACKUP_CONFIG_DIR="${CONFIG_DIR}"
    export BACKUP_SCRATCH_DIR="${SCRATCH_DIR}"
    export BACKUP_ARCHIVE_NAME="${ENCRYPTED_TARBALL_NAME:-}"
    export BACKUP_ARCHIVE_SIZE="${archive_size_hr:-unknown}"
    export BACKUP_UNCOMPRESSED_SIZE="${uncompressed_size_hr:-unknown}"
    export BACKUP_COMPRESSION_RATIO="${compression_ratio:-unknown}"
    export BACKUP_SPACE_SAVINGS="${space_savings_percent:-unknown}"
    export BACKUP_DURATION_SECONDS="${duration_secs:-0}"
    export BACKUP_STATUS="${1:-unknown}"
    export BACKUP_VERIFY_STATUS="${verify_status:-unknown}"
    export BACKUP_CLOUD_STATUS="${cloud_backup_status:-unknown}"
    export BACKUP_LOCAL_STATUS="${local_backup_status:-unknown}"
    export BACKUP_LOG_FILE="${LOG_FILE}"

    local script_rc=0
    if [ -f "$hook_script" ]; then
        log_message "Running hook script: ${hook_script}"
        if [ -x "$hook_script" ]; then
            "$hook_script" "$@" >> "$LOG_FILE" 2>&1 || script_rc=$?
        else
            bash "$hook_script" "$@" >> "$LOG_FILE" 2>&1 || script_rc=$?
        fi
        if [ "$script_rc" -ne 0 ]; then
            log_message "WARNING: Lifecycle hook script '${hook_script}' exited with code ${script_rc}."
            if [ "$hook_type" = "pre" ]; then
                return "$script_rc"
            fi
        else
            log_message "Lifecycle hook script '${hook_script}' completed successfully."
        fi
    fi

    local cmd_rc=0
    if [ -n "$hook_cmd" ]; then
        log_message "Running hook command: ${hook_cmd}"
        eval "$hook_cmd" >> "$LOG_FILE" 2>&1 || cmd_rc=$?
        if [ "$cmd_rc" -ne 0 ]; then
            log_message "WARNING: Lifecycle hook command (${hook_type}) exited with code ${cmd_rc}."
            if [ "$hook_type" = "pre" ]; then
                return "$cmd_rc"
            fi
        else
            log_message "Lifecycle hook command (${hook_type}) completed successfully."
        fi
    fi

    return 0
}


#---
#   FUNCTION:  check_dependencies()
#  DESCRIPTION:  Checks if required commands are installed.
#---
check_dependencies() {
    for cmd in tar rclone gpg pkill pgrep hostname zstd findmnt flock df awk numfmt sha256sum; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "ERROR: Required command '$cmd' is not installed. Please install it to continue." >&2
            exit 1
        fi
    done
}

#---
#   FUNCTION:  update_manifest_destination_status()
#  DESCRIPTION:  Updates the destination status (e.g. local_backup or cloud_backup)
#                inside a JSON companion manifest file.
#---
update_manifest_destination_status() {
    local manifest_file="$1"
    local dest_key="$2"     # "local_backup" or "cloud_backup"
    local status="$3"       # "OK", "Skipped (...)", "Failed", etc.

    [ -f "$manifest_file" ] || return 0

    local escaped_status
    escaped_status=$(printf '%s\n' "$status" | sed -e 's/[\/&]/\\&/g')
    sed -i -E "s/\"${dest_key}\":[[:space:]]*\"[^\"]*\"/\"${dest_key}\": \"${escaped_status}\"/" "$manifest_file" 2>/dev/null || true
}

#---
#   FUNCTION:  calculate_tiered_retention_prune_list()
#  DESCRIPTION:  Evaluates a list of backup archive filenames and determines which
#                archives to prune based on Grandfather-Father-Son (GFS) tiered retention:
#                - RETENTION_DAILY (default: 7 daily archives)
#                - RETENTION_WEEKLY (default: 4 weekly archives)
#                - RETENTION_MONTHLY (default: 6 monthly archives)
#                - RETENTION_YEARLY (default: 1 yearly archive)
#                Outputs filenames that should be pruned.
#---
# shellcheck disable=SC2120
calculate_tiered_retention_prune_list() {
    local daily_limit="${RETENTION_DAILY:-7}"
    local weekly_limit="${RETENTION_WEEKLY:-4}"
    local monthly_limit="${RETENTION_MONTHLY:-6}"
    local yearly_limit="${RETENTION_YEARLY:-1}"
    local min_keep="${RETENTION_MIN_KEEP:-0}"

    local -A kept_archives=()
    local -A day_buckets=()
    local -A week_buckets=()
    local -A month_buckets=()
    local -A year_buckets=()

    local -a all_archives=()
    if [ $# -gt 0 ]; then
        all_archives=("$@")
    else
        while IFS= read -r line || [ -n "$line" ]; do
            [[ -z "$line" ]] && continue
            all_archives+=("$line")
        done
    fi

    [ ${#all_archives[@]} -eq 0 ] && return 0

    # Sort newest to oldest:
    # Since filenames contain YYYY-MM-DD_HHMMSS, reverse lexical sort is chronological descending
    mapfile -t all_archives < <(printf '%s\n' "${all_archives[@]}" | sort -r)

    local day_count=0 week_count=0 month_count=0 year_count=0
    local overall_idx=0

    for archive in "${all_archives[@]}"; do
        ((overall_idx++))

        # Always keep if within min_keep threshold
        if [ "$min_keep" -gt 0 ] && [ "$overall_idx" -le "$min_keep" ]; then
            kept_archives["$archive"]=1
        fi

        if [[ "$archive" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{6}) ]]; then
            local y="${BASH_REMATCH[1]}"
            local m="${BASH_REMATCH[2]}"
            local d="${BASH_REMATCH[3]}"
            local date_str="${y}-${m}-${d}"

            local iso_week
            iso_week=$(date -d "${date_str}" +%G-W%V 2>/dev/null || echo "${y}-W$(( (10#$m * 30 + 10#$d) / 7 ))")
            local month_str="${y}-${m}"
            local year_str="${y}"

            local keep=false

            # Daily bucket (keep newest for each distinct day)
            if [ -z "${day_buckets[$date_str]+x}" ] && [ "$day_count" -lt "$daily_limit" ]; then
                day_buckets["$date_str"]=1
                ((day_count++))
                keep=true
            fi

            # Weekly bucket (keep newest for each distinct ISO week)
            if [ -z "${week_buckets[$iso_week]+x}" ] && [ "$week_count" -lt "$weekly_limit" ]; then
                week_buckets["$iso_week"]=1
                ((week_count++))
                keep=true
            fi

            # Monthly bucket (keep newest for each distinct month)
            if [ -z "${month_buckets[$month_str]+x}" ] && [ "$month_count" -lt "$monthly_limit" ]; then
                month_buckets["$month_str"]=1
                ((month_count++))
                keep=true
            fi

            # Yearly bucket (keep newest for each distinct year)
            if [ -z "${year_buckets[$year_str]+x}" ] && [ "$year_count" -lt "$yearly_limit" ]; then
                year_buckets["$year_str"]=1
                ((year_count++))
                keep=true
            fi

            if [ "$keep" = true ]; then
                kept_archives["$archive"]=1
            fi
        else
            # Preserve archives with unrecognized timestamp format safely
            kept_archives["$archive"]=1
        fi
    done

    # Output any archive that is NOT in kept_archives
    for archive in "${all_archives[@]}"; do
        if [ -z "${kept_archives[$archive]+x}" ]; then
            echo "$archive"
        fi
    done
}

#---
#   FUNCTION:  run_rotation()
#  DESCRIPTION:  Deletes old backups, keeping recent ones on cloud remote.
#                Supports count-based retention (default) and GFS tiered retention.
#---
run_rotation() {
    local -a files_to_delete=()

    if [ "$RETENTION_MODE" = "tiered" ] || [ "$RETENTION_MODE" = "gfs" ]; then
        log_message "Running tiered cloud backup rotation (daily=${RETENTION_DAILY:-7}, weekly=${RETENTION_WEEKLY:-4}, monthly=${RETENTION_MONTHLY:-6}, yearly=${RETENTION_YEARLY:-1})."
        echo "Running tiered cloud backup rotation (daily=${RETENTION_DAILY:-7}, weekly=${RETENTION_WEEKLY:-4}, monthly=${RETENTION_MONTHLY:-6}, yearly=${RETENTION_YEARLY:-1})..."
        mapfile -t files_to_delete < <(rclone lsf --fast-list "${BACKUP_DIR}" 2>/dev/null | grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" | calculate_tiered_retention_prune_list)
    else
        if ! [ "${CLOUD_KEEP_COUNT:-0}" -gt 0 ] 2>/dev/null; then
            log_message "WARNING: Cloud backup rotation skipped. CLOUD_KEEP_COUNT must be a positive integer (currently '${CLOUD_KEEP_COUNT}')."
            echo "Cloud backup rotation skipped (invalid or zero keep count)."
            return 0
        fi

        log_message "Running cloud backup rotation. Keeping the latest ${CLOUD_KEEP_COUNT} backups."
        echo "Running cloud backup rotation (keeping ${CLOUD_KEEP_COUNT})..."
        mapfile -t files_to_delete < <(rclone lsf --fast-list "${BACKUP_DIR}" 2>/dev/null | grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" | sort | head -n -"${CLOUD_KEEP_COUNT}")
    fi

    for file_to_delete in "${files_to_delete[@]}"; do
        [ -z "$file_to_delete" ] && continue
        log_message "Trashing old cloud backup: ${file_to_delete}"
        echo "Trashing old cloud backup: ${file_to_delete}"
        rclone deletefile "${BACKUP_DIR}${file_to_delete}" >> "$LOG_FILE" 2>&1
        rclone deletefile "${BACKUP_DIR}${file_to_delete}.sha256" >> "$LOG_FILE" 2>&1 || true
        rclone deletefile "${BACKUP_DIR}${file_to_delete}.manifest.json" >> "$LOG_FILE" 2>&1 || true
    done

    log_message "Cloud backup rotation complete."
}

#---
#   FUNCTION:  get_local_backup_path()
#  DESCRIPTION:  Queries findmnt for the exact mount point of LOCAL_DRIVE_UUID.
#                If not mounted but the block device exists at /dev/disk/by-uuid/${LOCAL_DRIVE_UUID},
#                attempts unprivileged mounting via udisksctl.
#                Returns the backup directory path if mounted, or returns 1.
#---
get_local_backup_path() {
    local mount_point
    mount_point=$(findmnt -rn -o TARGET -S UUID="${LOCAL_DRIVE_UUID}" 2>/dev/null)

    # If not mounted, check if the block device exists and attempt unprivileged mount via udisksctl
    if [ -z "$mount_point" ] && command -v udisksctl &>/dev/null; then
        local block_dev="/dev/disk/by-uuid/${LOCAL_DRIVE_UUID}"
        if [ -b "$block_dev" ]; then
            log_message "Local drive ${LOCAL_DRIVE_UUID} detected at ${block_dev} but not mounted. Attempting unprivileged mount via udisksctl..."
            if udisksctl mount -b "$block_dev" --no-user-interaction >/dev/null 2>&1; then
                mount_point=$(findmnt -rn -o TARGET -S UUID="${LOCAL_DRIVE_UUID}" 2>/dev/null)
                if [ -n "$mount_point" ]; then
                    log_message "Local drive ${LOCAL_DRIVE_UUID} successfully mounted at ${mount_point} via udisksctl."
                fi
            else
                log_message "WARNING: Failed to mount local drive ${LOCAL_DRIVE_UUID} via udisksctl."
            fi
        fi
    fi

    if [ -n "$mount_point" ]; then
        echo "${mount_point}/${LOCAL_BACKUP_SUBDIR}"
        return 0
    fi
    return 1
}

#---
#   FUNCTION:  get_preserved_archives()
#  DESCRIPTION:  Finds preserved backup archives from previous failed uploads
#                in SOURCE_DIR. Prints matching file paths, newest first.
#---
get_preserved_archives() {
    find "${SOURCE_DIR}" -maxdepth 1 -type f \( \
        -name "${TARBALL_BASENAME}_*.tar.zst.gpg" -o \
        -name "${TARBALL_BASENAME}_*.tar.gz.gpg" -o \
        -name "${TARBALL_BASENAME}_*.tar.xz.gpg" \
    \) 2>/dev/null | sort -r
}

#---
#   FUNCTION:  generate_backup_manifest()
#  DESCRIPTION:  Creates a lightweight companion JSON manifest for an encrypted backup.
#---
generate_backup_manifest() {
    local manifest_file="$1"
    local archive_name="$2"
    local archive_bytes="$3"
    local archive_size_hr="$4"
    local sha256_hash="$5"
    local duration_seconds="$6"
    local duration_hr="$7"
    local tar_warning="$8"
    local crontab_backed_up="$9"
    local pipx_backed_up="${10}"
    local flatpak_remotes="${11}"
    local flatpak_packages="${12}"
    local systemd_units="${13}"
    local dconf_backed_up="${14}"
    local apt_packages="${15}"
    local apt_repos_backed_up="${16}"
    local dnf_packages="${17:-0}"
    local dnf_repos_backed_up="${18:-false}"
    local local_status="${19:-Pending}"
    local cloud_status="${20:-Pending}"
    local uncompressed_bytes="${21:-0}"
    local uncompressed_size_hr="${22:-unknown}"
    local compression_ratio="${23:-unknown}"
    local space_savings_percent="${24:-unknown}"

    local created_iso
    created_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    local tags_enabled="false"
    [ "$ENABLE_EXCLUDE_TAGS" = true ] || [ "$ENABLE_EXCLUDE_TAGS" = "1" ] && tags_enabled="true"
    local ignores_enabled="false"
    [ "$ENABLE_EXCLUDE_IGNORE" = true ] || [ "$ENABLE_EXCLUDE_IGNORE" = "1" ] && ignores_enabled="true"

    local tags_json="[]"
    if [ ${#EXCLUDE_TAG_FILES[@]} -gt 0 ]; then
        tags_json=$(printf '"%s",' "${EXCLUDE_TAG_FILES[@]}")
        tags_json="[ ${tags_json%,} ]"
    fi
    local ignores_json="[]"
    if [ ${#EXCLUDE_IGNORE_FILES[@]} -gt 0 ]; then
        ignores_json=$(printf '"%s",' "${EXCLUDE_IGNORE_FILES[@]}")
        ignores_json="[ ${ignores_json%,} ]"
    fi

    local recipients_json="[]"
    if [ ${#GPG_RECIPIENTS[@]} -gt 0 ]; then
        recipients_json=$(printf '"%s",' "${GPG_RECIPIENTS[@]}")
        recipients_json="[ ${recipients_json%,} ]"
    fi

    cat <<EOF > "$manifest_file"
{
  "manifest_version": "1.0",
  "created_at": "${created_iso}",
  "timestamp_tag": "${TIMESTAMP}",
  "script_version": "${SCRIPT_VERSION}",
  "host": "${HOSTNAME}",
  "user": "${CURRENT_USER}",
  "source_directory": "${SOURCE_DIR}",
  "archive": {
    "filename": "${archive_name}",
    "size_bytes": ${archive_bytes:-0},
    "size_human": "${archive_size_hr}",
    "uncompressed_bytes": ${uncompressed_bytes:-0},
    "uncompressed_human": "${uncompressed_size_hr}",
    "compression_ratio": "${compression_ratio}",
    "space_savings_percent": "${space_savings_percent}",
    "sha256": "${sha256_hash}",
    "compression": {
      "algorithm": "zstd",
      "level": ${ZSTD_LEVEL:-6},
      "long_distance_matching": "${ZSTD_LONG}",
      "ratio": "${compression_ratio}",
      "space_savings": "${space_savings_percent}"
    },
    "encryption": {
      "tool": "gpg",
      "mode": "${ENCRYPTION_MODE:-symmetric}",
      "cipher": "AES256",
      "s2k_digest": "SHA512",
      "recipients": ${recipients_json}
    },
    "exclusions": {
      "patterns_count": ${#EXCLUDE_PATTERNS[@]},
      "per_directory_tags_enabled": ${tags_enabled},
      "per_directory_tags": ${tags_json},
      "per_directory_ignore_enabled": ${ignores_enabled},
      "per_directory_ignore_files": ${ignores_json}
    }
  },
  "system_state": {
    "crontab_backed_up": ${crontab_backed_up:-false},
    "pipx_spec_backed_up": ${pipx_backed_up:-false},
    "flatpak_remotes_count": ${flatpak_remotes:-0},
    "flatpak_packages_count": ${flatpak_packages:-0},
    "systemd_user_units_count": ${systemd_units:-0},
    "dconf_settings_backed_up": ${dconf_backed_up:-false},
    "apt_manual_packages_count": ${apt_packages:-0},
    "apt_repos_backed_up": ${apt_repos_backed_up:-false},
    "dnf_user_packages_count": ${dnf_packages:-0},
    "dnf_repos_backed_up": ${dnf_repos_backed_up:-false}
  },
  "execution": {
    "duration_seconds": ${duration_seconds:-0},
    "duration_human": "${duration_hr}",
    "tar_warnings": ${tar_warning:-false},
    "destinations": {
      "local_backup": "${local_status}",
      "cloud_backup": "${cloud_status}"
    }
  }
}
EOF
}

#---
#---
#   FUNCTION:  generate_disaster_recovery_cheatsheet()
#  DESCRIPTION:  Writes an up-to-date disaster recovery cheatsheet (RESTORE_README.txt)
#                with accurate system context, decompression limits, and CLI commands.
#---
generate_disaster_recovery_cheatsheet() {
    local output_file="$1"
    local location_label="${2:-${target_dir:-${SOURCE_DIR}}}"
    local date_str
    date_str=$(date '+%Y-%m-%d %H:%M:%S')

    local cd_instruction="cd ${location_label}"
    if [[ "$location_label" == *:* ]]; then
        cd_instruction="# (After downloading archive and sidecars locally)\n  cd /path/to/download_dir"
    fi

    cat << EOF > "${output_file}"
================================================================================
                    DISASTER RECOVERY & RESTORE CHEATSHEET
================================================================================
Host:     ${HOSTNAME}
User:     ${CURRENT_USER}
Updated:  ${date_str}
Location: ${location_label}
================================================================================

This location contains encrypted backup archives created by backup_script.sh.
Archives are named: ${TARBALL_BASENAME}_YYYY-MM-DD_HHMMSS.tar.zst.gpg

Prerequisites for recovery on a new or clean system:
  - GnuPG: 'gpg' (for AES-256 decryption)
  - Zstandard: 'zstd' (for multi-threaded decompression)
  - GNU Tar: 'tar'
  - Coreutils: 'sha256sum' (for archive integrity and bit-rot detection)
  - Rclone: 'rclone' (required for cloud storage download / streaming)
  Install via APT:
    sudo apt update && sudo apt install -y gpg zstd tar coreutils rclone
  Install via DNF:
    sudo dnf install -y gnupg2 zstd tar coreutils rclone

--------------------------------------------------------------------------------
VERIFYING ARCHIVE INTEGRITY & INSPECTING MANIFEST INVENTORY
--------------------------------------------------------------------------------
Every archive is accompanied by two lightweight sidecar files:
  1. SHA-256 sidecar:  <ARCHIVE_NAME>.tar.zst.gpg.sha256
  2. JSON manifest:    <ARCHIVE_NAME>.tar.zst.gpg.manifest.json

To check for media corruption or bit-rot without needing an encryption password:
  $(echo -e "${cd_instruction}")
  sha256sum -c <ARCHIVE_NAME>.tar.zst.gpg.sha256

Or using the mirrored backup_script.sh:
  ./backup_script.sh verify --checksum-only

To inspect backup metadata, sizes, and package inventory without decrypting:
  ./backup_script.sh manifest <ARCHIVE_NAME>.tar.zst.gpg
  # Or view raw JSON:
  cat <ARCHIVE_NAME>.tar.zst.gpg.manifest.json

--------------------------------------------------------------------------------
SPECIFYING THE ENCRYPTION PASSPHRASE
--------------------------------------------------------------------------------
Backup archives are symmetrically encrypted using AES-256 via GPG.
You can supply the decryption passphrase through any of the following methods:

1. Interactive Terminal Prompt (Default):
   - Simply run the restore command in a terminal.
   - You will be prompted securely:
       Enter backup encryption password:
     (Input is hidden while typing)

2. Secure Passphrase File:
   - Default file location used by backup_script.sh:
       ${PASSWORD_FILE}
   - Create or populate the file with strict permissions (chmod 600):
       mkdir -p "${CONFIG_DIR}" && chmod 700 "${CONFIG_DIR}"
       echo -n "YourPassphraseHere" > "${PASSWORD_FILE}"
       chmod 600 "${PASSWORD_FILE}"
   - Using a custom passphrase file location with backup_script.sh:
       PASSWORD_FILE="/path/to/passphrase_file" ./backup_script.sh restore ...
   - Using a passphrase file with manual GPG:
       gpg --batch --yes --pinentry-mode loopback --passphrase-file "${PASSWORD_FILE}" --decrypt <ARCHIVE>.tar.zst.gpg | ...

3. Environment Variable (Non-Interactive / Scripting):
   - Set ENCRYPTION_PASSWORD or BACKUP_ENCRYPTION_PASSWORD:
       export ENCRYPTION_PASSWORD="YourPassphraseHere"
       ./backup_script.sh restore <ARCHIVE_NAME>.tar.zst.gpg -y
   - Or prepend inline for a single execution:
       ENCRYPTION_PASSWORD="YourPassphraseHere" ./backup_script.sh restore <ARCHIVE_NAME>.tar.zst.gpg
   - Using environment variable with manual GPG:
       gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --decrypt <ARCHIVE_NAME>.tar.zst.gpg 3<<< "\$ENCRYPTION_PASSWORD" | ...
       # Or via stdin pipe:
       echo "\$ENCRYPTION_PASSWORD" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt <ARCHIVE_NAME>.tar.zst.gpg | ...

4. Public Key / Asymmetric GPG Decryption:
   - If the archive was encrypted using a GPG public key, no passphrase file is required.
   - Decryption uses the private key in your GPG keyring:
       gpg --decrypt <ARCHIVE_NAME>.tar.zst.gpg | zstd -dc --memory=${ZSTD_DECOMPRESS_MEMORY} | tar -xpvf - -C /home/${CURRENT_USER}/
   - If restoring on a new system, import your private key first:
       gpg --import /path/to/private_key.asc

--------------------------------------------------------------------------------
METHOD 1: Automated / Interactive Restore (Using Mirrored Script)
--------------------------------------------------------------------------------
A copy of backup_script.sh is mirrored alongside this cheatsheet.

1. Make the script executable:
   chmod +x ./backup_script.sh

2. Validate recovery environment, tools, and filesystem permissions:
   ./backup_script.sh check-config

3. Inspect backup manifest, file sizes, checksums, and inventory:
   ./backup_script.sh manifest <ARCHIVE_NAME>.tar.zst.gpg

4. Verify archive integrity and test decryption before extracting (safe & non-destructive):
   ./backup_script.sh verify <ARCHIVE_NAME>.tar.zst.gpg

5. List or search files inside an archive:
   ./backup_script.sh list-files <ARCHIVE_NAME>.tar.zst.gpg [pattern]

6. Interactive Restore Menu (prompts for passphrase if not in file or env):
   ./backup_script.sh restore

7. Restore a specific archive directly:
   ./backup_script.sh restore <ARCHIVE_NAME>.tar.zst.gpg

8. Restore with a custom passphrase file:
   PASSWORD_FILE=/path/to/passphrase ./backup_script.sh restore <ARCHIVE_NAME>.tar.zst.gpg

9. Selective file or folder extraction:
   ./backup_script.sh restore <ARCHIVE_NAME>.tar.zst.gpg --path Documents --dest /home/${CURRENT_USER}

10. Non-interactive batch restore (auto-accept prompts with env passphrase):
    ENCRYPTION_PASSWORD="YourPassphraseHere" ./backup_script.sh restore <ARCHIVE_NAME>.tar.zst.gpg -y

--------------------------------------------------------------------------------
METHOD 2: Manual Restore via Standard CLI (No Script Needed)
--------------------------------------------------------------------------------
If you prefer not to run the script or need to extract files on any Unix system:
(Note: '--memory=${ZSTD_DECOMPRESS_MEMORY}' ensures sufficient decompression buffer for Zstandard Long Distance Matching)

1. List files inside an archive without extracting (interactive password prompt):
   gpg --decrypt <ARCHIVE_NAME>.tar.zst.gpg | zstd -dc --memory=${ZSTD_DECOMPRESS_MEMORY} | tar -tvf - | less

2. Restore entire backup to home directory (interactive password prompt):
   gpg --decrypt <ARCHIVE_NAME>.tar.zst.gpg | zstd -dc --memory=${ZSTD_DECOMPRESS_MEMORY} | tar -xpvf - -C /home/${CURRENT_USER}/

3. Extract a single file or directory (interactive password prompt):
   gpg --decrypt <ARCHIVE_NAME>.tar.zst.gpg | zstd -dc --memory=${ZSTD_DECOMPRESS_MEMORY} | tar -xpvf - -C /home/${CURRENT_USER}/ path/to/file

4. Non-interactive restore using a passphrase file:
   gpg --batch --yes --pinentry-mode loopback --passphrase-file "${PASSWORD_FILE}" --decrypt <ARCHIVE_NAME>.tar.zst.gpg | zstd -dc --memory=${ZSTD_DECOMPRESS_MEMORY} | tar -xpvf - -C /home/${CURRENT_USER}/

5. Non-interactive restore using an environment variable:
   gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 --decrypt <ARCHIVE_NAME>.tar.zst.gpg 3<<< "\$ENCRYPTION_PASSWORD" | zstd -dc --memory=${ZSTD_DECOMPRESS_MEMORY} | tar -xpvf - -C /home/${CURRENT_USER}/

--------------------------------------------------------------------------------
METHOD 3: Post-Restore System Configuration Replay
--------------------------------------------------------------------------------
Each backup includes exported system configuration manifests in the root of the
archive:

1. APT Repositories & Signing Keyrings (${APT_REPOS_FILE}):
   sudo tar -xzvf ${APT_REPOS_FILE} -C /etc/apt/
   sudo apt update

2. Manually Installed APT Packages (${APT_PACKAGES_FILE}):
   xargs -a ${APT_PACKAGES_FILE} sudo apt install -y

3. DNF Repositories & RPM GPG Keys (${DNF_REPOS_FILE}):
   sudo tar -xzvf ${DNF_REPOS_FILE} -C /etc/
   sudo dnf clean all && sudo dnf makecache

4. User-Installed DNF Packages (${DNF_PACKAGES_FILE}):
   xargs -a ${DNF_PACKAGES_FILE} sudo dnf install -y --skip-broken

5. Desktop & GNOME Settings (${DCONF_SETTINGS_FILE}):
   dconf load / < ${DCONF_SETTINGS_FILE}

6. Flatpak Remotes & Applications:
   # Add remotes from ${FLATPAK_REMOTES_FILE}
   # Install apps: xargs -a ${FLATPAK_PACKAGES_FILE} flatpak install -y

7. Python Pipx Packages (${PIPX_SPEC_FILE}):
   pipx install <package_name> (refer to ${PIPX_SPEC_FILE} for package names)

8. Systemd User Units (${SYSTEMD_USER_UNITS_FILE}):
   systemctl --user daemon-reload
   while read -r unit _; do [ -n "\$unit" ] && systemctl --user enable "\$unit"; done < ${SYSTEMD_USER_UNITS_FILE}

9. Crontab (${CRONTAB_BACKUP_FILE}):
   crontab ${CRONTAB_BACKUP_FILE}

10. Security Hardening (SSH & GPG directory permissions):
   chmod 700 /home/${CURRENT_USER}/.ssh /home/${CURRENT_USER}/.gnupg 2>/dev/null
   chmod 600 /home/${CURRENT_USER}/.ssh/id_* /home/${CURRENT_USER}/.ssh/authorized_keys 2>/dev/null
   chmod 644 /home/${CURRENT_USER}/.ssh/*.pub /home/${CURRENT_USER}/.ssh/known_hosts 2>/dev/null
   find /home/${CURRENT_USER}/.gnupg -type f -exec chmod 600 {} + 2>/dev/null
   [ -d /home/${CURRENT_USER}/.config/backup_script ] && chmod 700 /home/${CURRENT_USER}/.config/backup_script && chmod 600 /home/${CURRENT_USER}/.config/backup_script/* 2>/dev/null
================================================================================
EOF
}

#---
#   FUNCTION:  mirror_script_and_cheatsheet()
#  DESCRIPTION:  Mirrors the standalone backup script and writes an up-to-date
#                disaster recovery cheatsheet (RESTORE_README.txt) to the local
#                backup directory.
#---
mirror_script_and_cheatsheet() {
    local target_dir="$1"

    if [ "$MIRROR_SCRIPT_TO_LOCAL" != "true" ] && [ "$MIRROR_SCRIPT_TO_LOCAL" != "1" ]; then
        return 0
    fi

    if [ -z "$target_dir" ] || [ ! -d "$target_dir" ]; then
        return 0
    fi

    # 1. Mirror the standalone backup script
    if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
        local mirrored_script="${target_dir}/backup_script.sh"
        local temp_script="${target_dir}/backup_script.sh.tmp.$$"
        if cp -p "${SCRIPT_PATH}" "${temp_script}" 2>/dev/null; then
            chmod 755 "${temp_script}" 2>/dev/null || true
            mv -f "${temp_script}" "${mirrored_script}" 2>/dev/null || true
            log_message "Mirrored standalone backup script to ${mirrored_script}"
        else
            rm -f "${temp_script}" 2>/dev/null || true
            log_message "WARNING: Failed to mirror backup script to ${target_dir}"
        fi
    fi

    # 2. Write disaster recovery cheatsheet
    local readme_file="${target_dir}/RESTORE_README.txt"
    local temp_readme="${target_dir}/RESTORE_README.txt.tmp.$$"

    if generate_disaster_recovery_cheatsheet "${temp_readme}" "${target_dir}"; then
        if mv -f "${temp_readme}" "${readme_file}" 2>/dev/null; then
            sync -f "${target_dir}" 2>/dev/null || sync
            log_message "Disaster recovery cheatsheet updated at ${readme_file}"
            echo "Disaster recovery bootstrap mirrored to ${target_dir} (backup_script.sh & RESTORE_README.txt)."
        else
            rm -f "${temp_readme}" 2>/dev/null || true
            log_message "WARNING: Failed to write disaster recovery cheatsheet to ${target_dir}"
        fi
    else
        rm -f "${temp_readme}" 2>/dev/null || true
        log_message "WARNING: Failed to generate disaster recovery cheatsheet"
    fi
}

#---
#   FUNCTION:  mirror_script_and_cheatsheet_to_cloud()
#  DESCRIPTION:  Generates an up-to-date disaster recovery cheatsheet (RESTORE_README.txt)
#                and mirrors the standalone backup script to cloud storage.
#---
mirror_script_and_cheatsheet_to_cloud() {
    local cloud_dest="$1"
    local staging_scratch="$2"
    local rclone_log_file="${3:-/dev/null}"

    if [ "$MIRROR_SCRIPT_TO_CLOUD" != "true" ] && [ "$MIRROR_SCRIPT_TO_CLOUD" != "1" ]; then
        return 0
    fi

    if [ -z "$cloud_dest" ]; then
        return 0
    fi

    local temp_readme="${staging_scratch}/RESTORE_README.txt"
    if generate_disaster_recovery_cheatsheet "${temp_readme}" "${cloud_dest}"; then
        echo "Uploading disaster recovery cheatsheet to ${cloud_dest}..."
        if rclone copy --retries 3 --low-level-retries 5 --timeout 5m "${temp_readme}" "${cloud_dest}" >> "$rclone_log_file" 2>&1; then
            log_message "Disaster recovery cheatsheet mirrored to cloud (${cloud_dest}RESTORE_README.txt)."
        else
            log_message "WARNING: Failed to upload disaster recovery cheatsheet to cloud storage."
        fi
        rm -f "${temp_readme}" 2>/dev/null || true
    fi

    if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then
        echo "Mirroring standalone backup script to ${cloud_dest}..."
        if rclone copy --retries 3 --low-level-retries 5 --timeout 5m "${SCRIPT_PATH}" "${cloud_dest}" >> "$rclone_log_file" 2>&1; then
            log_message "Standalone backup script mirrored to cloud (${cloud_dest}backup_script.sh)."
        else
            log_message "WARNING: Failed to upload standalone backup script to cloud storage."
        fi
    fi
    echo "Disaster recovery bootstrap mirrored to cloud storage."
}

#---
#   FUNCTION:  handle_local_backup()
#  DESCRIPTION:  Checks if the local drive is mounted, verifies space, safely
#                copies backup via atomic .part staging, and rotates old backups.
#---
handle_local_backup() {
    local file_path="$1"
    local file_name="$2"

    echo "Checking for local backup drive (UUID: ${LOCAL_DRIVE_UUID})..."
    
    local local_backup_path
    if local_backup_path=$(get_local_backup_path); then
        log_message "Local drive ${LOCAL_DRIVE_UUID} is mounted at $(dirname "$local_backup_path"). Starting local backup."
        echo "Local drive detected. Staging backup copy to ${local_backup_path}..."
        
        # Ensure the directory exists
        mkdir -p "${local_backup_path}"

        # Clean up any stale partial files from previous interrupted attempts
        rm -f "${local_backup_path}/${TARBALL_BASENAME}_"*.part "${local_backup_path}/${TARBALL_BASENAME}_"*.part* 2>/dev/null || true

        # Pre-flight check: Verify sufficient disk space on local backup drive
        local file_size_kb local_avail_kb
        file_size_kb=$(du -k "${file_path}" 2>/dev/null | awk '{print $1}')
        local_avail_kb=$(df -Pk "${local_backup_path}" 2>/dev/null | awk 'NR==2 {print $4}')

        if [ -n "$file_size_kb" ] && [ -n "$local_avail_kb" ]; then
            # Add 50MB safety buffer
            local required_kb=$((file_size_kb + 51200))
            if [ "$local_avail_kb" -lt "$required_kb" ]; then
                local avail_hr req_hr
                avail_hr=$(numfmt --to=iec --from-unit=1024 "${local_avail_kb}" 2>/dev/null || echo "$((local_avail_kb / 1024 / 1024))G")
                req_hr=$(numfmt --to=iec --from-unit=1024 "${file_size_kb}" 2>/dev/null || echo "$((file_size_kb / 1024 / 1024))G")
                local ERROR_MSG="ERROR: Insufficient disk space on local drive (${local_backup_path}). Available: ${avail_hr}, required: ${req_hr}. Skipping local backup."
                log_message "$ERROR_MSG"
                echo "$ERROR_MSG" >&2
                return 1
            fi
        fi

        local final_dest="${local_backup_path}/${file_name}"
        local temp_dest="${local_backup_path}/${file_name}.part"
        CURRENT_LOCAL_TEMP_ARCHIVE="${temp_dest}"

        if cp -p --reflink=auto --sparse=always "${file_path}" "${temp_dest}"; then
            mv -f "${temp_dest}" "${final_dest}"
            sync -f "${final_dest}" 2>/dev/null || sync
            CURRENT_LOCAL_TEMP_ARCHIVE=""
            log_message "Local backup successful: ${file_name}"

            # Mirror companion SHA-256 sidecar if present
            local sha256_src="${file_path}.sha256"
            if [ -f "$sha256_src" ]; then
                local final_sha_dest="${local_backup_path}/${file_name}.sha256"
                local temp_sha_dest="${local_backup_path}/${file_name}.sha256.part"
                CURRENT_LOCAL_TEMP_SHA256="${temp_sha_dest}"
                if cp -p "${sha256_src}" "${temp_sha_dest}" 2>/dev/null; then
                    mv -f "${temp_sha_dest}" "${final_sha_dest}" 2>/dev/null || true
                    CURRENT_LOCAL_TEMP_SHA256=""
                    log_message "Local SHA-256 sidecar mirrored: ${file_name}.sha256"
                else
                    rm -f "${temp_sha_dest}" 2>/dev/null || true
                    CURRENT_LOCAL_TEMP_SHA256=""
                    log_message "WARNING: Failed to mirror SHA-256 sidecar to local backup drive."
                fi
            fi

            # Mirror companion JSON manifest if present
            local manifest_src="${file_path}.manifest.json"
            if [ -f "$manifest_src" ]; then
                update_manifest_destination_status "$manifest_src" "local_backup" "OK"
                local final_manifest_dest="${local_backup_path}/${file_name}.manifest.json"
                local temp_manifest_dest="${local_backup_path}/${file_name}.manifest.json.part"
                CURRENT_LOCAL_TEMP_MANIFEST="${temp_manifest_dest}"
                if cp -p "${manifest_src}" "${temp_manifest_dest}" 2>/dev/null; then
                    mv -f "${temp_manifest_dest}" "${final_manifest_dest}" 2>/dev/null || true
                    CURRENT_LOCAL_TEMP_MANIFEST=""
                    log_message "Local backup manifest mirrored: ${file_name}.manifest.json"
                else
                    rm -f "${temp_manifest_dest}" 2>/dev/null || true
                    CURRENT_LOCAL_TEMP_MANIFEST=""
                    log_message "WARNING: Failed to mirror backup manifest to local backup drive."
                fi
            fi
            
            # Local Rotation
            local -a local_files_to_delete=()
            if [ "$RETENTION_MODE" = "tiered" ] || [ "$RETENTION_MODE" = "gfs" ]; then
                echo "Running tiered local backup rotation (daily=${RETENTION_DAILY:-7}, weekly=${RETENTION_WEEKLY:-4}, monthly=${RETENTION_MONTHLY:-6}, yearly=${RETENTION_YEARLY:-1})..."
                log_message "Running tiered local backup rotation (daily=${RETENTION_DAILY:-7}, weekly=${RETENTION_WEEKLY:-4}, monthly=${RETENTION_MONTHLY:-6}, yearly=${RETENTION_YEARLY:-1})."
                mapfile -t local_files_to_delete < <(find "${local_backup_path}" -maxdepth 1 -type f \( -name "${TARBALL_BASENAME}_*.tar.zst.gpg" -o -name "${TARBALL_BASENAME}_*.tar.gz.gpg" -o -name "${TARBALL_BASENAME}_*.tar.xz.gpg" \) -printf "%f\n" 2>/dev/null | calculate_tiered_retention_prune_list)
            else
                if [ "${LOCAL_KEEP_COUNT:-0}" -gt 0 ] 2>/dev/null; then
                    echo "Running local backup rotation (keeping ${LOCAL_KEEP_COUNT})..."
                    log_message "Running local backup rotation. Keeping the latest ${LOCAL_KEEP_COUNT} backups."
                    # Find files matching the basename, sort by name (timestamped), delete all but the newest
                    mapfile -t local_files_to_delete < <(find "${local_backup_path}" -maxdepth 1 -type f \( -name "${TARBALL_BASENAME}_*.tar.zst.gpg" -o -name "${TARBALL_BASENAME}_*.tar.gz.gpg" -o -name "${TARBALL_BASENAME}_*.tar.xz.gpg" \) -printf "%f\n" 2>/dev/null | sort | head -n -"${LOCAL_KEEP_COUNT}")
                else
                    log_message "WARNING: Local backup rotation skipped. LOCAL_KEEP_COUNT must be a positive integer (currently '${LOCAL_KEEP_COUNT}')."
                    echo "Local backup rotation skipped (invalid or zero keep count)."
                fi
            fi

            for old_file in "${local_files_to_delete[@]}"; do
                [ -z "$old_file" ] && continue
                log_message "Deleting old local backup: ${old_file}"
                rm -f "${local_backup_path}/${old_file}"
                rm -f "${local_backup_path}/${old_file}.sha256"
                rm -f "${local_backup_path}/${old_file}.manifest.json"
            done
            sync -f "${local_backup_path}" 2>/dev/null || sync

            # Disaster Recovery: Mirror standalone script and cheatsheet to local backup drive
            mirror_script_and_cheatsheet "${local_backup_path}"

            return 0
        else
            rm -f "${temp_dest}" "${final_dest}" "${local_backup_path}/${file_name}.sha256"* "${local_backup_path}/${file_name}.manifest.json"* 2>/dev/null
            CURRENT_LOCAL_TEMP_ARCHIVE=""
            CURRENT_LOCAL_TEMP_SHA256=""
            CURRENT_LOCAL_TEMP_MANIFEST=""
            log_message "ERROR: Failed to copy backup to local drive. Cleaned up incomplete archive."
            echo "Local copy failed! Incomplete archive cleaned up." >&2
            return 1
        fi
    else
        log_message "Local drive ${LOCAL_DRIVE_UUID} not found or not mounted. Skipping local backup."
        echo "Local drive not detected. Skipping local backup step."
        return 2
    fi
}

#---
#   FUNCTION:  upload_preserved_archive()
#  DESCRIPTION:  Uploads a preserved backup archive to the cloud, copies it to
#                the local backup drive if mounted, rotates backups, and removes
#                the preserved local archive upon successful upload.
#---
upload_preserved_archive() {
    local target_file="$1"
    if [ ! -f "$target_file" ]; then
        echo "ERROR: Preserved archive '${target_file}' not found." >&2
        return 1
    fi

    local upload_start_time=$SECONDS
    local target_name
    target_name=$(basename "$target_file")
    local target_bytes target_hr="unknown"
    target_bytes=$(stat -c %s "$target_file" 2>/dev/null || echo 0)
    [ "$target_bytes" -gt 0 ] && target_hr=$(numfmt --to=iec --suffix=B "$target_bytes" 2>/dev/null || echo "${target_bytes}B")

    # Ensure SHA-256 sidecar exists for preserved archive
    local target_sha256="${target_file}.sha256"
    if [ ! -f "$target_sha256" ]; then
        (cd "$(dirname "$target_file")" && sha256sum "$target_name" > "$(basename "$target_sha256")") 2>/dev/null || true
    fi

    echo "Uploading preserved archive ${target_name} (${target_hr}) to ${BACKUP_DIR}..."
    log_message "Uploading preserved archive: ${target_name} (${target_hr})"

    # Also stage to local backup drive if mounted and not yet present
    local local_backup_path
    if local_backup_path=$(get_local_backup_path) && [ -d "${local_backup_path}" ]; then
        if [ ! -f "${local_backup_path}/${target_name}" ]; then
            echo "Staging copy of preserved archive to local backup drive..."
            handle_local_backup "${target_file}" "${target_name}"
        fi
    fi

    local rclone_log="${LOG_FILE}.rclone"
    local rclone_common_opts=(
        --retries 3
        --low-level-retries 10
        --drive-chunk-size "${RCLONE_DRIVE_CHUNK_SIZE}"
        --drive-upload-cutoff "${RCLONE_DRIVE_CHUNK_SIZE}"
        --timeout 30m
        --contimeout 60s
    )
    [ -n "$RCLONE_BWLIMIT" ] && rclone_common_opts+=(--bwlimit "$RCLONE_BWLIMIT")

    if rclone copy "${rclone_common_opts[@]}" "${rclone_progress_opts[@]}" --log-file "$rclone_log" "${target_file}" "${BACKUP_DIR}"; then
        if [ -f "$target_sha256" ]; then
            rclone copy --retries 3 --low-level-retries 5 --timeout 5m "$target_sha256" "${BACKUP_DIR}" >> "$rclone_log" 2>&1 || true
        fi
        local target_manifest="${target_file}.manifest.json"
        if [ -f "$target_manifest" ]; then
            rclone copy --retries 3 --low-level-retries 5 --timeout 5m "$target_manifest" "${BACKUP_DIR}" >> "$rclone_log" 2>&1 || true
        fi
        local duration_str
        duration_str=$(format_duration $(( SECONDS - upload_start_time )))
        log_message "Preserved archive upload completed successfully: ${target_name} (${target_hr} in ${duration_str})"
        echo "Upload of ${target_name} succeeded in ${duration_str}!"
        rm -f "${target_file}" "${target_sha256}" "${target_manifest}"
        run_rotation
        send_notification "normal" "Backup Upload Succeeded" "Preserved archive ${target_name} (${target_hr}) successfully uploaded in ${duration_str}." "drive-harddisk"
        return 0
    else
        local err="Failed to upload preserved archive ${target_name}."
        local rclone_errors=""
        if [ -f "$rclone_log" ]; then
            rclone_errors=$(grep -E "(ERROR|Failed to|fatal)" "$rclone_log" 2>/dev/null | tail -n 5)
            [ -z "$rclone_errors" ] && rclone_errors=$(tail -n 5 "$rclone_log" 2>/dev/null)
        fi
        [ -n "$rclone_errors" ] && err="${err} | Details: ${rclone_errors}"
        log_message "$err"
        echo "ERROR: $err" >&2
        send_notification "critical" "Backup Upload Failed" "Could not upload preserved archive ${target_name}." "dialog-error"
        return 1
    fi
}

#---
#   FUNCTION:  manage_preserved_archives()
#  DESCRIPTION:  Provides an interactive menu or non-interactive handler to inspect,
#                retry uploading, or delete preserved backup archives.
#---
manage_preserved_archives() {
    local opt="${1:-}"
    local preserved_archives=()
    mapfile -t preserved_archives < <(get_preserved_archives)
    local count=${#preserved_archives[@]}

    if [ "$count" -eq 0 ]; then
        echo -e "\nNo preserved archives from failed uploads found in ${SOURCE_DIR}."
        return 0
    fi

    case "$opt" in
        --list|-l)
            echo "Found ${count} preserved failed-upload archive(s) in ${SOURCE_DIR}:"
            for p in "${preserved_archives[@]}"; do
                local p_bytes p_hr p_mtime
                p_bytes=$(stat -c %s "$p" 2>/dev/null || echo 0)
                p_hr=$(numfmt --to=iec --suffix=B "$p_bytes" 2>/dev/null || echo "${p_bytes}B")
                p_mtime=$(date -r "$p" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c "%y" "$p" 2>/dev/null | cut -d'.' -f1)
                printf "  %-9s %s  %s\n" "$p_hr" "$p_mtime" "$(basename "$p")"
            done
            return 0
            ;;
        --delete|-d)
            echo "Deleting all ${count} preserved failed-upload archive(s)..."
            for p in "${preserved_archives[@]}"; do
                log_message "Deleting preserved archive: $(basename "$p")"
                rm -f "$p" "${p}.sha256" "${p}.manifest.json"
            done
            echo "All preserved archive(s) deleted."
            return 0
            ;;
        --retry|-r)
            echo "Retrying upload for all ${count} preserved archive(s)..."
            local upload_err=0
            for p in "${preserved_archives[@]}"; do
                if ! upload_preserved_archive "$p"; then
                    upload_err=1
                fi
            done
            return $upload_err
            ;;
    esac

    if [ ! -t 0 ]; then
        echo "Non-interactive run: retrying upload for all ${count} preserved archive(s)..."
        log_message "Non-interactive batch retry of ${count} preserved archive(s)."
        local upload_err=0
        for p in "${preserved_archives[@]}"; do
            if ! upload_preserved_archive "$p"; then
                upload_err=1
            fi
        done
        return $upload_err
    fi

    while true; do
        mapfile -t preserved_archives < <(get_preserved_archives)
        count=${#preserved_archives[@]}

        if [ "$count" -eq 0 ]; then
            echo -e "\nAll preserved archives have been processed or removed."
            return 0
        fi

        echo
        echo "==============================================================================="
        echo "  Preserved Failed-Upload Archives Management (${count} detected)"
        echo "==============================================================================="
        local idx=1
        for p in "${preserved_archives[@]}"; do
            local p_bytes p_hr p_mtime
            p_bytes=$(stat -c %s "$p" 2>/dev/null || echo 0)
            p_hr=$(numfmt --to=iec --suffix=B "$p_bytes" 2>/dev/null || echo "${p_bytes}B")
            p_mtime=$(date -r "$p" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c "%y" "$p" 2>/dev/null | cut -d'.' -f1)
            printf "  %d) %-9s %s  %s\n" "$idx" "$p_hr" "$p_mtime" "$(basename "$p")"
            ((idx++))
        done
        echo "==============================================================================="
        echo "Actions:"
        echo "1) Retry uploading ALL preserved archive(s) to cloud"
        echo "2) Select a specific archive to retry uploading"
        echo "3) Delete ALL preserved archive(s)"
        echo "4) Select a specific archive to delete"
        echo "5) Return to previous menu"
        local action_choice=""
        if ! read -r -p "Please select [1-5, default: 5]: " action_choice; then
            echo -e "\nExiting."
            return 0
        fi

        case "${action_choice:-5}" in
            1)
                local success_count=0
                for p in "${preserved_archives[@]}"; do
                    if upload_preserved_archive "$p"; then
                        ((success_count++))
                    fi
                done
                echo "Processed ${count} archive(s): ${success_count} succeeded."
                ;;
            2)
                echo -e "\nChoose an archive to upload:"
                local file_names=()
                for p in "${preserved_archives[@]}"; do
                    file_names+=("$(basename "$p")")
                done
                local sel_name=""
                select sel_name in "${file_names[@]}" "Cancel"; do
                    if [ "$sel_name" = "Cancel" ] || [ -z "$sel_name" ]; then
                        echo "Upload cancelled."
                        break
                    fi
                    upload_preserved_archive "${SOURCE_DIR}/${sel_name}"
                    break
                done
                ;;
            3)
                local del_confirm=""
                read -r -p "Are you sure you want to permanently delete ALL ${count} preserved archive(s)? (y/N): " del_confirm
                if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                    for p in "${preserved_archives[@]}"; do
                        log_message "Deleting preserved archive: $(basename "$p")"
                        rm -f "$p" "${p}.sha256" "${p}.manifest.json"
                    done
                    echo "All preserved archive(s) deleted."
                    return 0
                else
                    echo "Deletion cancelled."
                fi
                ;;
            4)
                echo -e "\nChoose an archive to delete:"
                local file_names=()
                for p in "${preserved_archives[@]}"; do
                    file_names+=("$(basename "$p")")
                done
                local sel_name=""
                select sel_name in "${file_names[@]}" "Cancel"; do
                    if [ "$sel_name" = "Cancel" ] || [ -z "$sel_name" ]; then
                        echo "Deletion cancelled."
                        break
                    fi
                    local del_one=""
                    read -r -p "Permanently delete ${sel_name}? (y/N): " del_one
                    if [[ "$del_one" =~ ^[Yy]$ ]]; then
                        log_message "Deleting preserved archive: ${sel_name}"
                        rm -f "${SOURCE_DIR}/${sel_name}" "${SOURCE_DIR}/${sel_name}.sha256" "${SOURCE_DIR}/${sel_name}.manifest.json"
                        echo "Deleted ${sel_name}."
                    else
                        echo "Deletion cancelled."
                    fi
                    break
                done
                ;;
            5)
                return 0
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
    done
}

#---
#   FUNCTION:  handle_running_applications()
#  DESCRIPTION:  Detects active applications with open databases or write activity (e.g. browsers,
#                email clients) prior to archiving. Depending on RUNNING_APPS_ACTION ('prompt',
#                'close', 'sync', 'ignore'), either prompts user interactively, terminates apps
#                gracefully with SIGTERM, or logs and flushes OS/filesystem buffers with sync.
#---
handle_running_applications() {
    local action="${1:-${RUNNING_APPS_ACTION:-close}}"
    local settle_timeout="${RUNNING_APPS_SETTLE_TIMEOUT:-10}"
    local synced=false

    # Normalize action
    case "$action" in
        prompt|ask) action="prompt" ;;
        close|kill|terminate) action="close" ;;
        sync|warn|flush) action="sync" ;;
        ignore|skip|none|false|0) action="ignore" ;;
        *)
            log_message "WARNING: Unknown RUNNING_APPS_ACTION '${action}'. Defaulting to 'close'."
            action="close"
            ;;
    esac

    if [ "$action" = "ignore" ]; then
        log_message "Running applications consistency check skipped (RUNNING_APPS_ACTION=ignore)."
        return 0
    fi

    local target_apps=("${TARGET_RUNNING_APPS[@]}")
    if [ ${#target_apps[@]} -eq 0 ]; then
        target_apps=("${DEFAULT_TARGET_RUNNING_APPS[@]}")
    fi

    # Find running processes matching target applications for current user
    local running_detected=()
    for app in "${target_apps[@]}"; do
        [ -z "$app" ] && continue
        if pgrep -u "$CURRENT_USER" -x "$app" &>/dev/null; then
            running_detected+=("$app")
        fi
    done

    if [ ${#running_detected[@]} -gt 0 ]; then
        log_message "Active target application(s) detected: ${running_detected[*]} (Action mode: ${action})"

        if [ "$action" = "prompt" ]; then
            if [ -t 0 ]; then
                echo
                echo "==============================================================================="
                echo "  NOTICE: Active Application(s) Detected"
                echo "==============================================================================="
                echo "  The following application(s) with active databases are currently running:"
                for a in "${running_detected[@]}"; do
                    local p_count
                    p_count=$(pgrep -u "$CURRENT_USER" -x "$a" 2>/dev/null | wc -l | tr -d '[:space:]')
                    echo "    - $a (${p_count:-1} process(es))"
                done
                echo
                echo "  Backing up while applications are active may cause transient 'file changed'"
                echo "  warnings or archive intermediate database journal writes."
                echo "==============================================================================="
                echo "Choose an action:"
                echo "1) Close applications gracefully (SIGTERM) and proceed"
                echo "2) Flush filesystem buffers (sync) and proceed without closing [Default]"
                echo "3) Abort backup"
                local user_choice=""
                read -r -p "Please select [1-3, default: 2]: " user_choice
                case "${user_choice:-2}" in
                    1)
                        action="close"
                        ;;
                    3)
                        echo "Backup aborted by user."
                        log_message "Backup aborted by user due to running applications (${running_detected[*]})."
                        return 1
                        ;;
                    *)
                        action="sync"
                        ;;
                esac
            else
                # Non-interactive shell (timer, cron, background): keep GUI sessions alive, proceed with sync
                log_message "Non-interactive run: leaving running application(s) active and proceeding with filesystem sync."
                echo "Active application(s) detected (${running_detected[*]}). Flushing filesystem buffers and proceeding..."
                action="sync"
            fi
        fi

        if [ "$action" = "close" ]; then
            echo "Closing active application(s) gracefully..."
            local any_closed=false
            for app in "${running_detected[@]}"; do
                log_message "Sending SIGTERM to process '$app'..."
                if pkill -u "$CURRENT_USER" -TERM -x "$app" 2>/dev/null; then
                    any_closed=true
                fi
            done

            if [ "$any_closed" = true ]; then
                echo "Waiting up to ${settle_timeout}s for applications to write state and exit..."
                local waited=0
                while [ "$waited" -lt "$settle_timeout" ]; do
                    local still_running=0
                    for app in "${running_detected[@]}"; do
                        if pgrep -u "$CURRENT_USER" -x "$app" &>/dev/null; then
                            still_running=1
                            break
                        fi
                    done
                    [ "$still_running" -eq 0 ] && break
                    sleep 1
                    ((waited++))
                done

                # Check if any stubborn processes remain
                local remaining=()
                for app in "${running_detected[@]}"; do
                    if pgrep -u "$CURRENT_USER" -x "$app" &>/dev/null; then
                        remaining+=("$app")
                    fi
                done
                if [ ${#remaining[@]} -gt 0 ]; then
                    log_message "WARNING: Process(es) still running after ${settle_timeout}s: ${remaining[*]}."
                    echo "WARNING: ${remaining[*]} still active after ${settle_timeout}s. Continuing..."
                else
                    log_message "All target applications exited cleanly."
                    echo "Target application(s) closed cleanly."
                fi

                # Flush dirty operating system caches, disk write buffers, and SQLite WAL journals immediately after closing apps
                echo "Flushing filesystem buffers to disk after closing application(s)..."
                sync -f "$SOURCE_DIR" 2>/dev/null || sync
                log_message "Filesystem buffers flushed via sync after closing application(s)."
                synced=true
            fi
        fi
    else
        log_message "No sensitive target applications detected running."
        echo "No conflicting target applications were running."
    fi

    # Flush dirty operating system caches, disk write buffers, and SQLite WAL journals if not already synced
    if [ "$synced" = false ]; then
        echo "Flushing filesystem buffers to disk..."
        sync -f "$SOURCE_DIR" 2>/dev/null || sync
        log_message "Filesystem buffers flushed via sync."
    fi
    return 0
}

#---
#   FUNCTION:  run_backup()
#  DESCRIPTION:  Creates an encrypted tarball and uploads it using rclone.
#---
run_backup() {
    local start_time=$SECONDS
    local do_verify=false
    local verify_forced_source=""
    local verify_checksum_only=false
    local cli_apps_action=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --alert-email|-ae)
                if [ -n "${2:-}" ]; then
                    ALERT_EMAIL="$2"
                    shift 2
                else
                    echo "ERROR: Missing email address for --alert-email." >&2
                    return 1
                fi
                ;;
            --alert-from|-af)
                if [ -n "${2:-}" ]; then
                    ALERT_FROM="$2"
                    shift 2
                else
                    echo "ERROR: Missing sender address for --alert-from." >&2
                    return 1
                fi
                ;;
            --apps-action|-aa)
                if [[ "${2:-}" =~ ^(prompt|ask|close|kill|terminate|sync|warn|flush|ignore|skip|none)$ ]]; then
                    cli_apps_action="$2"
                    shift 2
                else
                    echo "ERROR: Invalid --apps-action option '${2:-}'. Use 'prompt', 'close', 'sync', or 'ignore'." >&2
                    return 1
                fi
                ;;
            --close-apps|--kill-apps)
                cli_apps_action="close"
                shift
                ;;
            --prompt-apps|--ask-apps)
                cli_apps_action="prompt"
                shift
                ;;
            --no-close-apps|--sync-apps)
                cli_apps_action="sync"
                shift
                ;;
            --ignore-apps)
                cli_apps_action="ignore"
                shift
                ;;
            --exclude-tag|-et)
                if [ -n "${2:-}" ]; then
                    ENABLE_EXCLUDE_TAGS=true
                    EXCLUDE_TAG_FILES+=("$2")
                    shift 2
                else
                    echo "ERROR: Missing tag filename for --exclude-tag." >&2
                    return 1
                fi
                ;;
            --no-exclude-tags|--no-tags)
                ENABLE_EXCLUDE_TAGS=false
                shift
                ;;
            --exclude-ignore|-ei)
                if [ -n "${2:-}" ]; then
                    ENABLE_EXCLUDE_IGNORE=true
                    EXCLUDE_IGNORE_FILES+=("$2")
                    shift 2
                else
                    echo "ERROR: Missing ignore filename for --exclude-ignore." >&2
                    return 1
                fi
                ;;
            --no-exclude-ignore|--no-ignore)
                ENABLE_EXCLUDE_IGNORE=false
                shift
                ;;
            --verify|-v)
                do_verify=true
                if [[ "${2:-}" == "local" || "${2:-}" == "cloud" || "${2:-}" == "auto" ]]; then
                    verify_forced_source="$2"
                    shift
                fi
                shift
                ;;
            --verify-checksum|--verify-quick|-vc)
                do_verify=true
                verify_checksum_only=true
                if [[ "${2:-}" == "local" || "${2:-}" == "cloud" || "${2:-}" == "auto" ]]; then
                    verify_forced_source="$2"
                    shift
                fi
                shift
                ;;
            --no-verify)
                do_verify=false
                shift
                ;;
            --asymmetric|--pubkey)
                ENCRYPTION_MODE="asymmetric"
                if [ -n "${2:-}" ] && [[ "${2:-}" != -* ]]; then
                    GPG_RECIPIENTS+=("$2")
                    shift
                fi
                shift
                ;;
            --symmetric|--passphrase)
                ENCRYPTION_MODE="symmetric"
                shift
                ;;
            --hybrid)
                ENCRYPTION_MODE="hybrid"
                if [ -n "${2:-}" ] && [[ "${2:-}" != -* ]]; then
                    GPG_RECIPIENTS+=("$2")
                    shift
                fi
                shift
                ;;
            --recipient|-r)
                if [ -n "${2:-}" ]; then
                    GPG_RECIPIENTS+=("$2")
                    shift 2
                else
                    echo "ERROR: Missing recipient for --recipient / -r." >&2
                    return 1
                fi
                ;;
            --mirror-cloud)
                MIRROR_SCRIPT_TO_CLOUD=true
                shift
                ;;
            --no-mirror-cloud)
                MIRROR_SCRIPT_TO_CLOUD=false
                shift
                ;;
            --mirror-local)
                MIRROR_SCRIPT_TO_LOCAL=true
                shift
                ;;
            --no-mirror-local)
                MIRROR_SCRIPT_TO_LOCAL=false
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ "$AUTO_VERIFY_BACKUP" = true ] || [ "$AUTO_VERIFY_BACKUP" = "1" ] || [ "$AUTO_VERIFY_BACKUP" = "local" ] || [ "$AUTO_VERIFY_BACKUP" = "cloud" ] || [ "$AUTO_VERIFY_BACKUP" = "checksum" ] || [ "$AUTO_VERIFY_BACKUP" = "quick" ] || [ "$AUTO_VERIFY_BACKUP" = "checksum-local" ] || [ "$AUTO_VERIFY_BACKUP" = "checksum-cloud" ]; then
        do_verify=true
        if [ -z "$verify_forced_source" ]; then
            if [[ "$AUTO_VERIFY_BACKUP" == "local" || "$AUTO_VERIFY_BACKUP" == "cloud" ]]; then
                verify_forced_source="$AUTO_VERIFY_BACKUP"
            elif [[ "$AUTO_VERIFY_BACKUP" == "checksum-local" ]]; then
                verify_forced_source="local"
                verify_checksum_only=true
            elif [[ "$AUTO_VERIFY_BACKUP" == "checksum-cloud" ]]; then
                verify_forced_source="cloud"
                verify_checksum_only=true
            elif [[ "$AUTO_VERIFY_BACKUP" == "checksum" || "$AUTO_VERIFY_BACKUP" == "quick" ]]; then
                verify_checksum_only=true
            fi
        fi
    fi

    if [ "$ENCRYPTION_MODE" = "asymmetric" ]; then
        if ! validate_gpg_recipients; then
            return 1
        fi
        log_message "Using GPG asymmetric encryption (recipients: ${GPG_RECIPIENTS[*]})."
        echo "Using GPG asymmetric encryption (recipients: ${GPG_RECIPIENTS[*]})."
    elif [ "$ENCRYPTION_MODE" = "hybrid" ]; then
        if ! validate_gpg_recipients; then
            return 1
        fi
        log_message "Using GPG hybrid encryption (passphrase + recipients: ${GPG_RECIPIENTS[*]})."
        echo "Using GPG hybrid encryption (passphrase + recipients: ${GPG_RECIPIENTS[*]})."
        if ! get_encryption_password "backup"; then
            return 1
        fi
    else
        # Default: symmetric
        if ! get_encryption_password "backup"; then
            return 1
        fi
    fi

    log_message "Starting backup of $SOURCE_DIR to $BACKUP_DIR"
    if [ "${INHIBITED:-0}" -eq 1 ]; then
        log_message "System sleep/shutdown inhibition active via systemd-inhibit."
    fi

    # --- Check for preserved archives from previous failed uploads ---
    local preserved_archives=()
    mapfile -t preserved_archives < <(get_preserved_archives)
    if [ ${#preserved_archives[@]} -gt 0 ]; then
        log_message "Found ${#preserved_archives[@]} preserved failed-upload archive(s) in ${SOURCE_DIR}."
        if [ -t 0 ]; then
            echo
            echo "==============================================================================="
            echo "  NOTICE: Preserved Failed-Upload Archive(s) Detected"
            echo "==============================================================================="
            echo "  Found ${#preserved_archives[@]} local archive(s) preserved from previous failed upload(s):"
            for p in "${preserved_archives[@]}"; do
                local p_bytes p_hr
                p_bytes=$(stat -c %s "$p" 2>/dev/null || echo 0)
                p_hr=$(numfmt --to=iec --suffix=B "$p_bytes" 2>/dev/null || echo "${p_bytes}B")
                echo "    - $(basename "$p") (${p_hr})"
            done
            echo "==============================================================================="
            echo "Choose an action for preserved archive(s):"
            echo "1) Retry uploading preserved archive(s) now"
            echo "2) Manage preserved archive(s) (select / inspect / delete)"
            echo "3) Delete all preserved archive(s) and proceed with fresh backup"
            echo "4) Keep preserved archive(s) and proceed with fresh backup"
            echo "5) Abort backup"
            local pres_choice=""
            read -r -p "Please select [1-5, default: 1]: " pres_choice
            case "${pres_choice:-1}" in
                1)
                    local upload_fail=0
                    for p in "${preserved_archives[@]}"; do
                        if ! upload_preserved_archive "$p"; then
                            upload_fail=1
                        fi
                    done
                    if [ "$upload_fail" -eq 0 ]; then
                        echo
                        local proceed_new=""
                        read -r -p "Preserved archive(s) uploaded and removed. Create another new backup now? (y/N): " proceed_new
                        if [[ ! "$proceed_new" =~ ^[Yy]$ ]]; then
                            echo "Backup finished."
                            return 0
                        fi
                    else
                        echo "Preserved archive upload encountered error(s). Aborting backup." >&2
                        return 1
                    fi
                    ;;
                2)
                    manage_preserved_archives
                    echo
                    local proceed_new=""
                    read -r -p "Proceed with fresh backup now? (y/N): " proceed_new
                    if [[ ! "$proceed_new" =~ ^[Yy]$ ]]; then
                        echo "Backup finished."
                        return 0
                    fi
                    ;;
                3)
                    local del_confirm=""
                    read -r -p "Are you sure you want to permanently delete all ${#preserved_archives[@]} preserved archive(s)? (y/N): " del_confirm
                    if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                        for p in "${preserved_archives[@]}"; do
                            log_message "Deleting preserved archive: $(basename "$p")"
                            rm -f "$p" "${p}.sha256" "${p}.manifest.json"
                        done
                        echo "Preserved archive(s) deleted. Proceeding with fresh backup..."
                    else
                        echo "Deletion cancelled. Keeping preserved archive(s) and proceeding..."
                    fi
                    ;;
                4)
                    echo "Keeping preserved archive(s). Proceeding with fresh backup..."
                    ;;
                5)
                    echo "Backup aborted by user."
                    return 0
                    ;;
                *)
                    echo "Invalid choice. Aborting backup." >&2
                    return 1
                    ;;
            esac
        else
            local p_names=""
            for p in "${preserved_archives[@]}"; do
                p_names="${p_names:+${p_names}, }$(basename "$p")"
            done
            log_message "WARNING: Preserved failed-upload archive(s) present in ${SOURCE_DIR} during unattended run: ${p_names}."
            send_notification "normal" "Preserved Backups Present" "Preserved backup archive(s) in ~ (${p_names}). Run backup or manage-preserved to handle."
        fi
    fi
    
    # --- Pre-flight check: Verify cloud remote connectivity if configured ---
    local cloud_available=true
    local cloud_preflight_msg=""
    if [[ "$BACKUP_DIR" == *:* ]]; then
        echo "Verifying cloud remote connectivity (${BACKUP_DIR%%:*})..."
        local rclone_err_tmp
        rclone_err_tmp=$(rclone lsf --max-depth 1 --contimeout 5s --timeout 8s "${BACKUP_DIR}" 2>&1)
        local rclone_preflight_rc=$?
        if [ "$rclone_preflight_rc" -ne 0 ]; then
            cloud_available=false
            cloud_preflight_msg=$(echo "$rclone_err_tmp" | tr '\n' ' ' | sed 's/  */ /g')
            local local_backup_path
            if local_backup_path=$(get_local_backup_path 2>/dev/null) && [ -d "${local_backup_path}" ]; then
                echo "WARNING: Cloud remote '${BACKUP_DIR}' is unreachable (${cloud_preflight_msg:-exit code $rclone_preflight_rc})."
                echo "Local backup drive is available at: ${local_backup_path}"
                log_message "WARNING: Cloud remote unreachable during pre-flight check (${cloud_preflight_msg:-exit code $rclone_preflight_rc}). Continuing with local backup drive."
                if [ -t 0 ]; then
                    local proceed_local=""
                    read -r -p "Proceed with local-only backup to external drive? [Y/n]: " proceed_local
                    if [[ "$proceed_local" =~ ^[Nn]$ ]]; then
                        echo "Backup aborted by user."
                        log_message "Backup aborted by user due to unreachable cloud remote."
                        return 0
                    fi
                fi
            else
                local ERROR_MSG="ERROR: Cloud remote '${BACKUP_DIR}' is unreachable (${cloud_preflight_msg:-exit code $rclone_preflight_rc}) and no local backup drive is mounted. Aborting backup."
                log_message "$ERROR_MSG"
                echo "$ERROR_MSG" >&2
                send_notification "critical" "Backup Aborted" "Cloud remote unreachable and no local backup drive mounted."
                return 1
            fi
        else
            log_message "Cloud remote connectivity check passed (${BACKUP_DIR})."
            echo "Cloud remote connectivity check passed."
        fi
    fi

    mkdir -p "${SCRATCH_DIR}"
    chmod 700 "${SCRATCH_DIR}"

    # --- Pre-flight check: Verify sufficient disk space in SCRATCH_DIR ---
    echo "Checking available disk space for scratch directory..."
    local avail_kb
    avail_kb=$(df -Pk "${SCRATCH_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')
    local min_required_kb=$((MIN_FREE_SPACE_GB * 1024 * 1024))
    local space_reason="configured minimum (${MIN_FREE_SPACE_GB}G)"

    # Dynamically estimate required space based on the largest recent backup archive
    local last_backup_bytes=""
    local space_source=""
    local local_backup_path
    if local_backup_path=$(get_local_backup_path 2>/dev/null) && [ -d "${local_backup_path}" ]; then
        last_backup_bytes=$(find "${local_backup_path}" -maxdepth 1 -type f \( -name "${TARBALL_BASENAME}_*.tar.zst.gpg" -o -name "${TARBALL_BASENAME}_*.tar.gz.gpg" -o -name "${TARBALL_BASENAME}_*.tar.xz.gpg" \) -printf "%s\n" 2>/dev/null | sort -n | tail -n 1)
        if [ -n "$last_backup_bytes" ] && [ "$last_backup_bytes" -gt 0 ] 2>/dev/null; then
            space_source="local"
        fi
    fi

    # Fallback to the most recent cloud archive if local drive is unavailable or has no archives
    if [ -z "$last_backup_bytes" ] || [ "$last_backup_bytes" -le 0 ] 2>/dev/null; then
        if [ "$cloud_available" = true ]; then
            echo "Local drive unavailable for size estimation. Checking cloud backups..."
            last_backup_bytes=$(rclone lsl --fast-list "${BACKUP_DIR}" 2>/dev/null | grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" | sort -k4 | tail -n 1 | awk '{print $1}')
            if [ -n "$last_backup_bytes" ] && [ "$last_backup_bytes" -gt 0 ] 2>/dev/null; then
                space_source="cloud"
            fi
        fi
    fi

    if [ -n "$last_backup_bytes" ] && [ "$last_backup_bytes" -gt 0 ] 2>/dev/null; then
        # Add 25% safety headroom on top of previous archive size
        local dynamic_required_kb=$(( (last_backup_bytes / 1024) * 125 / 100 ))
        if [ "$dynamic_required_kb" -gt "$min_required_kb" ]; then
            min_required_kb="$dynamic_required_kb"
            local last_hr
            last_hr=$(numfmt --to=iec --from-unit=1 "${last_backup_bytes}" 2>/dev/null || echo "$((last_backup_bytes / 1024 / 1024 / 1024))G")
            space_reason="previous ${space_source:+$space_source }archive (${last_hr}) + 25% headroom"
        fi
    fi

    if [ -n "$avail_kb" ]; then
        local avail_hr req_hr
        avail_hr=$(numfmt --to=iec --from-unit=1024 "${avail_kb}" 2>/dev/null || echo "$((avail_kb / 1024 / 1024))G")
        req_hr=$(numfmt --to=iec --from-unit=1024 "${min_required_kb}" 2>/dev/null || echo "$((min_required_kb / 1024 / 1024))G")
        if [ "$avail_kb" -lt "$min_required_kb" ]; then
            local ERROR_MSG="ERROR: Insufficient disk space in ${SCRATCH_DIR}. Available: ${avail_hr}, required: ${req_hr} (${space_reason}). Aborting backup."
            log_message "$ERROR_MSG"
            echo "$ERROR_MSG" >&2
            send_notification "critical" "Backup Aborted" "Insufficient disk space in ${SCRATCH_DIR} (${avail_hr} available, ${req_hr} required)."
            return 1
        fi
        log_message "Disk space check passed. Available: ${avail_hr} (required: ${req_hr}, based on ${space_reason})."
        echo "Disk space check passed: ${avail_hr} available (required: ${req_hr}, based on ${space_reason})."
    fi

    local TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
    local TEMP_TARBALL_NAME="${TARBALL_BASENAME}_${TIMESTAMP}.tar.zst"
    local ENCRYPTED_TARBALL_NAME="${TEMP_TARBALL_NAME}.gpg"
    local FULL_ENCRYPTED_PATH="${SCRATCH_DIR}/${ENCRYPTED_TARBALL_NAME}"

    CURRENT_TEMP_ARCHIVE=""
    CURRENT_ENCRYPTED_ARCHIVE="${FULL_ENCRYPTED_PATH}"

    # --- Pre-backup lifecycle hook ---
    if ! execute_lifecycle_hook "pre" "starting" "${SOURCE_DIR}" "${BACKUP_DIR}"; then
        local ERROR_MSG="ERROR: Pre-backup lifecycle hook returned non-zero exit status. Aborting backup."
        log_message "$ERROR_MSG"
        echo "$ERROR_MSG" >&2
        send_notification "critical" "Backup Aborted" "Pre-backup lifecycle hook failed."
        execute_lifecycle_hook "post" "failure" "${ENCRYPTED_TARBALL_NAME}" "0B" "0s" "Aborted" "Aborted" "Aborted" 2>/dev/null || true
        return 1
    fi

    # --- Pre-flight check: Application & database consistency guard ---
    if ! handle_running_applications "${cli_apps_action:-${RUNNING_APPS_ACTION:-close}}"; then
        local ERROR_MSG="Backup aborted by user or application consistency guard."
        execute_lifecycle_hook "post" "failure" "${ENCRYPTED_TARBALL_NAME}" "0B" "0s" "Aborted" "Aborted" "Aborted" 2>/dev/null || true
        return 1
    fi

    # Mark that scratch files are being created for this instance
    SCRATCH_FILES_CREATED=1

    # Stage system state metadata files inside dedicated staging subdirectory in SCRATCH_DIR
    local staging_dir="${SYSTEM_STATE_STAGING_DIR}"
    mkdir -p "${staging_dir}"
    chmod 700 "${staging_dir}"
    CURRENT_METADATA_STAGING_DIR="${staging_dir}"

    # --- Step 0: Backup Crontab ---
    echo "Backing up crontab..."
    log_message "Backing up crontab to ${staging_dir}/${CRONTAB_BACKUP_FILE}"
    if crontab -l > "${staging_dir}/${CRONTAB_BACKUP_FILE}" 2>/dev/null; then
        log_message "Crontab backed up successfully."
    else
        log_message "No crontab found or failed to read crontab. Creating empty backup file."
        touch "${staging_dir}/${CRONTAB_BACKUP_FILE}"
    fi

    # --- Step 0.5: Backup Pipx packages ---
    echo "Backing up pipx packages..."
    log_message "Backing up pipx packages to ${staging_dir}/${PIPX_SPEC_FILE}"
    if command -v pipx &> /dev/null; then
        if (cd "${SOURCE_DIR}" && pipx list --json > "${staging_dir}/${PIPX_SPEC_FILE}" 2>/dev/null); then
            log_message "Pipx packages backed up successfully."
        else
            log_message "WARNING: Failed to export pipx packages."
        fi
    else
        log_message "WARNING: pipx command not found. Skipping pipx backup."
    fi

    # --- Step 0.75: Backup Flatpak remotes and packages ---
    echo "Backing up flatpak remotes and packages..."
    log_message "Backing up flatpak configurations to ${staging_dir}/${FLATPAK_REMOTES_FILE} and ${staging_dir}/${FLATPAK_PACKAGES_FILE}"
    if command -v flatpak &> /dev/null; then
        if flatpak remotes --columns=name:f,url:f,options:f > "${staging_dir}/${FLATPAK_REMOTES_FILE}" 2>/dev/null && \
           flatpak list --app --columns=application:f,origin:f,installation:f,branch:f > "${staging_dir}/${FLATPAK_PACKAGES_FILE}" 2>/dev/null; then
            log_message "Flatpak remotes and packages backed up successfully."
        else
            log_message "WARNING: Failed to export flatpak remotes or packages."
        fi
    else
        log_message "WARNING: flatpak command not found. Skipping flatpak backup."
    fi

    # --- Step 0.85: Backup enabled Systemd user units ---
    echo "Backing up enabled systemd user units..."
    log_message "Backing up enabled systemd user units to ${staging_dir}/${SYSTEMD_USER_UNITS_FILE}"
    if command -v systemctl &> /dev/null; then
        if systemctl --user list-unit-files --state=enabled --no-legend --no-pager > "${staging_dir}/${SYSTEMD_USER_UNITS_FILE}" 2>/dev/null; then
            log_message "Systemd user units backed up successfully."
        else
            log_message "WARNING: Failed to export systemd user units."
            touch "${staging_dir}/${SYSTEMD_USER_UNITS_FILE}"
        fi
    else
        log_message "WARNING: systemctl command not found. Skipping systemd user units backup."
    fi

    # --- Step 0.90: Backup Desktop (dconf) settings ---
    echo "Backing up desktop (dconf) settings..."
    log_message "Backing up desktop settings to ${staging_dir}/${DCONF_SETTINGS_FILE}"
    if command -v dconf &> /dev/null; then
        if dconf dump / > "${staging_dir}/${DCONF_SETTINGS_FILE}" 2>/dev/null; then
            log_message "Desktop (dconf) settings backed up successfully."
        else
            log_message "WARNING: Failed to export dconf settings."
            touch "${staging_dir}/${DCONF_SETTINGS_FILE}"
        fi
    else
        log_message "WARNING: dconf command not found. Skipping desktop settings backup."
    fi

    # --- Step 0.95: Backup manually installed APT packages ---
    echo "Backing up manually installed APT package list..."
    log_message "Backing up manual APT package list to ${staging_dir}/${APT_PACKAGES_FILE}"
    if command -v apt-mark &> /dev/null; then
        if apt-mark showmanual > "${staging_dir}/${APT_PACKAGES_FILE}" 2>/dev/null; then
            log_message "Manual APT package list backed up successfully."
        else
            log_message "WARNING: Failed to export manual APT package list."
            touch "${staging_dir}/${APT_PACKAGES_FILE}"
        fi
    else
        log_message "WARNING: apt-mark command not found. Skipping APT package list backup."
    fi

    # --- Step 0.96: Backup APT repository sources and signing keyrings ---
    echo "Backing up APT repository sources and signing keyrings..."
    log_message "Backing up APT repository sources and keyrings to ${staging_dir}/${APT_REPOS_FILE}"
    if [ -d /etc/apt ]; then
        local apt_items_to_backup=()
        [ -f /etc/apt/sources.list ] && apt_items_to_backup+=("sources.list")
        [ -d /etc/apt/sources.list.d ] && apt_items_to_backup+=("sources.list.d")
        [ -d /etc/apt/keyrings ] && apt_items_to_backup+=("keyrings")
        [ -d /etc/apt/trusted.gpg.d ] && apt_items_to_backup+=("trusted.gpg.d")

        if [ ${#apt_items_to_backup[@]} -gt 0 ]; then
            if tar -czf "${staging_dir}/${APT_REPOS_FILE}" -C /etc/apt \
                --exclude='*.save' --exclude='*.bak' --exclude='*~' \
                "${apt_items_to_backup[@]}" 2>/dev/null; then
                log_message "APT repositories and keyrings backed up successfully."
            else
                log_message "WARNING: Failed to export APT repositories and keyrings."
                rm -f "${staging_dir}/${APT_REPOS_FILE}" 2>/dev/null || true
            fi
        else
            log_message "No APT repository sources or keyrings found to back up."
        fi
    else
        log_message "WARNING: /etc/apt directory not found. Skipping APT repository backup."
    fi

    # --- Step 0.97: Backup user-installed DNF packages ---
    if command -v dnf &> /dev/null; then
        echo "Backing up user-installed DNF package list..."
        log_message "Backing up user-installed DNF package list to ${staging_dir}/${DNF_PACKAGES_FILE}"
        if dnf repoquery --userinstalled --queryformat "%{name}\n" > "${staging_dir}/${DNF_PACKAGES_FILE}" 2>/dev/null; then
            log_message "User-installed DNF package list backed up successfully."
        else
            log_message "WARNING: Failed to export user-installed DNF package list."
            touch "${staging_dir}/${DNF_PACKAGES_FILE}"
        fi
    fi

    # --- Step 0.98: Backup DNF repository configurations and RPM GPG keys ---
    if [ -d /etc/yum.repos.d ] || [ -d /etc/pki/rpm-gpg ]; then
        echo "Backing up DNF repository configurations and RPM GPG keys..."
        log_message "Backing up DNF repository configurations and RPM GPG keys to ${staging_dir}/${DNF_REPOS_FILE}"
        local dnf_items_to_backup=()
        [ -d /etc/yum.repos.d ] && dnf_items_to_backup+=("yum.repos.d")
        [ -d /etc/pki/rpm-gpg ] && dnf_items_to_backup+=("pki/rpm-gpg")

        if [ ${#dnf_items_to_backup[@]} -gt 0 ]; then
            if tar -czf "${staging_dir}/${DNF_REPOS_FILE}" -C /etc \
                --exclude='*.rpmsave' --exclude='*.rpmnew' --exclude='*~' \
                "${dnf_items_to_backup[@]}" 2>/dev/null; then
                log_message "DNF repositories and RPM GPG keys backed up successfully."
            else
                log_message "WARNING: Failed to export DNF repositories and RPM GPG keys."
                rm -f "${staging_dir}/${DNF_REPOS_FILE}" 2>/dev/null || true
            fi
        else
            log_message "No DNF repository sources or RPM GPG keys found to back up."
        fi
    fi

    # Build array of staged metadata files for seamless root-level archiving in tar
    local staged_metadata_files=()
    [ -f "${staging_dir}/${CRONTAB_BACKUP_FILE}" ] && staged_metadata_files+=("${CRONTAB_BACKUP_FILE}")
    [ -f "${staging_dir}/${PIPX_SPEC_FILE}" ] && staged_metadata_files+=("${PIPX_SPEC_FILE}")
    [ -f "${staging_dir}/${FLATPAK_REMOTES_FILE}" ] && staged_metadata_files+=("${FLATPAK_REMOTES_FILE}")
    [ -f "${staging_dir}/${FLATPAK_PACKAGES_FILE}" ] && staged_metadata_files+=("${FLATPAK_PACKAGES_FILE}")
    [ -f "${staging_dir}/${SYSTEMD_USER_UNITS_FILE}" ] && staged_metadata_files+=("${SYSTEMD_USER_UNITS_FILE}")
    [ -f "${staging_dir}/${DCONF_SETTINGS_FILE}" ] && staged_metadata_files+=("${DCONF_SETTINGS_FILE}")
    [ -f "${staging_dir}/${APT_PACKAGES_FILE}" ] && staged_metadata_files+=("${APT_PACKAGES_FILE}")
    [ -f "${staging_dir}/${APT_REPOS_FILE}" ] && staged_metadata_files+=("${APT_REPOS_FILE}")
    [ -f "${staging_dir}/${DNF_PACKAGES_FILE}" ] && staged_metadata_files+=("${DNF_PACKAGES_FILE}")
    [ -f "${staging_dir}/${DNF_REPOS_FILE}" ] && staged_metadata_files+=("${DNF_REPOS_FILE}")

    local tar_staging_opts=()
    if [ ${#staged_metadata_files[@]} -gt 0 ]; then
        tar_staging_opts+=("-C" "${staging_dir}" "${staged_metadata_files[@]}")
    fi

    # --- Step 1: Create and encrypt the archive (streaming tar directly into gpg) ---
    echo "Creating and encrypting backup archive..."
    log_message "Creating encrypted archive at ${FULL_ENCRYPTED_PATH} (streaming tar directly into gpg)"
    
    # Safety Check: Guard against root-level exclusion tag files causing an empty archive
    if [ "$ENABLE_EXCLUDE_TAGS" = true ] || [ "$ENABLE_EXCLUDE_TAGS" = "1" ]; then
        for _tag in "${EXCLUDE_TAG_FILES[@]}"; do
            if [ -n "$_tag" ] && [ -e "${SOURCE_DIR}/${_tag}" ]; then
                local root_tag_err="ERROR: Root-level exclusion tag '${SOURCE_DIR}/${_tag}' detected! Placing an exclusion tag in the root of SOURCE_DIR causes GNU tar to exclude all files, resulting in an empty archive. Please remove or rename '${SOURCE_DIR}/${_tag}' before proceeding."
                echo "$root_tag_err" >&2
                log_message "$root_tag_err"
                send_failure_email "$root_tag_err" 2>/dev/null || true
                cleanup
            fi
        done
    fi

    local TAR_EXCLUDE_OPTS=()
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        TAR_EXCLUDE_OPTS+=("--exclude=$pattern")
    done

    local tar_tag_opts=()
    if [ "$ENABLE_EXCLUDE_TAGS" = true ] || [ "$ENABLE_EXCLUDE_TAGS" = "1" ]; then
        for _tag in "${EXCLUDE_TAG_FILES[@]}"; do
            [ -n "$_tag" ] && tar_tag_opts+=("--exclude-tag-all=${_tag}")
        done
    fi

    local tar_ignore_opts=()
    if [ "$ENABLE_EXCLUDE_IGNORE" = true ] || [ "$ENABLE_EXCLUDE_IGNORE" = "1" ]; then
        for _ign in "${EXCLUDE_IGNORE_FILES[@]}"; do
            [ -n "$_ign" ] && tar_ignore_opts+=("--exclude-ignore-recursive=${_ign}")
        done
    fi

    local tar_fs_opts=()
    if [ "$TAR_ONE_FILE_SYSTEM" = true ] || [ "$TAR_ONE_FILE_SYSTEM" = "1" ]; then
        tar_fs_opts+=("--one-file-system")
    fi
    if [ "$TAR_IGNORE_FAILED_READ" = true ] || [ "$TAR_IGNORE_FAILED_READ" = "1" ]; then
        tar_fs_opts+=("--ignore-failed-read" "--warning=no-file-removed")
    fi

    local tar_checkpoint_opts=("--checkpoint=10000" "--checkpoint-action=echo=Archived %u records...")
    if [ -t 1 ]; then
        tar_checkpoint_opts=("--checkpoint=10000" "--checkpoint-action=ttyout=\rArchiving: %u records...   ")
    fi

    local zstd_compress_cmd="zstd -${ZSTD_LEVEL} -T0 --check"
    if [ "${ZSTD_LEVEL:-6}" -gt 19 ] 2>/dev/null; then
        zstd_compress_cmd="${zstd_compress_cmd} --ultra"
    fi
    if [ "$ZSTD_LONG" = true ] || [ "$ZSTD_LONG" = "1" ]; then
        zstd_compress_cmd="${zstd_compress_cmd} --long=27"
    elif [[ "$ZSTD_LONG" =~ ^[0-9]+$ ]] && [ "$ZSTD_LONG" -gt 0 ]; then
        zstd_compress_cmd="${zstd_compress_cmd} --long=${ZSTD_LONG}"
    fi

    local backup_tmp_dir
    backup_tmp_dir=$(mktemp -d)
    CURRENT_BACKUP_TMP_DIR="$backup_tmp_dir"
    local gpg_err_file="${backup_tmp_dir}/gpg.err"
    local tar_err_file="${backup_tmp_dir}/tar.err"
    local tar_fifo="${backup_tmp_dir}/tar.fifo"
    mkfifo "$tar_fifo"

    tee "$tar_err_file" < "$tar_fifo" >&2 &
    local tee_pid=$!

    local gpg_encrypt_args=(--batch --yes --no-tty)
    if [ "$ENCRYPTION_MODE" = "asymmetric" ]; then
        gpg_encrypt_args+=(--trust-model always)
        for r in "${GPG_RECIPIENTS[@]}"; do
            gpg_encrypt_args+=(-r "$r")
        done
        gpg_encrypt_args+=(-z 0 --encrypt -o "${FULL_ENCRYPTED_PATH}")
        tar "${tar_fs_opts[@]}" --totals --sparse --exclude-caches-all "${tar_tag_opts[@]}" "${tar_ignore_opts[@]}" -l --acls --xattrs --xattrs-include='*' -I "${zstd_compress_cmd}" "${tar_checkpoint_opts[@]}" -cpf - "${TAR_EXCLUDE_OPTS[@]}" "${tar_staging_opts[@]}" -C "${SOURCE_DIR}" . 2>"$tar_fifo" \
            | gpg "${gpg_encrypt_args[@]}" 2>"$gpg_err_file"
    elif [ "$ENCRYPTION_MODE" = "hybrid" ]; then
        gpg_encrypt_args+=(--pinentry-mode loopback --trust-model always)
        for r in "${GPG_RECIPIENTS[@]}"; do
            gpg_encrypt_args+=(-r "$r")
        done
        gpg_encrypt_args+=(--encrypt --symmetric --cipher-algo AES256 -z 0 --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 --passphrase-fd 3 -o "${FULL_ENCRYPTED_PATH}")
        tar "${tar_fs_opts[@]}" --totals --sparse --exclude-caches-all "${tar_tag_opts[@]}" "${tar_ignore_opts[@]}" -l --acls --xattrs --xattrs-include='*' -I "${zstd_compress_cmd}" "${tar_checkpoint_opts[@]}" -cpf - "${TAR_EXCLUDE_OPTS[@]}" "${tar_staging_opts[@]}" -C "${SOURCE_DIR}" . 2>"$tar_fifo" \
            | gpg "${gpg_encrypt_args[@]}" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file"
    else
        # Default: symmetric
        tar "${tar_fs_opts[@]}" --totals --sparse --exclude-caches-all "${tar_tag_opts[@]}" "${tar_ignore_opts[@]}" -l --acls --xattrs --xattrs-include='*' -I "${zstd_compress_cmd}" "${tar_checkpoint_opts[@]}" -cpf - "${TAR_EXCLUDE_OPTS[@]}" "${tar_staging_opts[@]}" -C "${SOURCE_DIR}" . 2>"$tar_fifo" \
            | gpg --batch --yes --no-tty --pinentry-mode loopback --symmetric --cipher-algo AES256 \
                  -z 0 --s2k-mode 3 --s2k-count 65011712 --s2k-digest-algo SHA512 \
                  --passphrase-fd 3 -o "${FULL_ENCRYPTED_PATH}" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file"
    fi
    local pipe_statuses=("${PIPESTATUS[@]}")
    wait "$tee_pid" 2>/dev/null || true
    [ -t 1 ] && echo
    local tar_exit_code=${pipe_statuses[0]}
    local gpg_exit_code=${pipe_statuses[1]}

    local gpg_err_msg=""
    [ -f "$gpg_err_file" ] && gpg_err_msg=$(<"$gpg_err_file")

    local tar_err_lines=()
    if [ -f "$tar_err_file" ]; then
        mapfile -t tar_err_lines < <(tr -d '\r' < "$tar_err_file" 2>/dev/null | grep -v -E "(Total bytes written:|records\.\.\.)" | sed -e 's/^[[:space:]]*//' -e '/^$/d')
    fi

    # Extract uncompressed bytes from tar totals output
    local uncompressed_bytes=0
    local uncompressed_size_hr="unknown"
    if [ -f "$tar_err_file" ]; then
        uncompressed_bytes=$(grep -E "Total bytes written:" "$tar_err_file" 2>/dev/null | tail -n 1 | sed -n 's/.*Total bytes written: *\([0-9]*\).*/\1/p')
        if [ -n "$uncompressed_bytes" ] && [ "$uncompressed_bytes" -gt 0 ] 2>/dev/null; then
            uncompressed_size_hr=$(numfmt --to=iec --suffix=B "${uncompressed_bytes}" 2>/dev/null || echo "${uncompressed_bytes}B")
        else
            uncompressed_bytes=0
        fi
    fi

    rm -rf "$backup_tmp_dir" 2>/dev/null
    CURRENT_BACKUP_TMP_DIR=""

    # Snapshot metadata counts for companion manifest before removing temporary files
    local crontab_backed_up=false
    [ -s "${staging_dir}/${CRONTAB_BACKUP_FILE}" ] && crontab_backed_up=true

    local pipx_backed_up=false
    [ -s "${staging_dir}/${PIPX_SPEC_FILE}" ] && pipx_backed_up=true

    local flatpak_remotes_count=0
    [ -s "${staging_dir}/${FLATPAK_REMOTES_FILE}" ] && flatpak_remotes_count=$(wc -l < "${staging_dir}/${FLATPAK_REMOTES_FILE}" 2>/dev/null || echo 0)

    local flatpak_packages_count=0
    [ -s "${staging_dir}/${FLATPAK_PACKAGES_FILE}" ] && flatpak_packages_count=$(wc -l < "${staging_dir}/${FLATPAK_PACKAGES_FILE}" 2>/dev/null || echo 0)

    local systemd_units_count=0
    [ -s "${staging_dir}/${SYSTEMD_USER_UNITS_FILE}" ] && systemd_units_count=$(grep -c '^[a-zA-Z0-9_@.-]' "${staging_dir}/${SYSTEMD_USER_UNITS_FILE}" 2>/dev/null || echo 0)

    local dconf_backed_up=false
    [ -s "${staging_dir}/${DCONF_SETTINGS_FILE}" ] && dconf_backed_up=true

    local apt_packages_count=0
    [ -s "${staging_dir}/${APT_PACKAGES_FILE}" ] && apt_packages_count=$(wc -l < "${staging_dir}/${APT_PACKAGES_FILE}" 2>/dev/null || echo 0)

    local apt_repos_backed_up=false
    [ -f "${staging_dir}/${APT_REPOS_FILE}" ] && apt_repos_backed_up=true

    local dnf_packages_count=0
    [ -s "${staging_dir}/${DNF_PACKAGES_FILE}" ] && dnf_packages_count=$(wc -l < "${staging_dir}/${DNF_PACKAGES_FILE}" 2>/dev/null || echo 0)

    local dnf_repos_backed_up=false
    [ -f "${staging_dir}/${DNF_REPOS_FILE}" ] && dnf_repos_backed_up=true

    # Clean up staged temporary metadata files in SCRATCH_DIR
    rm -rf "${staging_dir}" 2>/dev/null || true
    CURRENT_METADATA_STAGING_DIR=""

    # 1. Check GPG encryption failure first:
    # If GPG failed (non-zero and not broken-pipe 141), or if tar terminated due to SIGPIPE (141) while GPG failed
    if [ "$gpg_exit_code" -ne 0 ] && [ "$gpg_exit_code" -ne 141 ]; then
        local ERROR_MSG="GPG encryption failed with exit code ${gpg_exit_code}. Aborting."
        log_message "$ERROR_MSG: ${gpg_err_msg}"
        echo "$ERROR_MSG" >&2
        [ -n "$gpg_err_msg" ] && echo "$gpg_err_msg" >&2
        rm -f "${FULL_ENCRYPTED_PATH}" # Clean up partial file
        CURRENT_ENCRYPTED_ARCHIVE=""
        SCRATCH_FILES_CREATED=0
        rmdir "${SCRATCH_DIR}" 2>/dev/null || true
        send_notification "critical" "Backup Failed" "Could not encrypt the local backup archive (GPG error ${gpg_exit_code})."
        execute_lifecycle_hook "post" "failure" "${ENCRYPTED_TARBALL_NAME:-}" "0B" "0s" "Skipped" "Failed" "Failed" 2>/dev/null || true
        return 1
    fi

    # 2. Check tar fatal error:
    # Ignore SIGPIPE (141) if GPG also exited non-zero
    if [ "$tar_exit_code" -gt 1 ] && [ "$tar_exit_code" -ne 141 ]; then
        local ERROR_MSG="tar failed with fatal error code ${tar_exit_code}. Aborting."
        log_message "$ERROR_MSG"
        if [ ${#tar_err_lines[@]} -gt 0 ]; then
            log_message "tar fatal error output (${#tar_err_lines[@]} line(s)):"
            for _err in "${tar_err_lines[@]}"; do
                log_message "  [tar error] ${_err}"
            done
        fi
        echo "$ERROR_MSG" >&2
        if [ ${#tar_err_lines[@]} -gt 0 ]; then
            for _err in "${tar_err_lines[@]}"; do
                echo "  ${_err}" >&2
            done
        fi
        rm -f "${FULL_ENCRYPTED_PATH}" # Clean up partial file
        CURRENT_ENCRYPTED_ARCHIVE=""
        SCRATCH_FILES_CREATED=0
        rmdir "${SCRATCH_DIR}" 2>/dev/null || true
        send_notification "critical" "Backup Failed" "Could not create the local backup archive (tar exit code ${tar_exit_code})."
        execute_lifecycle_hook "post" "failure" "${ENCRYPTED_TARBALL_NAME:-}" "0B" "0s" "Skipped" "Failed" "Failed" 2>/dev/null || true
        return 1
    fi

    # 3. Catch-all for unresolved pipeline errors
    if [ "$gpg_exit_code" -ne 0 ] || [ "$tar_exit_code" -gt 1 ]; then
        local ERROR_MSG="Archive creation pipeline failed (tar exit: ${tar_exit_code}, GPG exit: ${gpg_exit_code}). Aborting."
        log_message "$ERROR_MSG: ${gpg_err_msg}"
        if [ ${#tar_err_lines[@]} -gt 0 ]; then
            for _err in "${tar_err_lines[@]}"; do
                log_message "  [tar error] ${_err}"
            done
        fi
        echo "$ERROR_MSG" >&2
        [ -n "$gpg_err_msg" ] && echo "$gpg_err_msg" >&2
        if [ ${#tar_err_lines[@]} -gt 0 ]; then
            for _err in "${tar_err_lines[@]}"; do
                echo "  ${_err}" >&2
            done
        fi
        rm -f "${FULL_ENCRYPTED_PATH}"
        CURRENT_ENCRYPTED_ARCHIVE=""
        SCRATCH_FILES_CREATED=0
        rmdir "${SCRATCH_DIR}" 2>/dev/null || true
        send_notification "critical" "Backup Failed" "Archive creation pipeline failed."
        execute_lifecycle_hook "post" "failure" "${ENCRYPTED_TARBALL_NAME:-}" "0B" "0s" "Skipped" "Failed" "Failed" 2>/dev/null || true
        return 1
    fi

    if [ "$tar_exit_code" -eq 1 ]; then
        local num_tar_warnings=${#tar_err_lines[@]}
        if [ "$num_tar_warnings" -gt 0 ]; then
            log_message "tar completed with non-fatal warnings (${num_tar_warnings} diagnostic line(s)):"
            for _warn in "${tar_err_lines[@]}"; do
                log_message "  [tar warning] ${_warn}"
            done
            if [ -t 1 ]; then
                echo "tar completed with ${num_tar_warnings} non-fatal warning(s) (e.g. files modified during read):"
                local display_limit=5
                local i=0
                for ((i=0; i<num_tar_warnings && i<display_limit; i++)); do
                    echo "  - ${tar_err_lines[i]}"
                done
                if [ "$num_tar_warnings" -gt "$display_limit" ]; then
                    echo "  ... and $(( num_tar_warnings - display_limit )) more (see full details in $LOG_FILE)"
                fi
            else
                echo "tar completed with ${num_tar_warnings} non-fatal warning(s) (see $LOG_FILE)."
            fi
        else
            log_message "tar completed with non-fatal warnings (exit code 1)."
            echo "tar completed with non-fatal warnings. Continuing..."
        fi
    fi

    log_message "Encrypted tarball created successfully."
    echo "Encrypted archive created successfully."

    # Generate SHA-256 sidecar checksum
    local ENCRYPTED_SHA256_NAME="${ENCRYPTED_TARBALL_NAME}.sha256"
    local FULL_SHA256_PATH="${SCRATCH_DIR}/${ENCRYPTED_SHA256_NAME}"
    CURRENT_SHA256_FILE="${FULL_SHA256_PATH}"

    echo "Generating SHA-256 checksum sidecar..."
    local sha256_checksum=""
    if (cd "${SCRATCH_DIR}" && sha256sum "${ENCRYPTED_TARBALL_NAME}" > "${ENCRYPTED_SHA256_NAME}"); then
        log_message "Generated SHA-256 sidecar checksum: ${ENCRYPTED_SHA256_NAME}"
        sha256_checksum=$(awk '{print $1}' "${FULL_SHA256_PATH}" 2>/dev/null)
    else
        log_message "WARNING: Failed to generate SHA-256 sidecar checksum."
    fi

    # Record archive size before potential deletion / upload
    local archive_bytes=0 archive_size_hr="unknown"
    if [ -f "${FULL_ENCRYPTED_PATH}" ]; then
        archive_bytes=$(stat -c %s "${FULL_ENCRYPTED_PATH}" 2>/dev/null || echo 0)
        archive_size_hr=$(numfmt --to=iec --suffix=B "${archive_bytes}" 2>/dev/null || echo "${archive_bytes}B")
    fi

    # Calculate compression ratio and space savings percentage
    local compression_ratio="unknown"
    local space_savings_percent="unknown"
    if [ "$uncompressed_bytes" -gt 0 ] 2>/dev/null && [ "$archive_bytes" -gt 0 ] 2>/dev/null; then
        read -r compression_ratio space_savings_percent < <(awk -v u="$uncompressed_bytes" -v c="$archive_bytes" 'BEGIN {
            r = u / c;
            s = (1 - (c / u)) * 100;
            if (s < 0) s = 0.0;
            printf "%.2fx %.1f%%\n", r, s;
        }' 2>/dev/null || echo "unknown unknown")
    fi

    # Generate companion JSON manifest if enabled
    local ENCRYPTED_MANIFEST_NAME="${ENCRYPTED_TARBALL_NAME}.manifest.json"
    local FULL_MANIFEST_PATH="${SCRATCH_DIR}/${ENCRYPTED_MANIFEST_NAME}"
    CURRENT_MANIFEST_FILE=""
    if [ "$GENERATE_MANIFEST" = true ] || [ "$GENERATE_MANIFEST" = "1" ]; then
        echo "Generating lightweight backup manifest..."
        local cur_duration=$(( SECONDS - start_time ))
        local cur_duration_hr
        cur_duration_hr=$(format_duration "$cur_duration")
        local tar_warning_bool="false"
        [ "$tar_exit_code" -eq 1 ] && tar_warning_bool="true"

        generate_backup_manifest "$FULL_MANIFEST_PATH" \
            "$ENCRYPTED_TARBALL_NAME" "$archive_bytes" "$archive_size_hr" \
            "$sha256_checksum" "$cur_duration" "$cur_duration_hr" "$tar_warning_bool" \
            "$crontab_backed_up" "$pipx_backed_up" "$flatpak_remotes_count" \
            "$flatpak_packages_count" "$systemd_units_count" "$dconf_backed_up" \
            "$apt_packages_count" "$apt_repos_backed_up" \
            "$dnf_packages_count" "$dnf_repos_backed_up" \
            "Pending" "Pending" \
            "$uncompressed_bytes" "$uncompressed_size_hr" "$compression_ratio" "$space_savings_percent"
        CURRENT_MANIFEST_FILE="${FULL_MANIFEST_PATH}"
        log_message "Generated backup manifest: ${ENCRYPTED_MANIFEST_NAME}"
    fi

    # --- Step 3.5: Local Drive Backup ---
    local local_backup_status="Skipped (not mounted)"
    handle_local_backup "${FULL_ENCRYPTED_PATH}" "${ENCRYPTED_TARBALL_NAME}"
    local local_rc=$?
    if [ "$local_rc" -eq 0 ]; then
        local_backup_status="OK"
    elif [ "$local_rc" -eq 2 ]; then
        local_backup_status="Skipped (not mounted)"
    else
        local_backup_status="Failed"
    fi
    update_manifest_destination_status "$FULL_MANIFEST_PATH" "local_backup" "$local_backup_status"

    # --- Step 4: Upload the encrypted tarball ---
    local cloud_backup_status="OK"
    if [ "$cloud_available" = true ]; then
        echo "Uploading archive to ${BACKUP_DIR}..."
        local rclone_progress_opts=()
        if [ -t 1 ]; then
            rclone_progress_opts=("-P")
        else
            rclone_progress_opts=("--stats" "15s" "--stats-one-line" "--stats-log-level" "NOTICE")
        fi

        local rclone_log="${LOG_FILE}.rclone"
        local rclone_common_opts=(
            --retries 3
            --low-level-retries 10
            --drive-chunk-size "${RCLONE_DRIVE_CHUNK_SIZE}"
            --drive-upload-cutoff "${RCLONE_DRIVE_CHUNK_SIZE}"
            --timeout 30m
            --contimeout 60s
        )
        [ -n "$RCLONE_BWLIMIT" ] && rclone_common_opts+=(--bwlimit "$RCLONE_BWLIMIT")

        if ! rclone copy "${rclone_common_opts[@]}" "${rclone_progress_opts[@]}" --log-file "$rclone_log" "${FULL_ENCRYPTED_PATH}" "${BACKUP_DIR}"; then
            cloud_backup_status="Failed"
            update_manifest_destination_status "$FULL_MANIFEST_PATH" "cloud_backup" "Failed"
            local local_backup_path
            if local_backup_path=$(get_local_backup_path 2>/dev/null) && [ -n "$local_backup_path" ] && [ -d "$local_backup_path" ]; then
                update_manifest_destination_status "${local_backup_path}/${ENCRYPTED_MANIFEST_NAME}" "cloud_backup" "Failed"
            fi

            PRESERVE_ARCHIVE=true
            local PRESERVED_PATH="${SOURCE_DIR}/${ENCRYPTED_TARBALL_NAME}"
            if mv "${FULL_ENCRYPTED_PATH}" "${PRESERVED_PATH}"; then
                local ERROR_MSG="Failed to upload archive. Local encrypted tarball preserved at: ${PRESERVED_PATH}"
                CURRENT_ENCRYPTED_ARCHIVE="${PRESERVED_PATH}"
                if [ -f "${FULL_SHA256_PATH}" ]; then
                    mv -f "${FULL_SHA256_PATH}" "${SOURCE_DIR}/${ENCRYPTED_SHA256_NAME}" 2>/dev/null || true
                    CURRENT_SHA256_FILE="${SOURCE_DIR}/${ENCRYPTED_SHA256_NAME}"
                fi
                if [ -f "${FULL_MANIFEST_PATH}" ]; then
                    mv -f "${FULL_MANIFEST_PATH}" "${SOURCE_DIR}/${ENCRYPTED_MANIFEST_NAME}" 2>/dev/null || true
                    CURRENT_MANIFEST_FILE="${SOURCE_DIR}/${ENCRYPTED_MANIFEST_NAME}"
                fi
            else
                local ERROR_MSG="Failed to upload archive. Local encrypted tarball preserved at: ${FULL_ENCRYPTED_PATH}"
                PRESERVED_PATH="${FULL_ENCRYPTED_PATH}"
            fi
            local rclone_errors=""
            if [ -f "$rclone_log" ]; then
                rclone_errors=$(grep -E "(ERROR|Failed to|fatal)" "$rclone_log" 2>/dev/null | tail -n 10)
                [ -z "$rclone_errors" ] && rclone_errors=$(tail -n 10 "$rclone_log" 2>/dev/null)
            fi
            [ -n "$rclone_errors" ] && ERROR_MSG="${ERROR_MSG} | Details: ${rclone_errors}"
            log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
            if [ -n "$rclone_errors" ]; then
                echo -e "\n--- Last rclone log entries (${rclone_log}) ---" >&2
                echo "$rclone_errors" >&2
                echo "----------------------------------------" >&2
            fi
            send_notification "critical" "Backup Failed" "Upload failed. Archive preserved at ${PRESERVED_PATH}."
            return 1
        fi

        cloud_backup_status="OK"
        update_manifest_destination_status "$FULL_MANIFEST_PATH" "cloud_backup" "OK"
        local local_backup_path
        if local_backup_path=$(get_local_backup_path 2>/dev/null) && [ -n "$local_backup_path" ] && [ -d "$local_backup_path" ]; then
            update_manifest_destination_status "${local_backup_path}/${ENCRYPTED_MANIFEST_NAME}" "cloud_backup" "OK"
        fi

        # Also upload the companion SHA-256 sidecar to cloud
        if [ -f "${FULL_SHA256_PATH}" ]; then
            echo "Uploading SHA-256 sidecar to ${BACKUP_DIR}..."
            rclone copy --retries 3 --low-level-retries 5 --timeout 5m "${FULL_SHA256_PATH}" "${BACKUP_DIR}" >> "$rclone_log" 2>&1 || log_message "WARNING: Failed to upload SHA-256 sidecar to cloud storage."
        fi

        # Also upload the companion manifest to cloud
        if [ -f "${FULL_MANIFEST_PATH}" ]; then
            echo "Uploading backup manifest to ${BACKUP_DIR}..."
            rclone copy --retries 3 --low-level-retries 5 --timeout 5m "${FULL_MANIFEST_PATH}" "${BACKUP_DIR}" >> "$rclone_log" 2>&1 || log_message "WARNING: Failed to upload backup manifest to cloud storage."
        fi

        # Also mirror disaster recovery cheatsheet and standalone script to cloud if enabled
        if [ "$MIRROR_SCRIPT_TO_CLOUD" = true ] || [ "$MIRROR_SCRIPT_TO_CLOUD" = "1" ]; then
            mirror_script_and_cheatsheet_to_cloud "${BACKUP_DIR}" "${SCRATCH_DIR}" "$rclone_log"
        fi
        
        log_message "Upload completed successfully."
        echo "Upload completed successfully."

        # --- Step 5: Clean up local encrypted tarball and rotate ---
        rm -f "${FULL_ENCRYPTED_PATH}" "${FULL_SHA256_PATH}" "${FULL_MANIFEST_PATH}"
        CURRENT_ENCRYPTED_ARCHIVE=""
        CURRENT_SHA256_FILE=""
        CURRENT_MANIFEST_FILE=""
        rmdir "${SCRATCH_DIR}" 2>/dev/null || true
        SCRATCH_FILES_CREATED=0
        run_rotation
    else
        cloud_backup_status="Skipped (unreachable)"
        echo "Skipping cloud upload (cloud remote was unreachable during pre-flight check)."
        log_message "Skipped cloud upload: remote was unreachable during pre-flight check."
        update_manifest_destination_status "$FULL_MANIFEST_PATH" "cloud_backup" "Skipped (unreachable)"
        local local_backup_path
        if local_backup_path=$(get_local_backup_path 2>/dev/null) && [ -n "$local_backup_path" ] && [ -d "$local_backup_path" ]; then
            update_manifest_destination_status "${local_backup_path}/${ENCRYPTED_MANIFEST_NAME}" "cloud_backup" "Skipped (unreachable)"
        fi

        local should_preserve="$PRESERVE_ARCHIVE"
        if [ "$local_rc" -ne 0 ]; then
            should_preserve=true
            log_message "WARNING: Neither local drive nor cloud storage received backup. Forcing archive preservation in ${SOURCE_DIR} to prevent data loss."
            echo "WARNING: Neither destination received backup. Preserving encrypted archive in ${SOURCE_DIR}..." >&2
        fi

        if [ "$should_preserve" = true ]; then
            local PRESERVED_PATH="${SOURCE_DIR}/${ENCRYPTED_TARBALL_NAME}"
            if mv "${FULL_ENCRYPTED_PATH}" "${PRESERVED_PATH}"; then
                log_message "Encrypted tarball preserved at ${PRESERVED_PATH} for later upload."
                CURRENT_ENCRYPTED_ARCHIVE="${PRESERVED_PATH}"
                if [ -f "${FULL_SHA256_PATH}" ]; then
                    mv -f "${FULL_SHA256_PATH}" "${SOURCE_DIR}/${ENCRYPTED_SHA256_NAME}" 2>/dev/null || true
                    CURRENT_SHA256_FILE="${SOURCE_DIR}/${ENCRYPTED_SHA256_NAME}"
                fi
                if [ -f "${FULL_MANIFEST_PATH}" ]; then
                    mv -f "${FULL_MANIFEST_PATH}" "${SOURCE_DIR}/${ENCRYPTED_MANIFEST_NAME}" 2>/dev/null || true
                    CURRENT_MANIFEST_FILE="${SOURCE_DIR}/${ENCRYPTED_MANIFEST_NAME}"
                fi
                echo "Archive preserved at: ${PRESERVED_PATH}"
            fi
        else
            rm -f "${FULL_ENCRYPTED_PATH}" "${FULL_SHA256_PATH}" "${FULL_MANIFEST_PATH}"
            CURRENT_ENCRYPTED_ARCHIVE=""
            CURRENT_SHA256_FILE=""
            CURRENT_MANIFEST_FILE=""
        fi
        rmdir "${SCRATCH_DIR}" 2>/dev/null || true
        SCRATCH_FILES_CREATED=0
    fi

    # --- Step 6: Post-Backup Integrity Verification ---
    local verify_status="Skipped"
    local verify_exit_code=0
    if [ "$do_verify" = true ]; then
        echo
        echo "=================================================="
        echo "  Post-Backup Integrity Verification"
        echo "=================================================="
        local verify_target="${ENCRYPTED_TARBALL_NAME}"
        local effective_verify_source="${verify_forced_source}"

        if [ "$cloud_available" = false ] && [ "$local_rc" -ne 0 ]; then
            # Both destinations failed/skipped; archive was preserved in SOURCE_DIR
            verify_target="${SOURCE_DIR}/${ENCRYPTED_TARBALL_NAME}"
            effective_verify_source="local"
            log_message "Verifying preserved archive directly in ${SOURCE_DIR} (external destinations unavailable)..."
        elif [ "$cloud_available" = false ] && [ -z "$effective_verify_source" ]; then
            effective_verify_source="local"
        fi

        local verify_args=()
        if [ "$verify_checksum_only" = true ]; then
            verify_args+=("--checksum-only")
        fi
        verify_args+=("${verify_target}")
        [ -n "$effective_verify_source" ] && verify_args+=("${effective_verify_source}")

        log_message "Starting chained post-backup verification for ${verify_target} (${effective_verify_source:-auto}${verify_checksum_only:+, checksum-only})..."
        if run_verify "${verify_args[@]}"; then
            if [ "$verify_checksum_only" = true ]; then
                verify_status="Checksum OK"
            else
                verify_status="Verified OK"
            fi
            log_message "Post-backup integrity verification succeeded for ${verify_target}."
        else
            verify_exit_code=$?
            verify_status="FAILED"
            log_message "ERROR: Post-backup integrity verification failed for ${verify_target} (exit code ${verify_exit_code})."
        fi
    fi
    
    # Calculate duration and format metrics summary
    local duration_secs=$(( SECONDS - start_time ))
    local duration_str
    duration_str=$(format_duration "$duration_secs")

    local summary_oneline="Backup completed in ${duration_str} | Size: ${archive_size_hr}"
    if [ -n "$uncompressed_size_hr" ] && [ "$uncompressed_size_hr" != "unknown" ] && [ -n "$compression_ratio" ] && [ "$compression_ratio" != "unknown" ]; then
        summary_oneline="${summary_oneline} (uncompressed: ${uncompressed_size_hr}, ${compression_ratio} / ${space_savings_percent} savings)"
    fi
    summary_oneline="${summary_oneline} | Cloud: ${cloud_backup_status} | Local: ${local_backup_status}"
    if [ "$do_verify" = true ]; then
        summary_oneline="${summary_oneline} | Verify: ${verify_status}"
    fi
    log_message "${summary_oneline}"

    echo
    echo "=================================================="
    echo "  Backup Summary"
    echo "=================================================="
    echo "  Archive:      ${ENCRYPTED_TARBALL_NAME}"
    echo "  Archive Size: ${archive_size_hr}"
    if [ -n "$uncompressed_size_hr" ] && [ "$uncompressed_size_hr" != "unknown" ]; then
        echo "  Uncompressed: ${uncompressed_size_hr}"
        if [ -n "$compression_ratio" ] && [ "$compression_ratio" != "unknown" ]; then
            echo "  Compression:  ${compression_ratio} (${space_savings_percent} space savings)"
        fi
    fi
    echo "  Duration:     ${duration_str}"
    echo "  Cloud:        ${cloud_backup_status} (${BACKUP_DIR})"
    echo "  Local:        ${local_backup_status}"
    if [ "$do_verify" = true ]; then
        echo "  Verify:       ${verify_status}"
    fi
    echo "=================================================="

    # Determine notification title, urgency, and icon based on outcome
    local notif_title="Backup Complete"
    local notif_urgency="normal"
    local notif_icon="drive-harddisk"

    if [ "$verify_exit_code" -ne 0 ]; then
        notif_title="Backup Verification Failed"
        notif_urgency="critical"
        notif_icon="dialog-error"
    elif [ "$cloud_available" = false ] && [ "$local_rc" -ne 0 ]; then
        notif_title="Backup Preserved Locally in ~"
        notif_urgency="critical"
        notif_icon="dialog-warning"
    elif [ "$cloud_backup_status" = "Failed" ] || [ "$local_backup_status" = "Failed" ]; then
        notif_title="Backup Completed with Errors"
        notif_urgency="critical"
        notif_icon="dialog-warning"
    elif [ "$cloud_available" = false ]; then
        notif_title="Backup Complete (Local Only)"
        notif_icon="drive-harddisk"
    fi

    local size_notif="Size: ${archive_size_hr}"
    if [ -n "$compression_ratio" ] && [ "$compression_ratio" != "unknown" ]; then
        size_notif="${size_notif} (${compression_ratio})"
    fi
    local notif_msg="Archive: ${ENCRYPTED_TARBALL_NAME}"$'\n'"${size_notif} • Duration: ${duration_str}"$'\n'"Cloud: ${cloud_backup_status} • Local: ${local_backup_status}"
    if [ "$do_verify" = true ]; then
        notif_msg="${notif_msg}"$'\n'"Verification: ${verify_status}"
    fi
    send_notification "$notif_urgency" "$notif_title" "$notif_msg" "$notif_icon"

    # Determine overall backup status for lifecycle hooks
    local backup_overall_status="success"
    if [ "$verify_exit_code" -ne 0 ] || [ "$cloud_backup_status" = "Failed" ] || [ "$local_backup_status" = "Failed" ]; then
        backup_overall_status="failure"
    elif [ "$cloud_available" = false ] && [ "$local_rc" -ne 0 ]; then
        backup_overall_status="warning"
    fi

    # Execute post-backup lifecycle hook
    execute_lifecycle_hook "post" "$backup_overall_status" "${ENCRYPTED_TARBALL_NAME}" "${archive_size_hr}" "${duration_str}" "${verify_status}" "${cloud_backup_status}" "${local_backup_status}"

    if [ "$backup_overall_status" = "failure" ]; then
        send_failure_email "Backup Verification or Storage Failure" "Backup concluded with errors: verification=${verify_status}, cloud=${cloud_backup_status}, local=${local_backup_status}."
    fi

    if [ "$verify_exit_code" -ne 0 ]; then
        echo "ERROR: Backup archive was created, but post-backup verification failed." >&2
        return 1
    elif [ "$cloud_available" = false ] && [ "$local_rc" -ne 0 ]; then
        echo "WARNING: Backup archive was created and preserved in ${SOURCE_DIR}, but neither local drive nor cloud storage received a copy." >&2
        return 1
    fi

    echo "Backup complete."
    return 0
}

##---
#   FUNCTION:  normalize_restore_pattern()
#  DESCRIPTION:  Normalizes a user-provided file path or wildcard pattern for
#                tar extraction. Backups are rooted at './', so paths are
#                stripped of $SOURCE_DIR / $HOME / ~ prefixes and leading slashes,
#                and prefixed with './' (unless already prefixed or starting with '*').
#---
normalize_restore_pattern() {
    local raw="${1:-}"
    # Trim leading and trailing whitespace
    local pat="${raw#"${raw%%[![:space:]]*}"}"
    pat="${pat%"${pat##*[![:space:]]}"}"
    [ -z "$pat" ] && return 1

    # Strip SOURCE_DIR, HOME, or ~ prefix if provided
    if [ -n "${SOURCE_DIR:-}" ] && [[ "$pat" == "$SOURCE_DIR"* ]]; then
        pat="${pat#"$SOURCE_DIR"}"
    elif [[ "$pat" == "$HOME"* ]]; then
        pat="${pat#"$HOME"}"
    elif [[ "$pat" == "~"* ]]; then
        pat="${pat#"~"}"
    fi

    # Strip leading slashes
    while [[ "$pat" == /* ]]; do
        pat="${pat#/}"
    done

    # If already starts with "./" or "*", return as is
    if [[ "$pat" == ./* ]] || [[ "$pat" == \** ]]; then
        echo "$pat"
    else
        echo "./${pat}"
    fi
    return 0
}

#---
#   FUNCTION:  harden_security_permissions()
#  DESCRIPTION:  Ensures strict standard permissions on sensitive credential and configuration
#                directories (~/.ssh, ~/.gnupg, and ~/.config/backup_script) within the restored target
#                to prevent authentication errors and security warnings.
#---
harden_security_permissions() {
    local target_dir="${1:-$SOURCE_DIR}"
    local ssh_dir="${target_dir}/.ssh"
    local gnupg_dir="${target_dir}/.gnupg"
    local config_dir="${target_dir}/.config/backup_script"
    local hardened_any=false

    if [ -d "$ssh_dir" ]; then
        echo "Hardening permissions on ${ssh_dir}..."
        log_message "Hardening permissions on ${ssh_dir} (directory 700, private keys 600, public keys 644)"
        chmod 700 "$ssh_dir" 2>/dev/null || true
        find "$ssh_dir" -type d -exec chmod 700 {} + 2>/dev/null || true
        find "$ssh_dir" -type f -exec chmod 600 {} + 2>/dev/null || true
        find "$ssh_dir" -type f \( -name "*.pub" -o -name "known_hosts*" \) -exec chmod 644 {} + 2>/dev/null || true
        hardened_any=true
    fi

    if [ -d "$gnupg_dir" ]; then
        echo "Hardening permissions on ${gnupg_dir}..."
        log_message "Hardening permissions on ${gnupg_dir} (directories 700, files 600)"
        chmod 700 "$gnupg_dir" 2>/dev/null || true
        find "$gnupg_dir" -type d -exec chmod 700 {} + 2>/dev/null || true
        find "$gnupg_dir" -type f -exec chmod 600 {} + 2>/dev/null || true
        hardened_any=true
    fi

    if [ -d "$config_dir" ]; then
        echo "Hardening permissions on ${config_dir}..."
        log_message "Hardening permissions on ${config_dir} (directory 700, files 600)"
        chmod 700 "$config_dir" 2>/dev/null || true
        find "$config_dir" -type d -exec chmod 700 {} + 2>/dev/null || true
        find "$config_dir" -type f -exec chmod 600 {} + 2>/dev/null || true
        hardened_any=true
    fi

    if [ "$hardened_any" = true ]; then
        log_message "Post-restore permission hardening completed."
    fi
}

#---
#   FUNCTION:  verify_restore_checksum()
#  DESCRIPTION:  Validates backup archive against its SHA-256 sidecar checksum
#                prior to decryption and extraction. Protects target directories
#                from corrupt archives or bit-rot before touching the filesystem.
#---
verify_restore_checksum() {
    local archive_choice="$1"
    local restore_source="$2"
    local direct_archive_file="$3"
    local force_verify="$4"
    local target_dir="${5:-${SOURCE_DIR}}"

    local do_check=false
    if [ "$force_verify" = true ]; then
        do_check=true
    elif [ "$force_verify" = false ]; then
        log_message "Pre-restore SHA-256 checksum verification explicitly disabled via CLI."
        return 0
    elif [ "$RESTORE_VERIFY_CHECKSUM" = false ] || [ "$RESTORE_VERIFY_CHECKSUM" = "0" ] || [ "$RESTORE_VERIFY_CHECKSUM" = "none" ]; then
        log_message "Pre-restore SHA-256 checksum verification disabled in configuration."
        return 0
    else
        do_check=true
    fi

    if [ "$restore_source" = "local" ] || [ "$restore_source" = "local file" ] || [ -n "$direct_archive_file" ]; then
        local local_sha256_file=""
        local check_dir=""
        if [ -n "$direct_archive_file" ]; then
            local_sha256_file="${direct_archive_file}.sha256"
            check_dir="$(dirname "$direct_archive_file")"
        else
            local local_backup_path
            local_backup_path=$(get_local_backup_path 2>/dev/null || echo "")
            local_sha256_file="${local_backup_path}/${archive_choice}.sha256"
            check_dir="${local_backup_path}"
        fi

        if [ -f "$local_sha256_file" ]; then
            echo "Verifying SHA-256 sidecar checksum ($(basename "$local_sha256_file"))..."
            log_message "Verifying local SHA-256 checksum for ${archive_choice}..."
            if (cd "${check_dir}" && sha256sum -c "$(basename "$local_sha256_file")" --status); then
                echo "SHA-256 sidecar checksum verified OK (no bit-rot detected)."
                log_message "Pre-restore SHA-256 checksum valid for ${archive_choice}."
                return 0
            else
                local ERROR_MSG="ERROR: SHA-256 checksum verification failed for ${archive_choice}. The archive file on disk is corrupted or modified. Aborting restore to protect ${target_dir}."
                log_message "$ERROR_MSG"
                echo "$ERROR_MSG" >&2
                send_notification "critical" "Restore Aborted" "SHA-256 checksum mismatch for ${archive_choice}. Archive is corrupted." "dialog-error"
                return 1
            fi
        else
            if [ "$force_verify" = true ]; then
                local sidecar_basename
                sidecar_basename=$(basename "$local_sha256_file")
                local ERROR_MSG="ERROR: SHA-256 sidecar file '${sidecar_basename}' not found in ${check_dir}."
                log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                send_notification "critical" "Restore Aborted" "SHA-256 sidecar missing for ${archive_choice}." "dialog-warning"
                return 1
            fi
            echo "Notice: No SHA-256 sidecar found for ${archive_choice} in ${check_dir}. Proceeding with restore."
            log_message "No local SHA-256 sidecar found for ${archive_choice}; proceeding with restore."
            return 0
        fi
    else
        # Cloud verification: check sidecar existence and arm single-pass verification
        if [ "$do_check" = false ]; then
            log_message "Skipping pre-restore SHA-256 checksum verification for cloud archive."
            return 0
        fi

        echo "Checking for cloud SHA-256 sidecar checksum (${archive_choice}.sha256)..."
        local cloud_sha_output
        cloud_sha_output=$(rclone cat "${BACKUP_DIR}${archive_choice}.sha256" 2>/dev/null || true)
        if [ -n "$cloud_sha_output" ]; then
            local expected_hash
            expected_hash=$(awk '{print $1}' <<< "$cloud_sha_output")
            if [ -n "$expected_hash" ]; then
                EXPECTED_RESTORE_SHA256="$expected_hash"
                echo "Cloud SHA-256 sidecar detected (${expected_hash:0:12}...). Single-pass integrity validation armed."
                log_message "Cloud SHA-256 sidecar detected for ${archive_choice} (${expected_hash}). Single-pass integrity validation armed."
                return 0
            fi
        fi

        if [ "$force_verify" = true ]; then
            local ERROR_MSG="ERROR: SHA-256 sidecar file '${archive_choice}.sha256' not found in cloud storage."
            log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
            send_notification "critical" "Restore Aborted" "Cloud SHA-256 sidecar missing for ${archive_choice}." "dialog-warning"
            return 1
        fi
        echo "Notice: No SHA-256 sidecar found in cloud storage for ${archive_choice}. Proceeding with restore."
        log_message "No cloud SHA-256 sidecar found for ${archive_choice}; skipping checksum validation."
        EXPECTED_RESTORE_SHA256=""
        return 0
    fi
}

#---
#   FUNCTION:  run_restore()
#  DESCRIPTION:  Interactively or via CLI arguments lets user choose a backup to
#                restore and decrypts it. Supports full home directory restore or
#                selective file/folder/wildcard extraction.
#---
run_restore() {
    local start_time=$SECONDS
    local cli_patterns=()
    local cli_dest=""
    local cli_archive=""
    local cli_source=""
    local cli_yes=false
    local cli_verify_checksum=""
    local cli_stream=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --yes|-y|--batch)
                cli_yes=true
                shift
                ;;
            --verify-checksum|--check-checksum|-vc)
                cli_verify_checksum=true
                shift
                ;;
            --no-verify-checksum|--no-check-checksum|--no-vc)
                cli_verify_checksum=false
                shift
                ;;
            --stream)
                cli_stream="true"
                shift
                ;;
            --no-stream|--stage)
                cli_stream="false"
                shift
                ;;
            --path|-p|--pattern)
                if [ -n "${2:-}" ]; then
                    cli_patterns+=("$2")
                    shift 2
                else
                    shift
                fi
                ;;
            --dest|-d|--target)
                if [ -n "${2:-}" ]; then
                    cli_dest="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --archive|-a)
                if [ -n "${2:-}" ]; then
                    cli_archive="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --source|-s)
                if [ -n "${2:-}" ]; then
                    cli_source="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            help|-h|--help)
                echo "Usage: $0 restore [archive|path] [options] [patterns...]"
                echo
                echo "Options:"
                echo "  --path, -p, --pattern <pattern>   Specific file, folder, or wildcard pattern to restore"
                echo "                                    (can be specified multiple times)"
                echo "  --dest, -d, --target <dir>        Destination directory (default: ${SOURCE_DIR})"
                echo "  --source, -s <local|cloud>        Force restore source"
                echo "  --archive, -a <name|path>         Specify archive filename, path, or 'latest'"
                echo "  --verify-checksum, -vc            Verify SHA-256 sidecar checksum before restoring"
                echo "  --no-verify-checksum, --no-vc     Skip pre-restore SHA-256 sidecar checksum verification"
                echo "  --stream                          Force single-pass cloud streaming directly without scratch space"
                echo "  --no-stream, --stage              Force downloading archive to scratch directory before extracting"
                echo "  --yes, -y, --batch                Non-interactive batch mode (auto-confirm prompts)"
                return 0
                ;;
            *)
                if [ -z "$cli_archive" ] && [[ "$1" == *backup* || "$1" == *.tar.* || "$1" == "latest" || -f "$1" ]]; then
                    cli_archive="$1"
                else
                    cli_patterns+=("$1")
                fi
                shift
                ;;
        esac
    done

    log_message "Finding backups to restore..."
    if [ "${INHIBITED:-0}" -eq 1 ]; then
        log_message "System sleep/shutdown inhibition active via systemd-inhibit."
    fi
    echo "Finding available backups..."

    local restore_source="cloud"
    local local_available=false
    local local_backups=()
    local backups=()
    local backup_choice=""
    local direct_archive_file=""
    local restore_target="$SOURCE_DIR"
    local dest_choice=""
    local custom_dir=""
    local local_backup_path
    local local_rc=0
    local_backup_path=$(get_local_backup_path) || local_rc=$?

    # Check if local backup drive is mounted and has backups
    if [ "$local_rc" -eq 0 ] && [ -n "$local_backup_path" ] && [ -d "${local_backup_path}" ]; then
        mapfile -t local_backups < <(find "${local_backup_path}" -maxdepth 1 -type f \( -name "${TARBALL_BASENAME}_*.tar.zst.gpg" -o -name "${TARBALL_BASENAME}_*.tar.gz.gpg" -o -name "${TARBALL_BASENAME}_*.tar.xz.gpg" \) -printf "%f\n" 2>/dev/null | sort -r)
        if [ ${#local_backups[@]} -gt 0 ]; then
            local_available=true
        fi
    fi

    local preserved_archives=()
    mapfile -t preserved_archives < <(get_preserved_archives)

    # Handle CLI specified source or archive
    if [ -n "$cli_source" ]; then
        case "$cli_source" in
            local)
                if [ "$local_available" = false ] && [ ${#preserved_archives[@]} -eq 0 ]; then
                    local ERROR_MSG="ERROR: Local backup drive is not available and no preserved archives found in ${SOURCE_DIR}."
                    log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                    return 1
                fi
                if [ "$local_available" = true ]; then
                    restore_source="local"
                    backups=("${local_backups[@]}")
                else
                    restore_source="local file"
                    backups=("${preserved_archives[@]}")
                fi
                ;;
            cloud)
                restore_source="cloud"
                ;;
            *)
                echo "ERROR: Invalid source '${cli_source}'. Use 'local' or 'cloud'." >&2
                return 1
                ;;
        esac
    fi

    if [ -n "$cli_archive" ]; then
        if [ "$cli_archive" = "latest" ]; then
            if [ "$local_available" = true ] && [ "$restore_source" != "cloud" ]; then
                restore_source="local"
                backups=("${local_backups[@]}")
                backup_choice="${backups[0]}"
            elif [ ${#preserved_archives[@]} -gt 0 ] && [ "$restore_source" != "cloud" ]; then
                restore_source="local file"
                direct_archive_file="${preserved_archives[0]}"
                backup_choice="$(basename "$direct_archive_file")"
            else
                restore_source="cloud"
                echo "Querying cloud backups..."
                local rclone_output rclone_status
                rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
                rclone_status=$?
                if [ "$rclone_status" -ne 0 ]; then
                    local ERROR_MSG="Failed to query cloud storage (${BACKUP_DIR}): ${rclone_output}"
                    log_message "$ERROR_MSG"; echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                    return 1
                fi
                mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
                if [ ${#backups[@]} -eq 0 ]; then
                    local ERROR_MSG="ERROR: No cloud backups found for host (${HOSTNAME}) at ${BACKUP_DIR}."
                    log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                    return 1
                fi
                backup_choice="${backups[0]}"
            fi
        else
            local req_archive
            req_archive="$(basename "$cli_archive")"
            local direct_file=""
            if [ -f "$cli_archive" ]; then
                direct_file="$cli_archive"
            elif [[ "$cli_archive" =~ ^~(/.*)?$ ]] && [ -f "${HOME}${BASH_REMATCH[1]}" ]; then
                direct_file="${HOME}${BASH_REMATCH[1]}"
            elif [ -f "${SOURCE_DIR}/${req_archive}" ]; then
                direct_file="${SOURCE_DIR}/${req_archive}"
            fi

            if [ -n "$direct_file" ] && [ "$cli_source" != "cloud" ]; then
                direct_archive_file=$(realpath "$direct_file" 2>/dev/null || echo "$direct_file")
                restore_source="local file"
                backup_choice="$(basename "$direct_archive_file")"
            else
                local found_local=false
                if [ "$local_available" = true ] && [ "$cli_source" != "cloud" ]; then
                    for b in "${local_backups[@]}"; do
                        if [ "$b" = "$req_archive" ]; then
                            found_local=true
                            break
                        fi
                    done
                fi
                if [ "$found_local" = true ]; then
                    restore_source="local"
                    backups=("${local_backups[@]}")
                    backup_choice="$req_archive"
                elif [ "$cli_source" = "local" ]; then
                    local ERROR_MSG="ERROR: Specified archive '${req_archive}' not found as local file, in SOURCE_DIR, or on local backup drive."
                    log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                    return 1
                else
                    echo "Checking cloud storage for '${req_archive}'..."
                    local rclone_output rclone_status
                    rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
                    rclone_status=$?
                    if [ "$rclone_status" -ne 0 ]; then
                        local ERROR_MSG="Failed to query cloud storage (${BACKUP_DIR}): ${rclone_output}"
                        log_message "$ERROR_MSG"; echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                        return 1
                    fi
                    if grep -q -F "$req_archive" <<< "$rclone_output"; then
                        restore_source="cloud"
                        backup_choice="$req_archive"
                    else
                        local ERROR_MSG="ERROR: Specified archive '${cli_archive}' not found as local file, in SOURCE_DIR, on local drive, or in cloud storage."
                        log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                        return 1
                    fi
                fi
            fi
        fi
    fi

    if [ -z "$backup_choice" ]; then
        if [ ! -t 0 ] || [ "$cli_yes" = true ]; then
            if [ "$local_available" = true ] && [ "$cli_source" != "cloud" ]; then
                restore_source="local"
                backups=("${local_backups[@]}")
                backup_choice="${backups[0]}"
            elif [ ${#preserved_archives[@]} -gt 0 ] && [ "$cli_source" != "cloud" ]; then
                restore_source="local file"
                direct_archive_file="${preserved_archives[0]}"
                backup_choice="$(basename "$direct_archive_file")"
            else
                restore_source="cloud"
                local rclone_output
                rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1) || true
                mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
                if [ ${#backups[@]} -gt 0 ]; then
                    backup_choice="${backups[0]}"
                fi
            fi
            if [ -z "$backup_choice" ]; then
                echo "ERROR: No backups found for non-interactive restore." >&2
                return 1
            fi
        else
            local source_options=()
            [ "$local_available" = true ] && [ "$cli_source" != "cloud" ] && source_options+=("Local Drive (${local_backup_path}) [Fastest]")
            [ ${#preserved_archives[@]} -gt 0 ] && [ "$cli_source" != "cloud" ] && source_options+=("Preserved Local Archives (${SOURCE_DIR}) [${#preserved_archives[@]} archive(s)]")
            [ "$cli_source" != "local" ] && source_options+=("Cloud Storage (${BACKUP_DIR})")
            source_options+=("Cancel")

            if [ ${#source_options[@]} -gt 2 ]; then
                echo -e "\nChoose restore source:"
                local chosen_source=""
                select chosen_source in "${source_options[@]}"; do
                    case "$chosen_source" in
                        "Local Drive"*)
                            restore_source="local"
                            backups=("${local_backups[@]}")
                            break
                            ;;
                        "Preserved Local Archives"*)
                            restore_source="local file"
                            backups=("${preserved_archives[@]}")
                            break
                            ;;
                        "Cloud Storage"*)
                            restore_source="cloud"
                            break
                            ;;
                        "Cancel"|"")
                            echo "Restore cancelled."
                            return 0
                            ;;
                    esac
                done
            elif [ "$local_available" = true ] && [ "$cli_source" != "cloud" ]; then
                restore_source="local"
                backups=("${local_backups[@]}")
            elif [ ${#preserved_archives[@]} -gt 0 ] && [ "$cli_source" != "cloud" ]; then
                restore_source="local file"
                backups=("${preserved_archives[@]}")
            else
                echo "Local backup drive not detected. Checking cloud storage..."
                restore_source="cloud"
            fi

            if [ "$restore_source" = "cloud" ] && [ ${#backups[@]} -eq 0 ]; then
                echo "Querying cloud backups..."
                local rclone_output rclone_status
                rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
                rclone_status=$?

                if [ "$rclone_status" -ne 0 ]; then
                    local ERROR_MSG="Failed to query cloud storage (${BACKUP_DIR}): ${rclone_output}"
                    log_message "$ERROR_MSG"
                    echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                    return 1
                fi

                mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
            fi

            if [ ${#backups[@]} -eq 0 ]; then
                local ERROR_MSG="No backups found for this host (${HOSTNAME}) at ${restore_source} to restore."
                log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2; return 1
            fi

            echo -e "\nPlease choose a backup to restore (${restore_source}):"
            select backup_choice in "${backups[@]}" "Cancel"; do
                if [ "$backup_choice" = "Cancel" ]; then
                    echo "Restore cancelled."; return 0
                fi
                if [ -n "$backup_choice" ]; then
                    if [ "$restore_source" = "local file" ]; then
                        direct_archive_file="$backup_choice"
                        backup_choice="$(basename "$backup_choice")"
                    fi
                    break
                fi
            done
        fi
    fi

    if [ -n "$cli_dest" ]; then
        restore_target="${cli_dest/#\~/$HOME}"
    elif [ "$cli_yes" = true ]; then
        restore_target="$SOURCE_DIR"
    elif [ -t 0 ]; then
        echo -e "\nChoose restore destination:"
        echo "1) Original location: ${SOURCE_DIR}"
        echo "2) Alternative directory (e.g., for inspection or partial recovery)"
        read -r -p "Please select [1-2, default: 1]: " dest_choice
        case "$dest_choice" in
            2)
                read -r -e -p "Enter destination directory path: " custom_dir
                custom_dir="${custom_dir/#\~/$HOME}"
                if [ -z "$custom_dir" ]; then
                    echo "No directory entered. Restore cancelled."
                    return 1
                fi
                restore_target="$custom_dir"
                ;;
            *)
                restore_target="$SOURCE_DIR"
                ;;
        esac
    else
        restore_target="$SOURCE_DIR"
    fi

    mkdir -p "${restore_target}"
    if [ ! -d "${restore_target}" ] || [ ! -w "${restore_target}" ]; then
        echo "ERROR: Destination directory '${restore_target}' is not writable." >&2
        return 1
    fi

    local restore_patterns=()
    if [ ${#cli_patterns[@]} -gt 0 ]; then
        for raw_pat in "${cli_patterns[@]}"; do
            local norm_pat
            if norm_pat=$(normalize_restore_pattern "$raw_pat"); then
                restore_patterns+=("$norm_pat")
            fi
        done
    elif [ "$cli_yes" = true ]; then
        # In non-interactive batch mode without specified patterns, perform full restore
        :
    elif [ -t 0 ]; then
        echo -e "\nChoose restore scope:"
        echo "1) Full restore (entire home directory archive)"
        echo "2) Selective restore (specific file, folder, or wildcard pattern)"
        local scope_choice=""
        read -r -p "Please select [1-2, default: 1]: " scope_choice
        case "$scope_choice" in
            2)
                echo -e "\nEnter path(s) or wildcard pattern(s) to restore."
                echo "Examples:"
                echo "  - Specific file:        Documents/tax_2025.pdf"
                echo "  - Specific directory:   .config/nvim"
                echo "  - Directory contents:   .config/nvim/*"
                echo "  - Global wildcard:      *.pdf or *tax_2025*"
                echo "Note: Multiple patterns may be separated by commas."
                local user_patterns_raw=""
                read -r -e -p "Pattern(s) to restore: " user_patterns_raw
                if [ -n "$user_patterns_raw" ]; then
                    if [[ "$user_patterns_raw" == *","* ]]; then
                        local raw_item=""
                        while IFS= read -r raw_item; do
                            [ -z "$raw_item" ] && continue
                            local norm_pat
                            if norm_pat=$(normalize_restore_pattern "$raw_item"); then
                                restore_patterns+=("$norm_pat")
                            fi
                        done < <(tr ',' '\n' <<< "$user_patterns_raw")
                    else
                        local norm_pat
                        if norm_pat=$(normalize_restore_pattern "$user_patterns_raw"); then
                            restore_patterns+=("$norm_pat")
                        fi
                    fi
                fi
                if [ ${#restore_patterns[@]} -eq 0 ]; then
                    echo "No valid pattern entered. Defaulting to full restore."
                fi
                ;;
            *)
                # Full restore
                ;;
        esac
    fi

    local is_selective=false
    if [ ${#restore_patterns[@]} -gt 0 ]; then
        is_selective=true
    fi

    if [ "$is_selective" = true ]; then
        echo
        echo "==============================================================================="
        echo "  SELECTIVE RESTORE"
        echo "==============================================================================="
        echo "  Archive:     ${backup_choice} (${restore_source})"
        echo "  Destination: ${restore_target}"
        echo "  Pattern(s):"
        for p in "${restore_patterns[@]}"; do
            echo "    - $p"
        done
        echo "==============================================================================="
        echo
        if [ "$cli_yes" != true ] && [ -t 0 ]; then
            read -p "Are you sure you want to extract matching file(s) to ${restore_target}? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Restore cancelled."; return 0
            fi
        fi
    else
        if [ "$restore_target" = "$SOURCE_DIR" ]; then
            echo
            echo "==============================================================================="
            echo "  WARNING: LIVE HOME DIRECTORY RESTORE"
            echo "==============================================================================="
            echo "  You are about to restore directly into your active home directory (${SOURCE_DIR})."
            echo "  Existing files and configurations will be OVERWRITTEN with versions from"
            echo "  the backup. Any newer changes, active application data, or uncommitted files"
            echo "  will be permanently replaced."
            echo "==============================================================================="
            echo
        elif [ -d "${restore_target}" ] && [ -n "$(ls -A "${restore_target}" 2>/dev/null)" ]; then
            echo
            echo "-------------------------------------------------------------------------------"
            echo "  WARNING: Target directory '${restore_target}' is not empty."
            echo "  Existing files matching the archive contents will be OVERWRITTEN."
            echo "-------------------------------------------------------------------------------"
            echo
        fi

        if [ "$cli_yes" != true ] && [ -t 0 ]; then
            read -p "Are you sure you want to restore from ${backup_choice} (${restore_source}) to ${restore_target}? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Restore cancelled."; return 0
            fi
        fi
    fi

    # Pre-flight Check: SHA-256 sidecar checksum validation
    if ! verify_restore_checksum "$backup_choice" "$restore_source" "$direct_archive_file" "$cli_verify_checksum" "$restore_target"; then
        return 1
    fi

    # Detect encryption type of target archive
    local archive_enc_type="symmetric"
    if [ -n "$direct_archive_file" ]; then
        archive_enc_type=$(detect_archive_encryption "file" "$direct_archive_file")
    elif [ "$restore_source" = "local" ]; then
        archive_enc_type=$(detect_archive_encryption "file" "${local_backup_path}/${backup_choice}")
    else
        archive_enc_type=$(detect_archive_encryption "cloud" "$backup_choice")
    fi

    if [ "$archive_enc_type" = "asymmetric" ]; then
        log_message "Archive is encrypted with GPG public key(s)."
        echo "Archive is encrypted with GPG public key(s)."
    elif [ "$archive_enc_type" = "hybrid" ]; then
        log_message "Archive is encrypted with GPG hybrid mode (public key + passphrase)."
        echo "Archive is encrypted with GPG hybrid mode (public key + passphrase)."
        if ! get_encryption_password "restore" 2>/dev/null; then
            log_message "No symmetric passphrase provided for hybrid archive; attempting secret key decryption."
        fi
    else
        if ! get_encryption_password "restore"; then
            return 1
        fi
    fi

    mkdir -p "${SCRATCH_DIR}"
    chmod 700 "${SCRATCH_DIR}"

    # --- Pre-flight check: Verify sufficient disk space for restore ---
    echo "Checking available disk space for restore..."
    local archive_size_bytes=0
    if [ -n "$direct_archive_file" ]; then
        archive_size_bytes=$(stat -c %s "$direct_archive_file" 2>/dev/null || echo 0)
    elif [ "$restore_source" = "local" ]; then
        local local_file="${local_backup_path}/${backup_choice}"
        archive_size_bytes=$(stat -c %s "$local_file" 2>/dev/null || echo 0)
    else
        archive_size_bytes=$(rclone lsl "${BACKUP_DIR}${backup_choice}" 2>/dev/null | awk 'NR==1 {print $1}')
    fi

    if [ -n "$archive_size_bytes" ] && [ "$archive_size_bytes" -gt 0 ] 2>/dev/null; then
        local archive_size_kb=$((archive_size_bytes / 1024))
        local buffer_kb=$((512 * 1024)) # 512MB safety buffer
        local expansion_multiplier=1
        local extraction_desc="extraction"

        if [ "$is_selective" = true ]; then
            expansion_multiplier=0
            extraction_desc="selective extraction"
        elif [ "$restore_target" != "$SOURCE_DIR" ]; then
            if [ -d "${restore_target}" ] && [ -z "$(ls -A "${restore_target}" 2>/dev/null)" ]; then
                expansion_multiplier=3
                extraction_desc="3x uncompressed extraction"
            fi
        fi

        local extraction_required_kb=$((archive_size_kb * expansion_multiplier))
        local target_required_kb=$((extraction_required_kb + buffer_kb))
        local target_avail_kb scratch_avail_kb
        target_avail_kb=$(df -Pk "${restore_target}" 2>/dev/null | awk 'NR==2 {print $4}')

        local effective_stream_restore=false
        if [ "$restore_source" = "cloud" ]; then
            local stream_pref="${cli_stream:-${STREAM_CLOUD_RESTORE:-auto}}"
            if [ "$stream_pref" = "true" ] || [ "$stream_pref" = "1" ] || [ "$stream_pref" = "stream" ]; then
                effective_stream_restore=true
            elif [ "$stream_pref" = "false" ] || [ "$stream_pref" = "0" ] || [ "$stream_pref" = "stage" ]; then
                effective_stream_restore=false
            else
                # "auto": Check if scratch space is sufficient for archive staging (+ buffer + extraction if same fs)
                scratch_avail_kb=$(df -Pk "${SCRATCH_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')
                local scratch_fs target_fs
                scratch_fs=$(df -Pk "${SCRATCH_DIR}" 2>/dev/null | awk 'NR==2 {print $1}')
                target_fs=$(df -Pk "${restore_target}" 2>/dev/null | awk 'NR==2 {print $1}')

                local needed_scratch_kb=$((archive_size_kb + buffer_kb))
                if [ -n "$scratch_fs" ] && [ "$scratch_fs" = "$target_fs" ]; then
                    needed_scratch_kb=$((archive_size_kb + extraction_required_kb + buffer_kb))
                fi

                if [ -n "$scratch_avail_kb" ] && [ "$scratch_avail_kb" -ge "$needed_scratch_kb" ]; then
                    effective_stream_restore=false
                    log_message "Adaptive restore: staging archive in scratch directory (scratch free: $(numfmt --to=iec --from-unit=1024 "$scratch_avail_kb" 2>/dev/null), required: $(numfmt --to=iec --from-unit=1024 "$needed_scratch_kb" 2>/dev/null))."
                else
                    effective_stream_restore=true
                    log_message "Adaptive restore: insufficient scratch space for staging; using direct single-pass stream."
                fi
            fi

            if [ "$effective_stream_restore" = true ]; then
                # Direct streaming: target only needs extraction space + buffer
                if [ -n "$target_avail_kb" ] && [ "$target_avail_kb" -lt "$target_required_kb" ]; then
                    local avail_hr req_hr
                    avail_hr=$(numfmt --to=iec --from-unit=1024 "${target_avail_kb}" 2>/dev/null || echo "$((target_avail_kb / 1024 / 1024))G")
                    req_hr=$(numfmt --to=iec --from-unit=1024 "${target_required_kb}" 2>/dev/null || echo "$((target_required_kb / 1024 / 1024))G")
                    local ERROR_MSG="ERROR: Insufficient disk space on destination (${restore_target}). Available: ${avail_hr}, required: ${req_hr} (${extraction_desc} + buffer). Aborting restore."
                    log_message "$ERROR_MSG"
                    echo "$ERROR_MSG" >&2
                    send_notification "critical" "Restore Aborted" "Insufficient disk space on ${restore_target}."
                    return 1
                fi
            else
                # Staged download: verify scratch space
                scratch_avail_kb=$(df -Pk "${SCRATCH_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')
                local scratch_fs target_fs
                scratch_fs=$(df -Pk "${SCRATCH_DIR}" 2>/dev/null | awk 'NR==2 {print $1}')
                target_fs=$(df -Pk "${restore_target}" 2>/dev/null | awk 'NR==2 {print $1}')

                if [ -n "$scratch_fs" ] && [ "$scratch_fs" = "$target_fs" ]; then
                    local total_required_kb=$(( archive_size_kb + extraction_required_kb + buffer_kb ))
                    if [ -n "$target_avail_kb" ] && [ "$target_avail_kb" -lt "$total_required_kb" ]; then
                        local avail_hr req_hr
                        avail_hr=$(numfmt --to=iec --from-unit=1024 "${target_avail_kb}" 2>/dev/null || echo "$((target_avail_kb / 1024 / 1024))G")
                        req_hr=$(numfmt --to=iec --from-unit=1024 "${total_required_kb}" 2>/dev/null || echo "$((total_required_kb / 1024 / 1024))G")
                        local ERROR_MSG="ERROR: Insufficient disk space on ${restore_target}. Available: ${avail_hr}, required: ${req_hr} (archive download + ${extraction_desc} + buffer). Aborting restore."
                        log_message "$ERROR_MSG"
                        echo "$ERROR_MSG" >&2
                        send_notification "critical" "Restore Aborted" "Insufficient disk space on ${restore_target} (${avail_hr} available, ${req_hr} required)."
                        return 1
                    fi
                else
                    local scratch_required_kb=$((archive_size_kb + buffer_kb))
                    if [ -n "$scratch_avail_kb" ] && [ "$scratch_avail_kb" -lt "$scratch_required_kb" ]; then
                        local avail_hr req_hr
                        avail_hr=$(numfmt --to=iec --from-unit=1024 "${scratch_avail_kb}" 2>/dev/null || echo "$((scratch_avail_kb / 1024 / 1024))G")
                        req_hr=$(numfmt --to=iec --from-unit=1024 "${scratch_required_kb}" 2>/dev/null || echo "$((scratch_required_kb / 1024 / 1024))G")
                        local ERROR_MSG="ERROR: Insufficient disk space in scratch directory (${SCRATCH_DIR}). Available: ${avail_hr}, required: ${req_hr}. Aborting restore."
                        log_message "$ERROR_MSG"
                        echo "$ERROR_MSG" >&2
                        send_notification "critical" "Restore Aborted" "Insufficient scratch space in ${SCRATCH_DIR}."
                        return 1
                    fi
                    if [ -n "$target_avail_kb" ] && [ "$target_avail_kb" -lt "$target_required_kb" ]; then
                        local avail_hr req_hr
                        avail_hr=$(numfmt --to=iec --from-unit=1024 "${target_avail_kb}" 2>/dev/null || echo "$((target_avail_kb / 1024 / 1024))G")
                        req_hr=$(numfmt --to=iec --from-unit=1024 "${target_required_kb}" 2>/dev/null || echo "$((target_required_kb / 1024 / 1024))G")
                        local ERROR_MSG="ERROR: Insufficient disk space on destination (${restore_target}). Available: ${avail_hr}, required: ${req_hr} (${extraction_desc} + buffer). Aborting restore."
                        log_message "$ERROR_MSG"
                        echo "$ERROR_MSG" >&2
                        send_notification "critical" "Restore Aborted" "Insufficient disk space on ${restore_target}."
                        return 1
                    fi
                fi
            fi
        else
            # Local restore: direct streaming from drive, only target needs space
            if [ -n "$target_avail_kb" ] && [ "$target_avail_kb" -lt "$target_required_kb" ]; then
                local avail_hr req_hr
                avail_hr=$(numfmt --to=iec --from-unit=1024 "${target_avail_kb}" 2>/dev/null || echo "$((target_avail_kb / 1024 / 1024))G")
                req_hr=$(numfmt --to=iec --from-unit=1024 "${target_required_kb}" 2>/dev/null || echo "$((target_required_kb / 1024 / 1024))G")
                local ERROR_MSG="ERROR: Insufficient disk space on destination (${restore_target}). Available: ${avail_hr}, required: ${req_hr} (${extraction_desc} + buffer). Aborting restore."
                log_message "$ERROR_MSG"
                echo "$ERROR_MSG" >&2
                send_notification "critical" "Restore Aborted" "Insufficient disk space on ${restore_target}."
                return 1
            fi
        fi
        log_message "Restore pre-flight disk space check passed (${extraction_desc})."
        echo "Disk space check passed (${extraction_desc})."
    fi

    local ENCRYPTED_TARBALL_NAME="$backup_choice"
    local TEMP_TARBALL_NAME="${ENCRYPTED_TARBALL_NAME%.gpg}"

    CURRENT_TEMP_ARCHIVE=""
    if [ "$restore_source" != "local" ] && [ "$restore_source" != "local file" ] && [ "$effective_stream_restore" != true ]; then
        SCRATCH_FILES_CREATED=1
        CURRENT_ENCRYPTED_ARCHIVE="${SCRATCH_DIR}/${ENCRYPTED_TARBALL_NAME}"
    else
        SCRATCH_FILES_CREATED=0
        CURRENT_ENCRYPTED_ARCHIVE=""
    fi

    # Determine tar decompression option based on archive extension
    local tar_compress_opts=("-I" "zstd -d -T0 --memory=${ZSTD_DECOMPRESS_MEMORY}")
    if [[ "$TEMP_TARBALL_NAME" == *.tar.gz ]]; then
        tar_compress_opts=("-z")
    elif [[ "$TEMP_TARBALL_NAME" == *.tar.xz ]]; then
        tar_compress_opts=("-J")
    fi

    local tar_checkpoint_opts=("--checkpoint=10000" "--checkpoint-action=echo=Extracted %u records...")
    if [ -t 1 ]; then
        tar_checkpoint_opts=("--checkpoint=10000" "--checkpoint-action=ttyout=\rExtracted %u records...   ")
    fi

    local tar_wildcard_opts=()
    if [ "$is_selective" = true ]; then
        tar_wildcard_opts=("--wildcards" "--wildcards-match-slash" "--no-anchored")
    fi

    # --- Step 1 & 2: Obtain, Decrypt & Extract Archive (streamed) ---
    local restore_tmp_dir
    restore_tmp_dir=$(mktemp -d)
    CURRENT_RESTORE_TMP_DIR="$restore_tmp_dir"
    local gpg_err_file="${restore_tmp_dir}/gpg.err"
    local rclone_err_file="${restore_tmp_dir}/rclone.err"

    local gpg_exit_code=0 tar_exit_code=0 rclone_exit_code=0
    local check_inline_checksum=false
    local expected_stream_sha=""
    local actual_stream_sha=""

    if [ -n "$direct_archive_file" ] || [ "$restore_source" = "local" ]; then
        local SOURCE_ENCRYPTED_FILE="${direct_archive_file:-${local_backup_path}/${ENCRYPTED_TARBALL_NAME}}"
        echo "Decrypting and extracting archive directly from ${restore_source}..."
        log_message "Decrypting and extracting ${SOURCE_ENCRYPTED_FILE} directly to ${restore_target}"
        if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
            gpg --batch --yes --no-tty --decrypt "$SOURCE_ENCRYPTED_FILE" 2>"$gpg_err_file" \
                | tar "${tar_wildcard_opts[@]}" --acls --xattrs "${tar_compress_opts[@]}" "${tar_checkpoint_opts[@]}" -xpf - -C "${restore_target}" "${restore_patterns[@]}"
        else
            gpg --batch --yes --no-tty --pinentry-mode loopback --decrypt --passphrase-fd 3 "$SOURCE_ENCRYPTED_FILE" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                | tar "${tar_wildcard_opts[@]}" --acls --xattrs "${tar_compress_opts[@]}" "${tar_checkpoint_opts[@]}" -xpf - -C "${restore_target}" "${restore_patterns[@]}"
        fi
        local local_pipe_statuses=("${PIPESTATUS[@]}")
        [ -t 1 ] && echo
        gpg_exit_code=${local_pipe_statuses[0]}
        tar_exit_code=${local_pipe_statuses[1]}
    elif [ "$effective_stream_restore" = true ]; then
        echo "Streaming and extracting archive from cloud storage (${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME})..."
        log_message "Streaming and extracting ${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME} directly to ${restore_target} via rclone cat"

        if [ "$cli_verify_checksum" = true ]; then
            check_inline_checksum=true
        elif [ "$cli_verify_checksum" = false ]; then
            check_inline_checksum=false
        elif [ "$RESTORE_VERIFY_CHECKSUM" != false ] && [ "$RESTORE_VERIFY_CHECKSUM" != "0" ] && [ "$RESTORE_VERIFY_CHECKSUM" != "none" ]; then
            check_inline_checksum=true
        fi

        if [ "$check_inline_checksum" = true ]; then
            expected_stream_sha="${EXPECTED_RESTORE_SHA256:-}"
            if [ -z "$expected_stream_sha" ]; then
                local sidecar_data
                sidecar_data=$(rclone cat "${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME}.sha256" 2>/dev/null || true)
                expected_stream_sha=$(awk '{print $1}' <<< "$sidecar_data")
            fi
            if [ -n "$expected_stream_sha" ]; then
                echo "Enabling single-pass inline SHA-256 verification (expected: ${expected_stream_sha:0:12}...)..."
                log_message "Single-pass inline SHA-256 verification active for ${ENCRYPTED_TARBALL_NAME}."
            elif [ "$cli_verify_checksum" = true ]; then
                local ERROR_MSG="ERROR: SHA-256 sidecar file '${ENCRYPTED_TARBALL_NAME}.sha256' not found in cloud storage."
                log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                send_notification "critical" "Restore Aborted" "Cloud SHA-256 sidecar missing for ${ENCRYPTED_TARBALL_NAME}." "dialog-warning"
                rm -rf "$restore_tmp_dir" 2>/dev/null
                CURRENT_RESTORE_TMP_DIR=""
                return 1
            else
                log_message "No cloud SHA-256 sidecar found for ${ENCRYPTED_TARBALL_NAME}; streaming without checksum validation."
                check_inline_checksum=false
            fi
        fi

        if [ "$check_inline_checksum" = true ]; then
            local hash_fifo="${restore_tmp_dir}/hash.fifo"
            local actual_hash_file="${restore_tmp_dir}/actual.sha256"
            mkfifo "$hash_fifo"
            sha256sum < "$hash_fifo" | awk '{print $1}' > "$actual_hash_file" &
            local sha_pid=$!

            if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
                rclone cat "${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME}" 2>"$rclone_err_file" \
                    | tee "$hash_fifo" \
                    | gpg --batch --yes --no-tty --decrypt - 2>"$gpg_err_file" \
                    | tar "${tar_wildcard_opts[@]}" --acls --xattrs "${tar_compress_opts[@]}" "${tar_checkpoint_opts[@]}" -xpf - -C "${restore_target}" "${restore_patterns[@]}"
            else
                rclone cat "${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME}" 2>"$rclone_err_file" \
                    | tee "$hash_fifo" \
                    | gpg --batch --yes --no-tty --pinentry-mode loopback --decrypt --passphrase-fd 3 - 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                    | tar "${tar_wildcard_opts[@]}" --acls --xattrs "${tar_compress_opts[@]}" "${tar_checkpoint_opts[@]}" -xpf - -C "${restore_target}" "${restore_patterns[@]}"
            fi
            local cloud_pipe_statuses=("${PIPESTATUS[@]}")
            [ -t 1 ] && echo
            rclone_exit_code=${cloud_pipe_statuses[0]}
            gpg_exit_code=${cloud_pipe_statuses[2]}
            tar_exit_code=${cloud_pipe_statuses[3]}

            wait "$sha_pid" 2>/dev/null || true
            [ -f "$actual_hash_file" ] && actual_stream_sha=$(< "$actual_hash_file")
        else
            if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
                rclone cat "${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME}" 2>"$rclone_err_file" \
                    | gpg --batch --yes --no-tty --decrypt - 2>"$gpg_err_file" \
                    | tar "${tar_wildcard_opts[@]}" --acls --xattrs "${tar_compress_opts[@]}" "${tar_checkpoint_opts[@]}" -xpf - -C "${restore_target}" "${restore_patterns[@]}"
            else
                rclone cat "${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME}" 2>"$rclone_err_file" \
                    | gpg --batch --yes --no-tty --pinentry-mode loopback --decrypt --passphrase-fd 3 - 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                    | tar "${tar_wildcard_opts[@]}" --acls --xattrs "${tar_compress_opts[@]}" "${tar_checkpoint_opts[@]}" -xpf - -C "${restore_target}" "${restore_patterns[@]}"
            fi
            local cloud_pipe_statuses=("${PIPESTATUS[@]}")
            [ -t 1 ] && echo
            rclone_exit_code=${cloud_pipe_statuses[0]}
            gpg_exit_code=${cloud_pipe_statuses[1]}
            tar_exit_code=${cloud_pipe_statuses[2]}
        fi
    else
        local FULL_ENCRYPTED_PATH="${SCRATCH_DIR}/${ENCRYPTED_TARBALL_NAME}"
        echo "Downloading archive ${ENCRYPTED_TARBALL_NAME}..."
        local rclone_progress_opts=()
        if [ -t 1 ]; then
            rclone_progress_opts=("-P")
        else
            rclone_progress_opts=("--stats" "15s" "--stats-one-line" "--stats-log-level" "NOTICE")
        fi

        local rclone_log="${LOG_FILE}.rclone"
        local rclone_common_opts=(
            --retries 3
            --low-level-retries 10
            --drive-chunk-size "${RCLONE_DRIVE_CHUNK_SIZE}"
            --drive-upload-cutoff "${RCLONE_DRIVE_CHUNK_SIZE}"
            --timeout 30m
            --contimeout 60s
        )
        [ -n "$RCLONE_BWLIMIT" ] && rclone_common_opts+=(--bwlimit "$RCLONE_BWLIMIT")

        if ! rclone copy "${rclone_common_opts[@]}" "${rclone_progress_opts[@]}" --log-file "$rclone_log" "${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME}" "${SCRATCH_DIR}"; then
            local ERROR_MSG="Failed to download archive."
            local rclone_errors=""
            if [ -f "$rclone_log" ]; then
                rclone_errors=$(grep -E "(ERROR|Failed to|fatal)" "$rclone_log" 2>/dev/null | tail -n 10)
                [ -z "$rclone_errors" ] && rclone_errors=$(tail -n 10 "$rclone_log" 2>/dev/null)
            fi
            [ -n "$rclone_errors" ] && ERROR_MSG="${ERROR_MSG} | Details: ${rclone_errors}"
            log_message "$ERROR_MSG"
            echo "$ERROR_MSG" >&2
            rm -f "${FULL_ENCRYPTED_PATH}"
            CURRENT_ENCRYPTED_ARCHIVE=""
            rmdir "${SCRATCH_DIR}" 2>/dev/null || true
            SCRATCH_FILES_CREATED=0
            rm -rf "$restore_tmp_dir" 2>/dev/null
            CURRENT_RESTORE_TMP_DIR=""
            return 1
        fi

        # Verify downloaded staged archive against SHA-256 sidecar
        local staged_check_checksum=false
        if [ "$cli_verify_checksum" = true ]; then
            staged_check_checksum=true
        elif [ "$cli_verify_checksum" = false ]; then
            staged_check_checksum=false
        elif [ "$RESTORE_VERIFY_CHECKSUM" != false ] && [ "$RESTORE_VERIFY_CHECKSUM" != "0" ] && [ "$RESTORE_VERIFY_CHECKSUM" != "none" ]; then
            staged_check_checksum=true
        fi

        if [ "$staged_check_checksum" = true ]; then
            local staged_expected="${EXPECTED_RESTORE_SHA256:-}"
            if [ -z "$staged_expected" ]; then
                local staged_cloud_sha
                staged_cloud_sha=$(rclone cat "${BACKUP_DIR}${ENCRYPTED_TARBALL_NAME}.sha256" 2>/dev/null || true)
                staged_expected=$(awk '{print $1}' <<< "$staged_cloud_sha")
            fi
            if [ -n "$staged_expected" ]; then
                echo "Verifying downloaded archive against SHA-256 sidecar checksum..."
                local staged_actual
                staged_actual=$(sha256sum "${FULL_ENCRYPTED_PATH}" 2>/dev/null | awk '{print $1}')
                if [ -n "$staged_actual" ] && [ "$staged_actual" = "$staged_expected" ]; then
                    echo "Downloaded archive SHA-256 checksum verified OK (${staged_actual:0:12}...). No bit-rot detected."
                    log_message "Downloaded archive SHA-256 checksum valid for ${ENCRYPTED_TARBALL_NAME}."
                else
                    local ERROR_MSG="ERROR: Downloaded archive SHA-256 checksum verification failed for ${ENCRYPTED_TARBALL_NAME} (expected: ${staged_expected}, calculated: ${staged_actual}). Aborting restore to protect ${restore_target}."
                    log_message "$ERROR_MSG"
                    echo "$ERROR_MSG" >&2
                    rm -f "${FULL_ENCRYPTED_PATH}"
                    CURRENT_ENCRYPTED_ARCHIVE=""
                    rmdir "${SCRATCH_DIR}" 2>/dev/null || true
                    SCRATCH_FILES_CREATED=0
                    rm -rf "$restore_tmp_dir" 2>/dev/null
                    CURRENT_RESTORE_TMP_DIR=""
                    send_notification "critical" "Restore Aborted" "Downloaded archive SHA-256 checksum mismatch for ${ENCRYPTED_TARBALL_NAME}." "dialog-error"
                    return 1
                fi
            elif [ "$cli_verify_checksum" = true ]; then
                local ERROR_MSG="ERROR: SHA-256 sidecar file '${ENCRYPTED_TARBALL_NAME}.sha256' not found in cloud storage."
                log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                rm -f "${FULL_ENCRYPTED_PATH}"
                CURRENT_ENCRYPTED_ARCHIVE=""
                rmdir "${SCRATCH_DIR}" 2>/dev/null || true
                SCRATCH_FILES_CREATED=0
                rm -rf "$restore_tmp_dir" 2>/dev/null
                CURRENT_RESTORE_TMP_DIR=""
                send_notification "critical" "Restore Aborted" "Cloud SHA-256 sidecar missing for ${ENCRYPTED_TARBALL_NAME}." "dialog-warning"
                return 1
            else
                log_message "No cloud SHA-256 sidecar found for ${ENCRYPTED_TARBALL_NAME}; proceeding with extraction."
            fi
        fi

        echo "Decrypting and extracting archive..."
        log_message "Decrypting and extracting ${FULL_ENCRYPTED_PATH} directly to ${restore_target}"
        if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
            gpg --batch --yes --no-tty --decrypt "$FULL_ENCRYPTED_PATH" 2>"$gpg_err_file" \
                | tar "${tar_wildcard_opts[@]}" --acls --xattrs "${tar_compress_opts[@]}" "${tar_checkpoint_opts[@]}" -xpf - -C "${restore_target}" "${restore_patterns[@]}"
        else
            gpg --batch --yes --no-tty --pinentry-mode loopback --decrypt --passphrase-fd 3 "$FULL_ENCRYPTED_PATH" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                | tar "${tar_wildcard_opts[@]}" --acls --xattrs "${tar_compress_opts[@]}" "${tar_checkpoint_opts[@]}" -xpf - -C "${restore_target}" "${restore_patterns[@]}"
        fi
        local staged_pipe_statuses=("${PIPESTATUS[@]}")
        [ -t 1 ] && echo
        gpg_exit_code=${staged_pipe_statuses[0]}
        tar_exit_code=${staged_pipe_statuses[1]}

        rm -f "${FULL_ENCRYPTED_PATH}" # Clean up downloaded file regardless of outcome
        CURRENT_ENCRYPTED_ARCHIVE=""
        rmdir "${SCRATCH_DIR}" 2>/dev/null || true
    fi

    local gpg_err_msg="" rclone_err_msg=""
    [ -f "$gpg_err_file" ] && gpg_err_msg=$(<"$gpg_err_file")
    [ -f "$rclone_err_file" ] && rclone_err_msg=$(<"$rclone_err_file")
    rm -rf "$restore_tmp_dir" 2>/dev/null
    CURRENT_RESTORE_TMP_DIR=""

    SCRATCH_FILES_CREATED=0

    # 1. Cloud streaming / download error (ignore SIGPIPE 141 or broken pipe if downstream exited normally or handled)
    if [ "$restore_source" = "cloud" ] && [ "$rclone_exit_code" -ne 0 ] && [ "$rclone_exit_code" -ne 141 ] && [[ "$rclone_err_msg" != *"broken pipe"* ]]; then
        local ERROR_MSG="Cloud download/streaming failed with exit code ${rclone_exit_code}."
        log_message "$ERROR_MSG: ${rclone_err_msg}"
        echo "$ERROR_MSG" >&2
        [ -n "$rclone_err_msg" ] && echo "$rclone_err_msg" >&2
        return 1
    fi

    # 2. Genuine GPG decryption failure (bad password or corrupted archive header)
    local gpg_is_decryption_error=false
    if [ "$gpg_exit_code" -ne 0 ] && [ "$gpg_exit_code" -ne 141 ]; then
        if [[ "$gpg_err_msg" == *"decryption failed"* || "$gpg_err_msg" == *"Bad session key"* || "$gpg_err_msg" == *"bad passphrase"* || "$gpg_err_msg" == *"No secret key"* ]]; then
            gpg_is_decryption_error=true
        elif [[ "$gpg_err_msg" != *"Broken pipe"* && "$tar_exit_code" -eq 0 ]]; then
            gpg_is_decryption_error=true
        fi
    fi

    if [ "$gpg_is_decryption_error" = true ]; then
        local ERROR_MSG="GPG decryption failed with exit code ${gpg_exit_code}. Is the password correct?"
        if [[ "$gpg_err_msg" == *"No secret key"* || "$gpg_err_msg" == *"secret key not available"* ]]; then
            ERROR_MSG="GPG decryption failed: The required private key to decrypt this asymmetric archive is not in your GPG keyring."
        fi
        log_message "$ERROR_MSG: ${gpg_err_msg}"
        echo "$ERROR_MSG" >&2
        [ -n "$gpg_err_msg" ] && echo "$gpg_err_msg" >&2
        return 1
    fi

    # 3. Tar extraction / decompression failure (e.g. pattern not found, disk full, corrupted stream)
    if [ "$tar_exit_code" -gt 1 ] && [ "$tar_exit_code" -ne 141 ]; then
        local ERROR_MSG="Failed to extract archive with fatal exit code ${tar_exit_code}."
        if [ "$is_selective" = true ] && [ "$tar_exit_code" -eq 2 ]; then
            ERROR_MSG="Selective extraction error: one or more pattern(s) not found in archive (tar exit code 2)."
        fi
        log_message "$ERROR_MSG"
        echo "$ERROR_MSG" >&2
        return 1
    fi

    # 4. Catch-all for any unhandled pipeline error (SIGPIPE or unexpected failure)
    if [ "$tar_exit_code" -gt 1 ] || { [ "$gpg_exit_code" -ne 0 ] && [ "$gpg_exit_code" -ne 141 ]; } || { [ "$restore_source" = "cloud" ] && [ "$rclone_exit_code" -ne 0 ] && [ "$rclone_exit_code" -ne 141 ] && [[ "$rclone_err_msg" != *"broken pipe"* ]]; }; then
        local ERROR_MSG="Extraction pipeline failed (rclone: ${rclone_exit_code}, gpg: ${gpg_exit_code}, tar: ${tar_exit_code})."
        log_message "$ERROR_MSG: ${gpg_err_msg}"
        echo "$ERROR_MSG" >&2
        [ -n "$rclone_err_msg" ] && echo "rclone: $rclone_err_msg" >&2
        [ -n "$gpg_err_msg" ] && echo "gpg: $gpg_err_msg" >&2
        return 1
    fi

    # 5. Validate inline streaming SHA-256 checksum if active
    if [ "$restore_source" = "cloud" ] && [ "$check_inline_checksum" = true ] && [ -n "$expected_stream_sha" ]; then
        if [ -n "$actual_stream_sha" ] && [ "$actual_stream_sha" = "$expected_stream_sha" ]; then
            echo "Cloud SHA-256 checksum verified OK (${actual_stream_sha:0:12}...) [single-pass inline stream]."
            log_message "Cloud SHA-256 checksum valid for ${ENCRYPTED_TARBALL_NAME} (single-pass inline stream)."
        else
            local ERROR_MSG="ERROR: Cloud SHA-256 checksum verification failed for ${ENCRYPTED_TARBALL_NAME} (expected: ${expected_stream_sha}, calculated: ${actual_stream_sha:-none}). The archive stream was corrupted or modified in transmission."
            log_message "$ERROR_MSG"
            echo "$ERROR_MSG" >&2
            send_notification "critical" "Restore Integrity Failure" "Cloud SHA-256 checksum mismatch for ${ENCRYPTED_TARBALL_NAME}." "dialog-error"
            return 1
        fi
    fi

    if [ "$tar_exit_code" -eq 1 ]; then
        log_message "tar extraction completed with non-fatal warnings (e.g. unsupported extended attributes or permissions)."
        echo "tar extraction completed with non-fatal warnings. Continuing..."
    fi

    if [ "$is_selective" = true ]; then
        # Clean up or consolidate any system state manifests that may have matched selective patterns
        local meta_files=("${APT_REPOS_FILE}" "${APT_PACKAGES_FILE}" "${DNF_REPOS_FILE}" "${DNF_PACKAGES_FILE}" "${DCONF_SETTINGS_FILE}" "${FLATPAK_REMOTES_FILE}" "${FLATPAK_PACKAGES_FILE}" "${PIPX_SPEC_FILE}" "${SYSTEMD_USER_UNITS_FILE}" "${CRONTAB_BACKUP_FILE}")
        for mf in "${meta_files[@]}"; do
            if [ -f "${restore_target}/${mf}" ]; then
                if [ "$restore_target" = "$SOURCE_DIR" ]; then
                    rm -f "${restore_target}/${mf}" 2>/dev/null || true
                else
                    mkdir -p "${restore_target}/.system_state" 2>/dev/null
                    mv -f "${restore_target}/${mf}" "${restore_target}/.system_state/${mf}" 2>/dev/null || true
                fi
            fi
        done

        harden_security_permissions "${restore_target}"
        sync -f "${restore_target}" 2>/dev/null || sync
        local duration_str
        duration_str=$(format_duration $(( SECONDS - start_time )))
        echo "Selective restore complete in ${duration_str}."
        echo "Matching file(s) successfully extracted to: ${restore_target}"
        log_message "Selective restore complete for pattern(s) '${restore_patterns[*]}' into ${restore_target} in ${duration_str}."
        send_notification "normal" "Restore Complete" "Selective restore completed for ${restore_target} in ${duration_str}." "drive-harddisk"
    elif [ "$restore_target" = "$SOURCE_DIR" ]; then
        # --- Step 4: Restore APT Repository Sources and Signing Keyrings ---
        if [ -f "${SOURCE_DIR}/${APT_REPOS_FILE}" ]; then
            if [ -s "${SOURCE_DIR}/${APT_REPOS_FILE}" ]; then
                local restore_repos_confirm=""
                if [ "$cli_yes" = true ]; then
                    restore_repos_confirm="y"
                elif [ -t 0 ]; then
                    read -r -p "Restore APT repository sources and signing keyrings from backup? (y/N): " restore_repos_confirm
                fi
                if [[ "$restore_repos_confirm" =~ ^[Yy]$ ]]; then
                    echo "Restoring APT repositories and signing keyrings..."
                    log_message "Restoring APT repositories and keyrings from ${SOURCE_DIR}/${APT_REPOS_FILE}"
                    local repos_can_sudo=false
                    if command -v sudo &> /dev/null; then
                        if [ "$cli_yes" = true ] || [ ! -t 0 ]; then
                            if sudo -n -v 2>/dev/null; then
                                repos_can_sudo=true
                            else
                                log_message "WARNING: Sudo credentials not cached for APT repository restore in non-interactive mode. Proceeding without root privileges."
                            fi
                        else
                            echo "Root privileges are required to restore APT repository sources and keyrings to /etc/apt."
                            if sudo -v; then
                                repos_can_sudo=true
                            else
                                echo "WARNING: Sudo authentication failed. Skipping APT repository restore." >&2
                                log_message "WARNING: Sudo authentication failed for APT repository restore."
                            fi
                        fi
                    fi

                    if [ "$repos_can_sudo" = true ]; then
                        # shellcheck disable=SC2024
                        if sudo -n tar -xzpf "${SOURCE_DIR}/${APT_REPOS_FILE}" -C /etc/apt/ >> "$LOG_FILE" 2>&1; then
                            log_message "APT repositories and signing keyrings restored successfully to /etc/apt/."
                            echo "APT repositories and signing keyrings restored successfully."
                        else
                            log_message "WARNING: Failed to unpack APT repositories and keyrings to /etc/apt/."
                            echo "WARNING: Failed to unpack APT repositories and keyrings to /etc/apt/." >&2
                        fi
                    else
                        echo "Skipping APT repository restore due to lack of sudo privileges."
                        echo "Tip: You can manually restore them later with:"
                        echo "  sudo tar -xzpf \"${SOURCE_DIR}/${APT_REPOS_FILE}\" -C /etc/apt/"
                        log_message "Skipped APT repository restore (no sudo privileges)."
                    fi
                else
                    echo "Skipping APT repositories and keyrings restore."
                    log_message "APT repositories and keyrings restore skipped by user."
                fi
            else
                log_message "APT repositories backup file is empty. Skipping restore."
            fi
            rm -f "${SOURCE_DIR}/${APT_REPOS_FILE}"
        fi

        # --- Step 4.5: Restore/Reinstall Manually Installed APT Packages ---
        if [ -f "${SOURCE_DIR}/${APT_PACKAGES_FILE}" ]; then
            if [ -s "${SOURCE_DIR}/${APT_PACKAGES_FILE}" ]; then
                local apt_pkg_count
                apt_pkg_count=$(wc -l < "${SOURCE_DIR}/${APT_PACKAGES_FILE}" | tr -d '[:space:]')
                local restore_apt_confirm=""
                if [ "$cli_yes" = true ]; then
                    restore_apt_confirm="y"
                elif [ -t 0 ]; then
                    read -r -p "Reinstall missing APT packages from backup (${apt_pkg_count} recorded)? (y/N): " restore_apt_confirm
                fi
                if [[ "$restore_apt_confirm" =~ ^[Yy]$ ]]; then
                    echo "Checking and reinstalling APT packages..."
                    log_message "Restoring APT packages from ${SOURCE_DIR}/${APT_PACKAGES_FILE} (${apt_pkg_count} packages listed)"
                    if command -v apt-get &> /dev/null; then
                        local can_sudo=false
                        if command -v sudo &> /dev/null; then
                            if [ "$cli_yes" = true ] || [ ! -t 0 ]; then
                                if sudo -n -v 2>/dev/null; then
                                    can_sudo=true
                                else
                                    log_message "WARNING: Sudo credentials not cached for APT package install in non-interactive mode. Proceeding without root privileges."
                                fi
                            else
                                echo "Root privileges are required to install APT packages."
                                if sudo -v; then
                                    can_sudo=true
                                else
                                    echo "WARNING: Sudo authentication failed. Skipping APT package installation." >&2
                                    log_message "WARNING: Sudo authentication failed for APT package restore."
                                fi
                            fi
                        fi

                        if [ "$can_sudo" = true ]; then
                            echo "Updating package repository lists..."
                            # shellcheck disable=SC2024
                            sudo -n apt-get update -qq >> "$LOG_FILE" 2>&1 || true
                            echo "Installing APT packages (this may take several minutes)..."
                            mapfile -t apt_packages_to_install < "${SOURCE_DIR}/${APT_PACKAGES_FILE}"
                            # shellcheck disable=SC2024
                            if sudo -n apt-get install -y --no-upgrade "${apt_packages_to_install[@]}" >> "$LOG_FILE" 2>&1; then
                                log_message "APT packages batch installed successfully."
                                echo "APT packages installed successfully."
                            else
                                log_message "Batch APT install encountered issues; attempting individual package installs."
                                echo "Batch install encountered issues; attempting individual package installs..."
                                local apt_success=0 apt_failed=0
                                for pkg in "${apt_packages_to_install[@]}"; do
                                    [ -z "$pkg" ] && continue
                                    if ! dpkg -s "$pkg" &>/dev/null; then
                                        echo "Installing APT package: $pkg..."
                                        # shellcheck disable=SC2024
                                        if sudo -n apt-get install -y --no-upgrade "$pkg" >> "$LOG_FILE" 2>&1; then
                                            ((apt_success++))
                                        else
                                            ((apt_failed++))
                                            log_message "WARNING: Failed to install APT package $pkg"
                                        fi
                                    fi
                                done
                                log_message "Individual APT package installation completed (${apt_success} installed, ${apt_failed} failed)."
                            fi
                        else
                            echo "Skipping APT installation due to lack of sudo privileges."
                            echo "Tip: You can manually install them later with:"
                            echo "  xargs -a \"${SOURCE_DIR}/${APT_PACKAGES_FILE}\" sudo apt-get install -y"
                            log_message "Skipped APT package installation (no sudo privileges)."
                        fi
                    else
                        log_message "WARNING: apt-get command not found. Skipping APT packages restore."
                    fi
                else
                    echo "Skipping APT packages restore."
                    log_message "APT package restore skipped by user."
                fi
            else
                log_message "APT packages backup file is empty. Skipping restore."
            fi
            rm -f "${SOURCE_DIR}/${APT_PACKAGES_FILE}"
        fi

        # --- Step 4.6: Restore DNF Repository Sources and RPM GPG Keys ---
        if [ -f "${SOURCE_DIR}/${DNF_REPOS_FILE}" ]; then
            if [ -s "${SOURCE_DIR}/${DNF_REPOS_FILE}" ]; then
                local restore_dnf_repos_confirm=""
                if [ "$cli_yes" = true ]; then
                    restore_dnf_repos_confirm="y"
                elif [ -t 0 ]; then
                    read -r -p "Restore DNF repository configurations and RPM GPG keys from backup? (y/N): " restore_dnf_repos_confirm
                fi
                if [[ "$restore_dnf_repos_confirm" =~ ^[Yy]$ ]]; then
                    echo "Restoring DNF repositories and RPM GPG keys..."
                    log_message "Restoring DNF repositories and RPM GPG keys from ${SOURCE_DIR}/${DNF_REPOS_FILE}"
                    local dnf_repos_can_sudo=false
                    if command -v sudo &> /dev/null; then
                        if [ "$cli_yes" = true ] || [ ! -t 0 ]; then
                            if sudo -n -v 2>/dev/null; then
                                dnf_repos_can_sudo=true
                            else
                                log_message "WARNING: Sudo credentials not cached for DNF repository restore in non-interactive mode. Proceeding without root privileges."
                            fi
                        else
                            echo "Root privileges are required to restore DNF repositories and keys to /etc/."
                            if sudo -v; then
                                dnf_repos_can_sudo=true
                            else
                                echo "WARNING: Sudo authentication failed. Skipping DNF repository restore." >&2
                                log_message "WARNING: Sudo authentication failed for DNF repository restore."
                            fi
                        fi
                    fi

                    if [ "$dnf_repos_can_sudo" = true ]; then
                        # shellcheck disable=SC2024
                        if sudo -n tar -xzpf "${SOURCE_DIR}/${DNF_REPOS_FILE}" -C /etc/ >> "$LOG_FILE" 2>&1; then
                            log_message "DNF repositories and RPM GPG keys restored successfully to /etc/."
                            echo "DNF repositories and RPM GPG keys restored successfully."
                        else
                            log_message "WARNING: Failed to unpack DNF repositories and RPM GPG keys to /etc/."
                            echo "WARNING: Failed to unpack DNF repositories and RPM GPG keys to /etc/." >&2
                        fi
                    else
                        echo "Skipping DNF repository restore due to lack of sudo privileges."
                        echo "Tip: You can manually restore them later with:"
                        echo "  sudo tar -xzpf \"${SOURCE_DIR}/${DNF_REPOS_FILE}\" -C /etc/"
                        log_message "Skipped DNF repository restore (no sudo privileges)."
                    fi
                else
                    echo "Skipping DNF repositories and keys restore."
                    log_message "DNF repositories and keys restore skipped by user."
                fi
            else
                log_message "DNF repositories backup file is empty. Skipping restore."
            fi
            rm -f "${SOURCE_DIR}/${DNF_REPOS_FILE}"
        fi

        # --- Step 4.7: Restore/Reinstall User-Installed DNF Packages ---
        if [ -f "${SOURCE_DIR}/${DNF_PACKAGES_FILE}" ]; then
            if [ -s "${SOURCE_DIR}/${DNF_PACKAGES_FILE}" ]; then
                local dnf_pkg_count
                dnf_pkg_count=$(wc -l < "${SOURCE_DIR}/${DNF_PACKAGES_FILE}" | tr -d '[:space:]')
                local restore_dnf_confirm=""
                if [ "$cli_yes" = true ]; then
                    restore_dnf_confirm="y"
                elif [ -t 0 ]; then
                    read -r -p "Reinstall missing DNF packages from backup (${dnf_pkg_count} recorded)? (y/N): " restore_dnf_confirm
                fi
                if [[ "$restore_dnf_confirm" =~ ^[Yy]$ ]]; then
                    echo "Checking and reinstalling DNF packages..."
                    log_message "Restoring DNF packages from ${SOURCE_DIR}/${DNF_PACKAGES_FILE} (${dnf_pkg_count} packages listed)"
                    if command -v dnf &> /dev/null; then
                        local dnf_can_sudo=false
                        if command -v sudo &> /dev/null; then
                            if [ "$cli_yes" = true ] || [ ! -t 0 ]; then
                                if sudo -n -v 2>/dev/null; then
                                    dnf_can_sudo=true
                                else
                                    log_message "WARNING: Sudo credentials not cached for DNF package install in non-interactive mode. Proceeding without root privileges."
                                fi
                            else
                                echo "Root privileges are required to install DNF packages."
                                if sudo -v; then
                                    dnf_can_sudo=true
                                else
                                    echo "WARNING: Sudo authentication failed. Skipping DNF package installation." >&2
                                    log_message "WARNING: Sudo authentication failed for DNF package restore."
                                fi
                            fi
                        fi

                        if [ "$dnf_can_sudo" = true ]; then
                            echo "Refreshing repository metadata cache..."
                            # shellcheck disable=SC2024
                            sudo -n dnf makecache >> "$LOG_FILE" 2>&1 || true
                            echo "Installing DNF packages (this may take several minutes)..."
                            mapfile -t dnf_packages_to_install < "${SOURCE_DIR}/${DNF_PACKAGES_FILE}"
                            # shellcheck disable=SC2024
                            if sudo -n dnf install -y --skip-broken "${dnf_packages_to_install[@]}" >> "$LOG_FILE" 2>&1; then
                                log_message "DNF packages batch installed successfully."
                                echo "DNF packages installed successfully."
                            else
                                log_message "Batch DNF install encountered issues; attempting individual package installs."
                                echo "Batch install encountered issues; attempting individual package installs..."
                                local dnf_success=0 dnf_failed=0
                                for pkg in "${dnf_packages_to_install[@]}"; do
                                    [ -z "$pkg" ] && continue
                                    if ! rpm -q "$pkg" &>/dev/null; then
                                        echo "Installing DNF package: $pkg..."
                                        # shellcheck disable=SC2024
                                        if sudo -n dnf install -y "$pkg" >> "$LOG_FILE" 2>&1; then
                                            ((dnf_success++))
                                        else
                                            ((dnf_failed++))
                                            log_message "WARNING: Failed to install DNF package $pkg"
                                        fi
                                    fi
                                done
                                log_message "Individual DNF package installation completed (${dnf_success} installed, ${dnf_failed} failed)."
                            fi
                        else
                            echo "Skipping DNF installation due to lack of sudo privileges."
                            echo "Tip: You can manually install them later with:"
                            echo "  xargs -a \"${SOURCE_DIR}/${DNF_PACKAGES_FILE}\" sudo dnf install -y --skip-broken"
                            log_message "Skipped DNF package installation (no sudo privileges)."
                        fi
                    else
                        log_message "WARNING: dnf command not found. Skipping DNF packages restore."
                    fi
                else
                    echo "Skipping DNF packages restore."
                    log_message "DNF package restore skipped by user."
                fi
            else
                log_message "DNF packages backup file is empty. Skipping restore."
            fi
            rm -f "${SOURCE_DIR}/${DNF_PACKAGES_FILE}"
        fi

        # --- Step 5: Restore Desktop (dconf) Settings ---
        if [ -f "${SOURCE_DIR}/${DCONF_SETTINGS_FILE}" ]; then
            if [ -s "${SOURCE_DIR}/${DCONF_SETTINGS_FILE}" ]; then
                local restore_dconf_confirm=""
                if [ "$cli_yes" = true ]; then
                    restore_dconf_confirm="y"
                elif [ -t 0 ]; then
                    read -r -p "Restore desktop (dconf) settings from backup? (y/N): " restore_dconf_confirm
                fi
                if [[ "$restore_dconf_confirm" =~ ^[Yy]$ ]]; then
                    echo "Restoring desktop (dconf) settings..."
                    log_message "Restoring desktop settings from ${SOURCE_DIR}/${DCONF_SETTINGS_FILE}"
                    if command -v dconf &> /dev/null; then
                        if dconf load / < "${SOURCE_DIR}/${DCONF_SETTINGS_FILE}" 2>> "$LOG_FILE"; then
                            log_message "Desktop (dconf) settings restored successfully."
                            echo "Desktop (dconf) settings restored successfully."
                        else
                            log_message "WARNING: Failed to load desktop (dconf) settings."
                            echo "WARNING: Failed to load desktop (dconf) settings." >&2
                        fi
                    else
                        log_message "WARNING: dconf command not found. Skipping desktop settings restore."
                    fi
                else
                    echo "Skipping desktop (dconf) settings restore."
                    log_message "Desktop settings restore skipped by user."
                fi
            else
                log_message "Desktop (dconf) settings backup file is empty. Skipping restore."
            fi
            rm -f "${SOURCE_DIR}/${DCONF_SETTINGS_FILE}"
        fi

        # --- Step 6: Restore Flatpak remotes and packages ---
        if [ -f "${SOURCE_DIR}/${FLATPAK_REMOTES_FILE}" ] || [ -f "${SOURCE_DIR}/${FLATPAK_PACKAGES_FILE}" ]; then
            local restore_flatpak_confirm=""
            if [ "$cli_yes" = true ]; then
                restore_flatpak_confirm="y"
            elif [ -t 0 ]; then
                read -r -p "Restore flatpak remotes and packages from backup? (y/N): " restore_flatpak_confirm
            fi
            if [[ "$restore_flatpak_confirm" =~ ^[Yy]$ ]]; then
                echo "Restoring flatpaks..."
                if command -v flatpak &> /dev/null; then
                    # Restore remotes if any
                    if [ -f "${SOURCE_DIR}/${FLATPAK_REMOTES_FILE}" ]; then
                        log_message "Restoring flatpak remotes from ${SOURCE_DIR}/${FLATPAK_REMOTES_FILE}"
                        local remote_can_sudo=""
                        while IFS=$'\t' read -r remote_name remote_url remote_options; do
                            [ -z "$remote_name" ] || [ -z "$remote_url" ] && continue
                            local scope_flag="--system"
                            if [[ "$remote_options" == *"user"* ]]; then
                                scope_flag="--user"
                            elif [ -z "$remote_options" ]; then
                                scope_flag="--user"
                            fi
                            echo "Configuring flatpak remote (${scope_flag#--}): ${remote_name}..."
                            if ! flatpak remote-add --if-not-exists "$scope_flag" "${remote_name}" "${remote_url}" >> "$LOG_FILE" 2>&1; then
                                if [ "$scope_flag" = "--system" ] && command -v sudo &>/dev/null; then
                                    if [ -z "$remote_can_sudo" ]; then
                                        if [ "$cli_yes" = true ] || [ ! -t 0 ]; then
                                            if sudo -n -v 2>/dev/null; then
                                                remote_can_sudo=true
                                            else
                                                remote_can_sudo=false
                                                log_message "WARNING: Sudo credentials not cached for system flatpak remote in non-interactive mode. Proceeding without root privileges."
                                            fi
                                        else
                                            echo "Root privileges may be required to configure system flatpak remote(s)."
                                            if sudo -v; then
                                                remote_can_sudo=true
                                            else
                                                remote_can_sudo=false
                                                echo "WARNING: Sudo authentication failed. Proceeding without root privileges." >&2
                                                log_message "WARNING: Sudo authentication failed for system flatpak remote fallback."
                                            fi
                                        fi
                                    fi
                                    if [ "$remote_can_sudo" = true ]; then
                                        sudo -n -v 2>/dev/null || true
                                        # shellcheck disable=SC2024
                                        if ! sudo -n flatpak remote-add --if-not-exists "$scope_flag" "${remote_name}" "${remote_url}" >> "$LOG_FILE" 2>&1; then
                                            log_message "WARNING: Failed to configure system flatpak remote ${remote_name} with sudo."
                                            echo "WARNING: Failed to configure system flatpak remote: ${remote_name}" >&2
                                        fi
                                    else
                                        log_message "WARNING: Failed to configure system flatpak remote ${remote_name} (root privileges unavailable)."
                                    fi
                                else
                                    log_message "WARNING: Failed to configure flatpak remote ${remote_name} (${scope_flag})."
                                    echo "WARNING: Failed to configure flatpak remote: ${remote_name}" >&2
                                fi
                            fi
                        done < "${SOURCE_DIR}/${FLATPAK_REMOTES_FILE}"
                    fi

                    # Restore packages
                    if [ -f "${SOURCE_DIR}/${FLATPAK_PACKAGES_FILE}" ]; then
                        log_message "Restoring flatpak packages from ${SOURCE_DIR}/${FLATPAK_PACKAGES_FILE}"
                        local user_apps=()
                        local system_apps=()

                        while IFS=$'\t' read -r col1 _ col3 col4; do
                            [ -z "$col1" ] && continue
                            local app_id="$col1"
                            local installation="system"
                            local branch=""

                            if [ -n "$col4" ]; then
                                # 4 columns: app_id origin installation branch
                                installation="$col3"
                                branch="$col4"
                            elif [ "$col3" = "user" ] || [ "$col3" = "system" ]; then
                                installation="$col3"
                                branch=""
                            else
                                # 3 columns: app_id origin branch (legacy user backup)
                                installation="user"
                                branch="$col3"
                            fi

                            local app_ref="$app_id"
                            if [ -n "$branch" ] && [ "$branch" != "stable" ]; then
                                app_ref="${app_id}//${branch}"
                            fi

                            if [ "$installation" = "user" ]; then
                                user_apps+=("$app_ref")
                            else
                                system_apps+=("$app_ref")
                            fi
                        done < "${SOURCE_DIR}/${FLATPAK_PACKAGES_FILE}"

                        # Restore system flatpaks
                        if [ ${#system_apps[@]} -gt 0 ]; then
                            echo "Restoring ${#system_apps[@]} system flatpak(s)..."
                            log_message "Restoring ${#system_apps[@]} system flatpaks: ${system_apps[*]}"
                            if ! flatpak install -y --or-update --system "${system_apps[@]}" >> "$LOG_FILE" 2>&1; then
                                log_message "Batch system flatpak install encountered issues; attempting individual installs."
                                local can_sudo=false
                                if command -v sudo &>/dev/null; then
                                    if [ "$cli_yes" = true ] || [ ! -t 0 ]; then
                                        if sudo -n -v 2>/dev/null; then
                                            can_sudo=true
                                        else
                                            log_message "WARNING: Sudo credentials not cached for system flatpak install in non-interactive mode. Proceeding without root privileges."
                                        fi
                                    else
                                        echo "Root privileges may be required to install system flatpaks."
                                        if sudo -v; then
                                            can_sudo=true
                                        else
                                            echo "WARNING: Sudo authentication failed. Proceeding without root privileges." >&2
                                            log_message "WARNING: Sudo authentication failed for system flatpak fallback."
                                        fi
                                    fi
                                fi

                                for app in "${system_apps[@]}"; do
                                    echo "Installing system flatpak: $app..."
                                    if ! flatpak install -y --or-update --system "$app" >> "$LOG_FILE" 2>&1; then
                                        if [ "$can_sudo" = true ]; then
                                            sudo -n -v 2>/dev/null || true
                                            # shellcheck disable=SC2024
                                            sudo -n flatpak install -y --or-update --system "$app" >> "$LOG_FILE" 2>&1 || \
                                                log_message "WARNING: Failed to install system flatpak $app"
                                        else
                                            log_message "WARNING: Failed to install system flatpak $app"
                                        fi
                                    fi
                                done
                            fi
                        fi

                        # Restore user flatpaks
                        if [ ${#user_apps[@]} -gt 0 ]; then
                            echo "Restoring ${#user_apps[@]} user flatpak(s)..."
                            log_message "Restoring ${#user_apps[@]} user flatpaks: ${user_apps[*]}"
                            if ! flatpak install -y --or-update --user "${user_apps[@]}" >> "$LOG_FILE" 2>&1; then
                                log_message "Batch user flatpak install encountered issues; attempting individual installs."
                                for app in "${user_apps[@]}"; do
                                    echo "Installing user flatpak: $app..."
                                    flatpak install -y --or-update --user "$app" >> "$LOG_FILE" 2>&1 || \
                                        log_message "WARNING: Failed to install user flatpak $app"
                                done
                            fi
                        fi

                        log_message "Flatpak restore completed."
                    fi
                else
                    log_message "WARNING: flatpak command not found. Skipping flatpak restore."
                fi
            else
                echo "Skipping flatpak restore."
                log_message "Flatpak restore skipped by user."
            fi
            rm -f "${SOURCE_DIR}/${FLATPAK_REMOTES_FILE}" "${SOURCE_DIR}/${FLATPAK_PACKAGES_FILE}"
        fi

        # --- Step 7: Restore Pipx packages ---
        if [ -f "${SOURCE_DIR}/${PIPX_SPEC_FILE}" ]; then
            local restore_pipx_confirm=""
            if [ "$cli_yes" = true ]; then
                restore_pipx_confirm="y"
            elif [ -t 0 ]; then
                read -r -p "Restore pipx packages from backup? (y/N): " restore_pipx_confirm
            fi
            if [[ "$restore_pipx_confirm" =~ ^[Yy]$ ]]; then
                echo "Restoring pipx packages..."
                log_message "Restoring pipx packages from ${SOURCE_DIR}/${PIPX_SPEC_FILE}"
                if command -v pipx &> /dev/null; then
                    if (cd "${SOURCE_DIR}" && pipx install-all "${PIPX_SPEC_FILE}"); then
                        log_message "Pipx packages restored successfully."
                    else
                        log_message "WARNING: Failed to restore pipx packages."
                    fi
                else
                    log_message "WARNING: pipx command not found. Skipping pipx restore."
                fi
            else
                echo "Skipping pipx restore."
                log_message "Pipx restore skipped by user."
            fi
            rm -f "${SOURCE_DIR}/${PIPX_SPEC_FILE}"
        fi

        # --- Step 7.5: Restore/Re-enable Systemd user units ---
        if [ -f "${SOURCE_DIR}/${SYSTEMD_USER_UNITS_FILE}" ]; then
            if [ -s "${SOURCE_DIR}/${SYSTEMD_USER_UNITS_FILE}" ]; then
                local restore_systemd_confirm=""
                if [ "$cli_yes" = true ]; then
                    restore_systemd_confirm="y"
                elif [ -t 0 ]; then
                    read -r -p "Re-enable systemd user units from backup? (y/N): " restore_systemd_confirm
                fi
                if [[ "$restore_systemd_confirm" =~ ^[Yy]$ ]]; then
                    echo "Re-enabling systemd user units..."
                    log_message "Re-enabling systemd user units from ${SOURCE_DIR}/${SYSTEMD_USER_UNITS_FILE}"
                    if command -v systemctl &> /dev/null; then
                        systemctl --user daemon-reload 2>/dev/null || true
                        local unit_file _
                        while read -r unit_file _; do
                            [ -z "$unit_file" ] && continue
                            echo "Enabling systemd user unit: ${unit_file}..."
                            systemctl --user enable "$unit_file" >> "$LOG_FILE" 2>&1 || \
                                log_message "WARNING: Failed to enable systemd user unit ${unit_file}"
                        done < "${SOURCE_DIR}/${SYSTEMD_USER_UNITS_FILE}"
                        log_message "Systemd user units re-enabled."
                    else
                        log_message "WARNING: systemctl command not found. Skipping systemd user units restore."
                    fi
                else
                    echo "Skipping systemd user units re-enable."
                    log_message "Systemd user units restore skipped by user."
                fi
            else
                log_message "Systemd user units backup file is empty. Skipping restore."
            fi
            rm -f "${SOURCE_DIR}/${SYSTEMD_USER_UNITS_FILE}"
        fi

        # --- Step 7.75: Restore Crontab ---
        if [ -f "${SOURCE_DIR}/${CRONTAB_BACKUP_FILE}" ]; then
            if [ -s "${SOURCE_DIR}/${CRONTAB_BACKUP_FILE}" ]; then
                local restore_crontab_confirm=""
                if [ "$cli_yes" = true ]; then
                    restore_crontab_confirm="y"
                elif [ -t 0 ]; then
                    read -r -p "Restore crontab from backup? (y/N): " restore_crontab_confirm
                fi
                if [[ "$restore_crontab_confirm" =~ ^[Yy]$ ]]; then
                    echo "Restoring crontab..."
                    log_message "Restoring crontab from ${SOURCE_DIR}/${CRONTAB_BACKUP_FILE}"
                    crontab "${SOURCE_DIR}/${CRONTAB_BACKUP_FILE}"
                    log_message "Crontab restored."
                else
                    echo "Skipping crontab restore."
                    log_message "Crontab restore skipped by user."
                fi
            else
                log_message "Crontab backup file is empty. Skipping crontab restore."
            fi
            rm -f "${SOURCE_DIR}/${CRONTAB_BACKUP_FILE}"
        fi

        # --- Step 8: Post-Restore Permission Hardening (~/.ssh and ~/.gnupg) ---
        harden_security_permissions "${SOURCE_DIR}"

        sync -f "${SOURCE_DIR}" 2>/dev/null || sync
        local duration_str
        duration_str=$(format_duration $(( SECONDS - start_time )))
        echo "Restore complete in ${duration_str}."
        log_message "Full restore to ${SOURCE_DIR} completed in ${duration_str}."
        send_notification "normal" "Restore Complete" "Successfully restored ${SOURCE_DIR} in ${duration_str}." "drive-harddisk"
        
        if [ "$cli_yes" != true ] && [ -t 0 ]; then
            read -p "It is recommended to restart. Restart now? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Restarting now..."; systemctl reboot 2>/dev/null || sudo reboot
            fi
        fi
    else
        # Consolidate any extracted system state configuration manifests into a dedicated subdirectory
        local meta_files=("${APT_REPOS_FILE}" "${APT_PACKAGES_FILE}" "${DNF_REPOS_FILE}" "${DNF_PACKAGES_FILE}" "${DCONF_SETTINGS_FILE}" "${FLATPAK_REMOTES_FILE}" "${FLATPAK_PACKAGES_FILE}" "${PIPX_SPEC_FILE}" "${SYSTEMD_USER_UNITS_FILE}" "${CRONTAB_BACKUP_FILE}")
        local found_meta=()
        for mf in "${meta_files[@]}"; do
            [ -f "${restore_target}/${mf}" ] && found_meta+=("$mf")
        done

        if [ ${#found_meta[@]} -gt 0 ]; then
            local meta_dir="${restore_target}/.system_state"
            mkdir -p "$meta_dir" 2>/dev/null
            chmod 700 "$meta_dir" 2>/dev/null || true
            for mf in "${found_meta[@]}"; do
                mv -f "${restore_target}/${mf}" "${meta_dir}/${mf}" 2>/dev/null || true
            done
            log_message "Consolidated ${#found_meta[@]} system configuration manifests into ${meta_dir}"
        fi

        harden_security_permissions "${restore_target}"
        sync -f "${restore_target}" 2>/dev/null || sync
        local duration_str
        duration_str=$(format_duration $(( SECONDS - start_time )))
        echo "Restore complete in ${duration_str}."
        echo "Files successfully extracted to: ${restore_target}"
        if [ ${#found_meta[@]} -gt 0 ]; then
            echo "Note: Archived system configuration files (${#found_meta[@]} manifests) were not applied to the live system and have been consolidated in: ${restore_target}/.system_state/"
        else
            echo "Note: Live system configuration was not altered."
        fi
        log_message "Extracted backup to alternative directory ${restore_target} in ${duration_str}. Live system configuration was not altered."
        send_notification "normal" "Restore Complete" "Successfully extracted backup to ${restore_target} in ${duration_str}." "drive-harddisk"
    fi
}

#---
#   FUNCTION:  display_manifest()
#  DESCRIPTION:  Fetches and displays the lightweight JSON backup manifest and
#                inventory for a specified archive or the latest backup, without
#                requiring decryption or multi-gigabyte downloading.
#---
display_manifest() {
    local target="latest"
    local raw_json=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --json|-j)
                raw_json=true
                shift
                ;;
            help|-h|--help)
                echo "Usage: $0 manifest [archive|path] [--json]"
                echo
                echo "Display metadata, file sizes, checksum, system configurations, and"
                echo "inventory from the lightweight backup manifest (.manifest.json)."
                echo
                echo "Arguments:"
                echo "  [archive|path]    'latest' (default), archive filename, or path to an archive/manifest"
                echo "  --json, -j        Print raw JSON output"
                return 0
                ;;
            *)
                target="$1"
                shift
                ;;
        esac
    done

    local manifest_content=""
    local manifest_source=""

    # Case 1: Direct file path
    if [ -f "$target" ]; then
        if [[ "$target" == *.manifest.json ]]; then
            manifest_content=$(<"$target")
            manifest_source="local file (${target})"
        elif [ -f "${target}.manifest.json" ]; then
            manifest_content=$(<"${target}.manifest.json")
            manifest_source="local file (${target}.manifest.json)"
        fi
    fi

    # Case 2: Target is 'latest' or named archive - search local drive, preserved archives, and cloud
    if [ -z "$manifest_content" ]; then
        local local_backup_path=""
        local_backup_path=$(get_local_backup_path 2>/dev/null || echo "")

        if [ "$target" = "latest" ]; then
            # Try local drive first
            if [ -n "$local_backup_path" ] && [ -d "$local_backup_path" ]; then
                local latest_local_manifest=""
                latest_local_manifest=$(find "${local_backup_path}" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort -r | head -n 1)
                if [ -n "$latest_local_manifest" ] && [ -f "$latest_local_manifest" ]; then
                    manifest_content=$(<"$latest_local_manifest")
                    manifest_source="local drive (${latest_local_manifest})"
                fi
            fi

            # Try preserved archives in SOURCE_DIR
            if [ -z "$manifest_content" ]; then
                local latest_pres_manifest=""
                latest_pres_manifest=$(find "${SOURCE_DIR}" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort -r | head -n 1)
                if [ -n "$latest_pres_manifest" ] && [ -f "$latest_pres_manifest" ]; then
                    manifest_content=$(<"$latest_pres_manifest")
                    manifest_source="preserved archive (${latest_pres_manifest})"
                fi
            fi

            # Try cloud storage
            if [ -z "$manifest_content" ]; then
                echo "Searching cloud storage for latest manifest (${BACKUP_DIR})..." >&2
                local cloud_manifest_name=""
                cloud_manifest_name=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>/dev/null | grep -E "${TARBALL_BASENAME}_.*\.manifest\.json$" | sort -r | head -n 1)
                if [ -n "$cloud_manifest_name" ]; then
                    manifest_content=$(rclone cat "${BACKUP_DIR}${cloud_manifest_name}" 2>/dev/null)
                    manifest_source="cloud storage (${BACKUP_DIR}${cloud_manifest_name})"
                fi
            fi
        else
            # Specific archive name requested
            local clean_target="${target}"
            clean_target="${clean_target%.manifest.json}"

            # Check local drive
            if [ -n "$local_backup_path" ] && [ -d "$local_backup_path" ]; then
                if [ -f "${local_backup_path}/${clean_target}.manifest.json" ]; then
                    manifest_content=$(<"${local_backup_path}/${clean_target}.manifest.json")
                    manifest_source="local drive (${local_backup_path}/${clean_target}.manifest.json)"
                fi
            fi

            # Check SOURCE_DIR
            if [ -z "$manifest_content" ] && [ -f "${SOURCE_DIR}/${clean_target}.manifest.json" ]; then
                manifest_content=$(<"${SOURCE_DIR}/${clean_target}.manifest.json")
                manifest_source="preserved in ~ (${SOURCE_DIR}/${clean_target}.manifest.json)"
            fi

            # Check cloud storage
            if [ -z "$manifest_content" ]; then
                echo "Searching cloud storage for manifest: ${clean_target}.manifest.json..." >&2
                if rclone lsf "${BACKUP_DIR}${clean_target}.manifest.json" &>/dev/null; then
                    manifest_content=$(rclone cat "${BACKUP_DIR}${clean_target}.manifest.json" 2>/dev/null)
                    manifest_source="cloud storage (${BACKUP_DIR}${clean_target}.manifest.json)"
                fi
            fi
        fi
    fi

    if [ -z "$manifest_content" ]; then
        echo "ERROR: Could not find manifest for target '${target}'." >&2
        echo "Note: Backups created before manifest support may not have a companion .manifest.json sidecar." >&2
        return 1
    fi

    if [ "$raw_json" = true ]; then
        if command -v jq &>/dev/null; then
            echo "$manifest_content" | jq .
        else
            echo "$manifest_content"
        fi
        return 0
    fi

    if command -v python3 &>/dev/null; then
        python3 -c '
import json, sys

try:
    data = json.loads(sys.stdin.read())
except Exception as e:
    print(f"Error parsing manifest JSON: {e}", file=sys.stderr)
    sys.exit(1)

source = sys.argv[1] if len(sys.argv) > 1 else "Unknown"

is_tty = sys.stdout.isatty()
c_bold = "\033[1m" if is_tty else ""
c_yellow = "\033[33m" if is_tty else ""
c_reset = "\033[0m" if is_tty else ""

archive = data.get("archive", {})
comp = archive.get("compression", {})
enc = archive.get("encryption", {})
sys_st = data.get("system_state", {})
exec_st = data.get("execution", {})
dest = exec_st.get("destinations", {})

created_at = data.get("created_at", "N/A")
host = data.get("host", "N/A")
user = data.get("user", "N/A")
src_dir = data.get("source_directory", "N/A")
script_ver = data.get("script_version", "N/A")
dur_hr = exec_st.get("duration_human", "N/A")
dur_sec = exec_st.get("duration_seconds", 0)

fn = archive.get("filename", "N/A")
size_bytes = archive.get("size_bytes", 0)
size_hr = archive.get("size_human", "N/A")
uncomp_bytes = archive.get("uncompressed_bytes", 0)
uncomp_hr = archive.get("uncompressed_human", "N/A")
comp_ratio = archive.get("compression_ratio", "")
savings = archive.get("space_savings_percent", "")
sha = archive.get("sha256", "N/A")

algo = comp.get("algorithm", "zstd")
level = comp.get("level", "N/A")
ldm = comp.get("long_distance_matching", "N/A")

cipher = enc.get("cipher", "AES256")
tool = enc.get("tool", "gpg")
s2k = enc.get("s2k_digest", "SHA512")

loc_dst = dest.get("local_backup", "N/A")
cloud_dst = dest.get("cloud_backup", "N/A")

print("=" * 79)
print(f"  {c_bold}Backup Manifest & Inventory{c_reset}")
print("=" * 79)
print(f"  Manifest Source  : {source}")
print(f"  Created (UTC)    : {created_at}")
print(f"  Host / User      : {host} / {user}")
print(f"  Source Directory : {src_dir}")
print(f"  Script Version   : {script_ver}")
print(f"  Duration         : {dur_hr} ({dur_sec}s)")
print("-" * 79)
print(f"  {c_bold}Archive Details{c_reset}")
print("-" * 79)
print(f"  Filename         : {fn}")
if size_bytes:
    print(f"  Archive Size     : {size_hr} ({size_bytes:,} bytes)")
else:
    print(f"  Archive Size     : {size_hr}")
if uncomp_bytes and uncomp_bytes > 0:
    print(f"  Uncompressed     : {uncomp_hr} ({uncomp_bytes:,} bytes)")
    if comp_ratio and comp_ratio != "unknown":
        savings_str = f" ({savings} space savings)" if savings and savings != "unknown" else ""
        print(f"  Compression Ratio: {comp_ratio}{savings_str}")
print(f"  SHA-256 Checksum : {sha}")
print(f"  Compression      : {algo} (level {level}, long-matching: {ldm})")
enc_mode = enc.get("mode", "symmetric")
recipients = enc.get("recipients", [])
if enc_mode == "asymmetric":
    recip_str = ", ".join(recipients) if recipients else "configured keys"
    print(f"  Encryption       : Asymmetric (GPG Public Key: {recip_str})")
elif enc_mode == "hybrid":
    recip_str = ", ".join(recipients) if recipients else "configured keys"
    print(f"  Encryption       : Hybrid ({cipher} passphrase + GPG Public Key: {recip_str})")
else:
    print(f"  Encryption       : Symmetric {cipher} ({tool}, {s2k})")
print("-" * 79)
print(f"  {c_bold}System State Snapshot{c_reset}")
print("-" * 79)
apt_pkgs = sys_st.get("apt_manual_packages_count", 0)
if apt_pkgs:
    print(f"  APT Manual Pkgs  : {apt_pkgs} packages recorded")
else:
    print("  APT Manual Pkgs  : None / skipped")

if sys_st.get("apt_repos_backed_up"):
    print("  APT Repositories : Yes (sources & keyrings)")
else:
    print("  APT Repositories : No / skipped")

dnf_pkgs = sys_st.get("dnf_user_packages_count", 0)
if dnf_pkgs:
    print(f"  DNF User Pkgs    : {dnf_pkgs} packages recorded")
else:
    print("  DNF User Pkgs    : None / skipped")

if sys_st.get("dnf_repos_backed_up"):
    print("  DNF Repositories : Yes (repos & keys)")
else:
    print("  DNF Repositories : No / skipped")

fp_pkgs = sys_st.get("flatpak_packages_count", 0)
fp_rems = sys_st.get("flatpak_remotes_count", 0)
if fp_pkgs or fp_rems:
    print(f"  Flatpak Apps     : {fp_pkgs} apps ({fp_rems} remotes)")
else:
    print("  Flatpak Apps     : None / skipped")

if sys_st.get("pipx_spec_backed_up"):
    print("  Pipx Packages    : Yes (spec exported)")
else:
    print("  Pipx Packages    : No / skipped")

sysd = sys_st.get("systemd_user_units_count", 0)
if sysd:
    print(f"  Systemd Units    : {sysd} enabled user units")
else:
    print("  Systemd Units    : None / skipped")

if sys_st.get("dconf_settings_backed_up"):
    print("  Desktop (Dconf)  : Yes")
else:
    print("  Desktop (Dconf)  : No / skipped")

if sys_st.get("crontab_backed_up"):
    print("  Crontab Backup   : Yes")
else:
    print("  Crontab Backup   : No / skipped")

print("-" * 79)
print(f"  {c_bold}Storage Destinations{c_reset}")
print("-" * 79)
print(f"  Local Drive      : {loc_dst}")
print(f"  Cloud Storage    : {cloud_dst}")
if exec_st.get("tar_warnings", False):
    print(f"  {c_yellow}Tar Warnings     : Files changed during read (non-fatal){c_reset}")
print("=" * 79)
' "$manifest_source" <<< "$manifest_content"
    else
        echo "$manifest_content"
    fi

    return 0
}

#---
#   FUNCTION:  show_backup_stats()
#  DESCRIPTION:  Analyzes companion backup manifests (.manifest.json) across local
#                and cloud storage to report historical backup trends, size growth,
#                uncompressed capacity, compression ratios, and durations.
#                Supports --source, --limit, --json, and --csv options.
#---
show_backup_stats() {
    local source_mode="auto"
    local limit_count=15
    local output_format="table"
    local custom_path=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --json|-j)
                output_format="json"
                shift
                ;;
            --csv)
                output_format="csv"
                shift
                ;;
            --limit|-n|--count)
                if [ -n "${2:-}" ]; then
                    limit_count="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --source|-s)
                if [ -n "${2:-}" ]; then
                    source_mode="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            help|-h|--help)
                echo "Usage: $0 stats [options] [path]"
                echo
                echo "Display historical backup trends, capacity growth, and storage analytics"
                echo "from companion backup manifests (.manifest.json)."
                echo
                echo "Aliases: trends, history, analytics"
                echo
                echo "Options:"
                echo "  --source, -s <auto|local|cloud|all> Manifest source (default: auto)"
                echo "  --limit, -n <count>                Limit display to latest N backups (default: 15, 0 for all)"
                echo "  --json, -j                         Output results in structured JSON format"
                echo "  --csv                              Output results in CSV format"
                echo "  [path]                             Optional direct path to folder containing manifests"
                return 0
                ;;
            *)
                if [ -d "$1" ]; then
                    custom_path="$1"
                    source_mode="path"
                else
                    echo "Unknown option for stats: $1. Run '$0 stats --help' for usage." >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    local -a manifest_files=()
    local -a cloud_temp_dirs=()
    local local_backup_path=""
    local_backup_path=$(get_local_backup_path 2>/dev/null || echo "")

    cleanup_stats_tmp() {
        for d in "${cloud_temp_dirs[@]}"; do
            [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
        done
    }
    trap cleanup_stats_tmp RETURN

    # 1. Custom directory path source
    if [ "$source_mode" = "path" ] && [ -n "$custom_path" ]; then
        mapfile -t manifest_files < <(find "${custom_path}" -maxdepth 2 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
    # 2. Local only
    elif [ "$source_mode" = "local" ]; then
        if [ -n "$local_backup_path" ] && [ -d "$local_backup_path" ]; then
            mapfile -t manifest_files < <(find "${local_backup_path}" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
        fi
        local -a pres_files=()
        mapfile -t pres_files < <(find "${SOURCE_DIR}" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
        manifest_files+=("${pres_files[@]}")
    # 3. Cloud only
    elif [ "$source_mode" = "cloud" ]; then
        local stats_tmp_dir
        stats_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/backup_stats_cloud.XXXXXX")
        cloud_temp_dirs+=("$stats_tmp_dir")
        echo "Fetching backup manifests from cloud storage (${BACKUP_DIR})..." >&2
        if rclone copy --include "${TARBALL_BASENAME}_*.manifest.json" "${BACKUP_DIR}" "$stats_tmp_dir" 2>/dev/null; then
            mapfile -t manifest_files < <(find "$stats_tmp_dir" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
        fi
    # 4. All (merge local + cloud)
    elif [ "$source_mode" = "all" ]; then
        if [ -n "$local_backup_path" ] && [ -d "$local_backup_path" ]; then
            mapfile -t manifest_files < <(find "${local_backup_path}" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
        fi
        local -a pres_files=()
        mapfile -t pres_files < <(find "${SOURCE_DIR}" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
        manifest_files+=("${pres_files[@]}")

        local stats_tmp_dir
        stats_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/backup_stats_cloud.XXXXXX")
        cloud_temp_dirs+=("$stats_tmp_dir")
        echo "Fetching backup manifests from cloud storage (${BACKUP_DIR})..." >&2
        if rclone copy --include "${TARBALL_BASENAME}_*.manifest.json" "${BACKUP_DIR}" "$stats_tmp_dir" 2>/dev/null; then
            local -a cloud_files=()
            mapfile -t cloud_files < <(find "$stats_tmp_dir" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
            manifest_files+=("${cloud_files[@]}")
        fi
    # 5. Auto mode (local drive first, preserved in home, fall back to cloud if none found)
    else
        if [ -n "$local_backup_path" ] && [ -d "$local_backup_path" ]; then
            mapfile -t manifest_files < <(find "${local_backup_path}" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
        fi
        local -a pres_files=()
        mapfile -t pres_files < <(find "${SOURCE_DIR}" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
        manifest_files+=("${pres_files[@]}")

        if [ ${#manifest_files[@]} -eq 0 ]; then
            local stats_tmp_dir
            stats_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/backup_stats_cloud.XXXXXX")
            cloud_temp_dirs+=("$stats_tmp_dir")
            echo "No local manifests found. Fetching from cloud storage (${BACKUP_DIR})..." >&2
            if rclone copy --include "${TARBALL_BASENAME}_*.manifest.json" "${BACKUP_DIR}" "$stats_tmp_dir" 2>/dev/null; then
                mapfile -t manifest_files < <(find "$stats_tmp_dir" -maxdepth 1 -type f -name "${TARBALL_BASENAME}_*.manifest.json" 2>/dev/null | sort)
            fi
        fi
    fi

    # Filter out empty or non-existent file entries
    local -a valid_files=()
    for mf in "${manifest_files[@]}"; do
        [ -n "$mf" ] && [ -f "$mf" ] && valid_files+=("$mf")
    done

    if [ ${#valid_files[@]} -eq 0 ]; then
        echo "No backup manifests (.manifest.json) found for source: ${source_mode}." >&2
        echo "Note: Backups created before manifest support do not have companion .manifest.json sidecars." >&2
        return 1
    fi

    if ! command -v python3 &>/dev/null; then
        echo "ERROR: python3 is required to parse manifest analytics." >&2
        return 1
    fi

    python3 - "$limit_count" "$output_format" "$source_mode" "${valid_files[@]}" << 'PYEOF'
import sys, json, os, glob
from datetime import datetime

limit_arg = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 15
output_format = sys.argv[2] if len(sys.argv) > 2 else "table"
source_mode = sys.argv[3] if len(sys.argv) > 3 else "auto"

file_paths = sys.argv[4:]

def format_bytes(b, with_sign=False):
    if b == 0:
        return "0B" if not with_sign else "—"
    sign = "+" if b > 0 and with_sign else ("-" if b < 0 and with_sign else "")
    ab = abs(b)
    for unit in ["B", "KB", "MB", "GB", "TB", "PB"]:
        if ab < 1024.0 or unit == "PB":
            break
        ab /= 1024.0
    if unit in ["B", "KB"]:
        return f"{sign}{ab:.1f}{unit}"
    else:
        return f"{sign}{ab:.2f}{unit}"

def format_duration(sec):
    if not sec:
        return "0s"
    h = sec // 3600
    m = (sec % 3600) // 60
    s = sec % 60
    if h > 0:
        return f"{h}h {m}m {s}s"
    elif m > 0:
        return f"{m}m {s}s"
    else:
        return f"{s}s"

is_tty = sys.stdout.isatty()
c_bold = "\033[1m" if is_tty else ""
c_green = "\033[32m" if is_tty else ""
c_yellow = "\033[33m" if is_tty else ""
c_red = "\033[31m" if is_tty else ""
c_reset = "\033[0m" if is_tty else ""

records = {}
for path in file_paths:
    try:
        with open(path, "r", encoding="utf-8") as fp:
            d = json.load(fp)
    except Exception:
        continue

    archive = d.get("archive", {})
    created_at = d.get("created_at", "")
    ts_tag = d.get("timestamp_tag", "")
    fn = archive.get("filename", os.path.basename(path).replace(".manifest.json", ""))
    key = ts_tag if ts_tag else fn

    # Determine location tag
    loc = "Local"
    if "backup_stats_cloud" in path or "/cloud" in path.lower():
        loc = "Cloud"
    elif "preserved" in path.lower():
        loc = "Preserved"

    if key in records:
        existing = records[key].get("_loc_label", "")
        if loc != existing and "Local" in (loc, existing) and "Cloud" in (loc, existing):
            records[key]["_loc_label"] = "Local + Cloud"
        continue

    d["_loc_label"] = loc
    d["_key"] = key
    records[key] = d

sorted_records = sorted(
    records.values(),
    key=lambda r: (r.get("created_at", ""), r.get("timestamp_tag", ""), r.get("_key", ""))
)

if not sorted_records:
    print("ERROR: Failed to parse any valid manifest JSON files.", file=sys.stderr)
    sys.exit(1)

# Compute chronological deltas across the entire sequence
for i, r in enumerate(sorted_records):
    cur_sz = r.get("archive", {}).get("size_bytes", 0)
    cur_u = r.get("archive", {}).get("uncompressed_bytes", 0)

    if i == 0:
        r["_delta_sz_bytes"] = 0
        r["_delta_sz_pct"] = 0.0
        r["_delta_sz_str"] = "—"
        r["_delta_sz_color"] = ""
        r["_delta_u_bytes"] = 0
        r["_delta_u_str"] = "—"
    else:
        prev_sz = sorted_records[i-1].get("archive", {}).get("size_bytes", 0)
        prev_u = sorted_records[i-1].get("archive", {}).get("uncompressed_bytes", 0)

        diff = cur_sz - prev_sz
        pct = (diff / prev_sz) * 100.0 if prev_sz > 0 else 0.0
        r["_delta_sz_bytes"] = diff
        r["_delta_sz_pct"] = pct
        r["_delta_sz_str"] = f"{format_bytes(diff, with_sign=True)} ({pct:+.1f}%)"

        if diff > 1024 * 1024 * 1024:
            r["_delta_sz_color"] = c_red
        elif diff > 0:
            r["_delta_sz_color"] = c_yellow
        elif diff < 0:
            r["_delta_sz_color"] = c_green
        else:
            r["_delta_sz_color"] = ""

        if cur_u and prev_u:
            diff_u = cur_u - prev_u
            r["_delta_u_bytes"] = diff_u
            r["_delta_u_str"] = format_bytes(diff_u, with_sign=True)
        else:
            r["_delta_u_bytes"] = 0
            r["_delta_u_str"] = "—"

# Subdivide for display if limit is active
if limit_arg > 0 and len(sorted_records) > limit_arg:
    display_records = sorted_records[-limit_arg:]
else:
    display_records = sorted_records

# --- Format: JSON ---
if output_format == "json":
    all_sizes = [r.get("archive", {}).get("size_bytes", 0) for r in sorted_records if r.get("archive", {}).get("size_bytes")]
    all_uncomps = [r.get("archive", {}).get("uncompressed_bytes", 0) for r in sorted_records if r.get("archive", {}).get("uncompressed_bytes")]
    all_durs = [r.get("execution", {}).get("duration_seconds", 0) for r in sorted_records if r.get("execution", {}).get("duration_seconds")]

    ratios = []
    for r in sorted_records:
        rc = r.get("archive", {}).get("compression_ratio", "")
        if rc and rc.endswith("x"):
            try: ratios.append(float(rc[:-1]))
            except ValueError: pass

    out_obj = {
        "total_backups": len(sorted_records),
        "displayed_backups": len(display_records),
        "oldest_timestamp": sorted_records[0].get("created_at") if sorted_records else None,
        "newest_timestamp": sorted_records[-1].get("created_at") if sorted_records else None,
        "summary": {
            "min_archive_bytes": min(all_sizes) if all_sizes else 0,
            "max_archive_bytes": max(all_sizes) if all_sizes else 0,
            "avg_archive_bytes": int(sum(all_sizes) / len(all_sizes)) if all_sizes else 0,
            "avg_archive_human": format_bytes(int(sum(all_sizes) / len(all_sizes))) if all_sizes else "0B",
            "net_growth_bytes": (all_sizes[-1] - all_sizes[0]) if len(all_sizes) > 1 else 0,
            "net_growth_percent": round(((all_sizes[-1] - all_sizes[0]) / all_sizes[0]) * 100.0, 2) if len(all_sizes) > 1 and all_sizes[0] else 0.0,
            "avg_uncompressed_bytes": int(sum(all_uncomps) / len(all_uncomps)) if all_uncomps else 0,
            "avg_uncompressed_human": format_bytes(int(sum(all_uncomps) / len(all_uncomps))) if all_uncomps else "—",
            "avg_compression_ratio": f"{sum(ratios)/len(ratios):.2f}x" if ratios else "—",
            "avg_duration_seconds": int(sum(all_durs) / len(all_durs)) if all_durs else 0,
            "avg_duration_human": format_duration(int(sum(all_durs) / len(all_durs))) if all_durs else "0s"
        },
        "history": [
            {
                "timestamp_utc": r.get("created_at", ""),
                "timestamp_tag": r.get("timestamp_tag", ""),
                "filename": r.get("archive", {}).get("filename", ""),
                "archive_bytes": r.get("archive", {}).get("size_bytes", 0),
                "archive_human": r.get("archive", {}).get("size_human", ""),
                "delta_archive_bytes": r.get("_delta_sz_bytes", 0),
                "delta_archive_percent": round(r.get("_delta_sz_pct", 0.0), 2),
                "uncompressed_bytes": r.get("archive", {}).get("uncompressed_bytes", 0),
                "uncompressed_human": r.get("archive", {}).get("uncompressed_human", "—"),
                "compression_ratio": r.get("archive", {}).get("compression_ratio", "—"),
                "space_savings_percent": r.get("archive", {}).get("space_savings_percent", "—"),
                "duration_seconds": r.get("execution", {}).get("duration_seconds", 0),
                "duration_human": r.get("execution", {}).get("duration_human", "—"),
                "destination": r.get("_loc_label", "Local"),
                "tar_warnings": r.get("execution", {}).get("tar_warnings", False)
            }
            for r in display_records
        ]
    }
    print(json.dumps(out_obj, indent=2))
    sys.exit(0)

# --- Format: CSV ---
if output_format == "csv":
    import csv
    writer = csv.writer(sys.stdout)
    writer.writerow([
        "Timestamp_UTC", "Timestamp_Tag", "Archive_Filename", "Archive_Bytes", "Archive_Human",
        "Delta_Archive_Bytes", "Delta_Archive_Percent", "Uncompressed_Bytes", "Uncompressed_Human",
        "Compression_Ratio", "Space_Savings_Percent", "Duration_Seconds", "Duration_Human",
        "Destination", "Tar_Warnings"
    ])
    for r in display_records:
        writer.writerow([
            r.get("created_at", ""),
            r.get("timestamp_tag", ""),
            r.get("archive", {}).get("filename", ""),
            r.get("archive", {}).get("size_bytes", 0),
            r.get("archive", {}).get("size_human", ""),
            r.get("_delta_sz_bytes", 0),
            f"{r.get('_delta_sz_pct', 0.0):.2f}%",
            r.get("archive", {}).get("uncompressed_bytes", 0),
            r.get("archive", {}).get("uncompressed_human", ""),
            r.get("archive", {}).get("compression_ratio", ""),
            r.get("archive", {}).get("space_savings_percent", ""),
            r.get("execution", {}).get("duration_seconds", 0),
            r.get("execution", {}).get("duration_human", ""),
            r.get("_loc_label", "Local"),
            r.get("execution", {}).get("tar_warnings", False)
        ])
    sys.exit(0)

# --- Format: Table ---
header = f"{c_bold}{'Date & Time (UTC)':<19}  {'Archive Size':<12}  {'Delta Archive':<18}  {'Uncompressed':<12}  {'Ratio':<7}  {'Duration':<9}  {'Destination'}{c_reset}"
print("=" * 96)
if len(sorted_records) != len(display_records):
    print(f"  {c_bold}Backup Trends & Historical Analytics{c_reset} (showing latest {len(display_records)} of {len(sorted_records)} backups)")
else:
    print(f"  {c_bold}Backup Trends & Historical Analytics{c_reset} ({len(sorted_records)} backups analyzed)")
print("=" * 96)
print(header)
print("-" * 96)

for r in display_records:
    dt_raw = r.get("created_at", "")
    if "T" in dt_raw:
        dt_str = dt_raw.replace("T", " ").replace("Z", "")
    else:
        dt_str = r.get("timestamp_tag", "Unknown").replace("_", " ")

    arch_sz = r.get("archive", {}).get("size_human", "—")
    delta_str = r.get("_delta_sz_str", "—")
    delta_col = r.get("_delta_sz_color", "")
    delta_cell = f"{delta_col}{delta_str:<18}{c_reset}" if delta_col else f"{delta_str:<18}"

    uncomp = r.get("archive", {}).get("uncompressed_human", "—")
    if not uncomp or uncomp == "unknown": uncomp = "—"

    ratio = r.get("archive", {}).get("compression_ratio", "—")
    if not ratio or ratio == "unknown": ratio = "—"

    dur = r.get("execution", {}).get("duration_human", "—")
    dest = r.get("_loc_label", "Local")
    if r.get("execution", {}).get("tar_warnings", False):
        dest += " (warn)"

    print(f"{dt_str:<19}  {arch_sz:<12}  {delta_cell}  {uncomp:<12}  {ratio:<7}  {dur:<9}  {dest}")

print("-" * 96)

# Summary Section
all_sizes = [r.get("archive", {}).get("size_bytes", 0) for r in sorted_records if r.get("archive", {}).get("size_bytes")]
all_uncomps = [r.get("archive", {}).get("uncompressed_bytes", 0) for r in sorted_records if r.get("archive", {}).get("uncompressed_bytes")]
all_durs = [r.get("execution", {}).get("duration_seconds", 0) for r in sorted_records if r.get("execution", {}).get("duration_seconds")]

ratios = []
for r in sorted_records:
    rc = r.get("archive", {}).get("compression_ratio", "")
    if rc and rc.endswith("x"):
        try: ratios.append(float(rc[:-1]))
        except ValueError: pass

print(f"{c_bold}Summary Statistics:{c_reset}")
t_start = sorted_records[0].get("created_at", "").replace("T", " ").replace("Z", "")
t_end = sorted_records[-1].get("created_at", "").replace("T", " ").replace("Z", "")
print(f"  Total Backups Analyzed : {len(sorted_records)} (span: {t_start} to {t_end})")

if all_sizes:
    min_sz = format_bytes(min(all_sizes))
    max_sz = format_bytes(max(all_sizes))
    avg_sz = format_bytes(sum(all_sizes) / len(all_sizes))
    print(f"  Archive Size Range     : {min_sz} min / {max_sz} max / {avg_sz} avg")
    if len(all_sizes) > 1:
        net_sz = all_sizes[-1] - all_sizes[0]
        net_pct = (net_sz / all_sizes[0]) * 100.0 if all_sizes[0] else 0.0
        print(f"  Net Archive Growth     : {format_bytes(net_sz, with_sign=True)} ({net_pct:+.1f}%)")

if all_uncomps:
    avg_u = format_bytes(sum(all_uncomps) / len(all_uncomps))
    print(f"  Avg Uncompressed Size  : {avg_u}")
    if len(all_uncomps) > 1:
        net_u = all_uncomps[-1] - all_uncomps[0]
        net_u_pct = (net_u / all_uncomps[0]) * 100.0 if all_uncomps[0] else 0.0
        print(f"  Net Uncompressed Growth: {format_bytes(net_u, with_sign=True)} ({net_u_pct:+.1f}%)")

if ratios:
    avg_ratio = sum(ratios) / len(ratios)
    print(f"  Avg Compression Ratio  : {avg_ratio:.2f}x")

if all_durs:
    avg_dur = sum(all_durs) // len(all_durs)
    print(f"  Avg Execution Duration : {format_duration(avg_dur)}")

print("=" * 96)
PYEOF
    return $?
}

#---
#   FUNCTION:  list_backups()
#  DESCRIPTION:  Shows a list of available backups on the local drive and remote.
#---
list_backups() {
    local local_backup_path
    if local_backup_path=$(get_local_backup_path) && [ -d "${local_backup_path}" ]; then
        echo "Available local backups (${local_backup_path}):"
        local local_found=0
        while IFS=$'\t' read -r size mtime name; do
            [ -z "$name" ] && continue
            local hr_size
            hr_size=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")
            printf "  %-9s %s  %s\n" "$hr_size" "$mtime" "$name"
            local_found=1
        done < <(find "${local_backup_path}" -maxdepth 1 -type f \( -name "${TARBALL_BASENAME}_*.tar.zst.gpg" -o -name "${TARBALL_BASENAME}_*.tar.gz.gpg" -o -name "${TARBALL_BASENAME}_*.tar.xz.gpg" \) -printf "%s\t%TY-%Tm-%Td %TH:%TM:%.2TS\t%f\n" 2>/dev/null | sort -t$'\t' -k3 -r)

        if [ "$local_found" -eq 0 ]; then
            echo "  (None)"
        fi
        echo
    fi
    echo "Available cloud backups for this host (${HOSTNAME}) on ${BACKUP_DIR}:"
    local rclone_lsl_output rclone_lsl_status
    rclone_lsl_output=$(rclone lsl --fast-list "${BACKUP_DIR}" 2>&1)
    rclone_lsl_status=$?

    if [ "$rclone_lsl_status" -ne 0 ]; then
        echo "  ERROR: Failed to query cloud storage (${BACKUP_DIR}): ${rclone_lsl_output}" >&2
    else
        local cloud_found=0
        while read -r size date time name; do
            [ -z "$name" ] && continue
            local time_clean="${time%%.*}"
            local hr_size
            hr_size=$(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")
            printf "  %-9s %s %s  %s\n" "$hr_size" "$date" "$time_clean" "$name"
            cloud_found=1
        done < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_lsl_output" | sort -k4 -r)

        if [ "$cloud_found" -eq 0 ]; then
            echo "  (None)"
        fi
    fi

    local preserved_archives=()
    mapfile -t preserved_archives < <(get_preserved_archives)
    if [ ${#preserved_archives[@]} -gt 0 ]; then
        echo
        echo "Preserved local archives from failed uploads in ${SOURCE_DIR}:"
        for p_file in "${preserved_archives[@]}"; do
            [ -z "$p_file" ] && continue
            local p_size p_mtime p_name
            p_size=$(stat -c %s "$p_file" 2>/dev/null || echo 0)
            p_mtime=$(date -r "$p_file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c "%y" "$p_file" 2>/dev/null | cut -d'.' -f1)
            p_name=$(basename "$p_file")
            local hr_size
            hr_size=$(numfmt --to=iec --suffix=B "$p_size" 2>/dev/null || echo "$p_size")
            printf "  %-9s %s  %s (preserved)\n" "$hr_size" "$p_mtime" "$p_name"
        done
        echo "  [Notice: These files consume local disk space. Run backup to retry upload or clean up.]"
    fi
}

#---
#   FUNCTION:  list_archive_contents()
#  DESCRIPTION:  Lists or searches files and directories inside a backup archive
#                (streaming from local drive or cloud storage) without extracting to disk.
#                Usage: list-files [archive|latest|local|cloud] [pattern] [--long|-l]
#---
list_archive_contents() {
    local target_arg=""
    local pattern_filter=""
    local long_format=false
    local use_pager=false
    if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -n "${ARCHIVE_LIST_PAGER:-}" ]; then
        use_pager=true
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --long|-l|-v|--verbose)
                long_format=true
                shift
                ;;
            --no-pager)
                use_pager=false
                shift
                ;;
            --pager)
                use_pager=true
                shift
                ;;
            help|-h|--help)
                echo "Usage: $0 list-files [archive|path|latest|local|cloud] [pattern] [--long] [--no-pager]"
                echo
                echo "Options:"
                echo "  [archive]       Archive filename, file path, or 'latest', 'local', 'cloud' (default: interactive or latest)"
                echo "  [pattern]       Optional text or regex pattern to filter filenames (e.g. '.bashrc', 'Documents/')"
                echo "  --long, -l, -v  Detailed file listing (permissions, size, owner, modification date)"
                echo "  --no-pager      Disable terminal pagination"
                echo "  --pager         Force terminal pagination"
                return 0
                ;;
            *)
                if [ -z "$target_arg" ]; then
                    target_arg="$1"
                elif [ -z "$pattern_filter" ]; then
                    pattern_filter="$1"
                else
                    pattern_filter="${pattern_filter} $1"
                fi
                shift
                ;;
        esac
    done

    local archive_source="cloud"
    local local_available=false
    local local_backups=()
    local backups=()
    local backup_choice=""
    local direct_archive_file=""
    local local_backup_path
    local_backup_path=$(get_local_backup_path)

    # Check if local backup drive is mounted and has backups
    if [ -n "$local_backup_path" ] && [ -d "${local_backup_path}" ]; then
        mapfile -t local_backups < <(find "${local_backup_path}" -maxdepth 1 -type f \( -name "${TARBALL_BASENAME}_*.tar.zst.gpg" -o -name "${TARBALL_BASENAME}_*.tar.gz.gpg" -o -name "${TARBALL_BASENAME}_*.tar.xz.gpg" \) -printf "%f\n" 2>/dev/null | sort -r)
        if [ ${#local_backups[@]} -gt 0 ]; then
            local_available=true
        fi
    fi

    local preserved_archives=()
    mapfile -t preserved_archives < <(get_preserved_archives)

    # Determine selection mode (non-interactive vs interactive)
    local non_interactive=false
    if [ -n "$target_arg" ] || [ ! -t 0 ]; then
        non_interactive=true
    fi

    if [ "$non_interactive" = true ]; then
        case "$target_arg" in
            local)
                if [ "$local_available" = false ] && [ ${#preserved_archives[@]} -eq 0 ]; then
                    echo "ERROR: Local backup drive is not available and no preserved archives found in ${SOURCE_DIR}." >&2
                    return 1
                fi
                if [ "$local_available" = true ]; then
                    archive_source="local"
                    backups=("${local_backups[@]}")
                    backup_choice="${backups[0]}"
                else
                    archive_source="local file"
                    direct_archive_file="${preserved_archives[0]}"
                    backup_choice="$(basename "$direct_archive_file")"
                fi
                ;;
            cloud)
                archive_source="cloud"
                echo "Querying cloud backups..."
                local rclone_output
                rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1) || true
                mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
                if [ ${#backups[@]} -eq 0 ]; then
                    echo "ERROR: No cloud backups found for host (${HOSTNAME}) at ${BACKUP_DIR}." >&2
                    return 1
                fi
                backup_choice="${backups[0]}"
                ;;
            latest|"")
                if [ "$local_available" = true ]; then
                    archive_source="local"
                    backups=("${local_backups[@]}")
                    backup_choice="${backups[0]}"
                elif [ ${#preserved_archives[@]} -gt 0 ]; then
                    archive_source="local file"
                    direct_archive_file="${preserved_archives[0]}"
                    backup_choice="$(basename "$direct_archive_file")"
                else
                    archive_source="cloud"
                    echo "Querying cloud backups..."
                    local rclone_output
                    rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1) || true
                    mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
                    if [ ${#backups[@]} -eq 0 ]; then
                        echo "ERROR: No backups found for host (${HOSTNAME}) locally or on cloud." >&2
                        return 1
                    fi
                    backup_choice="${backups[0]}"
                fi
                ;;
            *)
                local requested_file
                requested_file="$(basename "$target_arg")"
                local direct_file=""
                if [ -f "$target_arg" ]; then
                    direct_file="$target_arg"
                elif [[ "$target_arg" =~ ^~(/.*)?$ ]] && [ -f "${HOME}${BASH_REMATCH[1]}" ]; then
                    direct_file="${HOME}${BASH_REMATCH[1]}"
                elif [ -f "${SOURCE_DIR}/${requested_file}" ]; then
                    direct_file="${SOURCE_DIR}/${requested_file}"
                fi

                if [ -n "$direct_file" ]; then
                    direct_archive_file=$(realpath "$direct_file" 2>/dev/null || echo "$direct_file")
                    archive_source="local file"
                    backup_choice="$(basename "$direct_archive_file")"
                else
                    local found_local=false
                    for b in "${local_backups[@]}"; do
                        if [ "$b" = "$requested_file" ]; then
                            found_local=true
                            break
                        fi
                    done
                    if [ "$found_local" = true ]; then
                        archive_source="local"
                        backup_choice="$requested_file"
                    else
                        echo "Checking cloud storage for '${requested_file}'..."
                        local rclone_output
                        rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1) || true
                        if grep -q -F "$requested_file" <<< "$rclone_output"; then
                            archive_source="cloud"
                            backup_choice="$requested_file"
                        else
                            echo "ERROR: Specified archive '${target_arg}' not found as local file, in SOURCE_DIR, on local drive, or in cloud storage." >&2
                            return 1
                        fi
                    fi
                fi
                ;;
        esac
    else
        # Interactive selection
        local source_options=()
        [ "$local_available" = true ] && source_options+=("Local Drive (${local_backup_path}) [Fastest]")
        [ ${#preserved_archives[@]} -gt 0 ] && source_options+=("Preserved Local Archives (${SOURCE_DIR}) [${#preserved_archives[@]} archive(s)]")
        source_options+=("Cloud Storage (${BACKUP_DIR})" "Cancel")

        if [ ${#source_options[@]} -gt 2 ]; then
            echo -e "\nChoose backup source to inspect:"
            local chosen_source=""
            select chosen_source in "${source_options[@]}"; do
                case "$chosen_source" in
                    "Local Drive"*)
                        archive_source="local"
                        backups=("${local_backups[@]}")
                        break
                        ;;
                    "Preserved Local Archives"*)
                        archive_source="local file"
                        backups=("${preserved_archives[@]}")
                        break
                        ;;
                    "Cloud Storage"*)
                        archive_source="cloud"
                        break
                        ;;
                    "Cancel"|"")
                        echo "Cancelled."
                        return 0
                        ;;
                esac
            done
        elif [ "$local_available" = true ]; then
            archive_source="local"
            backups=("${local_backups[@]}")
        elif [ ${#preserved_archives[@]} -gt 0 ]; then
            archive_source="local file"
            backups=("${preserved_archives[@]}")
        else
            archive_source="cloud"
        fi

        if [ "$archive_source" = "cloud" ]; then
            echo "Querying cloud backups..."
            local rclone_output rclone_status
            rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
            rclone_status=$?
            if [ "$rclone_status" -ne 0 ]; then
                echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                return 1
            fi
            mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
        fi

        if [ ${#backups[@]} -eq 0 ]; then
            echo "ERROR: No backups found for this host (${HOSTNAME}) at ${archive_source}." >&2
            return 1
        fi

        echo -e "\nPlease choose a backup archive to inspect (${archive_source}):"
        select backup_choice in "${backups[@]}" "Cancel"; do
            if [ "$backup_choice" = "Cancel" ]; then
                echo "Cancelled."; return 0
            fi
            if [ -n "$backup_choice" ]; then
                if [ "$archive_source" = "local file" ]; then
                    direct_archive_file="$backup_choice"
                    backup_choice="$(basename "$backup_choice")"
                fi
                break
            fi
        done

        if [ -z "$pattern_filter" ]; then
            echo
            read -r -p "Filter filenames by keyword or pattern (press Enter to show all): " pattern_filter
        fi
    fi

    # Detect encryption type of target archive
    local archive_enc_type="symmetric"
    if [ -n "$direct_archive_file" ]; then
        archive_enc_type=$(detect_archive_encryption "file" "$direct_archive_file")
    elif [ "$archive_source" = "local" ]; then
        archive_enc_type=$(detect_archive_encryption "file" "${local_backup_path}/${backup_choice}")
    else
        archive_enc_type=$(detect_archive_encryption "cloud" "$backup_choice")
    fi

    if [ "$archive_enc_type" = "asymmetric" ]; then
        : # Keyring will be used
    elif [ "$archive_enc_type" = "hybrid" ]; then
        if ! get_encryption_password "verify" 2>/dev/null; then
            log_message "No symmetric passphrase provided for hybrid archive; attempting secret key decryption."
        fi
    else
        if ! get_encryption_password "verify"; then
            return 1
        fi
    fi

    # Determine decompression flag based on archive extension
    local tar_compress_opts=("-I" "zstd -d -T0 --memory=${ZSTD_DECOMPRESS_MEMORY}")
    local raw_archive_name="${backup_choice%.gpg}"
    if [[ "$raw_archive_name" == *.tar.gz ]]; then
        tar_compress_opts=("-z")
    elif [[ "$raw_archive_name" == *.tar.xz ]]; then
        tar_compress_opts=("-J")
    fi

    local tar_list_flag="-tf"
    [ "$long_format" = true ] && tar_list_flag="-tvf"

    local list_tmp_dir
    list_tmp_dir=$(mktemp -d)
    local gpg_err_file="${list_tmp_dir}/gpg.err"
    local rclone_err_file="${list_tmp_dir}/rclone.err"

    echo "Listing contents of: ${backup_choice} (${archive_source})..."
    [ -n "$pattern_filter" ] && echo "Filtering for pattern: '${pattern_filter}'"
    echo "-------------------------------------------------------------------------------"

    local pager_cmd=()
    if [ "$use_pager" = true ]; then
        if [ -n "${ARCHIVE_LIST_PAGER:-}" ]; then
            read -r -a pager_cmd <<< "$ARCHIVE_LIST_PAGER"
        elif [ -n "${PAGER:-}" ]; then
            read -r -a pager_cmd <<< "$PAGER"
        elif command -v less &>/dev/null; then
            pager_cmd=(less -FRX)
        elif command -v more &>/dev/null; then
            pager_cmd=(more)
        fi
    fi

    if [ ${#pager_cmd[@]} -eq 0 ] || ! command -v "${pager_cmd[0]}" &>/dev/null; then
        pager_cmd=(cat)
    fi

    local grep_color="auto"
    [ "$use_pager" = true ] && grep_color="always"

    local gpg_exit_code=0 tar_exit_code=0 rclone_exit_code=0
    if [ -n "$direct_archive_file" ] || [ "$archive_source" = "local" ]; then
        local source_file="${direct_archive_file:-${local_backup_path}/${backup_choice}}"
        local gpg_cmd=(gpg --batch --yes --no-tty)
        if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
            gpg_cmd+=(--decrypt "$source_file")
        else
            gpg_cmd+=(--pinentry-mode loopback --decrypt --passphrase-fd 3 "$source_file")
        fi

        if [ -n "$pattern_filter" ]; then
            if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
                "${gpg_cmd[@]}" 2>"$gpg_err_file" \
                    | tar "${tar_compress_opts[@]}" "$tar_list_flag" - 2>/dev/null \
                    | grep --color="$grep_color" -E -i "$pattern_filter" \
                    | "${pager_cmd[@]}"
            else
                "${gpg_cmd[@]}" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                    | tar "${tar_compress_opts[@]}" "$tar_list_flag" - 2>/dev/null \
                    | grep --color="$grep_color" -E -i "$pattern_filter" \
                    | "${pager_cmd[@]}"
            fi
            local pipe_statuses=("${PIPESTATUS[@]}")
            gpg_exit_code=${pipe_statuses[0]}
            tar_exit_code=${pipe_statuses[1]}
        else
            if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
                "${gpg_cmd[@]}" 2>"$gpg_err_file" \
                    | tar "${tar_compress_opts[@]}" "$tar_list_flag" - 2>/dev/null \
                    | "${pager_cmd[@]}"
            else
                "${gpg_cmd[@]}" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                    | tar "${tar_compress_opts[@]}" "$tar_list_flag" - 2>/dev/null \
                    | "${pager_cmd[@]}"
            fi
            local pipe_statuses=("${PIPESTATUS[@]}")
            gpg_exit_code=${pipe_statuses[0]}
            tar_exit_code=${pipe_statuses[1]}
        fi
    else
        local gpg_cmd=(gpg --batch --yes --no-tty)
        if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
            gpg_cmd+=(--decrypt -)
        else
            gpg_cmd+=(--pinentry-mode loopback --decrypt --passphrase-fd 3 -)
        fi

        if [ -n "$pattern_filter" ]; then
            if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
                rclone cat "${BACKUP_DIR}${backup_choice}" 2>"$rclone_err_file" \
                    | "${gpg_cmd[@]}" 2>"$gpg_err_file" \
                    | tar "${tar_compress_opts[@]}" "$tar_list_flag" - 2>/dev/null \
                    | grep --color="$grep_color" -E -i "$pattern_filter" \
                    | "${pager_cmd[@]}"
            else
                rclone cat "${BACKUP_DIR}${backup_choice}" 2>"$rclone_err_file" \
                    | "${gpg_cmd[@]}" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                    | tar "${tar_compress_opts[@]}" "$tar_list_flag" - 2>/dev/null \
                    | grep --color="$grep_color" -E -i "$pattern_filter" \
                    | "${pager_cmd[@]}"
            fi
            local pipe_statuses=("${PIPESTATUS[@]}")
            rclone_exit_code=${pipe_statuses[0]}
            gpg_exit_code=${pipe_statuses[1]}
            tar_exit_code=${pipe_statuses[2]}
        else
            if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
                rclone cat "${BACKUP_DIR}${backup_choice}" 2>"$rclone_err_file" \
                    | "${gpg_cmd[@]}" 2>"$gpg_err_file" \
                    | tar "${tar_compress_opts[@]}" "$tar_list_flag" - 2>/dev/null \
                    | "${pager_cmd[@]}"
            else
                rclone cat "${BACKUP_DIR}${backup_choice}" 2>"$rclone_err_file" \
                    | "${gpg_cmd[@]}" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                    | tar "${tar_compress_opts[@]}" "$tar_list_flag" - 2>/dev/null \
                    | "${pager_cmd[@]}"
            fi
            local pipe_statuses=("${PIPESTATUS[@]}")
            rclone_exit_code=${pipe_statuses[0]}
            gpg_exit_code=${pipe_statuses[1]}
            tar_exit_code=${pipe_statuses[2]}
        fi
    fi

    echo "-------------------------------------------------------------------------------"

    local gpg_err_msg="" rclone_err_msg=""
    [ -f "$gpg_err_file" ] && gpg_err_msg=$(<"$gpg_err_file")
    [ -f "$rclone_err_file" ] && rclone_err_msg=$(<"$rclone_err_file")
    rm -rf "$list_tmp_dir" 2>/dev/null

    if [ "$gpg_exit_code" -ne 0 ] && [ "$gpg_exit_code" -ne 141 ]; then
        echo "ERROR: Decryption failed (exit code ${gpg_exit_code}). Incorrect password?" >&2
        [ -n "$gpg_err_msg" ] && echo "$gpg_err_msg" >&2
        return 1
    fi

    if [ "$archive_source" = "cloud" ] && [ "$rclone_exit_code" -ne 0 ] && [ "$rclone_exit_code" -ne 141 ] && [[ "$rclone_err_msg" != *"broken pipe"* ]]; then
        echo "ERROR: Cloud streaming error (exit code ${rclone_exit_code}): ${rclone_err_msg}" >&2
        return 1
    fi

    return 0
}

#---
#   FUNCTION:  run_verify()
#  DESCRIPTION:  Verifies the integrity of a backup archive (decryption and
#                tar/zstd stream structure) without writing files to disk.
#---
run_verify() {
    local target_arg=""
    local forced_source=""
    local checksum_only=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --checksum-only|-c|--checksum|--quick)
                checksum_only=true
                shift
                ;;
            help|-h|--help)
                echo "Usage: $0 verify [archive|path|latest|local|cloud] [source] [options]"
                echo
                echo "Options:"
                echo "  --checksum-only, -c, --quick   Perform fast SHA-256 sidecar checksum verification without decrypting"
                echo "  local | cloud                  Verify backup from specific source"
                echo "  [archive]                      Archive filename, file path, or 'latest' (default: latest)"
                return 0
                ;;
            local|cloud|auto)
                if [ -z "$target_arg" ]; then
                    target_arg="$1"
                elif [ -z "$forced_source" ]; then
                    forced_source="$1"
                fi
                shift
                ;;
            *)
                if [ -z "$target_arg" ]; then
                    target_arg="$1"
                elif [ -z "$forced_source" ]; then
                    forced_source="$1"
                fi
                shift
                ;;
        esac
    done

    log_message "Starting backup verification..."
    echo "Finding available backups for verification..."

    local verify_source="cloud"
    local local_available=false
    local local_backups=()
    local backups=()
    local backup_choice=""
    local direct_archive_file=""
    local local_backup_path
    local_backup_path=$(get_local_backup_path)

    # Check if local backup drive is mounted and has backups
    if [ -n "$local_backup_path" ] && [ -d "${local_backup_path}" ]; then
        mapfile -t local_backups < <(find "${local_backup_path}" -maxdepth 1 -type f \( -name "${TARBALL_BASENAME}_*.tar.zst.gpg" -o -name "${TARBALL_BASENAME}_*.tar.gz.gpg" -o -name "${TARBALL_BASENAME}_*.tar.xz.gpg" \) -printf "%f\n" 2>/dev/null | sort -r)
        if [ ${#local_backups[@]} -gt 0 ]; then
            local_available=true
        fi
    fi

    local preserved_archives=()
    mapfile -t preserved_archives < <(get_preserved_archives)

    # Determine whether to run non-interactively
    local non_interactive=false
    if [ -n "$target_arg" ] || [ ! -t 0 ]; then
        non_interactive=true
    fi

    if [ "$non_interactive" = true ]; then
        case "$target_arg" in
            local)
                if [ "$local_available" = false ] && [ ${#preserved_archives[@]} -eq 0 ]; then
                    local ERROR_MSG="ERROR: Local backup drive is not available and no preserved archives found in ${SOURCE_DIR}."
                    log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                    return 1
                fi
                if [ "$local_available" = true ]; then
                    verify_source="local"
                    backups=("${local_backups[@]}")
                    backup_choice="${backups[0]}"
                else
                    verify_source="local file"
                    direct_archive_file="${preserved_archives[0]}"
                    backup_choice="$(basename "$direct_archive_file")"
                fi
                ;;
            cloud)
                verify_source="cloud"
                echo "Querying cloud backups..."
                local rclone_output rclone_status
                rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
                rclone_status=$?
                if [ "$rclone_status" -ne 0 ]; then
                    local ERROR_MSG="Failed to query cloud storage (${BACKUP_DIR}): ${rclone_output}"
                    log_message "$ERROR_MSG"; echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                    return 1
                fi
                mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
                if [ ${#backups[@]} -eq 0 ]; then
                    local ERROR_MSG="ERROR: No cloud backups found for host (${HOSTNAME}) at ${BACKUP_DIR}."
                    log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                    return 1
                fi
                backup_choice="${backups[0]}"
                ;;
            latest|"")
                if [ "$forced_source" = "cloud" ]; then
                    verify_source="cloud"
                    echo "Querying cloud backups..."
                    local rclone_output rclone_status
                    rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
                    rclone_status=$?
                    if [ "$rclone_status" -ne 0 ]; then
                        local ERROR_MSG="Failed to query cloud storage (${BACKUP_DIR}): ${rclone_output}"
                        log_message "$ERROR_MSG"; echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                        return 1
                    fi
                    mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
                    if [ ${#backups[@]} -eq 0 ]; then
                        local ERROR_MSG="ERROR: No cloud backups found for host (${HOSTNAME}) at ${BACKUP_DIR}."
                        log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                        return 1
                    fi
                    backup_choice="${backups[0]}"
                elif [ "$local_available" = true ] && [ "$forced_source" != "cloud" ]; then
                    verify_source="local"
                    backups=("${local_backups[@]}")
                    backup_choice="${backups[0]}"
                elif [ ${#preserved_archives[@]} -gt 0 ] && [ "$forced_source" != "cloud" ]; then
                    verify_source="local file"
                    direct_archive_file="${preserved_archives[0]}"
                    backup_choice="$(basename "$direct_archive_file")"
                else
                    verify_source="cloud"
                    echo "Querying cloud backups..."
                    local rclone_output rclone_status
                    rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
                    rclone_status=$?
                    if [ "$rclone_status" -ne 0 ]; then
                        local ERROR_MSG="Failed to query cloud storage (${BACKUP_DIR}): ${rclone_output}"
                        log_message "$ERROR_MSG"; echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                        return 1
                    fi
                    mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
                    if [ ${#backups[@]} -eq 0 ]; then
                        local ERROR_MSG="ERROR: No cloud backups found for host (${HOSTNAME}) at ${BACKUP_DIR}."
                        log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                        return 1
                    fi
                    backup_choice="${backups[0]}"
                fi
                ;;
            *)
                # Specific archive filename or direct path requested
                local requested_file
                requested_file="$(basename "$target_arg")"
                local direct_file=""
                if [ -f "$target_arg" ]; then
                    direct_file="$target_arg"
                elif [[ "$target_arg" =~ ^~(/.*)?$ ]] && [ -f "${HOME}${BASH_REMATCH[1]}" ]; then
                    direct_file="${HOME}${BASH_REMATCH[1]}"
                elif [ -f "${SOURCE_DIR}/${requested_file}" ]; then
                    direct_file="${SOURCE_DIR}/${requested_file}"
                fi

                if [ -n "$direct_file" ] && [ "$forced_source" != "cloud" ]; then
                    direct_archive_file=$(realpath "$direct_file" 2>/dev/null || echo "$direct_file")
                    verify_source="local file"
                    backup_choice="$(basename "$direct_archive_file")"
                else
                    local found_local=false
                    if [ "$forced_source" != "cloud" ]; then
                        for b in "${local_backups[@]}"; do
                            if [ "$b" = "$requested_file" ]; then
                                found_local=true
                                break
                            fi
                        done
                    fi
                    if [ "$found_local" = true ]; then
                        verify_source="local"
                        backup_choice="$requested_file"
                    elif [ "$forced_source" = "local" ]; then
                        local ERROR_MSG="ERROR: Specified archive '${target_arg}' not found on local drive, in SOURCE_DIR, or as local file."
                        log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                        return 1
                    else
                        echo "Checking cloud storage for '${requested_file}'..."
                        local rclone_output rclone_status
                        rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
                        rclone_status=$?
                        if [ "$rclone_status" -ne 0 ]; then
                            local ERROR_MSG="Failed to query cloud storage (${BACKUP_DIR}): ${rclone_output}"
                            log_message "$ERROR_MSG"; echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                            return 1
                        fi
                        if grep -q -F "$requested_file" <<< "$rclone_output"; then
                            verify_source="cloud"
                            backup_choice="$requested_file"
                        else
                            local ERROR_MSG="ERROR: Specified archive '${target_arg}' not found as local file, in SOURCE_DIR, on local drive, or in cloud storage."
                            log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                            return 1
                        fi
                    fi
                fi
                ;;
        esac
        echo "Non-interactive verification selected: ${backup_choice} (${verify_source})"
    else
        # Interactive selection
        local source_options=()
        [ "$local_available" = true ] && source_options+=("Local Drive (${local_backup_path}) [Fastest]")
        [ ${#preserved_archives[@]} -gt 0 ] && source_options+=("Preserved Local Archives (${SOURCE_DIR}) [${#preserved_archives[@]} archive(s)]")
        source_options+=("Cloud Storage (${BACKUP_DIR})" "Cancel")

        if [ ${#source_options[@]} -gt 2 ]; then
            echo -e "\nChoose backup source to verify:"
            local chosen_source=""
            select chosen_source in "${source_options[@]}"; do
                case "$chosen_source" in
                    "Local Drive"*)
                        verify_source="local"
                        backups=("${local_backups[@]}")
                        break
                        ;;
                    "Preserved Local Archives"*)
                        verify_source="local file"
                        backups=("${preserved_archives[@]}")
                        break
                        ;;
                    "Cloud Storage"*)
                        verify_source="cloud"
                        break
                        ;;
                    "Cancel"|"")
                        echo "Verification cancelled."
                        return 0
                        ;;
                esac
            done
        elif [ "$local_available" = true ]; then
            verify_source="local"
            backups=("${local_backups[@]}")
        elif [ ${#preserved_archives[@]} -gt 0 ]; then
            verify_source="local file"
            backups=("${preserved_archives[@]}")
        else
            echo "Local backup drive not detected or contains no backups. Checking cloud storage..."
            verify_source="cloud"
        fi

        if [ "$verify_source" = "cloud" ]; then
            echo "Querying cloud backups..."
            local rclone_output rclone_status
            rclone_output=$(rclone lsf --fast-list "${BACKUP_DIR}" 2>&1)
            rclone_status=$?

            if [ "$rclone_status" -ne 0 ]; then
                local ERROR_MSG="Failed to query cloud storage (${BACKUP_DIR}): ${rclone_output}"
                log_message "$ERROR_MSG"
                echo "ERROR: Could not connect to cloud storage: ${rclone_output}" >&2
                return 1
            fi

            mapfile -t backups < <(grep -E "${TARBALL_BASENAME}_.*\.tar\.(zst|gz|xz)\.gpg$" <<< "$rclone_output" | sort -r)
        fi

        if [ ${#backups[@]} -eq 0 ]; then
            local ERROR_MSG="No backups found for this host (${HOSTNAME}) at ${verify_source} to verify."
            log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2; return 1
        fi

        echo -e "\nPlease choose a backup archive to verify (${verify_source}):"
        select backup_choice in "${backups[@]}" "Cancel"; do
            if [ "$backup_choice" = "Cancel" ]; then
                echo "Verification cancelled."; return 0
            fi
            if [ -n "$backup_choice" ]; then
                if [ "$verify_source" = "local file" ]; then
                    direct_archive_file="$backup_choice"
                    backup_choice="$(basename "$backup_choice")"
                fi
                break
            fi
        done
    fi

    # --- Step 1: SHA-256 Sidecar Checksum Validation ---
    local sha256_verified=false
    if [ -n "$direct_archive_file" ] || [ "$verify_source" = "local" ]; then
        local local_sha256_file=""
        local check_dir=""
        if [ -n "$direct_archive_file" ]; then
            local_sha256_file="${direct_archive_file}.sha256"
            check_dir="$(dirname "$direct_archive_file")"
        else
            local_sha256_file="${local_backup_path}/${backup_choice}.sha256"
            check_dir="${local_backup_path}"
        fi

        if [ -f "$local_sha256_file" ]; then
            echo "Verifying SHA-256 sidecar checksum ($(basename "$local_sha256_file"))..."
            log_message "Verifying local SHA-256 checksum for ${backup_choice}..."
            if (cd "${check_dir}" && sha256sum -c "$(basename "$local_sha256_file")" --status); then
                echo "SHA-256 checksum verified OK (no bit-rot detected)."
                log_message "SHA-256 checksum valid for ${backup_choice}."
                sha256_verified=true
                if [ "$checksum_only" = true ]; then
                    echo "SUCCESS: Archive '${backup_choice}' passed SHA-256 checksum verification."
                    send_notification "normal" "Checksum Verified" "SHA-256 checksum verified OK for ${backup_choice}." "drive-harddisk"
                    return 0
                fi
            else
                local ERROR_MSG="ERROR: SHA-256 checksum verification failed for ${backup_choice}. The archive file on disk is corrupted or modified."
                log_message "$ERROR_MSG"
                echo "$ERROR_MSG" >&2
                send_notification "critical" "Verification Failed" "SHA-256 checksum mismatch for ${backup_choice}." "dialog-error"
                return 1
            fi
        else
            if [ "$checksum_only" = true ]; then
                local sidecar_basename
                sidecar_basename=$(basename "$local_sha256_file")
                local ERROR_MSG="ERROR: SHA-256 sidecar file '${sidecar_basename}' not found in ${check_dir}."
                log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                send_notification "critical" "Verification Failed" "SHA-256 sidecar missing for ${backup_choice}." "dialog-warning"
                return 1
            fi
            echo "Notice: No SHA-256 sidecar found for ${backup_choice} in ${check_dir}. Proceeding with decryption stream check."
        fi
    else
        # Cloud verification
        local cloud_sha_output
        cloud_sha_output=$(rclone cat "${BACKUP_DIR}${backup_choice}.sha256" 2>/dev/null)
        if [ -n "$cloud_sha_output" ]; then
            if [ "$checksum_only" = true ]; then
                echo "Streaming cloud archive to verify SHA-256 checksum..."
                local expected_hash actual_hash
                expected_hash=$(awk '{print $1}' <<< "$cloud_sha_output")
                actual_hash=$(rclone cat "${BACKUP_DIR}${backup_choice}" 2>/dev/null | sha256sum | awk '{print $1}')
                if [ -n "$actual_hash" ] && [ "$actual_hash" = "$expected_hash" ]; then
                    echo "Cloud SHA-256 checksum verified OK (${actual_hash:0:12}...)."
                    log_message "Cloud SHA-256 checksum valid for ${backup_choice}."
                    echo "SUCCESS: Cloud archive '${backup_choice}' passed SHA-256 checksum verification."
                    send_notification "normal" "Checksum Verified" "Cloud SHA-256 checksum verified OK for ${backup_choice}." "drive-harddisk"
                    return 0
                else
                    local ERROR_MSG="ERROR: Cloud SHA-256 checksum mismatch for ${backup_choice} (expected: ${expected_hash}, calculated: ${actual_hash})."
                    log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                    send_notification "critical" "Verification Failed" "Cloud SHA-256 checksum mismatch for ${backup_choice}." "dialog-error"
                    return 1
                fi
            fi
        else
            if [ "$checksum_only" = true ]; then
                local ERROR_MSG="ERROR: SHA-256 sidecar file '${backup_choice}.sha256' not found in cloud storage."
                log_message "$ERROR_MSG"; echo "$ERROR_MSG" >&2
                send_notification "critical" "Verification Failed" "Cloud SHA-256 sidecar missing for ${backup_choice}." "dialog-warning"
                return 1
            fi
        fi
    fi

    # --- Step 2: Full Decryption & Archive Structure Verification ---
    # Detect encryption type of target archive
    local archive_enc_type="symmetric"
    if [ -n "$direct_archive_file" ]; then
        archive_enc_type=$(detect_archive_encryption "file" "$direct_archive_file")
    elif [ "$verify_source" = "local" ]; then
        archive_enc_type=$(detect_archive_encryption "file" "${local_backup_path}/${backup_choice}")
    else
        archive_enc_type=$(detect_archive_encryption "cloud" "$backup_choice")
    fi

    if [ "$archive_enc_type" = "asymmetric" ]; then
        log_message "Archive is encrypted with GPG public key(s)."
        echo "Archive is encrypted with GPG public key(s)."
    elif [ "$archive_enc_type" = "hybrid" ]; then
        log_message "Archive is encrypted with GPG hybrid mode (public key + passphrase)."
        echo "Archive is encrypted with GPG hybrid mode (public key + passphrase)."
        if ! get_encryption_password "verify" 2>/dev/null; then
            log_message "No symmetric passphrase provided for hybrid archive; attempting secret key decryption."
        fi
    else
        if ! get_encryption_password "verify"; then
            return 1
        fi
    fi

    # Determine decompression flag based on archive extension
    local tar_compress_opts=("-I" "zstd -d -T0 --memory=${ZSTD_DECOMPRESS_MEMORY}")
    local raw_archive_name="${backup_choice%.gpg}"
    if [[ "$raw_archive_name" == *.tar.gz ]]; then
        tar_compress_opts=("-z")
    elif [[ "$raw_archive_name" == *.tar.xz ]]; then
        tar_compress_opts=("-J")
    fi

    echo -e "\nStarting stream verification on: ${backup_choice} (${verify_source})"
    echo "Testing GPG decryption, decompression, and archive structure (no files written to disk)..."
    log_message "Verifying integrity of ${backup_choice} (${verify_source})"

    local verify_tmp_dir
    verify_tmp_dir=$(mktemp -d)
    CURRENT_VERIFY_TMP_DIR="$verify_tmp_dir"
    trap 'rm -rf "$verify_tmp_dir"; CURRENT_VERIFY_TMP_DIR=""; trap cleanup EXIT INT TERM HUP' RETURN
    trap 'rm -rf "$verify_tmp_dir"; cleanup' INT TERM

    local gpg_err_file="${verify_tmp_dir}/gpg.err"
    local tar_err_file="${verify_tmp_dir}/tar.err"
    local rclone_err_file="${verify_tmp_dir}/rclone.err"
    local count_file="${verify_tmp_dir}/item_count.txt"

    local gpg_exit_code=0 tar_exit_code=0 rclone_exit_code=0
    local is_tty=0
    [ -t 1 ] && is_tty=1

    if [ -n "$direct_archive_file" ] || [ "$verify_source" = "local" ]; then
        local source_file="${direct_archive_file:-${local_backup_path}/${backup_choice}}"
        if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
            gpg --batch --yes --no-tty --decrypt "$source_file" 2>"$gpg_err_file" \
                | tar "${tar_compress_opts[@]}" -tf - 2>"$tar_err_file" \
                | awk -v cf="$count_file" -v tty="$is_tty" -v label="Verifying" '
                    tty == 1 && NR % 5000 == 0 { printf "\r%s: %d items scanned...", label, NR; fflush() }
                    tty == 0 && NR % 25000 == 0 { printf "%s: %d items scanned...\n", label, NR; fflush() }
                    END {
                        if (tty == 1) {
                            printf "\rVerification finished: %d items scanned.           \n", NR
                        } else {
                            printf "Verification finished: %d items scanned.\n", NR
                        }
                        print NR > cf
                    }'
        else
            gpg --batch --yes --no-tty --pinentry-mode loopback --decrypt --passphrase-fd 3 "$source_file" 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                | tar "${tar_compress_opts[@]}" -tf - 2>"$tar_err_file" \
                | awk -v cf="$count_file" -v tty="$is_tty" -v label="Verifying" '
                    tty == 1 && NR % 5000 == 0 { printf "\r%s: %d items scanned...", label, NR; fflush() }
                    tty == 0 && NR % 25000 == 0 { printf "%s: %d items scanned...\n", label, NR; fflush() }
                    END {
                        if (tty == 1) {
                            printf "\rVerification finished: %d items scanned.           \n", NR
                        } else {
                            printf "Verification finished: %d items scanned.\n", NR
                        }
                        print NR > cf
                    }'
        fi
        local pipe_statuses=("${PIPESTATUS[@]}")
        gpg_exit_code=${pipe_statuses[0]}
        tar_exit_code=${pipe_statuses[1]}
    else
        echo "Streaming archive from cloud storage (${BACKUP_DIR})..."
        if [ "$archive_enc_type" = "asymmetric" ] && [ -z "$ENCRYPTION_PASSWORD" ]; then
            rclone cat "${BACKUP_DIR}${backup_choice}" 2>"$rclone_err_file" \
                | gpg --batch --yes --no-tty --decrypt - 2>"$gpg_err_file" \
                | tar "${tar_compress_opts[@]}" -tf - 2>"$tar_err_file" \
                | awk -v cf="$count_file" -v tty="$is_tty" -v label="Verifying cloud archive" '
                    tty == 1 && NR % 5000 == 0 { printf "\r%s: %d items scanned...", label, NR; fflush() }
                    tty == 0 && NR % 25000 == 0 { printf "%s: %d items scanned...\n", label, NR; fflush() }
                    END {
                        if (tty == 1) {
                            printf "\rVerification finished: %d items scanned.           \n", NR
                        } else {
                            printf "Verification finished: %d items scanned.\n", NR
                        }
                        print NR > cf
                    }'
        else
            rclone cat "${BACKUP_DIR}${backup_choice}" 2>"$rclone_err_file" \
                | gpg --batch --yes --no-tty --pinentry-mode loopback --decrypt --passphrase-fd 3 - 3<<< "$ENCRYPTION_PASSWORD" 2>"$gpg_err_file" \
                | tar "${tar_compress_opts[@]}" -tf - 2>"$tar_err_file" \
                | awk -v cf="$count_file" -v tty="$is_tty" -v label="Verifying cloud archive" '
                    tty == 1 && NR % 5000 == 0 { printf "\r%s: %d items scanned...", label, NR; fflush() }
                    tty == 0 && NR % 25000 == 0 { printf "%s: %d items scanned...\n", label, NR; fflush() }
                    END {
                        if (tty == 1) {
                            printf "\rVerification finished: %d items scanned.           \n", NR
                        } else {
                            printf "Verification finished: %d items scanned.\n", NR
                        }
                        print NR > cf
                    }'
        fi
        local pipe_statuses=("${PIPESTATUS[@]}")
        rclone_exit_code=${pipe_statuses[0]}
        gpg_exit_code=${pipe_statuses[1]}
        tar_exit_code=${pipe_statuses[2]}
    fi

    local gpg_err_msg="" tar_err_msg="" rclone_err_msg="" records_scanned=0
    [ -f "$gpg_err_file" ] && gpg_err_msg=$(<"$gpg_err_file")
    [ -f "$tar_err_file" ] && tar_err_msg=$(<"$tar_err_file")
    [ -f "$rclone_err_file" ] && rclone_err_msg=$(<"$rclone_err_file")
    [ -f "$count_file" ] && records_scanned=$(<"$count_file")
    records_scanned="${records_scanned:-0}"
    rm -rf "$verify_tmp_dir" 2>/dev/null

    # 1. Upstream cloud streaming/network error (genuine network failure, not broken pipe from downstream)
    if [ "$verify_source" = "cloud" ] && [ "$rclone_exit_code" -ne 0 ] && [ "$rclone_exit_code" -ne 141 ] && [[ "$rclone_err_msg" != *"broken pipe"* ]]; then
        local ERROR_MSG="Cloud streaming error (rclone exit code ${rclone_exit_code}): ${rclone_err_msg}"
        log_message "$ERROR_MSG"
        echo "ERROR: $ERROR_MSG" >&2
        [ -n "$rclone_err_msg" ] && echo "$rclone_err_msg" >&2
        send_notification "critical" "Verification Failed" "Cloud download error during verification of ${backup_choice}."
        return 1
    fi

    # 2. Upstream GPG decryption error (bad passphrase or corrupted header)
    if [ "$gpg_exit_code" -ne 0 ] && [ "$gpg_exit_code" -ne 141 ]; then
        local ERROR_MSG="GPG decryption failed with exit code ${gpg_exit_code}. Password may be incorrect or archive header corrupted."
        log_message "$ERROR_MSG: ${gpg_err_msg}"
        echo "ERROR: $ERROR_MSG" >&2
        [ -n "$gpg_err_msg" ] && echo "$gpg_err_msg" >&2
        send_notification "critical" "Verification Failed" "Decryption failed for ${backup_choice}."
        return 1
    fi

    # 3. Downstream archive corruption / decompression failure in tar
    if [ "$tar_exit_code" -ne 0 ] && [ "$tar_exit_code" -ne 141 ]; then
        local ERROR_MSG="Tar/decompression validation failed with exit code ${tar_exit_code}. Archive stream may be corrupted or incomplete."
        log_message "$ERROR_MSG: ${tar_err_msg}"
        echo "ERROR: $ERROR_MSG" >&2
        [ -n "$tar_err_msg" ] && echo "$tar_err_msg" >&2
        send_notification "critical" "Verification Failed" "Archive corruption detected in ${backup_choice}."
        return 1
    fi

    # 4. Catch-all for any unresolved failure in the pipeline
    if [ "$tar_exit_code" -ne 0 ] || [ "$gpg_exit_code" -ne 0 ] || { [ "$verify_source" = "cloud" ] && [ "$rclone_exit_code" -ne 0 ] && [ "$rclone_exit_code" -ne 141 ]; }; then
        local ERROR_MSG="Verification pipeline failed (rclone: ${rclone_exit_code}, gpg: ${gpg_exit_code}, tar: ${tar_exit_code})."
        log_message "$ERROR_MSG"
        echo "ERROR: $ERROR_MSG" >&2
        [ -n "$rclone_err_msg" ] && echo "rclone: $rclone_err_msg" >&2
        [ -n "$gpg_err_msg" ] && echo "gpg: $gpg_err_msg" >&2
        [ -n "$tar_err_msg" ] && echo "tar: $tar_err_msg" >&2
        send_notification "critical" "Verification Failed" "Pipeline failure during verification of ${backup_choice}."
        return 1
    fi

    # 5. Check that the archive actually contained files (guard against empty archives / false positives)
    if ! [ "$records_scanned" -gt 0 ] 2>/dev/null; then
        local ERROR_MSG="Verification failed: archive '${backup_choice}' contains 0 records (empty or unreadable archive)."
        log_message "$ERROR_MSG"
        echo "ERROR: $ERROR_MSG" >&2
        send_notification "critical" "Verification Failed" "Archive ${backup_choice} is empty (0 records scanned)."
        return 1
    fi

    local sha_note=""
    if [ "$sha256_verified" = true ]; then
        sha_note=" and SHA-256 sidecar verified"
    fi
    log_message "Integrity verification successful for ${backup_choice} (${records_scanned} records verified${sha_note})."
    echo "SUCCESS: Backup archive '${backup_choice}' is completely valid and uncorrupted (${records_scanned} records verified${sha_note})."
    send_notification "normal" "Verification Succeeded" "Backup archive ${backup_choice} is intact (${records_scanned} records verified${sha_note})."
    return 0
}

#---
#   FUNCTION:  acquire_lock()
#  DESCRIPTION:  Acquires a non-blocking kernel-managed lock via flock on FD 200,
#                records the PID, and reports the blocking PID if lock is held.
#---
acquire_lock() {
    local lock_dir
    lock_dir=$(dirname "$LOCK_FILE")
    [ -d "$lock_dir" ] || mkdir -p "$lock_dir" 2>/dev/null || true
    exec 200<>"$LOCK_FILE"
    if ! flock -n 200; then
        exec 200>&- || true
        local blocker=""
        if [ -s "$LOCK_FILE" ]; then
            blocker=$(head -n 1 "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
        fi
        if [ -z "$blocker" ] && command -v fuser &>/dev/null; then
            blocker=$(fuser "$LOCK_FILE" 2>/dev/null | tr ' ' '\n' | grep -v "^$$$" | grep -v "^$" | head -n 1)
        fi
        [ -n "$blocker" ] && blocker=" (PID: ${blocker})"
        log_message "Lock held by another instance${blocker}. Aborting."
        send_notification "normal" "Backup Skipped" "Another backup or restore process is already running${blocker}."
        echo "ERROR: Another backup or restore process is already running${blocker}." >&2
        return 1
    fi
    echo "$$" > "$LOCK_FILE"
    LOCK_HELD=1
    return 0
}

#---
#   FUNCTION:  release_lock()
#  DESCRIPTION:  Releases the flock on FD 200.
#---
release_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        : > "$LOCK_FILE" 2>/dev/null || true
        flock -u 200 2>/dev/null
        exec 200>&- || true
        LOCK_HELD=0
    fi
}

#---
#   FUNCTION:  cleanup()
#  DESCRIPTION:  Cleans up temporary files and releases locks on exit or interrupt.
#---
cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM HUP

    # Only clean up files and release lock if this instance actually acquired the lock
    if [ "$LOCK_HELD" -eq 1 ]; then
        # Clean up any in-flight temporary partial file on the local backup drive
        if [ -n "$CURRENT_LOCAL_TEMP_ARCHIVE" ]; then
            rm -f "$CURRENT_LOCAL_TEMP_ARCHIVE" 2>/dev/null
            CURRENT_LOCAL_TEMP_ARCHIVE=""
        fi
        if [ -n "$CURRENT_LOCAL_TEMP_SHA256" ]; then
            rm -f "$CURRENT_LOCAL_TEMP_SHA256" 2>/dev/null
            CURRENT_LOCAL_TEMP_SHA256=""
        fi
        if [ -n "$CURRENT_LOCAL_TEMP_MANIFEST" ]; then
            rm -f "$CURRENT_LOCAL_TEMP_MANIFEST" 2>/dev/null
            CURRENT_LOCAL_TEMP_MANIFEST=""
        fi

        # Clean up any temporary verification, backup, or restore directory
        if [ -n "$CURRENT_VERIFY_TMP_DIR" ]; then
            rm -rf "$CURRENT_VERIFY_TMP_DIR" 2>/dev/null
            CURRENT_VERIFY_TMP_DIR=""
        fi
        if [ -n "$CURRENT_BACKUP_TMP_DIR" ]; then
            rm -rf "$CURRENT_BACKUP_TMP_DIR" 2>/dev/null
            CURRENT_BACKUP_TMP_DIR=""
        fi
        if [ -n "$CURRENT_RESTORE_TMP_DIR" ]; then
            rm -rf "$CURRENT_RESTORE_TMP_DIR" 2>/dev/null
            CURRENT_RESTORE_TMP_DIR=""
        fi

        # Clean up temporary metadata staging directory in SCRATCH_DIR
        if [ -n "$CURRENT_METADATA_STAGING_DIR" ] && [ -d "$CURRENT_METADATA_STAGING_DIR" ]; then
            rm -rf "$CURRENT_METADATA_STAGING_DIR" 2>/dev/null
            CURRENT_METADATA_STAGING_DIR=""
        fi

        if [ "$SCRATCH_FILES_CREATED" -eq 1 ]; then
            # Clean up temporary metadata files in SOURCE_DIR if present from previous interrupted runs
            rm -f "${SOURCE_DIR}/${CRONTAB_BACKUP_FILE}" "${SOURCE_DIR}/${PIPX_SPEC_FILE}" "${SOURCE_DIR}/${FLATPAK_REMOTES_FILE}" "${SOURCE_DIR}/${FLATPAK_PACKAGES_FILE}" "${SOURCE_DIR}/${SYSTEMD_USER_UNITS_FILE}" "${SOURCE_DIR}/${DCONF_SETTINGS_FILE}" "${SOURCE_DIR}/${APT_PACKAGES_FILE}" "${SOURCE_DIR}/${APT_REPOS_FILE}" "${SOURCE_DIR}/${DNF_PACKAGES_FILE}" "${SOURCE_DIR}/${DNF_REPOS_FILE}" 2>/dev/null
            rm -rf "${SYSTEM_STATE_STAGING_DIR}" 2>/dev/null || true

            # Clean up partial backup/restore archives in SCRATCH_DIR
            if [ -d "${SCRATCH_DIR}" ]; then
                if [ "$PRESERVE_ARCHIVE" = true ]; then
                    local keep_name="" keep_sha="" keep_manifest=""
                    [ -n "$CURRENT_ENCRYPTED_ARCHIVE" ] && keep_name=$(basename "$CURRENT_ENCRYPTED_ARCHIVE")
                    [ -n "$CURRENT_SHA256_FILE" ] && keep_sha=$(basename "$CURRENT_SHA256_FILE")
                    [ -n "$CURRENT_MANIFEST_FILE" ] && keep_manifest=$(basename "$CURRENT_MANIFEST_FILE")
                    if [ -n "$keep_name" ]; then
                        find "${SCRATCH_DIR}" -maxdepth 1 \( -name "${TARBALL_BASENAME}_*" ! -name "$keep_name" ${keep_sha:+! -name "$keep_sha"} ${keep_manifest:+! -name "$keep_manifest"} \) -delete 2>/dev/null
                    fi
                    rmdir "${SCRATCH_DIR}" 2>/dev/null || true
                else
                    [ -n "$CURRENT_TEMP_ARCHIVE" ] && rm -f "$CURRENT_TEMP_ARCHIVE" 2>/dev/null
                    [ -n "$CURRENT_ENCRYPTED_ARCHIVE" ] && rm -f "$CURRENT_ENCRYPTED_ARCHIVE" 2>/dev/null
                    [ -n "$CURRENT_SHA256_FILE" ] && rm -f "$CURRENT_SHA256_FILE" 2>/dev/null
                    [ -n "$CURRENT_MANIFEST_FILE" ] && rm -f "$CURRENT_MANIFEST_FILE" 2>/dev/null
                    # Fallback in case archive tracking was unset
                    if [ -z "$CURRENT_TEMP_ARCHIVE" ] && [ -z "$CURRENT_ENCRYPTED_ARCHIVE" ]; then
                        rm -f "${SCRATCH_DIR}/${TARBALL_BASENAME}_"* 2>/dev/null
                    fi
                    rmdir "${SCRATCH_DIR}" 2>/dev/null || true
                fi
            fi
            SCRATCH_FILES_CREATED=0
        fi

        # Release flock if held
        release_lock
    fi

    # Clean up inhibition sentinel if trapped before normal completion
    [ -n "${INHIBIT_SENTINEL:-}" ] && rm -f "$INHIBIT_SENTINEL" 2>/dev/null

    exit "$exit_code"
}

#---
#   FUNCTION:  execute_with_inhibit()
#  DESCRIPTION:  Wraps execution in systemd-inhibit if available to prevent system
#                sleep or shutdown during backup, restore, or verify operations.
#                Falls back to direct execution if systemd-inhibit fails to launch.
#                Acquires the process lock before running and releases it upon exit.
#---
execute_with_inhibit() {
    local action="$1"
    shift
    local why_msg="Managing backup operations"

    case "$action" in
        backup)  why_msg="Backing up home directory" ;;
        restore) why_msg="Restoring home directory" ;;
        verify)  why_msg="Verifying backup archive integrity" ;;
        list-files|view-archive|list-contents) why_msg="Listing backup archive contents" ;;
        manage-preserved|clean-preserved) why_msg="Managing preserved backup archives" ;;
    esac

    # If invoked under systemd-inhibit, acknowledge invocation and consume sentinel
    if [ -n "${INHIBIT_SENTINEL:-}" ] && [ -f "$INHIBIT_SENTINEL" ]; then
        rm -f "$INHIBIT_SENTINEL" 2>/dev/null
    fi

    # Fast non-blocking lock probe prior to invoking inhibitor subprocess.
    # Fast-fails immediately if another instance is already running without spawning redundant inhibitor leases.
    if [ "${INHIBITED:-0}" -ne 1 ]; then
        exec 201<>"$LOCK_FILE"
        if ! flock -n 201; then
            exec 201>&- || true
            local blocker=""
            if [ -s "$LOCK_FILE" ]; then
                blocker=$(head -n 1 "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
            fi
            if [ -z "$blocker" ] && command -v fuser &>/dev/null; then
                blocker=$(fuser "$LOCK_FILE" 2>/dev/null | tr ' ' '\n' | grep -v "^$$$" | grep -v "^$" | head -n 1)
            fi
            [ -n "$blocker" ] && blocker=" (PID: ${blocker})"
            log_message "Lock held by another instance${blocker}. Aborting."
            send_notification "normal" "Backup Skipped" "Another backup or restore process is already running${blocker}."
            echo "ERROR: Another backup or restore process is already running${blocker}." >&2
            return 1
        fi
        flock -u 201 2>/dev/null
        exec 201>&- || true
    fi

    if [ "${INHIBITED:-0}" -ne 1 ] && command -v systemd-inhibit &> /dev/null; then
        local sentinel_file
        sentinel_file=$(mktemp /tmp/backup_inhibit.XXXXXX 2>/dev/null)
        export INHIBITED=1
        export INHIBIT_SENTINEL="$sentinel_file"

        systemd-inhibit --who="backup_script" --why="$why_msg" --what="sleep:shutdown:idle" "$SCRIPT_PATH" "$action" "$@"
        local ret=$?
        export INHIBITED=0
        unset INHIBIT_SENTINEL

        # If sentinel still exists, systemd-inhibit failed before invoking the script
        if [ -n "$sentinel_file" ] && [ -f "$sentinel_file" ]; then
            rm -f "$sentinel_file" 2>/dev/null
            log_message "WARNING: systemd-inhibit failed to invoke script (exit code ${ret}). Falling back to direct execution."
            echo "WARNING: systemd-inhibit failed to launch (exit code ${ret}). Falling back to direct execution..." >&2
        else
            return $ret
        fi
    fi

    if acquire_lock; then
        local ret=0
        case "$action" in
            backup)  run_backup "$@" || ret=$? ;;
            restore) run_restore "$@" || ret=$? ;;
            verify)  run_verify "$@" || ret=$? ;;
            list-files|view-archive|list-contents) list_archive_contents "$@" || ret=$? ;;
            manage-preserved|clean-preserved) manage_preserved_archives "$@" || ret=$? ;;
            *)       echo "Unknown action: $action" >&2; ret=1 ;;
        esac
        release_lock
        return $ret
    fi
    return 1
}

#---
#   FUNCTION:  install_systemd_timer()
#  DESCRIPTION:  Installs and enables a systemd --user service and timer for
#                automated scheduled backups (default: daily at 00:45:00).
#---
install_systemd_timer() {
    if ! command -v systemctl &>/dev/null; then
        echo "ERROR: 'systemctl' command not found. systemd is required for timer management." >&2
        return 1
    fi

    local schedule="${1:-}"
    if [ -z "$schedule" ]; then
        if [ -t 0 ]; then
            echo
            echo "==============================================================================="
            echo "  Install Systemd Backup Timer"
            echo "==============================================================================="
            echo "  This will configure a systemd --user timer to run automatic encrypted backups."
            echo "  Default schedule: daily at 00:45:00 (with randomized 15-minute delay buffer)."
            echo "  (Format: standard systemd calendar event, e.g. 'daily', '*-*-* 03:00:00', or 'weekly')"
            echo "==============================================================================="
            read -r -p "Enter backup schedule [default: *-*-* 00:45:00]: " schedule
        fi
        schedule="${schedule:-*-*-* 00:45:00}"
    fi

    local user_unit_dir="${HOME}/.config/systemd/user"
    mkdir -p "$user_unit_dir"

    local service_path="${user_unit_dir}/backup-home.service"
    local timer_path="${user_unit_dir}/backup-home.timer"

    echo "Writing service unit to ${service_path}..."
    cat <<EOF > "$service_path"
[Unit]
Description=Automated Encrypted Home Directory Backup
Documentation=file://${SCRIPT_PATH}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} backup
TimeoutStartSec=0
Environment="PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin"
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

    echo "Writing timer unit to ${timer_path}..."
    cat <<EOF > "$timer_path"
[Unit]
Description=Run automated home directory backup on schedule
Documentation=file://${SCRIPT_PATH}

[Timer]
OnCalendar=${schedule}
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

    # Prevent systemd from triggering an immediate catch-up backup upon installation
    local stamp_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/systemd/timers"
    local stamp_file="${stamp_dir}/stamp-backup-home.timer"
    mkdir -p "$stamp_dir"
    touch "$stamp_file"

    echo "Reloading systemd user daemon and enabling backup-home.timer..."
    systemctl --user daemon-reload
    if systemctl --user enable --now backup-home.timer; then
        echo
        echo "SUCCESS: backup-home.timer is now installed, enabled, and active!"
        echo "Timer schedule: ${schedule}"
        echo
        systemctl --user list-timers backup-home.timer --no-pager 2>/dev/null || true
        log_message "Systemd user timer backup-home.timer installed with schedule '${schedule}'."

        local linger_status
        linger_status=$(loginctl show-user "${CURRENT_USER}" --property=Linger 2>/dev/null || echo "")
        if [[ "$linger_status" == *"Linger=no"* ]]; then
            echo
            echo "Note: User lingering is currently disabled for ${CURRENT_USER}."
            echo "      To allow backups to run while logged out, consider running:"
            echo "        loginctl enable-linger ${CURRENT_USER}"
        fi
        return 0
    else
        echo "ERROR: Failed to enable backup-home.timer with systemctl --user." >&2
        return 1
    fi
}

#---
#   FUNCTION:  status_systemd_timer()
#  DESCRIPTION:  Displays the status and next run time of the systemd backup timer.
#---
status_systemd_timer() {
    if ! command -v systemctl &>/dev/null; then
        echo "ERROR: 'systemctl' command not found. systemd is required." >&2
        return 1
    fi

    local timer_path="${HOME}/.config/systemd/user/backup-home.timer"
    if [ ! -f "$timer_path" ]; then
        echo "Systemd backup timer is not installed."
        echo "Run '$0 install-timer' to set up automated scheduled backups."
        return 0
    fi

    echo "==============================================================================="
    echo "  Systemd User Backup Timer Status"
    echo "==============================================================================="
    systemctl --user status backup-home.timer --no-pager
    echo
    echo "Next Scheduled Trigger:"
    systemctl --user list-timers backup-home.timer --no-pager
    echo
    echo "Service Status (Last Run):"
    systemctl --user status backup-home.service --no-pager -n 5 2>/dev/null || true
    echo "==============================================================================="
    return 0
}

#---
#   FUNCTION:  journal_systemd_timer()
#  DESCRIPTION:  Displays systemd journal logs for the backup service unit.
#---
journal_systemd_timer() {
    if ! command -v journalctl &>/dev/null; then
        echo "ERROR: 'journalctl' command not found. systemd journal is required." >&2
        return 1
    fi

    local lines="${1:-50}"
    local follow="${2:-false}"

    if [ "$lines" = "-f" ] || [ "$lines" = "--follow" ]; then
        follow=true
        lines=50
    fi

    echo "==============================================================================="
    if [ "$follow" = true ]; then
        echo "  Systemd User Backup Service Journal (Streaming live, Ctrl+C to stop)"
    else
        echo "  Systemd User Backup Service Journal (Last ${lines} lines)"
    fi
    echo "==============================================================================="

    if [ "$follow" = true ]; then
        journalctl --user -u backup-home.service -f
    else
        journalctl --user -u backup-home.service -n "$lines" --no-pager
    fi
    echo "==============================================================================="
    return 0
}

#---
#   FUNCTION:  uninstall_systemd_timer()
#  DESCRIPTION:  Disables and removes the systemd user backup timer and service units.
#---
uninstall_systemd_timer() {
    if ! command -v systemctl &>/dev/null; then
        echo "ERROR: 'systemctl' command not found. systemd is required." >&2
        return 1
    fi

    local user_unit_dir="${HOME}/.config/systemd/user"
    local timer_path="${user_unit_dir}/backup-home.timer"
    local service_path="${user_unit_dir}/backup-home.service"

    if [ ! -f "$timer_path" ] && [ ! -f "$service_path" ]; then
        echo "No systemd backup timer units found in ${user_unit_dir}."
        return 0
    fi

    local force_yes=false
    if [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; then
        force_yes=true
    fi

    if [ "$force_yes" = false ] && [ -t 0 ]; then
        local confirm=""
        read -r -p "Are you sure you want to stop, disable, and remove backup-home.timer? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Uninstall cancelled."
            return 0
        fi
    fi

    echo "Stopping and disabling backup-home.timer..."
    systemctl --user disable --now backup-home.timer 2>/dev/null || true
    rm -f "$timer_path" "$service_path"
    rm -f "${XDG_DATA_HOME:-${HOME}/.local/share}/systemd/timers/stamp-backup-home.timer"
    systemctl --user daemon-reload
    echo "SUCCESS: backup-home.timer and backup-home.service have been removed."
    log_message "Systemd user timer backup-home.timer uninstalled and removed."
    return 0
}

#---
#   FUNCTION:  manage_systemd_timer()
#  DESCRIPTION:  Interactive management menu for systemd backup timer.
#---
manage_systemd_timer() {
    local subcmd="${1:-}"
    case "$subcmd" in
        install|add)
            install_systemd_timer "${2:-}"
            return $?
            ;;
        status|info)
            status_systemd_timer
            return $?
            ;;
        journal|logs|log)
            journal_systemd_timer "${2:-50}" "${3:-false}"
            return $?
            ;;
        uninstall|remove|disable)
            uninstall_systemd_timer
            return $?
            ;;
        run|test)
            echo "Triggering backup-home.service via systemctl --user start..."
            systemctl --user start backup-home.service
            systemctl --user status backup-home.service --no-pager
            return $?
            ;;
    esac

    while true; do
        echo
        echo "==============================================================================="
        echo "  Systemd Backup Timer Management"
        echo "==============================================================================="
        local is_installed=false
        local is_active=false
        if [ -f "${HOME}/.config/systemd/user/backup-home.timer" ]; then
            is_installed=true
            if systemctl --user is-active --quiet backup-home.timer 2>/dev/null; then
                is_active=true
            fi
        fi

        if [ "$is_active" = true ]; then
            echo "  Status: INSTALLED & ACTIVE"
        elif [ "$is_installed" = true ]; then
            echo "  Status: INSTALLED (INACTIVE/STOPPED)"
        else
            echo "  Status: NOT INSTALLED"
        fi
        echo "==============================================================================="
        echo "1) View Timer Status & Next Trigger"
        echo "2) View Service Journal Logs (journalctl)"
        echo "3) Install / Update Timer Schedule"
        echo "4) Trigger Backup Service Now (Run in background)"
        echo "5) Uninstall / Remove Timer"
        echo "6) Return to Main Menu"
        local choice=""
        if ! read -r -p "Please select [1-6, default: 1]: " choice; then
            echo
            return 0
        fi

        case "${choice:-1}" in
            1) status_systemd_timer ;;
            2)
                local j_input=""
                read -r -p "Enter number of log lines to view (or 'f' to follow/stream) [default: 50]: " j_input
                case "$j_input" in
                    [fF]|follow|-f|--follow)
                        journal_systemd_timer 50 true
                        ;;
                    "")
                        journal_systemd_timer 50 false
                        ;;
                    *[!0-9]*)
                        echo "Invalid number of lines. Defaulting to 50."
                        journal_systemd_timer 50 false
                        ;;
                    *)
                        journal_systemd_timer "$j_input" false
                        ;;
                esac
                ;;
            3) install_systemd_timer ;;
            4)
                echo "Starting backup-home.service..."
                systemctl --user start backup-home.service
                echo "Backup service triggered. Status:"
                systemctl --user status backup-home.service --no-pager
                ;;
            5) uninstall_systemd_timer ;;
            6) return 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

#---
#   FUNCTION:  init_config()
#  DESCRIPTION:  Generates a template configuration file with all configurable settings.
#                Usage: init_config [path] [--force]
#---
init_config() {
    local target_file=""
    local force=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --force|-f|-y|--yes)
                force=1
                shift
                ;;
            *)
                if [ -z "$target_file" ]; then
                    target_file="$1"
                else
                    echo "WARNING: Unexpected argument '$1' ignored." >&2
                fi
                shift
                ;;
        esac
    done

    target_file="${target_file:-${CONFIG_FILE:-${CONFIG_DIR}/config}}"

    # Expand leading tilde if literal ~ was passed in quotes
    if [[ "$target_file" =~ ^~(/.*)?$ ]]; then
        target_file="${HOME}${BASH_REMATCH[1]}"
    fi

    if [ -f "$target_file" ] && [ "$force" -ne 1 ]; then
        if [ -t 0 ]; then
            echo "Configuration file '${target_file}' already exists."
            local overwrite_choice
            read -r -p "Do you want to overwrite it with the default template? [y/N]: " overwrite_choice
            case "$overwrite_choice" in
                [yY]|[yY][eE][sS])
                    ;;
                *)
                    echo "Aborted: Existing configuration file was not modified."
                    return 0
                    ;;
            esac
        else
            echo "ERROR: Configuration file '${target_file}' already exists. Use --force to overwrite." >&2
            return 1
        fi
    fi

    local target_dir
    target_dir=$(dirname "$target_file")
    if [ ! -d "$target_dir" ]; then
        if ! mkdir -p "$target_dir"; then
            echo "ERROR: Failed to create configuration directory '${target_dir}'." >&2
            return 1
        fi
    fi
    chmod 700 "$target_dir" 2>/dev/null || true

    (
        umask 077
        cat << 'EOF' > "$target_file"
#==============================================================================
# Configuration File for backup_script.sh
# Location: ~/.config/backup_script/config
# Permissions: chmod 600 ~/.config/backup_script/config
#
# This file is sourced as a Bash script by backup_script.sh at startup.
# All settings below represent the default values used if unspecified.
# Uncomment and modify any settings you wish to customize.
#==============================================================================

#------------------------------------------------------------------------------
# 1. Cloud Backup & Remote Storage (rclone)
#------------------------------------------------------------------------------
# The rclone remote and directory path where backup archives will be stored.
# MUST include a trailing slash (e.g., "googledrive:backup/" or "b2:my-bucket/backups/").
# Default: googledrive:backup/
#BACKUP_DIR="googledrive:backup/"

# Chunk size and upload cutoff for cloud transfers (e.g. 64M, 128M, 256M).
# Larger chunks improve transfer throughput for large archives on fast connections.
# Default: 256M
#RCLONE_DRIVE_CHUNK_SIZE="256M"

# Optional bandwidth cap for rclone cloud transfers (e.g. "10M", "5M", "500k").
# Leave empty or commented out for maximum speed.
# Default: "" (unlimited)
#RCLONE_BWLIMIT=""

#------------------------------------------------------------------------------
# 2. Source & Staging Directories
#------------------------------------------------------------------------------
# The local directory to back up and restore.
# Default: "$HOME"
#SOURCE_DIR="$HOME"

# Dedicated scratch directory for staging temporary archives during backup/restore.
# Recommended to remain inside SOURCE_DIR or on a filesystem with ample free space.
# Default: "${SOURCE_DIR}/.backup_scratch"
#SCRATCH_DIR="${SOURCE_DIR}/.backup_scratch"

# Minimum free disk space (in gigabytes) required in SCRATCH_DIR before archiving.
# If free space is below this threshold, the backup aborts early to prevent disk exhaustion.
# Default: 15
#MIN_FREE_SPACE_GB=15

#------------------------------------------------------------------------------
# 3. Encryption & Credentials
#------------------------------------------------------------------------------
# Encryption mode:
#   'symmetric'  - Traditional passphrase-based AES-256 encryption (default).
#   'asymmetric' - GPG public-key encryption. Allows headless/automated backups with
#                  zero secret keys or passphrases on the machine taking backups.
#   'hybrid'     - Encrypts simultaneously with both public key(s) and symmetric passphrase.
# Default: "symmetric"
#ENCRYPTION_MODE="symmetric"

# GPG recipient key ID, fingerprint, or email address for asymmetric/hybrid encryption.
# Example: "rorymobley5@gmail.com" or "3705D97D7F33594119EF5973E6DBD94FCA75E4EF"
#GPG_RECIPIENT=""

# Multiple GPG recipients (array). All recipients will be able to decrypt the archive.
#GPG_RECIPIENTS=("user1@example.com" "user2@example.com")

# Path to the secure file containing your GPG symmetric encryption passphrase (chmod 600).
# Used when ENCRYPTION_MODE is 'symmetric' or 'hybrid'.
# Default: "${CONFIG_DIR}/passphrase" (e.g., ~/.config/backup_script/passphrase)
#PASSWORD_FILE="${CONFIG_DIR}/passphrase"

# Direct passphrase setting (NOT recommended for security; use PASSWORD_FILE instead).
# Priority fallback: ENCRYPTION_PASSWORD -> PASSWORD_FILE -> interactive prompt.
#ENCRYPTION_PASSWORD=""

#------------------------------------------------------------------------------
# 4. Retention Policies
#------------------------------------------------------------------------------
# Retention mode:
#   'count'  - Retains the N most recent backups (default, uses CLOUD_KEEP_COUNT / LOCAL_KEEP_COUNT).
#   'tiered' - Grandfather-Father-Son (GFS) retention based on archive dates (daily, weekly, monthly, yearly).
# Default: "count"
#RETENTION_MODE="count"

# Number of most recent cloud backup archives to retain on the rclone remote (for 'count' mode).
# Older archives matching the naming pattern will be pruned after successful upload.
# Default: 10
#CLOUD_KEEP_COUNT=10

# Number of most recent local backup archives to retain on the external backup drive (for 'count' mode).
# Older archives will be pruned automatically.
# Default: 10
#LOCAL_KEEP_COUNT=10

# Tiered / GFS Retention Limits (active when RETENTION_MODE is 'tiered' or 'gfs')
# Keep the newest backup for each distinct day, week, month, and year.
# Default: daily=7, weekly=4, monthly=6, yearly=1
#RETENTION_DAILY=7
#RETENTION_WEEKLY=4
#RETENTION_MONTHLY=6
#RETENTION_YEARLY=1
# Optional floor: always preserve the N newest backups regardless of buckets (0 = disabled)
#RETENTION_MIN_KEEP=0

#------------------------------------------------------------------------------
# 5. Local Drive Backup Settings
#------------------------------------------------------------------------------
# Filesystem UUID of the external drive partition to use for local backup mirroring.
# You can find your drive UUID using 'lsblk -f' or 'blkid'.
# Default: bc3968af-d154-4167-b73c-5a172d2a25b8
#LOCAL_DRIVE_UUID="bc3968af-d154-4167-b73c-5a172d2a25b8"

# Subdirectory on the mounted local drive partition where backup archives are stored.
# Default: Backups
#LOCAL_BACKUP_SUBDIR="Backups"

# Mirror backup_script.sh and write a disaster recovery cheatsheet (RESTORE_README.txt)
# to the local backup drive directory alongside backup archives.
# Default: true
#MIRROR_SCRIPT_TO_LOCAL="true"

# Mirror backup_script.sh and write a disaster recovery cheatsheet (RESTORE_README.txt)
# to cloud storage directory alongside backup archives.
# Default: true
#MIRROR_SCRIPT_TO_CLOUD="true"

#------------------------------------------------------------------------------
# 6. Archive Naming & Identity
#------------------------------------------------------------------------------
# Override the username used in backup archive file naming.
# Default: current logged-in user ($USER or id -un)
#CURRENT_USER="rory"

# Override the full archive basename prefix.
# Default: "${CURRENT_USER}_home_backup_${HOSTNAME}"
#TARBALL_BASENAME="${CURRENT_USER}_home_backup_${HOSTNAME}"

#------------------------------------------------------------------------------
# 7. Metadata Dump Files (Saved in $SOURCE_DIR before archiving)
#------------------------------------------------------------------------------
# Filename for exported user crontab backup.
# Default: crontab_backup.txt
#CRONTAB_BACKUP_FILE="crontab_backup.txt"

# Filename for exported pipx packages specification.
# Default: pipx-spec.json
#PIPX_SPEC_FILE="pipx-spec.json"

# Filename for exported Flatpak remotes configuration.
# Default: flatpak_remotes.txt
#FLATPAK_REMOTES_FILE="flatpak_remotes.txt"

# Filename for exported Flatpak packages list.
# Default: flatpak_packages.txt
#FLATPAK_PACKAGES_FILE="flatpak_packages.txt"

# Filename for exported active/enabled systemd user units list.
# Default: systemd_user_enabled_units.txt
#SYSTEMD_USER_UNITS_FILE="systemd_user_enabled_units.txt"

# Filename for exported desktop (dconf) settings.
# Default: dconf_settings.ini
#DCONF_SETTINGS_FILE="dconf_settings.ini"

# Filename for exported manually installed APT packages list.
# Default: apt_packages_manual.txt
#APT_PACKAGES_FILE="apt_packages_manual.txt"

# Filename for exported APT repository sources and signing keyrings archive.
# Default: apt_repos_keys.tar.gz
#APT_REPOS_FILE="apt_repos_keys.tar.gz"

# Filename for exported user-installed DNF packages list.
# Default: dnf_packages_userinstalled.txt
#DNF_PACKAGES_FILE="dnf_packages_userinstalled.txt"

# Filename for exported DNF repository sources and RPM GPG keys archive.
# Default: dnf_repos_keys.tar.gz
#DNF_REPOS_FILE="dnf_repos_keys.tar.gz"

#------------------------------------------------------------------------------
# 8. Logging, Locking & Error Recovery
#------------------------------------------------------------------------------
# Path to the backup execution log file.
# Default: "${SOURCE_DIR}/backup_${CURRENT_USER}.log"
#LOG_FILE="${SOURCE_DIR}/backup_${CURRENT_USER}.log"

# Path to the concurrency lockfile preventing overlapping runs.
# Default: /run/user/<UID>/backup_${CURRENT_USER}.lock (fallback: /tmp/backup_${CURRENT_USER}.lock)
#LOCK_FILE="/run/user/1000/backup_${CURRENT_USER}.lock"

# Preserve the local encrypted archive in $SOURCE_DIR if cloud upload fails.
# Note: If both cloud remote and local drive are unavailable/fail, the archive is
# always automatically preserved in $SOURCE_DIR to prevent data loss.
# When true, you can later retry uploading via the 'manage-preserved' command.
# Default: false
#PRESERVE_ARCHIVE="false"

# Automatically verify archive integrity immediately following a successful backup.
# When enabled, tests archive structure or checksum sidecar without extracting files to disk.
# Valid values:
#   "local"           - Full decryption stream and tar integrity test against local copy (default)
#   "cloud"           - Full decryption stream and tar integrity test against cloud copy
#   "checksum"        - Fast SHA-256 sidecar checksum verification (detects bit-rot in ~10s)
#   "checksum-local"  - Fast SHA-256 sidecar checksum verification forced against local copy
#   "checksum-cloud"  - Fast SHA-256 sidecar checksum verification forced against cloud copy
#   "false"           - Disable automatic post-backup verification
# Can also be triggered per-run via 'backup --verify [auto|local|cloud]' or 'backup --verify-checksum'.
# Default: local
#AUTO_VERIFY_BACKUP="local"

# Generate lightweight companion JSON manifest (.manifest.json) alongside archive and checksum.
# Allows instantaneous inspection of archive inventory, metadata, system configurations, and sizes
# without downloading or decrypting multi-gigabyte archives.
# Default: true
#GENERATE_MANIFEST="true"

#------------------------------------------------------------------------------
# 9. Compression
#------------------------------------------------------------------------------
# Zstandard (zstd) compression level (1 to 19, or up to 22 with ultra).
# Levels > 19 automatically enable zstd --ultra.
# Level 6 offers an optimal balance of compression speed and ratio.
# Default: 6
#ZSTD_LEVEL=6

# Zstandard Long Distance Matching (LDM) window log (e.g. 27 for 128MB window).
# Significantly improves compression ratio across large repetitive files and repositories.
# Set to an integer window log (10-31), true (uses default 27), or false to disable.
# Default: 27
#ZSTD_LONG=27

# Zstandard decompression memory limit (e.g. 512MB, 1024MB, 2048MB).
# Automatically scaled if ZSTD_LONG requires more buffer memory.
# Default: 512MB
#ZSTD_DECOMPRESS_MEMORY="512MB"

#------------------------------------------------------------------------------
# 10. Archiving & Filesystem Traversal Options
#------------------------------------------------------------------------------
# Confine tar archive creation to a single filesystem (--one-file-system).
# When true, prevents traversing into other mounted filesystems, external drives, or remote mounts.
# Set to false if your home directory contains multiple partitions or Btrfs subvolumes that should be backed up.
# Default: true
#TAR_ONE_FILE_SYSTEM="true"

# Continue archiving without fatal aborts if unreadable files or directories are encountered (--ignore-failed-read).
# Default: true
#TAR_IGNORE_FAILED_READ="true"

#------------------------------------------------------------------------------
# 11. Restore & Streaming Options
#------------------------------------------------------------------------------
# Stream cloud archives directly during restore using 'rclone cat' without
# downloading the entire archive to local scratch space.
# Options:
#   "auto"  - Automatically stage if scratch space is sufficient (fast, resumable, verified on disk);
#             fall back to direct stream with single-pass inline SHA-256 check if low space (default)
#   "true"  - Always stream directly from cloud via rclone cat (with single-pass inline SHA-256 validation)
#   "false" - Always download to local scratch directory first before extracting
# Default: auto
#STREAM_CLOUD_RESTORE="auto"

# Verify SHA-256 sidecar checksum prior to restoring archive.
# Valid values:
#   "true" (or 1, local) - Verify sidecar checksum for local and staged archives (default)
#   "cloud" (or all)     - Verify sidecar checksum for all archives (including streamed cloud)
#   "false" (or 0)       - Disable automatic pre-restore checksum validation
# Can also be overridden per-run via 'restore --verify-checksum' (-vc) or '--no-verify-checksum'.
# Default: true
#RESTORE_VERIFY_CHECKSUM="true"

# Preferred pager command for viewing archive file listings in interactive terminals.
# Set to an empty string ("") to disable pagination by default.
# Default: "${PAGER:-less -FRX}"
#ARCHIVE_LIST_PAGER="less -FRX"

#------------------------------------------------------------------------------
# 12. Exclusion Patterns
#------------------------------------------------------------------------------
# Path to an external file containing exclude patterns, one per line.
# Blank lines and lines starting with '#' are ignored.
# Default: "${CONFIG_DIR}/excludes" (e.g., ~/.config/backup_script/excludes)
#EXCLUDES_FILE="${CONFIG_DIR}/excludes"

# Additional exclude patterns to append to the default exclusions.
# Syntax: Bash array of relative paths or wildcard patterns.
# Example:
#ADDITIONAL_EXCLUDES=(
#    "./VirtualBox VMs"
#    "./Android/Sdk"
#    "*.iso"
#)

# Full override of all exclude patterns (replaces DEFAULT_EXCLUDE_PATTERNS entirely).
# Uncomment ONLY if you wish to bypass the script's built-in exclusion defaults.
#EXCLUDE_PATTERNS=(
#    "./.backup_scratch"
#    "./tmp"
#    "./cache"
#    "./.cache"
#    "./Downloads"
#    "./external_drive"
#    "./sensitive"
#    "./googledrive"
#    "./.config/google-chrome"
#    "./.config/chromium"
#    "./.config/vivaldi-snapshot"
#    "./.mozilla"
#    # Browser transient state, internal caches, and IPC/process locks (Vivaldi & Chromium)
#    "SingletonLock"
#    "*/SingletonLock"
#    "SingletonCookie"
#    "*/SingletonCookie"
#    "SingletonSocket"
#    "*/SingletonSocket"
#    "Crashpad"
#    "*/Crashpad"
#    "GPUCache"
#    "*/GPUCache"
#    "Code Cache"
#    "*/Code Cache"
#    "*/Service Worker/CacheStorage"
#    "*/Service Worker/ScriptCache"
#    "./.var/app/*/cache"
#    "./.local/share/Trash"
#    "./.local/share/flatpak/app"
#    "./.local/share/flatpak/runtime"
#    "./.local/share/flatpak/repo"
#    "./.local/share/flatpak/.changed"
#    "./.var/app/*/data/tmp"
#    "./.local/share/pipx/venvs"
#    "./.cargo/registry"
#    "./.cargo/git"
#    "target"
#    "*/target"
#    "node_modules"
#    "*/node_modules"
#    "./.npm"
#    "./.yarn/cache"
#    "./.pnpm-store"
#    ".next/cache"
#    "*/.next/cache"
#    ".nuxt"
#    "*/.nuxt"
#    ".turbo"
#    "*/.turbo"
#    "__pycache__"
#    "*.pyc"
#    ".venv"
#    "*/.venv"
#    ".pytest_cache"
#    "*/.pytest_cache"
#    ".mypy_cache"
#    "*/.mypy_cache"
#    ".ruff_cache"
#    "*/.ruff_cache"
#    ".tox"
#    "./.gradle/caches"
#    "./.gradle/wrapper"
#    "./.m2/repository"
#    "./go/pkg/mod"
#    "./.ccache"
#    "CMakeFiles"
#    "*/CMakeFiles"
#    "CMakeCache.txt"
#    "./linsw"
#    "./Videos"
#    # Games, containers, and virtual machines
#    "./.local/share/Steam"
#    "./.steam"
#    "./.local/share/containers"
#    "./.rustup"
#    "./.local/share/gnome-boxes/images"
#    "./VirtualBox VMs"
#    "*.qcow2"
#    "*.vdi"
#    "*.vmdk"
#    "*.raw"
#    # Temporary files and external trash
#    "*.tmp"
#    "*.log"
#    "*.bak"
#    "*/.Trash-*"
#    "./.Trash-*"
#    # Exclude the backup files themselves
#    "./${TARBALL_BASENAME}_*.tar.*"
#    "./${TARBALL_BASENAME}_*.tar.*.gpg"
#    "./${TARBALL_BASENAME}_*.sha256"
#    "./${TARBALL_BASENAME}_*.manifest.json"
#)

#------------------------------------------------------------------------------
# 12. Pre-Backup & Post-Backup Lifecycle Hooks
#------------------------------------------------------------------------------
# Shell commands or scripts to execute before and after backup operations.
# You can define inline shell commands here, or place executable scripts at:
#   ~/.config/backup_script/pre-backup.sh
#   ~/.config/backup_script/post-backup.sh
#
# Contextual environment variables automatically exported to hook processes:
#   BACKUP_HOOK_TYPE          - "pre" or "post"
#   BACKUP_SOURCE_DIR         - Path to the source directory being backed up ($HOME)
#   BACKUP_DEST_DIR           - Remote or local destination path ($BACKUP_DIR)
#   BACKUP_CONFIG_DIR         - Configuration directory (~/.config/backup_script)
#   BACKUP_SCRATCH_DIR        - Staging scratch directory
#   BACKUP_ARCHIVE_NAME       - Archive filename (e.g., backup_rory_2026-09-17_085500.tar.zst.gpg)
#   BACKUP_ARCHIVE_SIZE       - Human-readable archive size (e.g., 7.8G)
#   BACKUP_DURATION_SECONDS   - Total run elapsed duration in seconds
#   BACKUP_STATUS             - "success", "warning", or "failure"
#   BACKUP_VERIFY_STATUS      - "Verified OK", "Checksum OK", "FAILED", or "Skipped"
#   BACKUP_CLOUD_STATUS       - Cloud upload status ("Success", "Failed", "Skipped")
#   BACKUP_LOCAL_STATUS       - Local drive status ("Success", "Failed", "Skipped")
#   BACKUP_LOG_FILE           - Path to current run log file
#
# Note: If a pre-backup hook exits with a non-zero status code, the backup is safely
# aborted before any archiving, process termination, or staging occurs.
# Default: ""
#PRE_BACKUP_COMMAND=""
#POST_BACKUP_COMMAND=""

#------------------------------------------------------------------------------
# 14. Application & Database Consistency Guard
#------------------------------------------------------------------------------
# Action to take when applications with active databases (browsers, email clients)
# are running during pre-flight backup checks.
# Options:
#   'close'   - Gracefully terminate target applications (SIGTERM) and wait for settlement. (default)
#   'prompt'  - In interactive terminals, prompt whether to close apps, sync & proceed, or abort.
#               In non-interactive runs (cron, systemd timer), falls back to 'sync'.
#   'sync'    - Leave applications running; log detected apps and flush OS/disk write buffers.
#   'ignore'  - Skip application checks and buffer flushing entirely.
# Default: close
#RUNNING_APPS_ACTION="close"

# Process names to check for open database activity before archiving.
# Default: ("chrome" "chromium" "google-chrome" "firefox" "firefox-bin" "vivaldi" "vivaldi-bin" "brave" "opera" "thunderbird")
#TARGET_RUNNING_APPS=("chrome" "chromium" "google-chrome" "firefox" "firefox-bin" "vivaldi" "vivaldi-bin" "brave" "opera" "thunderbird")

# Seconds to wait for applications to exit and flush state after SIGTERM (when action is 'close').
# Default: 10
#RUNNING_APPS_SETTLE_TIMEOUT=10

#------------------------------------------------------------------------------
# 15. Email Alerts on Backup Failure
#------------------------------------------------------------------------------
# Recipient email address to notify if backup operations encounter fatal errors
# or post-backup verification failure.
# Leave empty or commented out to disable email notifications.
# Example: ALERT_EMAIL="alert@domain.com"
# Default: ""
#ALERT_EMAIL=""

# Sender email address for outgoing failure alert emails.
# If unset, automatically detects sender from msmtp account configuration (e.g. /etc/msmtprc)
# or falls back to user@host. Note: Authenticated SMTP relays (Vivaldi, Gmail, etc.)
# require From to match the authenticated account to prevent '550 forged sender' rejection.
# Example: ALERT_FROM="user@domain.com"
# Default: "" (auto-detect)
#ALERT_FROM=""

# Mail delivery agent command ('auto', 'msmtp', 'mailx', 'mail', or custom path).
# Default: auto (automatically detects msmtp, mailx, mail)
#MAIL_COMMAND="auto"

#------------------------------------------------------------------------------
# 16. Per-Directory Exclusion Tags & Ignore Files
#------------------------------------------------------------------------------
# Enable or disable per-directory tag-based folder exclusion.
# When enabled, placing a tag file (e.g. .nobackup) in any directory causes GNU tar
# to completely skip that directory and all its contents (--exclude-tag-all).
# Note: Placing an exclusion tag in the root of SOURCE_DIR (~/) is blocked by the script
# to prevent creating an empty archive.
# Default: true
#ENABLE_EXCLUDE_TAGS="true"

# Tag filenames that cause their containing directory to be excluded entirely.
# Default: (".nobackup")
#EXCLUDE_TAG_FILES=(".nobackup")

# Enable or disable per-directory recursive ignore pattern files (.gitignore syntax).
# When enabled, any directory containing an ignore file (e.g. .backupignore)
# will have its patterns recursively applied to that directory tree (--exclude-ignore-recursive).
# Default: true
#ENABLE_EXCLUDE_IGNORE="true"

# Filenames that contain recursive ignore patterns.
# Default: (".backupignore")
#EXCLUDE_IGNORE_FILES=(".backupignore")
EOF
    ) || {
        echo "ERROR: Failed to write configuration file '${target_file}'." >&2
        return 1
    }

    chmod 600 "$target_file" 2>/dev/null || true

    echo "Successfully generated configuration file:"
    echo "  ${target_file} (permissions: $(stat -c "%a" "$target_file" 2>/dev/null || echo "600"))"
    echo
    echo "You can edit this file to customize backup locations, retention, compression, and exclusions."
    if [ ! -f "${PASSWORD_FILE}" ]; then
        echo
        echo "Tip: To configure an encryption passphrase without interactive prompts:"
        echo "  echo -n \"YourSecretPassphrase\" > \"${PASSWORD_FILE}\""
        echo "  chmod 600 \"${PASSWORD_FILE}\""
        echo
        echo "Tip: Or to use zero-knowledge/passphrase-less asymmetric backups via GPG public key:"
        echo "  Set ENCRYPTION_MODE=\"asymmetric\" and GPG_RECIPIENT=\"your-key-or-email\" in ${target_file}"
    fi
}

#---
#   FUNCTION:  check_config()
#  DESCRIPTION:  Validates configuration files, file permissions, security settings,
#                filesystem paths, disk space, remote/local destinations, tools, and timer status.
#                Usage: check_config [options]
#                Options:
#                  --fix, -f      Automatically correct file and directory permissions
#                  --quiet, -q    Only display warnings and failures
#                  --help, -h     Show check-config help
#---
check_config() {
    local opt_fix=false
    local opt_quiet=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --fix|-f)
                opt_fix=true
                shift
                ;;
            --quiet|-q)
                opt_quiet=true
                shift
                ;;
            help|-h|--help)
                echo "Usage: $0 check-config [options]"
                echo
                echo "Validate configuration files, file permissions, security settings,"
                echo "filesystem paths, backup destinations, dependencies, and timer state."
                echo
                echo "Options:"
                echo "  --fix, -f       Automatically fix insecure directory and file permissions"
                echo "  --quiet, -q     Suppress passing checks, displaying only warnings and errors"
                echo "  --help, -h      Display this help message"
                return 0
                ;;
            *)
                echo "WARNING: Unknown argument '$1' ignored." >&2
                shift
                ;;
        esac
    done

    local c_reset="" c_bold="" c_green="" c_yellow="" c_red="" c_blue="" c_cyan=""
    if [ -t 1 ]; then
        c_reset="\033[0m"
        c_bold="\033[1m"
        c_green="\033[0;32m"
        c_yellow="\033[1;33m"
        c_red="\033[0;31m"
        c_blue="\033[0;34m"
        c_cyan="\033[0;36m"
    fi

    local tag_ok="[  ${c_green}OK${c_reset}  ]"
    local tag_warn="[ ${c_yellow}WARN${c_reset} ]"
    local tag_fail="[ ${c_red}FAIL${c_reset} ]"
    local tag_info="[ ${c_cyan}INFO${c_reset} ]"

    local total_checks=0
    local pass_count=0
    local warn_count=0
    local fail_count=0

    report_ok() {
        local category="$1"
        local message="$2"
        total_checks=$((total_checks + 1))
        pass_count=$((pass_count + 1))
        if [ "$opt_quiet" = false ]; then
            printf " %b  %-28s %s\n" "$tag_ok" "$category" "$message"
        fi
    }

    report_warn() {
        local category="$1"
        local message="$2"
        total_checks=$((total_checks + 1))
        warn_count=$((warn_count + 1))
        printf " %b  %-28s %s\n" "$tag_warn" "$category" "$message"
    }

    report_fail() {
        local category="$1"
        local message="$2"
        total_checks=$((total_checks + 1))
        fail_count=$((fail_count + 1))
        printf " %b  %-28s %s\n" "$tag_fail" "$category" "$message"
    }

    report_info() {
        local category="$1"
        local message="$2"
        if [ "$opt_quiet" = false ]; then
            printf " %b  %-28s %s\n" "$tag_info" "$category" "$message"
        fi
    }

    print_section() {
        if [ "$opt_quiet" = false ]; then
            printf "\n%b%s%b\n" "${c_bold}${c_blue}" "$1" "$c_reset"
        fi
    }

    echo -e "\n==============================================================================="
    echo "  Backup Configuration & Environment Check"
    echo "==============================================================================="
    if [ "$opt_fix" = true ]; then
        echo "  Mode: Auto-fix enabled (--fix)"
    fi

    # 1. Configuration & Exclusion Files
    print_section "Configuration & Excludes:"
    if [ -d "$CONFIG_DIR" ]; then
        local dir_perms
        dir_perms=$(stat -c "%a" "$CONFIG_DIR" 2>/dev/null)
        if [ "$dir_perms" = "700" ]; then
            report_ok "Config Directory" "${CONFIG_DIR} (permissions: 700)"
        else
            if [ "$opt_fix" = true ]; then
                chmod 700 "$CONFIG_DIR" 2>/dev/null
                report_ok "Config Directory" "Corrected permissions on ${CONFIG_DIR} from ${dir_perms} to 700"
            else
                report_warn "Config Directory" "${CONFIG_DIR} has permissions ${dir_perms} (expected 700; run with --fix)"
            fi
        fi
    else
        report_info "Config Directory" "${CONFIG_DIR} not found (default settings active; run 'init-config' to create)"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        local file_perms
        file_perms=$(stat -c "%a" "$CONFIG_FILE" 2>/dev/null)
        if [ "$file_perms" = "600" ] || [ "$file_perms" = "400" ]; then
            report_ok "Config File Perms" "${CONFIG_FILE} (permissions: ${file_perms})"
        else
            if [ "$opt_fix" = true ]; then
                chmod 600 "$CONFIG_FILE" 2>/dev/null
                report_ok "Config File Perms" "Corrected permissions on ${CONFIG_FILE} from ${file_perms} to 600"
            else
                report_warn "Config File Perms" "${CONFIG_FILE} has permissions ${file_perms} (expected 600; run with --fix)"
            fi
        fi
        local syntax_err
        if syntax_err=$(bash -n "$CONFIG_FILE" 2>&1); then
            report_ok "Config Syntax" "Syntax validation passed for ${CONFIG_FILE}"
        else
            report_fail "Config Syntax" "Syntax error in ${CONFIG_FILE}: $(echo "$syntax_err" | head -n 1)"
        fi
    else
        report_info "Config File" "${CONFIG_FILE} not found (built-in defaults active; run 'init-config' to create)"
    fi

    local excludes_target="${EXCLUDES_FILE:-${CONFIG_DIR}/excludes}"
    if [ -f "$excludes_target" ]; then
        local rule_count
        rule_count=$(grep -v -c -E '^[[:space:]]*(#|$)' "$excludes_target" 2>/dev/null || true)
        rule_count="${rule_count:-0}"
        report_ok "Excludes File" "${excludes_target} found (${rule_count} active rule(s))"
    elif [ "$excludes_target" != "${CONFIG_DIR}/excludes" ]; then
        report_warn "Excludes File" "Custom EXCLUDES_FILE not found: ${excludes_target}"
    else
        report_info "Excludes File" "No custom excludes file (${excludes_target}); built-in exclusions active (${#EXCLUDE_PATTERNS[@]} patterns)"
    fi

    # Per-Directory Exclusion Tags & Ignore Files
    if [ "$ENABLE_EXCLUDE_TAGS" = true ] || [ "$ENABLE_EXCLUDE_TAGS" = "1" ]; then
        local tag_list="${EXCLUDE_TAG_FILES[*]}"
        report_ok "Exclude Tags (.nobackup)" "Enabled (tag files: ${tag_list:-none})"
        
        # Check for hazardous root-level tag
        local root_tag_found=false
        for _tag in "${EXCLUDE_TAG_FILES[@]}"; do
            if [ -n "$_tag" ] && [ -e "${SOURCE_DIR}/${_tag}" ]; then
                report_fail "Root Exclusion Tag" "${SOURCE_DIR}/${_tag} exists! This causes GNU tar to exclude all files and produce an empty archive."
                root_tag_found=true
            fi
        done
        if [ "$root_tag_found" = false ]; then
            report_ok "Root Exclusion Tag" "Safe (no exclusion tag in root of ${SOURCE_DIR})"
        fi
    else
        report_info "Exclude Tags (.nobackup)" "Disabled (ENABLE_EXCLUDE_TAGS=false)"
    fi

    if [ "$ENABLE_EXCLUDE_IGNORE" = true ] || [ "$ENABLE_EXCLUDE_IGNORE" = "1" ]; then
        local ignore_list="${EXCLUDE_IGNORE_FILES[*]}"
        report_ok "Exclude Ignore Rules" "Enabled (recursive files: ${ignore_list:-none})"
    else
        report_info "Exclude Ignore Rules" "Disabled (ENABLE_EXCLUDE_IGNORE=false)"
    fi

    # Lifecycle Hooks
    local pre_hook_script="${HOOKS_DIR}/pre-backup.sh"
    local post_hook_script="${HOOKS_DIR}/post-backup.sh"
    local has_any_hook=false

    if [ -f "$pre_hook_script" ]; then
        has_any_hook=true
        local pre_perms
        pre_perms=$(stat -c "%a" "$pre_hook_script" 2>/dev/null)
        if [ -x "$pre_hook_script" ]; then
            report_ok "Pre-Backup Script" "${pre_hook_script} (executable, permissions: ${pre_perms})"
        else
            if [ "$opt_fix" = true ]; then
                chmod +x "$pre_hook_script" 2>/dev/null
                report_ok "Pre-Backup Script" "Corrected permissions on ${pre_hook_script} to executable (--fix)"
            else
                report_warn "Pre-Backup Script" "${pre_hook_script} exists but is not executable (run 'chmod +x' or use --fix)"
            fi
        fi
        local pre_syntax
        if pre_syntax=$(bash -n "$pre_hook_script" 2>&1); then
            report_ok "Pre-Backup Syntax" "Syntax validation passed for ${pre_hook_script}"
        else
            report_fail "Pre-Backup Syntax" "Syntax error in ${pre_hook_script}: $(echo "$pre_syntax" | head -n 1)"
        fi
    fi

    if [ -n "${PRE_BACKUP_COMMAND:-}" ]; then
        has_any_hook=true
        report_ok "Pre-Backup Command" "Configured: ${PRE_BACKUP_COMMAND}"
    fi

    if [ -f "$post_hook_script" ]; then
        has_any_hook=true
        local post_perms
        post_perms=$(stat -c "%a" "$post_hook_script" 2>/dev/null)
        if [ -x "$post_hook_script" ]; then
            report_ok "Post-Backup Script" "${post_hook_script} (executable, permissions: ${post_perms})"
        else
            if [ "$opt_fix" = true ]; then
                chmod +x "$post_hook_script" 2>/dev/null
                report_ok "Post-Backup Script" "Corrected permissions on ${post_hook_script} to executable (--fix)"
            else
                report_warn "Post-Backup Script" "${post_hook_script} exists but is not executable (run 'chmod +x' or use --fix)"
            fi
        fi
        local post_syntax
        if post_syntax=$(bash -n "$post_hook_script" 2>&1); then
            report_ok "Post-Backup Syntax" "Syntax validation passed for ${post_hook_script}"
        else
            report_fail "Post-Backup Syntax" "Syntax error in ${post_hook_script}: $(echo "$post_syntax" | head -n 1)"
        fi
    fi

    if [ -n "${POST_BACKUP_COMMAND:-}" ]; then
        has_any_hook=true
        report_ok "Post-Backup Command" "Configured: ${POST_BACKUP_COMMAND}"
    fi

    if [ "$has_any_hook" = false ]; then
        report_info "Lifecycle Hooks" "No pre/post backup hooks configured (optional)"
    fi

    # 2. Encryption & Credentials
    print_section "Encryption & Credentials:"
    report_ok "Encryption Mode" "Configured mode: ${ENCRYPTION_MODE:-symmetric}"

    if [ "${ENCRYPTION_MODE}" = "asymmetric" ] || [ "${ENCRYPTION_MODE}" = "hybrid" ]; then
        if [ ${#GPG_RECIPIENTS[@]} -eq 0 ] && [ -z "$GPG_RECIPIENT" ]; then
            report_fail "GPG Recipients" "No recipient keys configured for ${ENCRYPTION_MODE} mode (set GPG_RECIPIENT in config)"
        else
            local recip_list=("${GPG_RECIPIENTS[@]}")
            [ ${#recip_list[@]} -eq 0 ] && read -ra recip_list <<< "$GPG_RECIPIENT"
            report_ok "GPG Recipients" "${#recip_list[@]} recipient(s) configured (${recip_list[*]})"

            for r in "${recip_list[@]}"; do
                if gpg --batch --list-keys "$r" &>/dev/null; then
                    local key_fingerprint
                    key_fingerprint=$(gpg --batch --with-colons --list-keys "$r" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')
                    report_ok "GPG Recipient Key" "Key for '${r}' found in public keyring (${key_fingerprint: -16})"
                    if gpg --batch --list-secret-keys "$r" &>/dev/null; then
                        report_ok "GPG Secret Key" "Secret key for '${r}' available locally (restore/verify capable)"
                    else
                        report_info "GPG Secret Key" "Secret key for '${r}' not in local keyring (encryption-only host, restore requires recovery key)"
                    fi
                else
                    report_fail "GPG Recipient Key" "Key for '${r}' NOT found in public keyring (import with 'gpg --import')"
                fi
            done

            if command -v gpg &>/dev/null && [ ${#recip_list[@]} -gt 0 ]; then
                local probe_args=(--batch --yes --no-tty --trust-model always)
                for r in "${recip_list[@]}"; do
                    probe_args+=(-r "$r")
                done
                if echo "probe_payload" | gpg "${probe_args[@]}" --encrypt &>/dev/null; then
                    report_ok "GPG Pubkey Probe" "Asymmetric encryption pipeline self-test passed"
                else
                    report_fail "GPG Pubkey Probe" "Asymmetric encryption self-test failed"
                fi
            fi
        fi
    fi

    if [ "${ENCRYPTION_MODE}" = "symmetric" ] || [ "${ENCRYPTION_MODE}" = "hybrid" ]; then
        local pass_source=""
        if [ -n "${ENCRYPTION_PASSWORD:-}" ] && [ "$ENCRYPTION_PASSWORD" != "EnterPasswordHere" ]; then
            pass_source="environment variable (ENCRYPTION_PASSWORD)"
        elif [ -n "${BACKUP_ENCRYPTION_PASSWORD:-}" ] && [ "$BACKUP_ENCRYPTION_PASSWORD" != "EnterPasswordHere" ]; then
            pass_source="environment variable (BACKUP_ENCRYPTION_PASSWORD)"
        elif [ -f "$PASSWORD_FILE" ]; then
            pass_source="file (${PASSWORD_FILE})"
        fi

        if [ -n "$pass_source" ]; then
            report_ok "Passphrase Source" "Configured via ${pass_source}"
        else
            if [ "${ENCRYPTION_MODE}" = "symmetric" ]; then
                report_warn "Passphrase Source" "No passphrase configured in environment or ${PASSWORD_FILE}. Automated timer runs will fail (interactive runs prompt)."
            else
                report_info "Passphrase Source" "No passphrase configured (hybrid mode can still restore with secret key)."
            fi
        fi

        if [ -f "$PASSWORD_FILE" ]; then
            local pfile_perms
            pfile_perms=$(stat -c "%a" "$PASSWORD_FILE" 2>/dev/null)
            if [ "$pfile_perms" = "600" ] || [ "$pfile_perms" = "400" ]; then
                report_ok "Password File Perms" "${PASSWORD_FILE} (permissions: ${pfile_perms})"
            else
                if [ "$opt_fix" = true ]; then
                    chmod 600 "$PASSWORD_FILE" 2>/dev/null
                    report_ok "Password File Perms" "Corrected permissions on ${PASSWORD_FILE} from ${pfile_perms} to 600"
                else
                    report_warn "Password File Perms" "${PASSWORD_FILE} has permissions ${pfile_perms} (expected 600; run with --fix)"
                fi
            fi
            local pfile_content
            pfile_content=$(< "$PASSWORD_FILE")
            if [ -z "$pfile_content" ] || [ "$pfile_content" = "EnterPasswordHere" ]; then
                report_fail "Password File Content" "${PASSWORD_FILE} is empty or contains placeholder text"
            else
                report_ok "Password File Content" "${PASSWORD_FILE} contains active passphrase"
            fi
        fi

        # Test GPG cipher execution if gpg is available and password is set or in file
        if command -v gpg &>/dev/null; then
            local test_pass=""
            if [ -n "${ENCRYPTION_PASSWORD:-}" ] && [ "$ENCRYPTION_PASSWORD" != "EnterPasswordHere" ]; then
                test_pass="$ENCRYPTION_PASSWORD"
            elif [ -n "${BACKUP_ENCRYPTION_PASSWORD:-}" ] && [ "$BACKUP_ENCRYPTION_PASSWORD" != "EnterPasswordHere" ]; then
                test_pass="$BACKUP_ENCRYPTION_PASSWORD"
            elif [ -f "$PASSWORD_FILE" ]; then
                test_pass=$(< "$PASSWORD_FILE")
            fi

            if [ -n "$test_pass" ] && [ "$test_pass" != "EnterPasswordHere" ]; then
                local gpg_probe_res
                if gpg_probe_res=$(echo "check_config_test_payload" \
                    | gpg --batch --yes --no-tty --pinentry-mode loopback --symmetric --cipher-algo AES256 --passphrase-fd 3 3<<< "$test_pass" 2>/dev/null \
                    | gpg --batch --yes --no-tty --pinentry-mode loopback --decrypt --passphrase-fd 3 3<<< "$test_pass" 2>/dev/null) \
                    && [ "$gpg_probe_res" = "check_config_test_payload" ]; then
                    report_ok "GPG Symmetric Test" "Symmetric AES-256 loopback encryption & decryption passed"
                else
                    report_fail "GPG Symmetric Test" "Encryption/decryption self-test failed (check GPG installation and loopback pinentry support)"
                fi
            fi
        fi
    fi

    # 3. Filesystem & Storage Paths
    print_section "Filesystem & Storage Paths:"
    if [ -d "$SOURCE_DIR" ]; then
        if [ -r "$SOURCE_DIR" ]; then
            report_ok "Source Directory" "${SOURCE_DIR} exists and is readable"
        else
            report_fail "Source Directory" "${SOURCE_DIR} exists but is not readable (check permissions)"
        fi
    else
        report_fail "Source Directory" "${SOURCE_DIR} does not exist"
    fi

    local scratch_parent
    scratch_parent=$(dirname "$SCRATCH_DIR")
    if [ -d "$SCRATCH_DIR" ]; then
        if [ -w "$SCRATCH_DIR" ]; then
            report_ok "Scratch Directory" "${SCRATCH_DIR} exists and is writable"
        else
            report_fail "Scratch Directory" "${SCRATCH_DIR} exists but is not writable"
        fi
    elif [ -d "$scratch_parent" ] && [ -w "$scratch_parent" ]; then
        report_ok "Scratch Directory" "${SCRATCH_DIR} will be created in writable parent (${scratch_parent})"
    else
        report_fail "Scratch Directory" "Parent directory of ${SCRATCH_DIR} (${scratch_parent}) is not writable"
    fi

    local avail_kb
    avail_kb=$(df -Pk "${SCRATCH_DIR%/*}" 2>/dev/null | awk 'NR==2 {print $4}')
    local min_kb=$((MIN_FREE_SPACE_GB * 1024 * 1024))
    if [ -n "$avail_kb" ] && [ "$avail_kb" -gt 0 ] 2>/dev/null; then
        local avail_hr req_hr
        avail_hr=$(numfmt --to=iec --from-unit=1024 "${avail_kb}" 2>/dev/null || echo "$((avail_kb / 1024 / 1024))G")
        req_hr=$(numfmt --to=iec --from-unit=1024 "${min_kb}" 2>/dev/null || echo "$((min_kb / 1024 / 1024))G")
        if [ "$avail_kb" -ge "$min_kb" ]; then
            report_ok "Scratch Free Space" "${avail_hr} available (minimum required: ${req_hr})"
        else
            report_fail "Scratch Free Space" "${avail_hr} available is less than configured MIN_FREE_SPACE_GB (${req_hr})"
        fi
    else
        report_warn "Scratch Free Space" "Could not determine available disk space for ${SCRATCH_DIR}"
    fi

    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [ -d "$log_dir" ] && [ -w "$log_dir" ]; then
        report_ok "Log File Location" "${LOG_FILE} (parent directory is writable)"
    else
        report_fail "Log File Location" "Parent directory of ${LOG_FILE} (${log_dir}) is not writable"
    fi

    local lock_dir
    lock_dir=$(dirname "$LOCK_FILE")
    if [ -d "$lock_dir" ] && [ -w "$lock_dir" ]; then
        report_ok "Lock File Location" "${LOCK_FILE} (directory is writable)"
    else
        report_fail "Lock File Location" "Parent directory of ${LOCK_FILE} (${lock_dir}) is not writable"
    fi

    # 4. Local Drive Destination
    print_section "Local Drive Destination:"
    local drive_dev=""
    if [ -b "/dev/disk/by-uuid/${LOCAL_DRIVE_UUID}" ]; then
        drive_dev="/dev/disk/by-uuid/${LOCAL_DRIVE_UUID}"
    elif command -v blkid &>/dev/null && blkid -U "${LOCAL_DRIVE_UUID}" &>/dev/null; then
        drive_dev=$(blkid -U "${LOCAL_DRIVE_UUID}" 2>/dev/null)
    fi

    if [ -n "$drive_dev" ]; then
        report_ok "Local Drive Device" "Partition detected at ${drive_dev} (UUID: ${LOCAL_DRIVE_UUID})"
    else
        report_warn "Local Drive Device" "Drive UUID ${LOCAL_DRIVE_UUID} not detected (drive unplugged or UUID changed)"
    fi

    local local_dest
    if local_dest=$(get_local_backup_path 2>/dev/null) && [ -n "$local_dest" ]; then
        report_ok "Local Drive Mount" "Mounted at ${local_dest%/*}"
        if [ -d "$local_dest" ]; then
            if [ -w "$local_dest" ]; then
                local drive_free_kb drive_free_hr
                drive_free_kb=$(df -Pk "$local_dest" 2>/dev/null | awk 'NR==2 {print $4}')
                drive_free_hr=$(numfmt --to=iec --from-unit=1024 "${drive_free_kb}" 2>/dev/null || echo "${drive_free_kb}K")
                report_ok "Local Backup Subdir" "${local_dest} is writable (${drive_free_hr} free)"
            else
                report_fail "Local Backup Subdir" "${local_dest} exists but is not writable"
            fi
        else
            local parent_mount="${local_dest%/*}"
            if [ -w "$parent_mount" ]; then
                report_ok "Local Backup Subdir" "${LOCAL_BACKUP_SUBDIR} will be created in ${parent_mount}"
            else
                report_fail "Local Backup Subdir" "${parent_mount} is mounted read-only or not writable"
            fi
        fi
    else
        if [ -n "$drive_dev" ]; then
            if command -v udisksctl &>/dev/null; then
                report_warn "Local Drive Mount" "Drive partition connected but unmounted (udisksctl available for auto-mount on run)"
            else
                report_warn "Local Drive Mount" "Drive partition connected but unmounted (udisksctl not found for unprivileged mounting)"
            fi
        else
            report_info "Local Drive Mount" "External drive not connected; cloud-only backups will proceed if cloud is reachable"
        fi
    fi

    # 5. Cloud Remote Destination (rclone)
    print_section "Cloud Remote Destination (rclone):"
    if [[ "$BACKUP_DIR" != */ ]]; then
        report_warn "Cloud Path Format" "BACKUP_DIR '${BACKUP_DIR}' is missing a trailing slash (will be appended automatically)"
    else
        report_ok "Cloud Path Format" "BACKUP_DIR '${BACKUP_DIR}' has valid format"
    fi

    if [[ "$BACKUP_DIR" == *:* ]]; then
        if command -v rclone &>/dev/null; then
            local rclone_check_err
            if rclone_check_err=$(rclone lsf --max-depth 1 --contimeout 5s --timeout 8s "${BACKUP_DIR}" 2>&1); then
                report_ok "Cloud Connectivity" "Remote '${BACKUP_DIR}' is reachable and authenticated"
            else
                local clean_err
                clean_err=$(echo "$rclone_check_err" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-80)
                report_fail "Cloud Connectivity" "Failed connecting to '${BACKUP_DIR}': ${clean_err:-timeout or auth error}"
            fi
        else
            report_fail "Cloud Connectivity" "rclone command is not installed"
        fi
    else
        report_info "Cloud Destination" "BACKUP_DIR is a local path (${BACKUP_DIR}), not an rclone remote"
    fi

    report_ok "Rclone Chunk Size" "${RCLONE_DRIVE_CHUNK_SIZE} (upload cutoff: ${RCLONE_DRIVE_CHUNK_SIZE})"
    if [ -n "$RCLONE_BWLIMIT" ]; then
        report_ok "Rclone Bandwidth Limit" "Throttled to ${RCLONE_BWLIMIT}"
    else
        report_info "Rclone Bandwidth Limit" "Unlimited (RCLONE_BWLIMIT not set)"
    fi

    # 6. Compression & Retention Settings
    print_section "Compression & Retention Settings:"
    if [[ "${ZSTD_LEVEL:-6}" =~ ^[0-9]+$ ]] && [ "$ZSTD_LEVEL" -ge 1 ] && [ "$ZSTD_LEVEL" -le 22 ]; then
        if [ "$ZSTD_LEVEL" -gt 19 ]; then
            report_ok "Zstd Level" "Level ${ZSTD_LEVEL} (ultra mode enabled)"
        else
            report_ok "Zstd Level" "Level ${ZSTD_LEVEL}"
        fi
    else
        report_fail "Zstd Level" "Invalid ZSTD_LEVEL '${ZSTD_LEVEL}' (must be integer 1 to 22)"
    fi

    if [ "$ZSTD_LONG" = true ] || [ "$ZSTD_LONG" = "1" ]; then
        report_ok "Zstd Long Matching" "Enabled (window log 27 / 128MB)"
    elif [ "$ZSTD_LONG" = false ] || [ "$ZSTD_LONG" = "0" ]; then
        report_ok "Zstd Long Matching" "Disabled"
    elif [[ "$ZSTD_LONG" =~ ^[0-9]+$ ]] && [ "$ZSTD_LONG" -ge 10 ] && [ "$ZSTD_LONG" -le 31 ]; then
        report_ok "Zstd Long Matching" "Enabled (window log ${ZSTD_LONG})"
    else
        report_fail "Zstd Long Matching" "Invalid ZSTD_LONG '${ZSTD_LONG}' (must be true/false or window log 10-31)"
    fi

    report_ok "Zstd Decompress Memory" "${ZSTD_DECOMPRESS_MEMORY}"

    if [ "$RETENTION_MODE" = "tiered" ] || [ "$RETENTION_MODE" = "gfs" ]; then
        report_ok "Retention Policy" "Tiered GFS (daily=${RETENTION_DAILY:-7}, weekly=${RETENTION_WEEKLY:-4}, monthly=${RETENTION_MONTHLY:-6}, yearly=${RETENTION_YEARLY:-1})"
    else
        report_ok "Retention Policy" "Count-based mode"
        if [[ "${CLOUD_KEEP_COUNT:-10}" =~ ^[0-9]+$ ]] && [ "$CLOUD_KEEP_COUNT" -gt 0 ]; then
            report_ok "Cloud Retention" "Retain ${CLOUD_KEEP_COUNT} newest archives"
        else
            report_fail "Cloud Retention" "Invalid CLOUD_KEEP_COUNT '${CLOUD_KEEP_COUNT}' (must be positive integer)"
        fi

        if [[ "${LOCAL_KEEP_COUNT:-10}" =~ ^[0-9]+$ ]] && [ "$LOCAL_KEEP_COUNT" -gt 0 ]; then
            report_ok "Local Retention" "Retain ${LOCAL_KEEP_COUNT} newest archives"
        else
            report_fail "Local Retention" "Invalid LOCAL_KEEP_COUNT '${LOCAL_KEEP_COUNT}' (must be positive integer)"
        fi
    fi

    # Post-Backup Auto-Verification Mode
    case "$AUTO_VERIFY_BACKUP" in
        checksum|quick)
            report_ok "Auto Verification" "Checksum-only enabled (fast SHA-256 sidecar validation)"
            ;;
        checksum-local)
            report_ok "Auto Verification" "Checksum-only enabled (forced local SHA-256 sidecar validation)"
            ;;
        checksum-cloud)
            report_ok "Auto Verification" "Checksum-only enabled (forced cloud SHA-256 sidecar validation)"
            ;;
        local|true|1)
            report_ok "Auto Verification" "Full decryption stream & tar structure validation (local)"
            ;;
        cloud)
            report_ok "Auto Verification" "Full decryption stream & tar structure validation (cloud)"
            ;;
        false|0|none|"")
            report_info "Auto Verification" "Disabled (post-backup verification skipped)"
            ;;
        *)
            report_warn "Auto Verification" "Unrecognized AUTO_VERIFY_BACKUP setting '${AUTO_VERIFY_BACKUP}'"
            ;;
    esac

    case "${STREAM_CLOUD_RESTORE:-auto}" in
        auto)
            report_ok "Cloud Restore Mode" "Adaptive auto mode (stages when scratch space permits; streams with inline SHA-256 check when constrained)"
            ;;
        true|1|stream)
            report_ok "Cloud Restore Mode" "Direct streaming mode (single-pass rclone cat stream with inline SHA-256 check)"
            ;;
        false|0|stage)
            report_ok "Cloud Restore Mode" "Staged download mode (always stages archive in scratch space before extraction)"
            ;;
        *)
            report_warn "Cloud Restore Mode" "Unrecognized STREAM_CLOUD_RESTORE setting '${STREAM_CLOUD_RESTORE}'"
            ;;
    esac

    # Pre-Restore Checksum Verification Mode
    case "$RESTORE_VERIFY_CHECKSUM" in
        true|1|local|auto)
            report_ok "Restore Checksum" "Enabled (single-pass SHA-256 validation for local, staged, and streamed cloud archives)"
            ;;
        cloud|all)
            report_ok "Restore Checksum" "Enabled (single-pass SHA-256 validation for all archives)"
            ;;
        false|0|none|"")
            report_info "Restore Checksum" "Disabled (pre-restore checksum validation skipped by default)"
            ;;
        *)
            report_warn "Restore Checksum" "Unrecognized RESTORE_VERIFY_CHECKSUM setting '${RESTORE_VERIFY_CHECKSUM}'"
            ;;
    esac

    case "${RUNNING_APPS_ACTION:-close}" in
        prompt|ask)
            report_ok "Apps Consistency" "Interactive prompt mode (non-interactive fallback: sync)"
            ;;
        close|kill|terminate)
            report_ok "Apps Consistency" "Auto-close mode (SIGTERM graceful termination with ${RUNNING_APPS_SETTLE_TIMEOUT:-5}s timeout)"
            ;;
        sync|warn|flush)
            report_ok "Apps Consistency" "Filesystem sync mode (apps remain running; disk buffers flushed)"
            ;;
        ignore|skip|none|false|0)
            report_info "Apps Consistency" "Disabled (running apps detection skipped)"
            ;;
        *)
            report_warn "Apps Consistency" "Unrecognized RUNNING_APPS_ACTION setting '${RUNNING_APPS_ACTION}'"
            ;;
    esac

    # Check which target applications are currently active
    local active_target_apps=()
    local check_apps=("${TARGET_RUNNING_APPS[@]}")
    [ ${#check_apps[@]} -eq 0 ] && check_apps=("${DEFAULT_TARGET_RUNNING_APPS[@]}")
    for a in "${check_apps[@]}"; do
        [ -z "$a" ] && continue
        if pgrep -u "$CURRENT_USER" -x "$a" &>/dev/null; then
            active_target_apps+=("$a")
        fi
    done
    if [ ${#active_target_apps[@]} -gt 0 ]; then
        report_info "Active Applications" "Currently running: ${active_target_apps[*]}"
    else
        report_ok "Active Applications" "No monitored database/browser applications running"
    fi

    # Failure Email Alerting Check
    local alert_recip="${ALERT_EMAIL:-${NOTIFICATION_EMAIL:-}}"
    if [ -n "$alert_recip" ]; then
        if [[ "$alert_recip" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            report_ok "Failure Email Alert" "Configured: ${alert_recip}"
        else
            report_warn "Failure Email Alert" "Unusual email format: ${alert_recip}"
        fi

        local found_mta=""
        for mta in msmtp mailx mail; do
            if command -v "$mta" &>/dev/null; then
                found_mta="$mta ($(command -v "$mta"))"
                break
            fi
        done
        if [ -n "$found_mta" ]; then
            report_ok "Mail Transport" "MTA detected: ${found_mta}"
        else
            report_warn "Mail Transport" "No mail agent found (install msmtp, mailx, or mail)"
        fi

        local alert_sender="${ALERT_FROM:-${NOTIFICATION_FROM:-${MAIL_FROM:-}}}"
        local sender_source="explicit"
        if [ -z "$alert_sender" ] && command -v msmtp &>/dev/null; then
            alert_sender=$(msmtp -P -a default </dev/null 2>/dev/null | awk -F' = ' '$1 == "from" && $2 != "(not set)" {print $2; exit}')
            [ -n "$alert_sender" ] && sender_source="auto-detected from msmtp"
        fi
        if [ -n "$alert_sender" ]; then
            report_ok "Email Sender" "${alert_sender} (${sender_source})"
        else
            report_warn "Email Sender" "${CURRENT_USER}@${HOSTNAME} (unqualified sender; set ALERT_FROM to avoid SMTP 550 rejection)"
        fi
    else
        report_info "Failure Email Alert" "Disabled (ALERT_EMAIL not set; configure to receive error emails)"
    fi

    # 7. Dependencies
    print_section "Tools & Dependencies:"
    local req_tools=("tar" "rclone" "gpg" "pkill" "pgrep" "hostname" "zstd" "findmnt" "flock" "df" "awk" "numfmt" "sha256sum")
    local missing_req=()
    for tool in "${req_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_req+=("$tool")
        fi
    done
    if [ ${#missing_req[@]} -eq 0 ]; then
        report_ok "Required Dependencies" "All core utilities present (${#req_tools[@]} tools verified)"
    else
        report_fail "Required Dependencies" "Missing required utilities: ${missing_req[*]}"
    fi

    if tar --help 2>&1 | grep -q -- '--exclude-tag-all'; then
        report_ok "Tar Capability" "GNU tar supports --exclude-tag-all and --exclude-ignore-recursive"
    else
        report_warn "Tar Capability" "Installed tar does not appear to support --exclude-tag-all (GNU tar recommended)"
    fi

    local opt_tools=("dconf" "flatpak" "pipx" "apt-mark" "dnf" "systemd-inhibit" "notify-send" "udisksctl")
    local present_opt=() missing_opt=()
    for tool in "${opt_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            present_opt+=("$tool")
        else
            missing_opt+=("$tool")
        fi
    done
    if [ ${#missing_opt[@]} -eq 0 ]; then
        report_ok "Optional Helpers" "All optional integrations available (${#opt_tools[@]} tools)"
    else
        report_info "Optional Helpers" "Present: ${present_opt[*]}; not installed: ${missing_opt[*]}"
    fi

    # 8. Systemd User Timer & Service
    print_section "Systemd User Timer & Service:"
    if command -v systemctl &>/dev/null; then
        local timer_installed=false
        if systemctl --user list-unit-files backup-home.timer &>/dev/null; then
            timer_installed=true
        fi

        if [ "$timer_installed" = true ]; then
            local timer_active timer_enabled
            timer_active=$(systemctl --user is-active backup-home.timer 2>/dev/null || echo "inactive")
            timer_enabled=$(systemctl --user is-enabled backup-home.timer 2>/dev/null || echo "disabled")
            if [ "$timer_active" = "active" ] && [ "$timer_enabled" = "enabled" ]; then
                local next_run
                next_run=$(systemctl --user list-timers --no-legend backup-home.timer 2>/dev/null | awk '{print $1, $2, $3, $4}')
                report_ok "Systemd Timer" "Active & enabled (next run: ${next_run:-unknown})"
            else
                report_warn "Systemd Timer" "Installed but currently ${timer_active} / ${timer_enabled}"
            fi
        else
            report_info "Systemd Timer" "Not installed (use 'backup_script.sh install-timer' to enable automated daily backups)"
        fi
    else
        report_info "Systemd Timer" "systemctl command not found (systemd not in use)"
    fi

    echo
    echo "==============================================================================="
    echo "  Diagnostic Summary"
    echo "==============================================================================="
    printf "  Total Checks : %d\n" "$total_checks"
    printf "  %bPassed       : %d%b\n" "$c_green" "$pass_count" "$c_reset"
    if [ "$warn_count" -gt 0 ]; then
        printf "  %bWarnings     : %d%b\n" "$c_yellow" "$warn_count" "$c_reset"
    else
        printf "  Warnings     : %d\n" "$warn_count"
    fi
    if [ "$fail_count" -gt 0 ]; then
        printf "  %bFailures     : %d%b\n" "$c_red" "$fail_count" "$c_reset"
    else
        printf "  Failures     : %d\n" "$fail_count"
    fi
    echo "-------------------------------------------------------------------------------"
    local summary_rc=0
    if [ "$fail_count" -eq 0 ]; then
        if [ "$warn_count" -eq 0 ]; then
            printf "  %bResult: All checks passed! Configuration and environment are in excellent health.%b\n" "${c_bold}${c_green}" "$c_reset"
        else
            printf "  %bResult: Configuration is operational with %d non-critical warning(s).%b\n" "${c_bold}${c_yellow}" "$warn_count" "$c_reset"
        fi
        summary_rc=0
    else
        printf "  %bResult: Found %d critical issue(s) that should be resolved before backing up.%b\n" "${c_bold}${c_red}" "$fail_count" "$c_reset"
        summary_rc=1
    fi
    echo "==============================================================================="

    unset -f report_ok report_warn report_fail report_info print_section 2>/dev/null
    return "$summary_rc"
}

#---
#   FUNCTION:  test_email()
#  DESCRIPTION:  Dispatches a test notification to verify MTA delivery and recipient reachability.
#---
test_email() {
    local recipient="${1:-${ALERT_EMAIL:-${NOTIFICATION_EMAIL:-}}}"
    local custom_sender="${2:-}"
    if [ -z "$recipient" ]; then
        echo "ERROR: No recipient email address specified." >&2
        echo "Usage: $0 test-email <recipient@example.com> [sender@example.com]" >&2
        echo "Or configure ALERT_EMAIL in ${CONFIG_FILE:-~/.config/backup_script/config}" >&2
        return 1
    fi

    echo "Sending test notification email to ${recipient}..."
    local old_alert_email="$ALERT_EMAIL"
    local old_alert_from="$ALERT_FROM"
    local old_sent="$EMAIL_ALERT_SENT"
    ALERT_EMAIL="$recipient"
    [ -n "$custom_sender" ] && ALERT_FROM="$custom_sender"
    EMAIL_ALERT_SENT=0

    if send_failure_email "Test Notification" "This is an automated test from backup_script.sh on ${HOSTNAME} to verify email alert delivery."; then
        echo "Test email successfully dispatched to ${recipient}."
        ALERT_EMAIL="$old_alert_email"
        ALERT_FROM="$old_alert_from"
        EMAIL_ALERT_SENT="$old_sent"
        return 0
    else
        echo "ERROR: Failed to dispatch test email to ${recipient}." >&2
        ALERT_EMAIL="$old_alert_email"
        ALERT_FROM="$old_alert_from"
        EMAIL_ALERT_SENT="$old_sent"
        return 1
    fi
}

#---
#   FUNCTION:  show_main_menu()
#  DESCRIPTION:  Displays the main interactive menu.
#---
show_main_menu() {
    while true; do
        echo -e "\n========================\n  System Utility Menu\n========================"
        local preserved_count
        preserved_count=$(get_preserved_archives | wc -l)
        if [ "$preserved_count" -gt 0 ]; then
            echo "* NOTICE: ${preserved_count} preserved archive(s) from failed upload(s) in ~ (Select 8 to manage)"
        fi
        echo "1. Backup Home Directory"
        echo "2. Restore Home Directory"
        echo "3. Verify Backup Integrity"
        echo "4. List Available Backups"
        echo "5. View Backup Manifest / Summary"
        echo "6. Backup Trends & Storage Analytics"
        echo "7. View / Search Files Inside Archive"
        if [ "$preserved_count" -gt 0 ]; then
            echo "8. Manage Preserved Archives (* ${preserved_count} pending *)"
        else
            echo "8. Manage Preserved Archives"
        fi
        echo "9. Systemd Backup Timer (Schedule/Status)"
        echo "10. Check Configuration & Environment"
        echo "11. Initialize Configuration File"
        echo "12. Exit"
        if ! read -r -p "Please enter your choice [1-12]: " choice; then
            echo -e "\nExiting."
            break
        fi

        case $choice in
            1) execute_with_inhibit backup ;;
            2) execute_with_inhibit restore ;;
            3) execute_with_inhibit verify ;;
            4) list_backups ;;
            5) display_manifest ;;
            6) show_backup_stats ;;
            7) execute_with_inhibit list-files ;;
            8) execute_with_inhibit manage-preserved ;;
            9) manage_systemd_timer ;;
            10) check_config ;;
            11) init_config ;;
            12) echo "Exiting."; break ;;
            *) echo "Invalid option." ;;
        esac
    done
}

#------------------------------------------------------------------------------
#  Main Script
#------------------------------------------------------------------------------

# Handle help and diagnostic options early before dependency checking or signal traps
case "${1:-}" in
    help|-h|--help)
        echo "Usage: $0 [command] [options]"
        echo
        echo "Commands:"
        echo "  backup [opts]                 Create and upload an encrypted backup of the home directory"
        echo "                                Options:"
        echo "                                  --alert-email, -ae <email>        Recipient email address to notify if backup fails"
        echo "                                  --alert-from, -af <email>         Sender email address for failure notifications"
        echo "                                  --apps-action, -aa <mode>         Running applications consistency action"
        echo "                                                                    ('close', 'prompt', 'sync', or 'ignore')"
        echo "                                  --close-apps                      Gracefully terminate running target apps (default)"
        echo "                                  --prompt-apps                     Prompt whether to close running apps interactively"
        echo "                                  --no-close-apps                   Keep running apps open; flush buffers via sync"
        echo "                                  --exclude-tag, -et <tag>          Add per-directory exclusion tag (default: .nobackup)"
        echo "                                  --no-exclude-tags                 Disable per-directory tag exclusion"
        echo "                                  --exclude-ignore, -ei <file>      Add recursive ignore pattern file (default: .backupignore)"
        echo "                                  --no-exclude-ignore               Disable per-directory recursive ignore rules"
        echo "                                  --asymmetric, --pubkey [key]      Use GPG public-key encryption (no password required)"
        echo "                                  --symmetric, --passphrase         Use symmetric passphrase encryption (default)"
        echo "                                  --hybrid [key]                    Encrypt with both public key and symmetric passphrase"
        echo "                                  --recipient, -r <key>             Add GPG recipient key ID, fingerprint, or email"
        echo "                                  --verify, -v [source]             Verify archive integrity immediately after creation"
        echo "                                                                    (optional source: 'auto', 'local', or 'cloud')"
        echo "                                  --verify-checksum, -vc [source]   Fast SHA-256 sidecar checksum verification after creation"
        echo "                                  --no-verify                       Skip post-backup verification"
        echo "                                  --mirror-cloud                    Mirror script and RESTORE_README.txt to cloud (default: true)"
        echo "                                  --no-mirror-cloud                 Disable mirroring script and cheatsheet to cloud"
        echo "                                  --mirror-local                    Mirror script and RESTORE_README.txt to local drive (default: true)"
        echo "                                  --no-mirror-local                 Disable mirroring script and cheatsheet to local drive"
        echo "  restore [archive|path] [opts] Interactively select and restore a backup, or selectively extract"
        echo "                                specific files, directories, or wildcard patterns without full restore."
        echo "                                Options:"
        echo "                                  --path, -p, --pattern <pattern>   Specific file, folder, or wildcard pattern"
        echo "                                                                    (can be specified multiple times)"
        echo "                                  --dest, -d, --target <dir>        Destination directory (default: $SOURCE_DIR)"
        echo "                                  --source, -s <local|cloud>        Force restore source (local drive or cloud)"
        echo "                                  --archive, -a <name|path>         Specify archive filename, path, or 'latest'"
        echo "                                  --verify-checksum, -vc            Verify SHA-256 sidecar checksum before restore"
        echo "                                  --no-verify-checksum, --no-vc     Skip pre-restore SHA-256 sidecar check"
        echo "                                  --stream                          Force single-pass cloud streaming without staging to scratch"
        echo "                                  --no-stream, --stage              Force downloading archive to scratch directory before extracting"
        echo "                                  --yes, -y, --batch                Non-interactive batch mode (auto-confirm prompts)"
        echo "  verify [target] [source] [opts] Verify integrity of a backup archive without disk writes"
        echo "                                [target] can be: 'latest', 'local', 'cloud', a filename, or a direct file path."
        echo "                                [source] optional: 'local' or 'cloud' to force verification source."
        echo "                                Options:"
        echo "                                  --checksum-only, -c, --quick      Fast SHA-256 sidecar checksum check"
        echo "                                                                    (detects bit-rot without decryption/passphrase)"
        echo "                                Runs non-interactively if target is specified or stdin is non-interactive."
        echo "  list, -l, --list              List available local and cloud backups"
        echo "  manifest [archive|path]       View lightweight JSON backup manifest & inventory without decryption"
        echo "                                [archive] can be: 'latest' (default), an archive filename, or direct file path."
        echo "                                Options: --json, -j (print raw JSON output)"
        echo "  stats, trends [opts]          Show historical backup trends, size growth, and analytics"
        echo "                                Options:"
        echo "                                  --source, -s <auto|local|cloud|all|path>"
        echo "                                  --limit, -n <count>               (default: 15, 0 for all)"
        echo "                                  --json, -j                        (structured JSON output)"
        echo "                                  --csv                             (CSV export)"
        echo "  list-files [archive] [pat]    List or search files inside a backup archive (local, cloud, or file path)"
        echo "                                [archive] can be: 'latest', 'local', 'cloud', a filename, or a direct file path."
        echo "                                [pat] is an optional pattern to filter files (e.g. '.bashrc', '*.pdf')."
        echo "                                Options: --long, -l (detailed listing with permissions, owner, size)"
        echo "                                         --no-pager (disable pager)"
        echo "  manage-preserved [opt]        Manage, retry upload, or delete preserved failed-upload archives"
        echo "                                [opt] can be: '--retry' (or -r), '--delete' (or -d), or '--list' (or -l)."
        echo "                                Runs interactively if no option is specified."
        echo "  check-config [opts]           Validate configuration, permissions, paths, destinations, and tools"
        echo "                                Options:"
        echo "                                  --fix, -f                         Auto-correct directory and file permissions"
        echo "                                  --quiet, -q                       Only report warnings and errors"
        echo "  install-timer [schedule]      Install and enable a systemd --user timer (default: daily at 00:45:00)"
        echo "  status-timer                  Show status and next run time of the systemd backup timer"
        echo "  journal-timer [lines|-f]      Show recent journal logs for the systemd backup service"
        echo "  uninstall-timer               Disable and remove the systemd backup timer and service units"
        echo "  timer [status|journal|install|remove] Manage systemd backup timer interactively or via subcommand"
        echo "  test-email [addr] [sender]    Send a test email notification to verify MTA delivery and recipient reachability"
        echo "  init-config [path] [--force]  Generate a template configuration file with all configurable settings"
        echo "  help, -h, --help              Display this help message"
        echo
        echo "Run without arguments to launch the interactive menu."
        exit 0
        ;;
    check-config|check_config|test-config|verify-config)
        check_config "${@:2}"
        exit $?
        ;;
    test-email|test_email|send-test-email)
        test_email "${@:2}"
        exit $?
        ;;
esac

check_dependencies

# Trap signals and exit to ensure lock release and temporary file cleanup
trap cleanup EXIT INT TERM HUP

if [ -n "$1" ]; then
    case "$1" in
        list|-l|--list)
            list_backups
            exit 0
            ;;
        manifest|show-manifest|view-manifest|info)
            display_manifest "${@:2}"
            exit $?
            ;;
        stats|trends|history|analytics)
            show_backup_stats "${@:2}"
            exit $?
            ;;
        list-files|list_files|view-archive|view_archive|list-contents|list_contents)
            execute_with_inhibit list-files "${@:2}"
            exit $?
            ;;
        install-timer|install_timer)
            install_systemd_timer "${2:-}"
            exit $?
            ;;
        status-timer|status_timer)
            status_systemd_timer
            exit $?
            ;;
        journal-timer|journal_timer|logs-timer|logs_timer)
            journal_systemd_timer "${2:-50}" "${3:-false}"
            exit $?
            ;;
        uninstall-timer|uninstall_timer|remove-timer|remove_timer)
            uninstall_systemd_timer "${2:-}"
            exit $?
            ;;
        timer|systemd-timer)
            manage_systemd_timer "${@:2}"
            exit $?
            ;;
        init-config|--init-config|init_config)
            init_config "${@:2}"
            exit $?
            ;;
        test-email|test_email|send-test-email)
            test_email "${@:2}"
            exit $?
            ;;
        backup|restore|verify|manage-preserved|clean-preserved)
            execute_with_inhibit "$1" "${@:2}"
            exit $?
            ;;
        *)
            echo "Invalid action: $1. Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
else
    show_main_menu
fi
