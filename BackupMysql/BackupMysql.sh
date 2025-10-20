#!/usr/bin/env bash

# A robust script to back up MySQL databases with locking, pre-flight checks,
# multiple compression strategies, and detailed email notifications.

set -euo pipefail

################################################################################
# SCRIPT INITIALIZATION
################################################################################

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# --- Global Variables ---
readonly SCRIPT_DIR
readonly LOG_DIR="${LOG_DIR:-/var/log/custom}"
readonly HOSTNAME=$(hostname)
readonly TODAY=$(date +%Y-%m-%d)
readonly DATE=$(date +%d)
readonly MONTH=$(date +%m)
readonly YEAR=$(date +%Y)

# Detect if running in an interactive terminal
IS_INTERACTIVE=false
if [[ -t 1 ]]; then
    IS_INTERACTIVE=true
fi

# These must be global for the trap to see them. They are defined in main().
LOCK_FILE=""
LOG_FILE=""

# --- Global Result Arrays ---
SUCCESS_DBS=()
FAILED_DBS=()
declare -A FAILED_DB_ERRORS
declare -A DB_SIZES_PRE_COMPRESS
declare -A DB_SIZES_POST_COMPRESS
declare -A DB_ARCHIVE_PATHS

# Global variables for per_job summary
JOB_ARCHIVE_PATH=""
JOB_PRE_COMPRESS_SIZE=""
JOB_POST_COMPRESS_SIZE=""

################################################################################
# CORE FUNCTIONS
################################################################################

log() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] $@"
    echo "$message" >> "$LOG_FILE"
    
    # Only print INFO messages to console if interactive
    # Always print ERROR/FATAL to console
    if [[ "$IS_INTERACTIVE" == "true" ]]; then
        echo "$message"
    elif [[ "$@" == *"ERROR:"* || "$@" == *"FATAL:"* ]]; then
        echo "$message"
    fi
}

setup_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        echo "ERROR: Script is already running with PID: $(cat "$LOCK_FILE"). Exiting."
        exit 1
    fi
    echo $$ > "$LOCK_FILE"
    trap 'cleanup_lock' EXIT INT TERM
}

cleanup_lock() {
    rm -f "$LOCK_FILE"
}

################################################################################
# PRE-FLIGHT CHECKS
################################################################################

validate_config() {
    log "INFO: Validating configuration..."
    local has_error=0

    if [[ -z "$BACKUP_PATH" || ! -d "$BACKUP_PATH" || ! -w "$BACKUP_PATH" ]]; then
        log "FATAL: BACKUP_PATH ('$BACKUP_PATH') is not set, not a directory, or not writable."
        has_error=1
    fi
    if ! [[ "$RETENTION_COUNT" =~ ^[0-9]+$ ]]; then
        log "FATAL: RETENTION_COUNT ('$RETENTION_COUNT') is not a valid integer."
        has_error=1
    fi
    if [[ "${BACKUP_ALL_DATABASES,,}" != "yes" && ${#DATABASES[@]} -eq 0 ]]; then
        log "FATAL: BACKUP_ALL_DATABASES is 'no' but the DATABASES array is empty."
        has_error=1
    fi
    if [[ "$COMPRESSION_STRATEGY" != "per_database" && "$COMPRESSION_STRATEGY" != "per_job" ]]; then
        log "FATAL: COMPRESSION_STRATEGY must be 'per_database' or 'per_job'."
        has_error=1
    fi

    if [[ $has_error -eq 1 ]]; then
        log "FATAL: Script aborted due to configuration errors."
        exit 1
    fi
    log "INFO: Configuration validation passed."
}

check_deps() {
    log "INFO: Checking dependencies..."
    local missing_deps=0
    local cmds=("mysqldump" "mysql" "sendmail" "du" "df" "find" "rm" "tar" "sort" "cut" "stat" "basename")
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log "ERROR: Command not found: $cmd"
            missing_deps=1
        fi
    done
    if ! command -v "${COMPRESSION_TYPE,,}" &> /dev/null; then
        log "ERROR: Compression tool '${COMPRESSION_TYPE,,}' not found."
        missing_deps=1
    fi
    if [[ $missing_deps -eq 1 ]]; then
        log "FATAL: Please install missing dependencies."
        exit 1
    fi
}

check_db_connection() {
    log "INFO: Checking MySQL connection and database list..."
    local mysql_auth_opts=(-u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST")
    local error_output
    error_output=$(mktemp)
    
    if ! mysql "${mysql_auth_opts[@]}" -e "SHOW DATABASES;" > /dev/null 2> "$error_output"; then
        local error_details=$(<"$error_output")
        rm -f "$error_output"
        log "FATAL: Failed to connect to MySQL. Please check credentials and host. Details: $error_details"
        send_report "FAILED" "0s" "Failed to connect to MySQL. Details: $error_details"
        exit 1
    fi
    rm -f "$error_output"

    local all_server_dbs
    mapfile -t all_server_dbs < <(mysql "${mysql_auth_opts[@]}" -e "SHOW DATABASES;" | sed 1d)

    if [[ "${BACKUP_ALL_DATABASES,,}" == "yes" ]]; then
        log "INFO: BACKUP_ALL_DATABASES is enabled."
        local dbs_to_backup=()
        for db in "${all_server_dbs[@]}"; do
            if [[ ! " ${EXCLUDE_DATABASES[*]} " =~ " $db " ]]; then
                dbs_to_backup+=("$db")
            else
                log "INFO: Excluding database '$db'."
            fi
        done
        DATABASES=("${dbs_to_backup[@]}")
    fi

    if [[ ${#DATABASES[@]} -eq 0 ]]; then
        log "WARN: No databases are scheduled for backup."
    else
        log "INFO: Databases to be backed up: ${DATABASES[*]}"
    fi
}

################################################################################
# WORKFLOW FUNCTIONS
################################################################################

get_archive_extension() {
    case "${COMPRESSION_TYPE,,}" in
        gzip) echo ".tar.gz" ;;
        bzip2) echo ".tar.bz2" ;;
        xz) echo ".tar.xz" ;;
        *) log "WARN: Unknown compression type '$COMPRESSION_TYPE'. Defaulting to .tar.gz"; echo ".tar.gz" ;;
    esac
}

get_tar_options() {
    case "${COMPRESSION_TYPE,,}" in
        gzip) echo "-czf" ;;
        bzip2) echo "-cjf" ;;
        xz) echo "-cJf" ;;
        *) echo "-czf" ;;
    esac
}

backup_databases() {
    local dest_dir="$1"
    local mysql_dump_opts=(-u"$MYSQL_USER" -p"$MYSQL_PASS" -h"$MYSQL_HOST" --single-transaction -R -K --triggers --set-gtid-purged=OFF)

    for db in "${DATABASES[@]}"; do
        log "INFO: Backing up database '$db'..."
        local sql_file="${dest_dir}/${db}.sql"
        
        if mysqldump "${mysql_dump_opts[@]}" "$db" > "$sql_file" 2>> "$LOG_FILE"; then
            SUCCESS_DBS+=("$db")
            local size
            size=$(du -sh "$sql_file" | awk '{print $1}')
            DB_SIZES_PRE_COMPRESS["$db"]=$size
            log "SUCCESS: Backup for database '$db' completed ($size)."
        else
            FAILED_DBS+=("$db")
            FAILED_DB_ERRORS["$db"]="mysqldump failed. See log for details."
            log "ERROR: Backup for database '$db' failed."
            rm -f "$sql_file" # Clean up failed dump
        fi
    done
}

compress_backups() {
    local temp_dir=$1
    local final_dir=$2
    local archive_ext
    archive_ext=$(get_archive_extension)
    local tar_opts
    tar_opts=$(get_tar_options)

    local unique_id_suffix=""
    if [[ "${UNIQUE_ID_ENABLED,,}" == "yes" ]]; then
        unique_id_suffix="_$(mktemp -u XXXXXX)"
    fi

    if [[ "$COMPRESSION_STRATEGY" == "per_database" ]]; then
        log "INFO: Compressing per database..."
        for db in "${SUCCESS_DBS[@]}"; do
            local sql_file="${temp_dir}/${db}.sql"
            local archive_path="${final_dir}/${db}${unique_id_suffix}${archive_ext}"
            DB_ARCHIVE_PATHS["$db"]=$archive_path
            
            log "INFO: Compressing '$sql_file' to '$archive_path'..."
            if tar "$tar_opts" "$archive_path" -C "$temp_dir" "${db}.sql"; then
                local post_size
                post_size=$(du -sh "$archive_path" | awk '{print $1}')
                DB_SIZES_POST_COMPRESS["$db"]=$post_size
                log "SUCCESS: Compression for '$db' complete ($post_size)."
            else
                log "ERROR: Compression failed for '$db'."
                DB_SIZES_POST_COMPRESS["$db"]="Compression Failed"
            fi
        done
    elif [[ "$COMPRESSION_STRATEGY" == "per_job" ]]; then
        log "INFO: Compressing per job..."
        local job_archive_name="${DATE}${unique_id_suffix}${archive_ext}"
        local archive_path="${final_dir}/${job_archive_name}"
        
        if [[ ${#SUCCESS_DBS[@]} -gt 0 ]]; then
            log "INFO: Compressing all successful SQL dumps to '$archive_path'..."
            # Create a list of just the successful .sql filenames for tar
            local successful_sql_files=()
            for db in "${SUCCESS_DBS[@]}"; do successful_sql_files+=("${db}.sql"); done

            if tar "$tar_opts" "$archive_path" -C "$temp_dir" "${successful_sql_files[@]}"; then
                local total_pre_size=$(du -shc "${temp_dir}"/*.sql | tail -n1 | awk '{print $1}')
                local total_post_size=$(du -sh "$archive_path" | awk '{print $1}')
                
                JOB_PRE_COMPRESS_SIZE=$total_pre_size
                JOB_POST_COMPRESS_SIZE=$total_post_size
                JOB_ARCHIVE_PATH=$archive_path
                log "SUCCESS: Job compression complete ($total_post_size)."
            else
                log "ERROR: Job compression failed."
            fi
        else
            log "INFO: No successful backups to compress for this job."
        fi
    fi
}

cleanup_old_backups() {
    if [[ "$RETENTION_COUNT" -eq 0 ]]; then
        log "INFO: RETENTION_COUNT is 0, cleanup process is disabled."
        return
    fi

    log "INFO: Cleaning up old backups..."
    local base_host_dir="${BACKUP_PATH}/${MYSQL_HOST}"
    if [[ ! -d "$base_host_dir" ]]; then return; fi

    local year="$YEAR"
    local month="$MONTH"
    local archive_ext=$(get_archive_extension)

    if [[ "$COMPRESSION_STRATEGY" == "per_database" ]]; then
        for db in "${DATABASES[@]}"; do
            local find_pattern="${db}"
            if [[ "${UNIQUE_ID_ENABLED,,}" == "yes" ]]; then
                find_pattern+="_*.tar.*"
            else
                find_pattern+=".tar.*"
            fi
            # Get files sorted by modification time (newest first), then take the oldest ones
            find "$base_host_dir" -name "$find_pattern" -type f -exec stat -f "%m %N" {} + | sort -rn | cut -d' ' -f2- | tail -n +$((RETENTION_COUNT + 1)) | xargs -I {} rm -v {} >> "$LOG_FILE"
        done
    elif [[ "$COMPRESSION_STRATEGY" == "per_job" ]]; then
        local current_month_dir="${base_host_dir}/${YEAR}/${MONTH}"
        if [[ -d "$current_month_dir" ]]; then
            local find_pattern="${DATE}*.tar.*"
            # Get files sorted by modification time (newest first), then take the oldest ones
            find "$current_month_dir" -name "$find_pattern" -type f -exec stat -f "%m %N" {} + | sort -rn | cut -d' ' -f2- | tail -n +$((RETENTION_COUNT + 1)) | xargs -I {} rm -v {} >> "$LOG_FILE"
        fi
    fi
    log "INFO: Cleanup finished."
}

################################################################################
# NOTIFICATION FUNCTIONS
################################################################################

send_mail() {
    local mail_file
    mail_file=$(mktemp)
    local encoded_subject="=?UTF-8?B?$(echo -n "$3" | base64)?="
    {
        echo "From: $2";
        echo "To: $1";
        echo "Subject: $encoded_subject";
        echo "MIME-Version: 1.0";
        echo "Content-Type: text/plain; charset=UTF-8";
        echo "";
        echo -e "$4";
    } > "$mail_file"
    /usr/sbin/sendmail -t < "$mail_file"
    rm -f "$mail_file"
}

send_start_notification() {
    if [[ "${NOTIFY_ON_START,,}" != "yes" ]]; then return; fi
    local subject="🚀 [Backup Started] MySQL Backup on $MYSQL_HOST"
    local from="${MAIL_FROM:-mysql-backup@$HOSTNAME}"
    local body="The MySQL backup process has started.\n\nDatabases to be backed up:\n"
    for db in "${DATABASES[@]}"; do body+="- $db\n"; done
    log "INFO: Sending start notification..."
    send_mail "$MAIL_TO" "$from" "$subject" "$body"
}

send_report() {
    local status=$1
    local duration=$2
    local error_msg=${3:-"N/A"}
    local subject=""
    if [[ "$status" == "SUCCESS" ]]; then
        subject="✅ [Backup SUCCESS] MySQL Backup on $MYSQL_HOST"
    else
        subject="❌ [Backup FAILED] MySQL Backup on $MYSQL_HOST"
    fi
    local from="${MAIL_FROM:-mysql-backup@$HOSTNAME}"

    local body="Backup process finished with status: $status\n\nTotal duration: $duration\n"
    if [[ "$status" == "FAILED" && "$error_msg" != "N/A" ]]; then
        body+="Error Details: $error_msg\n"
    fi
    body+="-------------------------------------\n"

    if [[ ${#SUCCESS_DBS[@]} -gt 0 ]]; then
        body+="Successful Backups:\n"
        local year="$YEAR"
        local month="$MONTH"
        local archive_ext=$(get_archive_extension)

        if [[ "$COMPRESSION_STRATEGY" == "per_job" ]]; then
            body+="- 📦 Backup Job Summary\n"
            body+="  - Size (uncompressed total): ${JOB_PRE_COMPRESS_SIZE:-N/A}\n"
            body+="  - Size (compressed total): ${JOB_POST_COMPRESS_SIZE:-N/A}\n"
            body+="  - filename: $(basename "$JOB_ARCHIVE_PATH")\n"
            body+="  - Location: $JOB_ARCHIVE_PATH\n\n"

            body+="  Databases included in this job:\n"
            for db in "${SUCCESS_DBS[@]}"; do
                body+="    - $db (uncompressed: ${DB_SIZES_PRE_COMPRESS[$db]:-N/A})\n"
            done
            body+="\n"

            # --- Get Old Backup List & Total Size for the Job Archive ---
            local all_job_backups=()
            local current_search_base_dir="${BACKUP_PATH}/${MYSQL_HOST}"
            local current_find_start_dir="${current_search_base_dir}/${YEAR}/${MONTH}"
            local current_find_pattern="${DATE}*.tar.*" # Match any day.ext in this month

            if [[ -d "$current_find_start_dir" ]]; then
                mapfile -t all_job_backups < <(find "$current_find_start_dir" -name "$current_find_pattern" -type f -exec stat -f "%m %N" {} + | sort -rn | cut -d' ' -f2-)
            fi

            if [[ ${#all_job_backups[@]} -gt 0 ]]; then
                if [[ "${UNIQUE_ID_ENABLED,,}" == "yes" ]]; then
                    body+="  🗃️ Old Job Backup List (newest first):\n"
                    for backup_file in "${all_job_backups[@]}"; do
                        if [[ -f "$backup_file" ]]; then
                            local m_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup_file")
                            local file_size=$(du -h "$backup_file" | awk '{print $1}')
                            body+="  - $m_date $(basename "$backup_file") $file_size\n"
                        fi
                    done
                    body+="\n"

                    local total_size=$(printf "%s\0" "${all_job_backups[@]}" | xargs -0 du -ch | tail -n1 | awk '{print $1}')
                    body+="  💾 Total size all job backups for this month: ${total_size:-0B}\n"
                else
                    body+="  (Old Job Backup List is not displayed when UNIQUE_ID_ENABLED is 'no')\n"
                fi
            fi
            body+="\n-------------------------------------\n"

        elif [[ "$COMPRESSION_STRATEGY" == "per_database" ]]; then
            for db in "${SUCCESS_DBS[@]}"; do
                body+="- 📦 database $db\n"
                body+="  - Size (uncompressed): ${DB_SIZES_PRE_COMPRESS[$db]:-N/A}\n"
                body+="  - Size (compressed): ${DB_SIZES_POST_COMPRESS[$db]:-N/A}\n"
                body+="  - filename: $(basename "${DB_ARCHIVE_PATHS[$db]}")\n"
                body+="  - Location: ${BACKUP_PATH}/${MYSQL_HOST}/${YEAR}/${MONTH}/${DATE}\n\n"

                # --- Get Old Backup List & Total Size for per_database ---
                local all_db_backups=()
                local current_search_base_dir="${BACKUP_PATH}/${MYSQL_HOST}"
                local find_pattern="${db}"
                if [[ "${UNIQUE_ID_ENABLED,,}" == "yes" ]]; then
                    find_pattern+="_*.tar.*"
                else
                    find_pattern+=".tar.*"
                fi

                if [[ -d "$current_search_base_dir" ]]; then
                    mapfile -t all_db_backups < <(find "$current_search_base_dir" -name "$find_pattern" -type f -exec stat -f "%m %N" {} + | sort -rn | cut -d' ' -f2-)
                fi

                if [[ ${#all_db_backups[@]} -gt 0 ]]; then
                    if [[ "${UNIQUE_ID_ENABLED,,}" == "yes" ]]; then
                        body+="  🗃️ Old Backup List (newest first):\n"
                        local recent_backups=("${all_db_backups[@]:0:3}")
                        for backup_file in "${recent_backups[@]}"; do
                            if [[ -f "$backup_file" ]]; then
                                local m_date=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$backup_file")
                                local file_size=$(du -h "$backup_file" | awk '{print $1}')
                                body+="  - $m_date $(basename "$backup_file") $file_size\n"
                            fi
                        done
                        body+="\n"

                        local total_size=$(printf "%s\0" "${all_db_backups[@]}" | xargs -0 du -ch | tail -n1 | awk '{print $1}')
                        body+="  💾 Total size all backups for $db: ${total_size:-0B}\n"
                    else
                        body+="  (Old Backup List is not displayed when UNIQUE_ID_ENABLED is 'no')\n"
                    fi
                fi
                body+="\n-------------------------------------\n"
            done
        fi
    fi

    if [[ ${#FAILED_DBS[@]} -gt 0 ]]; then
        body+="Failed Backups:\n"
        for db in "${FAILED_DBS[@]}"; do body+="- $db: ${FAILED_DB_ERRORS[$db]}\n"; done
        body+="\n"
    fi

    log "INFO: Sending final report..."
    send_mail "$MAIL_TO" "$from" "$subject" "$body"
}

################################################################################
# SCRIPT ENTRYPOINT
################################################################################

main() {
    # --- Config & Environment Setup ---
    local config_file_arg="${1:-mysql-backup.conf}"
    local config_file="${SCRIPT_DIR}/${config_file_arg}"
    if [[ ! -f "$config_file" ]]; then
        echo "FATAL: Configuration file not found at: $config_file"
        exit 1
    fi
    source "$config_file"

    local lock_file_name=$(basename "$config_file").lock
    LOCK_FILE="/tmp/${lock_file_name}"
    LOG_FILE="${LOG_DIR}/mysql_dump_${MYSQL_HOST}.log"

    mkdir -p "$LOG_DIR"
    > "$LOG_FILE"
    setup_lock
    
    local start_time=$SECONDS
    log "=============================================================================="
    log "Initializing MySQL Backup for config: $config_file_arg"
    log "=============================================================================="

    # --- Pre-flight Checks ---
    validate_config
    check_deps
    check_db_connection

    send_start_notification

    # --- Main Backup Logic ---
    local base_month_dir="${BACKUP_PATH}/${MYSQL_HOST}/${YEAR}/${MONTH}"
    local temp_dump_dir="${BACKUP_PATH}/.tmp_dumps_$$"
    
    mkdir -p "$base_month_dir" # Create up to month level
    mkdir -p "$temp_dump_dir"

    local final_archive_dir=""
    if [[ "$COMPRESSION_STRATEGY" == "per_database" ]]; then
        final_archive_dir="${base_month_dir}/${DATE}" # Per-database archives go into a day folder
        mkdir -p "$final_archive_dir"
    elif [[ "$COMPRESSION_STRATEGY" == "per_job" ]]; then
        final_archive_dir="${base_month_dir}" # Per-job archive goes into month folder
    fi

    backup_databases "$temp_dump_dir"
    compress_backups "$temp_dump_dir" "$final_archive_dir"

    rm -rf "$temp_dump_dir"

    # --- Final Reporting & Cleanup ---
    cleanup_old_backups

    local backup_status="SUCCESS"
    if [[ ${#FAILED_DBS[@]} -gt 0 ]]; then
        backup_status="FAILED"
    fi
    
    local elapsed_seconds=$((SECONDS - start_time))
    local elapsed_formatted=$(printf "%dh %dm %ds" $((elapsed_seconds/3600)) $((elapsed_seconds%3600/60)) $((elapsed_seconds%60)))

    send_report "$backup_status" "$elapsed_formatted"

    log "=============================================================================="
    log "Script Finished. Status: $backup_status"
    log "=============================================================================="

    if [[ "$backup_status" == "FAILED" ]]; then
        exit 1
    fi
}

main "$@"