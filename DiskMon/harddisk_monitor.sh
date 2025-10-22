#!/usr/bin/env bash
#
# harddisk_monitor.sh v2.0
# Script to monitor hard disk health using smartctl and send email reports.
# Integrated email sending, includes df -h report, and handles disabled SMART.
# Improved compatibility for both Linux and BSD systems.
# Automatically detects OS and uses appropriate device detection methods.

set -euo pipefail

# --- Configuration ---
LOG_FILE="/var/log/harddisk_monitor.log"
DISK_USAGE_WARNING_THRESHOLD=90 # Percentage of disk usage to trigger a warning
REQUIRE_SMARTCTL=true # Set to 'false' to skip SMART checks if smartctl is not available
# --- Email Configuration ---
# REPORT_EMAIL_TO="your_email@example.com" # Replace with the recipient email address
# REPORT_EMAIL_FROM="monitor@yourdomain.com" # Replace with the sender email address
REPORT_EMAIL_TO="admin@example.com"
REPORT_EMAIL_FROM="noreply@monitoring.net"
EMAIL_SUBJECT_PREFIX="[DiskMon Report]"

# --- SMART Attributes ---
# If these attributes have a RAW_VALUE > 0, a warning will be triggered.
CRITICAL_SMART_ATTRIBUTES="Reallocated_Sector_Ct Current_Pending_Sector_Ct Offline_Uncorrectable UDMA_CRC_Error_Count"

# --- Helper Functions ---

log_message() {
    level="INFO"
    message="$1"
    if [ $# -gt 1 ]; then
        level="$1"
        message="$2"
    fi

    log_line="$(date '+%Y-%m-%d %H:%M:%S') - ${level} - ${message}"

    # Always write to the log file
    echo "$log_line" >> "$LOG_FILE"

    # Write to console only under specific conditions
    if [ "$IS_INTERACTIVE" -eq 1 ]; then
        # In interactive mode, print everything
        echo "$log_line"
    elif [ "$level" != "INFO" ]; then
        # In non-interactive (cron) mode, only print WARN and ERROR
        echo "$log_line"
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Detect the operating system
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$NAME" | grep -qi "bsd" && echo "bsd" && return
    fi
    
    uname_out=$(uname -s)
    case "${uname_out}" in
        Linux*) 
            echo "linux"
            ;;
        FreeBSD*) 
            echo "bsd"
            ;;
        Darwin*) 
            echo "bsd"
            ;;
        *)
            # Default to linux if we can't determine
            echo "linux"
            ;;
    esac
}

# Detect disks based on the operating system
detect_disks() {
    os_type="$1"
    disk_list=""
    
    case "${os_type}" in
        "bsd")
            # BSD systems: use camcontrol and smartctl --scan
            standard_disks=""
            megaraid_disks=""
            if command_exists camcontrol; then
                standard_disks=$(camcontrol devlist | grep -E '\(([^,]+),(da[0-9]+|ada[0-9]+)\)' | sed -E 's/.*\(([^,]+),(da[0-9]+|ada[0-9]+)\).*/\2/' | sed 's/^/\/dev\//' | tr '\n' ' ')
            fi
            
            if command_exists smartctl; then
                # Only add megaraid disks if smartctl --scan actually finds them
                # and filter out any non-megaraid entries that might slip through
                megaraid_scan_output=$(smartctl --scan | grep 'megaraid' || true)
                if [ -n "$megaraid_scan_output" ]; then
                    megaraid_disks=$(echo "$megaraid_scan_output" | awk '{print $1","$3}' | tr '\n' ' ')
                fi
            fi
            disk_list="$standard_disks $megaraid_disks"
            ;;
        "linux")
            # Linux systems: use lsblk or smartctl --scan
            if command_exists lsblk; then
                disk_list=$(lsblk -r -o NAME,TYPE | grep -E "disk" | grep -v "loop\|ram\|sr" | awk '{print "\/dev\/" $1}')
            elif command_exists smartctl; then
                # Fallback to smartctl --scan
                disk_list=$(smartctl --scan | grep '^\/dev\/' | awk '{print $1}' | sort -u)
            fi
            ;;
        *)
            # Default to smartctl --scan for unknown systems
            disk_list=$(smartctl --scan | grep '^\/dev\/' | awk '{print $1}' | sort -u)
            ;;
    esac
    
    echo "$disk_list"
}

send_email_report() {
    # Sends the final report via sendmail.
    subject="$1"
    body="$2"
    boundary="===BOUNDARY_$(date +%s)_$$="
    mailfile=$(mktemp)
    if [ -z "$mailfile" ] || [ ! -f "$mailfile" ]; then
        log_message "FATAL: Failed to create temporary file for email."
        return 1
    fi

    log_message "Sending email report with subject: $subject"

    # Use raw subject for direct readability
    final_subject="$subject"

    # Build email headers and body
    {
        echo "From: ${REPORT_EMAIL_FROM}"
        echo "To: ${REPORT_EMAIL_TO}"
        echo "Subject: ${final_subject}"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"${boundary}\""
        echo ""
        echo "--${boundary}"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        echo -e "$body"
        echo ""
        echo "--${boundary}--"
    } > "$mailfile"

    # Send the email
    if sendmail -t < "$mailfile"; then
        log_message "Email report sent successfully to $REPORT_EMAIL_TO."
    else
        log_message "ERROR: Failed to send email report."
    fi

    # Cleanup
    rm -f "$mailfile"
}

# Helper function to run smartctl with a custom timeout
run_smartctl_with_timeout() {
    local device_path="$1"
    local smartctl_args="$2"
    local timeout_seconds=10
    local smart_output=""
    local tmp_file=$(mktemp) # Create temp file internally

    log_message "INFO" "Running smartctl for $device_path with custom timeout of $timeout_seconds seconds."
    log_message "DEBUG" "Executing: smartctl -a $smartctl_args \"$device_path\" > \"$tmp_file\" 2>&1 &"

    # Run smartctl in the background
    smartctl -a $smartctl_args "$device_path" > "$tmp_file" 2>&1 &
    local smartctl_pid=$!
    log_message "DEBUG" "smartctl PID: $smartctl_pid"

    # Wait for smartctl to finish, with a timeout
    local elapsed_time=0
    local interval=1 # Check every 1 second
    local smartctl_finished=0

    while [ "$elapsed_time" -lt "$timeout_seconds" ]; do
        if ! kill -0 "$smartctl_pid" 2>/dev/null; then
            # Process is no longer running
            log_message "DEBUG" "smartctl PID $smartctl_pid finished."
            smartctl_finished=1
            break
        fi
        sleep "$interval"
        elapsed_time=$((elapsed_time + interval))
        log_message "DEBUG" "Waiting for smartctl PID $smartctl_pid. Elapsed: $elapsed_time s."
    done

    if [ "$smartctl_finished" -eq 0 ]; then
        # smartctl is still running after timeout, kill it
        log_message "ERROR" "smartctl for $device_path (PID $smartctl_pid) timed out after $timeout_seconds seconds. Attempting to kill."
        kill -9 "$smartctl_pid" 2>/dev/null
        log_message "DEBUG" "Sent KILL -9 to PID $smartctl_pid."
        wait "$smartctl_pid" 2>/dev/null # Wait for it to be truly dead
        log_message "DEBUG" "Wait for PID $smartctl_pid completed after KILL -9."
        
        # Add error to report
        REPORT_BODY+="  - ❌ Disk $device_path: smartctl timed out and was force-killed after $timeout_seconds seconds (ERROR!)\n"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        rm -f "$tmp_file" # Clean up temp file
        echo "" # Return empty string for SMART_OUTPUT
        return 1 # Indicate failure
    else
        # smartctl finished within the timeout
        wait "$smartctl_pid" # Get the actual exit code
        local smartctl_exit_code=$?
        log_message "DEBUG" "smartctl PID $smartctl_pid exited with code $smartctl_exit_code."
        if [ "$smartctl_exit_code" -ne 0 ]; then
            log_message "ERROR" "smartctl for $device_path failed with exit code $smartctl_exit_code."
            REPORT_BODY+="  - ❌ Disk $device_path: smartctl failed with exit code $smartctl_exit_code (ERROR!)\n"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            rm -f "$tmp_file" # Clean up temp file
            echo "" # Return empty string for SMART_OUTPUT
            return 1 # Indicate failure
        fi
    fi

    # If successful, read the content and clean up
    smart_output=$(cat "$tmp_file")
    rm -f "$tmp_file" # Clean up temp file
    echo "$smart_output" # Return the SMART output
    return 0 # Indicate success
}

# --- Main Logic ---

main() {
    # Detect if running in an interactive terminal
    IS_INTERACTIVE=0
    if [ -t 1 ]; then
        IS_INTERACTIVE=1
    fi

    # Check if required commands exist
    SMARTCTL_AVAILABLE=true
    if ! command_exists smartctl; then
        if [ "$REQUIRE_SMARTCTL" = "true" ]; then
            log_message "FATAL" "smartctl is not available. Please install smartmontools."
            exit 1
        else
            log_message "WARN" "smartctl is not available. Skipping SMART checks."
            SMARTCTL_AVAILABLE=false
        fi
    fi
    
    if ! command_exists sendmail; then
        log_message "FATAL" "sendmail is not available. Please install a mail transfer agent."
        exit 1
    fi

    log_message "INFO" "Starting hard disk check..."

    # Detect operating system
    OS_TYPE=$(detect_os)
    log_message "INFO" "Detected OS type: $OS_TYPE"

    HOSTNAME=$(hostname)
    REPORT_BODY=""
    WARNING_COUNT=0
    ERROR_COUNT=0

    # 1. Add Filesystem Usage Report
    REPORT_BODY+="=== Filesystem Usage on $HOSTNAME ===\n"
    DF_OUTPUT=$(df -h)
    REPORT_BODY+="$DF_OUTPUT\n\n"

    # 1.1 Check Filesystem Usage for Warnings
    DISK_USAGE_WARNINGS=""
    # Use a process substitution to allow WARNING_COUNT to be updated in the main shell
    while read -r filesystem size used avail capacity mounted_on; do
        # Remove '%' sign and convert to integer
        usage_percent=$(echo "$capacity" | sed 's/%//')
        
        # Skip if not a valid number (e.g., header or special entries)
        if ! [[ "$usage_percent" =~ ^[0-9]+$ ]]; then
            continue
        fi

        if [ "$usage_percent" -ge "$DISK_USAGE_WARNING_THRESHOLD" ]; then
            DISK_USAGE_WARNINGS+="  - ⚠️ Filesystem $mounted_on ($filesystem) is ${usage_percent}% full (WARNING!)\n"
            log_message "WARN" "Filesystem $mounted_on ($filesystem) is ${usage_percent}% full."
        fi
    done <<< "$(echo "$DF_OUTPUT" | tail -n +2)"

    if [ -n "$DISK_USAGE_WARNINGS" ]; then
        REPORT_BODY+="=== Filesystem Usage Warnings ===\n"
        REPORT_BODY+="$DISK_USAGE_WARNINGS"
        REPORT_BODY+="\n" # Blank line
        # Count warnings and add to total WARNING_COUNT
        WARNING_COUNT=$((WARNING_COUNT + $(echo "$DISK_USAGE_WARNINGS" | grep -c "⚠️")))
    fi

    # 2. Detect and Check SMART-capable disks
    log_message "INFO" "Scanning for disks using $OS_TYPE-specific methods..."
    REPORT_BODY+="=== SMART Health Status ===\n"
    
    # Detect disks based on OS
    DISK_LIST=$(detect_disks "$OS_TYPE")
    log_message "INFO" "Detected disks:\n$DISK_LIST"

    if [ -z "$DISK_LIST" ]; then
        REPORT_BODY+="No disks detected on this system.\n"
        log_message "INFO" "No disks detected."
    else
        # Check each disk
        for disk_entry in $DISK_LIST; do
            
            device_path="$disk_entry"
            smartctl_args=""

            # Handle megaraid devices differently
            if echo "$disk_entry" | grep -q 'megaraid'; then
                device_path=$(echo "$disk_entry" | cut -d, -f1)
                smartctl_args="-d $(echo "$disk_entry" | cut -d, -f2-)"
            fi

            # Skip if disk device does not exist
            if [ ! -e "$device_path" ]; then
                log_message "WARN" "Disk device $device_path (from entry '$disk_entry') does not exist, skipping."
                continue
            fi

            log_message "INFO" "Checking disk: $disk_entry"

            # Get SMART information with timeout to prevent hanging
            
            if echo "$disk_entry" | grep -q 'megaraid'; then
                # For MegaRAID devices, use the robust custom timeout function
                SMART_OUTPUT=$(run_smartctl_with_timeout "$device_path" "$smartctl_args")
                # The function handles logging, REPORT_BODY updates, and temp file cleanup
            else
                # For standard SATA/ATA devices, use perl alarm (BSD) or timeout (Linux)
                TMP_SMART_FILE=$(mktemp) # Create temp file for smartctl output
                if [ "$OS_TYPE" = "bsd" ]; then
                    if command_exists perl; then
                        # Use perl alarm for timeout on BSD
                        PERLDB_OPTS="" PERL5OPT="" PERL5DB="" perl -e 'alarm(30); system("smartctl", "-a", @ARGV);' $(echo $smartctl_args) "$device_path" > "$TMP_SMART_FILE" 2>&1;
                    else
                        # Fallback to smartctl without timeout if perl is not available
                        smartctl -a $smartctl_args "$device_path" > "$TMP_SMART_FILE" 2>&1;
                    fi
                else # Linux
                    if command_exists timeout; then
                        # Use timeout command on Linux
                        timeout 30 smartctl -a $smartctl_args "$device_path" > "$TMP_SMART_FILE" 2>&1;
                    else
                        # Fallback to smartctl without timeout if timeout is not available
                        smartctl -a $smartctl_args "$device_path" > "$TMP_SMART_FILE" 2>&1;
                    fi
                fi
                SMART_OUTPUT=$(cat "$TMP_SMART_FILE")
                rm -f "$TMP_SMART_FILE"
            fi

            # Check if SMART is disabled or unavailable
            if printf '%s\n' "$SMART_OUTPUT" | grep -qi "SMART support is: Disabled"; then
                WARNING_COUNT=$((WARNING_COUNT + 1))
                REPORT_BODY+="SMART Status: DISABLED\n\n"
                log_message "WARN" "Disk $disk_entry has SMART disabled."
                continue
            elif ! printf '%s\n' "$SMART_OUTPUT" | grep -qi "SMART support is: Available"; then
                REPORT_BODY+="SMART Status: UNAVAILABLE OR FAILED TO READ\n\n"
                log_message "INFO" "SMART is not available or could not be read on $disk_entry."
                continue
            fi

            log_message "INFO" "Processing SMART data for $disk_entry..."

            # --- 1. Extract All Data Points Safely ---
            MODEL_FAMILY=$(printf '%s\n' "$SMART_OUTPUT" | grep "Model Family:" | cut -d: -f2- | xargs || true)
            DEVICE_MODEL=$(printf '%s\n' "$SMART_OUTPUT" | grep "Device Model:" | cut -d: -f2- | xargs || true)
            SERIAL_NUMBER=$(printf '%s\n' "$SMART_OUTPUT" | grep "Serial Number:" | cut -d: -f2- | xargs || true)
            FIRMWARE_VERSION=$(printf '%s\n' "$SMART_OUTPUT" | grep "Firmware Version:" | cut -d: -f2- | xargs || true)
            USER_CAPACITY=$(printf '%s\n' "$SMART_OUTPUT" | grep "User Capacity:" | cut -d: -f2- | xargs || true)
            ROTATION_RATE=$(printf '%s\n' "$SMART_OUTPUT" | grep "Rotation Rate:" | cut -d: -f2- | xargs || true)
            POWER_CYCLE_COUNT_LINE=$(printf '%s\n' "$SMART_OUTPUT" | grep -E "^\s*12\s+Power_Cycle_Count" || true)
            HEALTH_STATUS=$(printf '%s\n' "$SMART_OUTPUT" | grep "SMART overall-health self-assessment test result:" | awk '{print $NF}' || true)
            POWER_ON_HOURS=$(printf '%s\n' "$SMART_OUTPUT" | grep -E "^\s*9\s+Power_On_Hours" | awk '{print $10}' || true)
            TEMPERATURE_LINE=$(printf '%s\n' "$SMART_OUTPUT" | grep -i "Temperature_Celsius" | head -n 1 || true)
            ATA_ERROR_COUNT_LINE=$(printf '%s\n' "$SMART_OUTPUT" | grep -i "ATA Error Count:" | head -n 1 || true)
            WEAR_LEVELING_COUNT_LINE=$(printf '%s\n' "$SMART_OUTPUT" | grep -E "^\s*177\s+Wear_Leveling_Count" || true)
            TOTAL_LBAS_WRITTEN=$(printf '%s\n' "$SMART_OUTPUT" | grep -E "^\s*241\s+Total_LBAs_Written" | awk '{print $10}' || true)
            LOAD_CYCLE_COUNT=$(printf '%s\n' "$SMART_OUTPUT" | grep -E "^\s*193\s+Load_Cycle_Count" | awk '{print $10}' || true)

            # --- 2. Build Report Section ---
            
            # Infer Disk Type
            DISK_TYPE="Unknown"
            if [ -n "$ROTATION_RATE" ]; then
                if echo "$ROTATION_RATE" | grep -qi "Solid State Device"; then
                    DISK_TYPE="SSD"
                elif echo "$ROTATION_RATE" | grep -qi "rpm"; then
                    DISK_TYPE="HDD"
                fi
            fi

            # Header
            REPORT_BODY+="\n----------------------------------------------------\n"
            REPORT_BODY+="💽 Disk: $disk_entry (Type: $DISK_TYPE)\n"
            REPORT_BODY+="----------------------------------------------------\n\n"

            # Basic Info
            [ -n "$USER_CAPACITY" ] && REPORT_BODY+="Capacity: $USER_CAPACITY\n"
            [ -n "$MODEL_FAMILY" ] && REPORT_BODY+="Model Family: $MODEL_FAMILY\n"
            [ -n "$DEVICE_MODEL" ] && REPORT_BODY+="Device Model: $DEVICE_MODEL\n"
            [ -n "$FIRMWARE_VERSION" ] && REPORT_BODY+="Firmware Version: $FIRMWARE_VERSION\n"
            [ -n "$SERIAL_NUMBER" ] && REPORT_BODY+="Serial Number: $SERIAL_NUMBER\n"
            
            REPORT_BODY+="\n" # Blank line

            # Power Cycle
            [ -n "$POWER_CYCLE_COUNT_LINE" ] && REPORT_BODY+="$POWER_CYCLE_COUNT_LINE\n"

            # Health Status
            if [ "$HEALTH_STATUS" != "PASSED" ]; then
                ERROR_COUNT=$((ERROR_COUNT + 1))
                REPORT_BODY+="!!! CRITICAL: Disk $disk_entry FAILED SMART HEALTH TEST !!!\n"
                log_message "CRITICAL" "Disk $disk_entry FAILED SMART HEALTH TEST ($HEALTH_STATUS)."
            fi

            # Power On Hours
            if [ -n "$POWER_ON_HOURS" ] && [ "$POWER_ON_HOURS" != "0" ]; then
                if echo "$POWER_ON_HOURS" | grep -E "^[0-9]+$" >/dev/null;
                    then
                        years=$(echo "$POWER_ON_HOURS / 8760" | bc -l | awk '{printf "%.1f", $1}')
                        REPORT_BODY+="Power On Hours: $POWER_ON_HOURS (Approx. $years years of operation)\n"
                    else
                        REPORT_BODY+="Power On Hours: $POWER_ON_HOURS\n"
                fi
            fi

            # Temperature
            if [ -n "$TEMPERATURE_LINE" ]; then
                TEMPERATURE=$(printf '%s\n' "$TEMPERATURE_LINE" | awk '{print $10}' | sed 's/[^0-9]*\([0-9]*\).*/\1/')
                if [ -n "$TEMPERATURE" ] && [ "$TEMPERATURE" != "0" ]; then
                    REPORT_BODY+="Temperature: ${TEMPERATURE}°C\n"
                fi
            fi

            # ATA Error Count
            if [ -n "$ATA_ERROR_COUNT_LINE" ]; then
                ATA_ERROR_COUNT=$(printf '%s\n' "$ATA_ERROR_COUNT_LINE" | cut -d: -f2- | xargs)
                if [ -n "$ATA_ERROR_COUNT" ] && [ "$ATA_ERROR_COUNT" != "0" ]; then
                    REPORT_BODY+="ATA Error Count: $ATA_ERROR_COUNT\n"
                fi
            fi

            # SSD/HDD Specific Attributes
            if [ "$DISK_TYPE" = "SSD" ]; then
                if [ -n "$WEAR_LEVELING_COUNT_LINE" ]; then
                    REPORT_BODY+="$WEAR_LEVELING_COUNT_LINE\n"
                    WLC_VALUE=$(echo "$WEAR_LEVELING_COUNT_LINE" | awk '{print $4}')
                    [ -n "$WLC_VALUE" ] && REPORT_BODY+="  -> NAND Health: ${WLC_VALUE}%\n"
                fi
                if [ -n "$TOTAL_LBAS_WRITTEN" ]; then
                    tbw=$(echo "($TOTAL_LBAS_WRITTEN * 512) / 1000000000000" | bc -l | awk '{printf "%.2f", $1}')
                    REPORT_BODY+="Total Data Written: $tbw TB\n"
                fi
            elif [ "$DISK_TYPE" = "HDD" ]; then
                [ -n "$LOAD_CYCLE_COUNT" ] && REPORT_BODY+="Load Cycle Count: $LOAD_CYCLE_COUNT\n"
            fi

            REPORT_BODY+="\n" # Blank line

            # Critical Attributes
            REPORT_BODY+="Critical Attributes:\n"
            for ATTR in $CRITICAL_SMART_ATTRIBUTES; do
                ATTR_LINE=$(printf '%s\n' "$SMART_OUTPUT" | grep -E "^[[:space:]]*[0-9]+[[:space:]]+$ATTR" || true)
                
                ATTR_VALUE="0"
                if [ -n "$ATTR_LINE" ]; then
                    ATTR_VALUE=$(printf '%s\n' "$ATTR_LINE" | awk '{print $10}')
                fi

                if [ "$ATTR_VALUE" -gt 0 ]; then
                    WARNING_COUNT=$((WARNING_COUNT + 1))
                    REPORT_BODY+="  - ⚠️ $ATTR: $ATTR_VALUE (WARNING!)\n"
                    log_message "WARN" "Disk $disk_entry - Attribute '$ATTR' has value $ATTR_VALUE."
                else
                    REPORT_BODY+="  - ✅ $ATTR: $ATTR_VALUE (OK)\n"
                fi
            done
            REPORT_BODY+="\n"
            
            log_message "Completed processing $disk_entry"
        done
    fi

    # 3. Finalize and Send Report
    FINAL_SUBJECT="$EMAIL_SUBJECT_PREFIX on $HOSTNAME - $(date '+%Y-%m-%d')"

    REPORT_BODY+="\n=== Summary ===\n"
    if [ "$ERROR_COUNT" -gt 0 ]; then
        FINAL_SUBJECT+=" - CRITICAL ($ERROR_COUNT Errors)"
        REPORT_BODY+="CRITICAL: Found $ERROR_COUNT disk(s) with FAILED status and $WARNING_COUNT other warning(s).\n"
    elif [ "$WARNING_COUNT" -gt 0 ]; then
        FINAL_SUBJECT+=" - WARNING ($WARNING_COUNT Warnings)"
        REPORT_BODY+="WARNING: Found $WARNING_COUNT warning(s) on disks (e.g., high attribute values or SMART disabled).\n"
    else
        FINAL_SUBJECT+=" - OK"
        REPORT_BODY+="OK: All checked disks appear to be in good condition.\n"
    fi

    send_email_report "$FINAL_SUBJECT" "$REPORT_BODY"

    log_message "INFO" "Hard disk check completed."
}

# --- Script Execution ---
main "$@"
