#!/usr/bin/env bash

# Script created by alif
# updated at 2025-10-19

# A robust script to back up InfluxDB databases with locking, pre-flight checks,
# and detailed email notifications.

set -euo pipefail

################################################################################
# CONFIGURATION & INITIALIZATION
################################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# --- Lock File Setup ---
# This is now handled within each main function.

# --- Global Variables ---
readonly LOG_DIR="${LOG_DIR:-/var/log/custom}"
readonly HOSTNAME=$(hostname)
readonly TODAY=$(date +%Y-%m-%d)

# Detect if running in an interactive terminal
IS_INTERACTIVE=false
if [[ -t 1 ]]; then
    IS_INTERACTIVE=true
fi

# LOCK_FILE must be global for the trap to see it. It will be defined in the main functions.
LOCK_FILE="" 
LOG_FILE="" # Will be defined in main functions
BACKUP_DIR_BASE="" # Will be defined in main functions

# --- Global Result Arrays ---
SUCCESS_DBS=()
FAILED_DBS=()
declare -A FAILED_DB_ERRORS
declare -A DB_SIZES_PRE_COMPRESS
declare -A DB_SIZES_POST_COMPRESS
declare -A DB_ARCHIVE_PATHS

################################################################################
# CORE FUNCTIONS
################################################################################

# Simplified and robust logging function.
log() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] $@"
    # Append to the log file.
    echo "$message" >> "$LOG_FILE"
    
    # Only print INFO messages to console if interactive
    # Always print ERROR/FATAL to console
    if [[ "$IS_INTERACTIVE" == "true" ]]; then
        echo "$message"
    elif [[ "$@" == *"ERROR:"* || "$@" == *"FATAL:"* ]]; then
        echo "$message"
    fi
}

get_backup_filepath() {
    local db_name=$1
    local comp_ext=$2 # e.g., .tar.gz
    local year
    year=$(date +%Y)
    local unique_id
    unique_id=$(mktemp -u XXXXXX) # 6 random characters

    # Use HOST variable from config, which should be sanitized or simple
    local final_dir="${BACKUP_DIR_BASE}/${HOST}/${year}"
    # Ensure the directory exists
    mkdir -p "$final_dir"

    echo "${final_dir}/${db_name}-${TODAY}_${unique_id}${comp_ext}"
}

# --- Locking ---
setup_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        # Use echo directly as logging is not yet configured.
        echo "ERROR: Script is already running with PID: $(cat "$LOCK_FILE"). Exiting."
        exit 1
    fi
    echo $$ > "$LOCK_FILE"
    trap 'cleanup_lock' EXIT INT TERM
}

cleanup_lock() {
    rm -f "$LOCK_FILE"
}

# --- Dependency & Pre-flight Checks ---
check_deps() {
    log "INFO: Checking dependencies..."
    local missing_deps=0
    local base_cmds=("influx" "influxd" "sendmail" "du" "df" "find" "rm" "tar" "sort" "head" "xargs" "base64" "file")
    for cmd in "${base_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR: Base command not found: $cmd"
            missing_deps=1
        fi
    done

    if [[ "${COMPRESS_BACKUP,,}" == "yes" ]]; then
        local comp_tool=${COMPRESSION_TYPE,,}
        if ! command -v "$comp_tool" &> /dev/null; then
             log "ERROR: Compression tool '$comp_tool' not found, but is required by COMPRESSION_TYPE."
             missing_deps=1
        fi
    fi

    if [[ $missing_deps -eq 1 ]]; then
        log "FATAL: Please install missing dependencies and ensure sendmail is configured, then try again."
        exit 1
    fi
}

check_disk_space() {
    log "INFO: Checking available disk space..."
    local required_kb=$((MIN_DISK_SPACE_GB * 1024 * 1024))
    local available_kb
    available_kb=$(df -k "$BACKUP_DIR_BASE" | awk 'NR==2 {print $4}')

    if (( available_kb < required_kb )); then
        log "FATAL: Not enough disk space. Required: ${MIN_DISK_SPACE_GB}GB, Available: $((available_kb / 1024 / 1024))GB."
        send_report "FAILED" "0s" "$BACKUP_DIR_BASE" # Send a failure report
        exit 1
    fi
    log "INFO: Disk space check passed."
}

check_db_connection_and_existence() {
    log "INFO: Checking InfluxDB connection and database list..."
    local server_dbs_str
    
    local influx_cmd=("influx" "-host" "$HOST" "-port" "$QUERY_PORT" "-format" "csv")
    if [[ -n "${INFLUX_USER:-}" ]]; then
        log "INFO: Using authentication for user: $INFLUX_USER"
        influx_cmd+=("-username" "$INFLUX_USER" "-password" "$INFLUX_PASS")
    fi
    influx_cmd+=("-execute" "SHOW DATABASES")

    local error_output
    error_output=$(mktemp)
    if ! server_dbs_str=$("${influx_cmd[@]}" 2> "$error_output"); then
        log "FATAL: Failed to connect to InfluxDB or execute query."
        local error_details
        error_details=$(<"$error_output")
        rm -f "$error_output"
        FAILED_DBS+=("DATABASE_CONNECTION")
        FAILED_DB_ERRORS["DATABASE_CONNECTION"]=$error_details
        send_report "FAILED" "0s" "$BACKUP_DIR_BASE"
        exit 1
    fi
    rm -f "$error_output"

    # Read server databases into an array
    mapfile -t server_dbs < <(echo "$server_dbs_str" | tail -n +2 | cut -d, -f2)

    # Decide whether to back up all databases or a specified list
    if [[ "${BACKUP_ALL_DATABASES,,}" == "yes" ]]; then
        log "INFO: BACKUP_ALL_DATABASES is enabled. Preparing to back up all databases."
        local dbs_to_backup=()
        local excluded_db_found
        
        for db in "${server_dbs[@]}"; do
            excluded_db_found=0
            for excluded_db in "${EXCLUDE_DATABASES[@]}"; do
                if [[ "$db" == "$excluded_db" ]]; then
                    excluded_db_found=1
                    break
                fi
            done
            
            if [[ $excluded_db_found -eq 0 ]]; then
                dbs_to_backup+=("$db")
            else
                log "INFO: Excluding database '$db' as specified in EXCLUDE_DATABASES."
            fi
        done
        
        # Overwrite the global DATABASE array
        DATABASE=("${dbs_to_backup[@]}")
        
        if [[ ${#DATABASE[@]} -eq 0 ]]; then
            log "WARN: After exclusions, no databases are left to back up."
        fi

    else
        log "INFO: Checking specified databases for existence..."
        local missing_dbs=()
        for db_to_backup in "${DATABASE[@]}"; do
            local found=0
            for server_db in "${server_dbs[@]}"; do
                if [[ "$db_to_backup" == "$server_db" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                missing_dbs+=("$db_to_backup")
            fi
        done

        if [[ ${#missing_dbs[@]} -gt 0 ]]; then
            log "FATAL: The following databases were not found on the server: ${missing_dbs[*]}"
            FAILED_DBS+=("DATABASE_NOT_FOUND")
            FAILED_DB_ERRORS["DATABASE_NOT_FOUND"]="The following databases were not found: ${missing_dbs[*]}"
            send_report "FAILED" "0s" "$BACKUP_DIR_BASE"
            exit 1
        fi
    fi

    if [[ ${#DATABASE[@]} -gt 0 ]]; then
        log "INFO: Database check passed. The following databases will be backed up: ${DATABASE[*]}"
    else
        log "INFO: Database check passed, but no databases are scheduled for backup."
    fi
}

validate_config() {
    log "INFO: Validating configuration..."
    local has_error=0

    # Check 1: PATH_BCKP
    if [[ -z "$PATH_BCKP" ]]; then
        log "FATAL: Configuration error: PATH_BCKP is not set."
        has_error=1
    elif [[ ! -d "$PATH_BCKP" ]]; then
        log "FATAL: Configuration error: PATH_BCKP ('$PATH_BCKP') is not a directory."
        has_error=1
    elif [[ ! -w "$PATH_BCKP" ]]; then
        log "FATAL: Configuration error: PATH_BCKP ('$PATH_BCKP') is not writable."
        has_error=1
    fi

    # Check 2: RETENTION_COUNT
    if ! [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]]; then
        log "FATAL: Configuration error: RETENTION_COUNT ('$RETENTION_COUNT') is not a valid non-negative integer."
        has_error=1
    fi

    # Check 3: MIN_DISK_SPACE_GB
    if ! [[ "$MIN_DISK_SPACE_GB" =~ ^[0-9]+$ ]]; then
        log "FATAL: Configuration error: MIN_DISK_SPACE_GB ('$MIN_DISK_SPACE_GB') is not a valid non-negative integer."
        has_error=1
    fi

    # Check 4: MAIL_TO (Warning only)
    if [[ -n "$MAIL_TO" && ! "$MAIL_TO" =~ ^.+@.+\..+$ ]]; then
        log "WARN: Configuration warning: MAIL_TO ('$MAIL_TO') does not look like a valid email address."
    fi

    # Check 5: DATABASE array if not backing up all
    if [[ "${BACKUP_ALL_DATABASES,,}" != "yes" && ${#DATABASE[@]} -eq 0 ]]; then
        log "FATAL: Configuration error: BACKUP_ALL_DATABASES is 'no' but the DATABASE array is empty. Nothing to back up."
        has_error=1
    fi

    if [[ $has_error -eq 1 ]]; then
        log "FATAL: Script aborted due to configuration errors."
        exit 1
    fi
    log "INFO: Configuration validation passed."
}


# --- Main Workflow Functions ---

compress_single_backup() {
    local db_name=$1
    local db_backup_path=$2

    # Get pre-compression size
    local pre_compress_size
    pre_compress_size=$(du -sh "$db_backup_path" | awk '{print $1}')
    DB_SIZES_PRE_COMPRESS["$db_name"]=$pre_compress_size

    if [[ "${COMPRESS_BACKUP,,}" != "yes" ]]; then
        DB_SIZES_POST_COMPRESS["$db_name"]="N/A (Compression disabled)"
        # When not compressing, the final backup is the temporary directory itself, which is now in the correct structure
        DB_ARCHIVE_PATHS["$db_name"]=$db_backup_path
        
        # Log the final location of the uncompressed backup
        log "INFO: Uncompressed backup for '$db_name' saved to: $db_backup_path"
        return
    fi

    local comp_type=${COMPRESSION_TYPE,,}
    local archive_ext=""
    local tar_opts=""
    local use_pipe=0

    case "$comp_type" in
        gzip) archive_ext=".tar.gz"; tar_opts="-czf" ;;
        bzip2) archive_ext=".tar.bz2"; tar_opts="-cjf" ;;
        xz) archive_ext=".tar.xz"; tar_opts="-cJf" ;;
        zstd) archive_ext=".tar.zst"; use_pipe=1 ;;
        *) log "ERROR: Unsupported COMPRESSION_TYPE: '$comp_type'. Skipping compression for $db_name."; return ;;
    esac

    # Get the new unique archive path
    local archive_path
    archive_path=$(get_backup_filepath "$db_name" "$archive_ext")
    DB_ARCHIVE_PATHS["$db_name"]=$archive_path

    log "INFO: Compressing backup for '$db_name' with '$comp_type' to: $archive_path"

    local compress_success=0
    if [[ $use_pipe -eq 1 ]]; then
        tar -cf - -C "$db_backup_path" . | "$comp_type" -o "$archive_path" && compress_success=1
    else
        tar "$tar_opts" "$archive_path" -C "$db_backup_path" . && compress_success=1
    fi

    if [[ $compress_success -eq 1 ]]; then
        log "SUCCESS: Compression complete for $db_name."
        
        # Get post-compression size
        local post_compress_size
        post_compress_size=$(du -sh "$archive_path" | awk '{print $1}')
        DB_SIZES_POST_COMPRESS["$db_name"]=$post_compress_size

        log "INFO: Removing original backup directory for $db_name: $db_backup_path"
        rm -rf "$db_backup_path"
    else
        log "ERROR: Compression failed for $db_name. The original directory will be kept."
        DB_SIZES_POST_COMPRESS["$db_name"]="Compression Failed"
    fi
}

backup_databases() {
    log "INFO: Starting backup for databases: ${DATABASE[*]}"
    local error_log
    error_log=$(mktemp)

    for db in "${DATABASE[@]}"; do
        # Ensure the base directory for this host/year exists
        local final_base_dir="${BACKUP_DIR_BASE}/${HOST}/${TODAY:0:4}" # YYYY part of TODAY
        mkdir -p "$final_base_dir"

        # Create a temporary directory for this specific DB backup within the final_base_dir
        local temp_db_backup_path
        temp_db_backup_path=$(mktemp -d "${final_base_dir}/${db}-${TODAY}-XXXXXX")
        log "INFO: Backing up database '$db' to temporary path: $temp_db_backup_path"

        if influxd backup -portable -db "$db" -host "${HOST}:${BACKUP_PORT}" "$temp_db_backup_path" 2> "$error_log"; then
            log "SUCCESS: Backup for database '$db' completed."
            SUCCESS_DBS+=("$db")
            compress_single_backup "$db" "$temp_db_backup_path"
        else
            log "ERROR: Backup for database '$db' failed."
            FAILED_DBS+=("$db")
            FAILED_DB_ERRORS["$db"]=$(<"$error_log")
            # Clean up the failed temporary directory
            rm -rf "$temp_db_backup_path"
        fi
    done
    rm -f "$error_log"
}

cleanup_backups() {
    log "INFO: Cleaning up old backups based on retention count of $RETENTION_COUNT..."
    local host_backup_dir="${BACKUP_DIR_BASE}/${HOST}"

    if [[ ! -d "$host_backup_dir" ]]; then
        log "INFO: Host backup directory not found at '$host_backup_dir'. Skipping cleanup."
        return
    fi

    # For each database, find its backups and apply retention
    for db in "${DATABASE[@]}"; do
        log "INFO: Applying retention for database: $db"
        
        local all_backups=()
        # Search recursively within the host's backup directory for files matching the db name
        # Sort by modification time (newest first) before applying retention
        while IFS= read -r; do
            all_backups+=("$REPLY")
        done < <(find "$host_backup_dir" -name "${db}-*" -type f -exec stat -f "%m %N" {} + | sort -rn | cut -d' ' -f2-)

        local backup_count=${#all_backups[@]}
        log "INFO: Found $backup_count total backups for database: $db"

        if [[ $backup_count -le $RETENTION_COUNT ]]; then
            log "INFO: No old backups to delete for $db."
            continue
        fi

        # Get the backups to delete (all except the first RETENTION_COUNT newest ones)
        local backups_to_delete=("${all_backups[@]:$RETENTION_COUNT}")

        log "INFO: The following ${#backups_to_delete[@]} old backups for $db will be deleted:"
        for backup_file in "${backups_to_delete[@]}"; do
            log "  - $backup_file"
        done

        printf "%s\0" "${backups_to_delete[@]}" | xargs -0 rm -rf
        log "INFO: Cleanup finished for $db."
    done
}


# --- Notification Functions ---

# This function is a direct adaptation of the user's proven SendMail.sh script.
send_mail() {
    local to_address=$1
    local from_address=$2
    local subject_line=$3
    local body_content=$4

    local mail_file
    mail_file=$(mktemp)

    # Encode Subject for UTF-8/emoji support
    local encoded_subject="=?UTF-8?B?$(echo -n "$subject_line" | base64)?="

    # Build the email with MIME headers and plain text content
    {
        echo "From: $from_address";
        echo "To: $to_address";
        echo "Subject: $encoded_subject";
        echo "MIME-Version: 1.0";
        echo "Content-Type: text/plain; charset=UTF-8";
        echo "Content-Transfer-Encoding: 8bit";
        echo "";
        echo -e "$body_content";
    } > "$mail_file"

    # Send the email using input redirection from the temp file
    if /usr/sbin/sendmail -t < "$mail_file"; then
        log "INFO: Email sent successfully to $to_address."
    else
        log "ERROR: Failed to execute sendmail command for $to_address."
    fi

    rm -f "$mail_file"
}

send_start_notification() {
    if [[ "${NOTIFY_ON_START,,}" != "yes" ]]; then
        return
    fi
    
    # Emoticon: 🚀
    local subject="🚀 [Backup Started] InfluxDB Backup on $HOST"
    local from="${MAIL_FROM:-influxdb-backup@$HOSTNAME}"
    
    local body="The InfluxDB backup process has started at $(date '+%Y-%m-%d %H:%M:%S').\n\n"
    body+="The following databases will be backed up:\n"
    for db in "${DATABASE[@]}"; do
        body+="- $db\n"
    done
    body+="\n"

    log "INFO: sendt notif start"
    send_mail "$MAIL_TO" "$from" "$subject" "$body"
}

send_report() {
    local status_msg=$1
    local elapsed_time=$2
    local host_backup_dir="${BACKUP_DIR_BASE}/${HOST}"
    
    log "INFO: Total duration: $elapsed_time"

    local subject=""
    if [[ "$status_msg" == "SUCCESS" ]]; then
        subject="✅ [Backup $status_msg] InfluxDB Backup on $HOST"
    else
        subject="❌ [Backup $status_msg] InfluxDB Backup on $HOST"
    fi

    local from="${MAIL_FROM:-influxdb-backup@$HOSTNAME}"

    local body=""
    body+="Backup process finished with status: $status_msg\n\n"
    body+="Total duration: $elapsed_time\n"
    body+="-------------------------------------\n"

    if [[ ${#SUCCESS_DBS[@]} -gt 0 ]]; then
        body+="Successful Backups:\n"
        for db in "${SUCCESS_DBS[@]}"; do
            body+="- 📦 database $db\n"
            body+="  - Size (uncompressed): ${DB_SIZES_PRE_COMPRESS[$db]:-N/A}\n"
            body+="  - Size (compressed): ${DB_SIZES_POST_COMPRESS[$db]:-N/A}\n"
            body+="  - filename: $(basename "${DB_ARCHIVE_PATHS[$db]}")\n\n"

            # --- Get Old Backup List & Total Size ---
            local all_db_backups=()
            if [[ -d "$host_backup_dir" ]]; then
                # Find files, print mod_time + path, sort by time, then cut to get only the path.
                while IFS= read -r; do
                    all_db_backups+=("$REPLY")
                done < <(find "$host_backup_dir" -name "${db}-*" -exec stat -f "%m %N" {} + | sort -rn | cut -d' ' -f2-)
            fi

            if [[ ${#all_db_backups[@]} -gt 0 ]]; then
                body+="  🗃️ Old Backup List (newest first):\n"
                local recent_backups=("${all_db_backups[@]:0:3}")
                for backup_file in "${recent_backups[@]}"; do
                    if [[ -f "$backup_file" ]]; then # Ensure it's a file
                        # Get file modification time (BSD stat)
                        local m_date
                        m_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup_file")
                        
                        # Get human-readable file size
                        local file_size
                        file_size=$(du -h "$backup_file" | awk '{print $1}')

                        body+="  - $m_date $(basename "$backup_file") $file_size\n"
                    fi
                done
                body+="\n"

                local total_size
                total_size=$(printf "%s\0" "${all_db_backups[@]}" | xargs -0 du -ch | tail -1 | awk '{print $1}')
                body+="  💾 Total size all backups for $db\n"
                body+="   - Size : ${total_size:-0B}\n"
            fi
            # Add a separator for readability between databases
            body+="\n-------------------------------------\n"
        done
    fi

    if [[ ${#FAILED_DBS[@]} -gt 0 ]]; then
        body+="Failed Backups:\n"
        for db in "${FAILED_DBS[@]}"; do
            body+="- $db\n"
            body+="  Error: ${FAILED_DB_ERRORS[$db]}\n"
        done
        body+="\n"
    fi

    if [[ "$status_msg" == "SUCCESS" ]]; then
        body+="All backups completed successfully. Great job! 🎉"
    else
        body+="Some backups failed. Please check the logs. 🧐"
    fi

    log "INFO: sendt notif finish report"
    send_mail "$MAIL_TO" "$from" "$subject" "$body"
}


################################################################################
# SCRIPT ENTRYPOINT
################################################################################

main_backup() {
    # --- Config & Environment Setup for Backup ---
    local config_file_arg="${1:-backup-influx.conf}"
    local config_file="${SCRIPT_DIR}/${config_file_arg}"

    if [[ ! -f "$config_file" ]]; then
        echo "FATAL: Configuration file not found at: $config_file"
        exit 1
    fi
    # shellcheck source=backup-influx.conf
    source "$config_file"

    local lock_file_name
    lock_file_name=$(basename "$config_file").lock
    LOCK_FILE="/tmp/${lock_file_name}"
    
    LOG_FILE="${LOG_DIR}/influx_dump_${HOST}.log"
    BACKUP_DIR_BASE="$PATH_BCKP"

    # Now that LOG_FILE is defined, create the dir and clear the log
    mkdir -p "$LOG_DIR"
    > "$LOG_FILE"

    setup_lock
    
    local start_time
    start_time=$(date +%s)

    log "=============================================================================="
    log "Initializing InfluxDB Backup for config: $config_file_arg"
    log "=============================================================================="

    # --- Run all checks first ---
    validate_config
    check_deps
    check_disk_space
    check_db_connection_and_existence
    
    send_start_notification

    # --- Core backup process ---
    backup_databases

    local backup_status="SUCCESS"
    if [[ ${#FAILED_DBS[@]} -gt 0 ]]; then
        backup_status="FAILED"
    fi

    cleanup_backups

    # --- Final reporting ---
    local end_time
    end_time=$(date +%s)
    local elapsed_seconds=$((end_time - start_time))
    local elapsed_formatted
    elapsed_formatted=$(printf "%dh %dm %ds" $((elapsed_seconds/3600)) $((elapsed_seconds%3600/60)) $((elapsed_seconds%60)))

    # The final_path for the report is now just the base directory
    send_report "$backup_status" "$elapsed_formatted" "$BACKUP_DIR_BASE"

    log "=============================================================================="
    log "Script Finished. Status: $backup_status"
    log "=============================================================================="

    if [[ "$backup_status" == "FAILED" ]]; then
        exit 1
    fi
    exit 0
}

main_restore() {
    # --- Config & Environment Setup for Restore ---
    local config_file_arg="${1:-backup-influx.conf}"
    local config_file="${SCRIPT_DIR}/${config_file_arg}"

    if [[ ! -f "$config_file" ]]; then
        # Can't use log function yet as LOG_FILE is not set.
        echo "FATAL: Configuration file not found for restore at: $config_file"
        exit 1
    fi
    # shellcheck source=backup-influx.conf
    source "$config_file"

    local lock_file_name
    lock_file_name=$(basename "$config_file").lock
    LOCK_FILE="/tmp/${lock_file_name}"

    LOG_FILE="${LOG_DIR}/influx_restore_${HOST}.log"
    BACKUP_DIR_BASE="$PATH_BCKP"

    # Create log directory and clear log file for this run
    mkdir -p "$LOG_DIR"
    > "$LOG_FILE"

    # Now that logging is configured, we can use the log function.
    log "INFO: Starting restore process with config $config_file_arg..."
    
    setup_lock

    local host_backup_dir="${BACKUP_DIR_BASE}/${HOST}"
    if [[ ! -d "$host_backup_dir" ]]; then
        echo "ERROR: Backup directory not found at '$host_backup_dir'. Cannot restore."
        log "ERROR: Backup directory not found at '$host_backup_dir'. Cannot restore."
        exit 1
    fi

    # 1. Find and list all backup files
    log "INFO: Searching for available backups in '$host_backup_dir'..."
    local all_backups=()
    while IFS= read -r; do
        all_backups+=("$REPLY")
    done < <(find "$host_backup_dir" -type f \( -name "*.tar.gz" -o -name "*.tar.bz2" -o -name "*.tar.xz" -o -name "*.tar.zst" \) -o -type d -name "*-*-*-*-*" -exec stat -f "%m %N" {} + | sort -rn | cut -d' ' -f2-)

    if [[ ${#all_backups[@]} -eq 0 ]]; then
        echo "No backup files found. Nothing to restore."
        log "INFO: No backup files found."
        exit 0
    fi

    # 2. Display backups and get user selection
    echo "Available backups (newest first):"
    local i=0
    for backup_file in "${all_backups[@]}"; do
        i=$((i + 1))
        local m_date
        m_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup_file")
        local file_size
        file_size=$(du -h "$backup_file" | awk '{print $1}')
        echo "  $i) $m_date $(basename "$backup_file") ($file_size)"
    done

    local choice
    echo -n "Enter the number of the backup to restore (or 'q' to quit): "
    read -r choice

    if [[ "$choice" == "q" || -z "$choice" ]]; then
        echo "Restore cancelled."
        exit 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#all_backups[@]} ]]; then
        echo "Invalid selection. Please enter a number from 1 to ${#all_backups[@]}."
        exit 1
    fi

    local selected_backup="${all_backups[$((choice - 1))]}"
    log "INFO: User selected backup: $selected_backup"
    echo "You selected: $(basename "$selected_backup")"

    # 3. Decompress the selected backup
    local temp_restore_dir
    temp_restore_dir=$(mktemp -d "/tmp/influx_restore-XXXXXX")
    log "INFO: Decompressing '$selected_backup' to '$temp_restore_dir'..."
    echo "Decompressing backup..."

    if [[ -f "$selected_backup" ]]; then # It's a compressed file
        if ! tar -xf "$selected_backup" -C "$temp_restore_dir"; then
            log "FATAL: Failed to decompress backup file."
            echo "FATAL: Failed to decompress backup file. Check logs for details."
            rm -rf "$temp_restore_dir"
            exit 1
        fi
    elif [[ -d "$selected_backup" ]]; then # It's an uncompressed directory
        # Copy contents of the directory to the temp restore dir
        if ! cp -R "$selected_backup"/* "$temp_restore_dir"/; then
            log "FATAL: Failed to copy uncompressed backup directory."
            echo "FATAL: Failed to copy uncompressed backup directory. Check logs for details."
            rm -rf "$temp_restore_dir"
            exit 1
        fi
    else
        log "FATAL: Selected backup is neither a file nor a directory. This should not happen."
        echo "FATAL: Invalid backup type selected. Exiting."
        rm -rf "$temp_restore_dir"
        exit 1
    fi

    # 4. Get original and new database names
    local original_db_name
    original_db_name=$(basename "$selected_backup" | cut -d'-' -f1)
    
    local new_db_name
    echo -n "Enter the name for the new database (or press Enter to use original name '$original_db_name'): "
    read -r new_db_name
    if [[ -z "$new_db_name" ]]; then
        new_db_name=$original_db_name
    fi
    log "INFO: Original DB: '$original_db_name'. Target DB: '$new_db_name'."

    # 5. Execute the restore command
    log "INFO: Starting InfluxDB restore..."
    echo "Starting restore. This may take a while..."
    local error_log
    error_log=$(mktemp)
    if influxd restore -host "${HOST}:${BACKUP_PORT}" -portable -db "$original_db_name" -newdb "$new_db_name" "$temp_restore_dir" 2> "$error_log"; then
        log "SUCCESS: Restore completed for database '$new_db_name'."
        echo "✅ Restore successful!"
        echo "Database '$original_db_name' from backup has been restored as '$new_db_name'."
    else
        log "FATAL: Restore command failed for database '$new_db_name'."
        log "ERROR DETAILS: $(<"$error_log")"
        echo "❌ FATAL: Restore command failed. Check logs at '$LOG_FILE' for details."
    fi

    # 6. Cleanup
    log "INFO: Cleaning up temporary restore directory '$temp_restore_dir'."
    rm -f "$error_log"
    rm -rf "$temp_restore_dir"
}

if [[ "$1" == "restore" ]]; then
    shift
    main_restore "$@"
else
    # Default to backup behavior, passing all arguments (like the config file)
    main_backup "$@"
fi