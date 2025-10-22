# Hard Disk Health Monitor Script (harddisk_monitor.sh)

## Version 2.0

### Description

This is a robust and versatile Bash script for monitoring the health of hard disks (both HDD and SSD) using `smartctl`. It is designed to be run automatically as a cron job, providing detailed email reports on disk status, critical SMART attributes, and overall system health.

The script is self-contained, POSIX-compliant, and includes OS detection to ensure compatibility with both Linux and BSD-based systems.

### Key Features

- **Cross-Platform Compatibility**: Automatically detects the OS (Linux or BSD) and uses the appropriate commands for disk discovery (`lsblk` on Linux, `camcontrol` on BSD).
- **Comprehensive SMART Reporting**: Extracts and reports on essential disk health indicators:
    - Overall health status (`PASSED`, `FAILED`).
    - Basic disk identity (Model, Serial Number, Firmware, Capacity).
    - Disk type detection (SSD or HDD).
    - Disk age and usage (`Power_On_Hours`, `Power_Cycle_Count`).
    - Disk temperature.
    - ATA Error Count.
- **Critical Attribute Monitoring**: Specifically tracks critical SMART attributes that are strong predictors of disk failure:
    - `Reallocated_Sector_Ct`
    - `Current_Pending_Sector_Ct`
    - `Offline_Uncorrectable`
    - `UDMA_CRC_Error_Count`
- **SSD & HDD Specific Metrics**: 
    - For **SSDs**, it reports the full `Wear_Leveling_Count` line with a human-readable interpretation of the NAND health percentage, and calculates the total data written (`TBW`).
    - For **HDDs**, it reports the mechanical `Load_Cycle_Count`.
- **Filesystem Usage**: Includes a `df -h` report to give a quick overview of filesystem capacity.
- **Filesystem Usage Warnings**: Generates warnings if any mounted filesystem exceeds a configurable usage threshold (e.g., 90% full).
- **Self-Contained Email Reports**: Generates and sends clear, well-formatted email reports without external script dependencies. The subject line provides an at-a-glance status (`OK`, `WARNING`, or `CRITICAL`).
- **Robust and Safe**: 
    - Uses `set -euo pipefail` for strict error checking.
    - All data extraction commands are designed to be fail-safe to prevent the script from exiting unexpectedly.
    - Employs a sophisticated, conditional timeout mechanism for `smartctl` calls to prevent the script from hanging, adapting to different disk controller types (e.g., SATA, MegaRAID).
    - Allows `smartctl` checks to be optional, enabling `df -h` reports even if `smartctl` is unavailable.

### Prerequisites

- A POSIX-compliant shell (e.g., `bash`, `sh`).
- `smartmontools` (`smartctl` command) must be installed (can be optional, see `REQUIRE_SMARTCTL` in configuration).
- A configured Mail Transfer Agent (MTA) that provides the `sendmail` command.
- `perl` (optional, but recommended on BSD for reliable command timeouts, especially for SATA/ATA disks).
- `bc` for floating-point calculations (used for TBW and age in years).

### Installation & Setup

1.  **Place the Script**: Copy `harddisk_monitor.sh` to a suitable location, such as `/usr/local/bin/` or a custom scripts directory.

2.  **Set Permissions**: Make the script executable:
    ```bash
    chmod +x harddisk_monitor.sh
    ```

3.  **Configure the Script**: Open `harddisk_monitor.sh` and edit the configuration variables at the top of the file:
    - `REPORT_EMAIL_TO`: The email address to send reports to.
    - `REPORT_EMAIL_FROM`: The "From" address for the email report.
    - `LOG_FILE`: The path to the log file (ensure the directory is writable).
- `DISK_USAGE_WARNING_THRESHOLD`: The percentage of disk usage (e.g., 90) at which a warning will be triggered.
- `REQUIRE_SMARTCTL`: Set to `true` (default) if `smartctl` is a mandatory dependency. Set to `false` if you want the script to proceed with only `df -h` checks when `smartctl` is not available.

### Usage

To run the script manually, simply execute it:

```bash
./harddisk_monitor.sh
```

For automated monitoring, it is highly recommended to run the script as a cron job. For example, to run the check daily at 2 AM, add the following to your crontab (as root):

```crontab
0 2 * * * /path/to/your/harddisk_monitor.sh
```

### Sample Email Report

The email report is formatted for readability and provides a quick summary followed by detailed information for each disk.

```
Subject: [DiskMon Report] on your-server - 2025-10-22 - WARNING (1 Warnings)

=== Filesystem Usage on your-server ===
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        28G   12G   15G  45% /
devtmpfs        3.9G     0  3.9G   0% /dev
...

=== Filesystem Usage Warnings ===
  - ⚠️ Filesystem /mnt/data (/dev/sdb1) is 92% full (WARNING!)

=== SMART Health Status ===

----------------------------------------------------
💽 Disk: /dev/sda (Type: SSD)
----------------------------------------------------

Capacity: 256,060,514,304 bytes [256 GB]
Model Family: Samsung based SSDs
Device Model: Samsung SSD 860 PRO
Firmware Version: RVM02B6Q
Serial Number: S3Z7NX0K123456

Power Cycle Count: 12 Power_Cycle_Count       0x0032   100   100   000    Old_age   Always       -       1500
SMART Health Status: ✅ PASSED
Power On Hours: 15000 (Approx. 1.7 years of operation)
Temperature: 35°C
177 Wear_Leveling_Count     0x0013   099   099   000    Pre-fail  Always       -       7
  -> NAND Health: 99%
Total Data Written: 25.60 TB

Critical Attributes:
  - ✅ Reallocated_Sector_Ct: 0 (OK)
  - ✅ Current_Pending_Sector_Ct: 0 (OK)
  - ✅ Offline_Uncorrectable: 0 (OK)
  - ✅ UDMA_CRC_Error_Count: 0 (OK)

----------------------------------------------------
💽 Disk: /dev/sdb (Type: HDD)
----------------------------------------------------

Capacity: 4,000,787,030,016 bytes [4.00 TB]
Model Family: Seagate IronWolf
Device Model: ST4000VN008-2DR166
Firmware Version: SC60
Serial Number: ZGY8N5H8

Power Cycle Count: 12 Power_Cycle_Count       0x0032   100   100   020    Old_age   Always       -       54
SMART Health Status: ✅ PASSED
Power On Hours: 27746 (Approx. 3.2 years of operation)
Temperature: 28°C
Load Cycle Count: 8647

Critical Attributes:
  - ⚠️ Reallocated_Sector_Ct: 275 (WARNING!)
  - ✅ Current_Pending_Sector_Ct: 0 (OK)
  - ✅ Offline_Uncorrectable: 0 (OK)
  - ✅ UDMA_CRC_Error_Count: 0 (OK)


=== Summary ===
WARNING: Found 1 warning(s) on disks (e.g., high attribute values or SMART disabled).
```
