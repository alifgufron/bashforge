# Hard Disk Health Monitor Script


### Description

This is a robust and versatile Bash script, now named `DiskMon`, for monitoring the health of hard disks (HDD, SSD, NVMe) using `smartctl`. It is designed to be run automatically as a cron job or manually with command-line arguments, providing detailed email reports on disk status, critical SMART attributes, and overall system health.

The script features enhanced compatibility for both Linux and BSD systems, with improved automatic OS and device detection methods. It now intelligently handles various disk controller types including SATA (atacam/sat), NVMe, and MegaRAID, ensuring correct `smartctl` command invocation and robust parsing of their diverse outputs. It also includes retry mechanisms for `smartctl` commands to prevent script stoppage on intermittent errors.

### Key Features

- **Command-Line Argument Support**: All key configuration parameters can now be overridden via command-line arguments, offering greater flexibility for execution and integration.
- **Cross-Platform Compatibility**: Automatically detects the OS (Linux or BSD) and uses the appropriate commands for disk discovery. Now includes robust detection for SATA, NVMe, and MegaRAID devices.
- **Comprehensive SMART Reporting**: Extracts and reports on essential disk health indicators, with enhanced parsing for NVMe-specific attributes:
    - Overall health status (`PASSED`, `FAILED`).
    - Basic disk identity (Model, Serial Number, Firmware, Capacity).
    - Disk type detection (HDD, SATA SSD, NVMe SSD).
    - Disk interface (SATA, PCIe NVMe, SAS/RAID).
    - Disk form factor (M.2, 2.5 inches, 3.5 inches).
    - Disk age and usage (`Power On Hours`, `Power Cycles`).
    - Disk temperature.
    - Total Data Written (TBW) for all SSD types.
    - Data Units Read/Written for NVMe.
    - Unsafe Shutdowns and Controller Busy Time for NVMe.
- **Critical Attribute Monitoring**: Specifically tracks critical SMART attributes that are strong predictors of disk failure, with tailored checks for NVMe devices (e.g., Media and Data Integrity Errors, Percentage Used).
- **SSD & HDD Specific Metrics**: 
    - For **SSDs** (SATA & NVMe), it reports NAND health (derived from Wear Leveling Count or Percentage Used) and calculates total data written (`TBW`).
    - For **HDDs**, it reports `Load Cycle Count`.
- **Filesystem Usage**: Includes a `df -h` report to give a quick overview of filesystem capacity.
- **Filesystem Usage Warnings**: Generates warnings if any mounted filesystem exceeds a configurable usage threshold (e.g., 90% full), with an option to ignore specific filesystems (e.g., `devfs`, `tmpfs`).
- **Self-Contained Email Reports**: Generates and sends clear, well-formatted email reports without external script dependencies. The subject line provides an at-a-glance status (`✅ OK`, `⚠️ WARNING`, or `❌ CRITICAL`) with proper emoji display.
- **Robust and Safe**: 
    - Uses `set -euo pipefail` for strict error checking.
    - Ensures the shell environment is UTF-8 aware by explicitly setting `LANG` and `LC_ALL`.
    - All data extraction commands are designed to be fail-safe to prevent the script from exiting unexpectedly.
    - Employs a sophisticated, conditional timeout mechanism for `smartctl` calls to prevent the script from hanging, adapting to different disk controller types (e.g., SATA, MegaRAID). Includes a retry mechanism for `smartctl` commands to handle intermittent failures.
    - Allows `smartctl` checks to be optional, enabling `df -h` reports even if `smartctl` is unavailable.

### Prerequisites

- A POSIX-compliant shell (e.g., `bash`, `sh`).
- `smartmontools` (`smartctl` command) must be installed (can be optional, see `REQUIRE_SMARTCTL` in configuration).
- A configured Mail Transfer Agent (MTA) that provides the `sendmail` command.
- `perl` (optional, but recommended on BSD for reliable command timeouts for standard SATA/ATA disks).
- `bc` for floating-point calculations (used for TBW and age in years).

### Installation & Setup

1.  **Place the Script**: Copy `DiskMon` to a suitable location, such as `/usr/local/bin/` or a custom scripts directory.

2.  **Set Permissions**: Make the script executable:
    ```bash
    chmod +x DiskMon
    ```

3.  **Configure the Script**: Open `DiskMon` and edit the configuration variables at the top of the file. Note that these can also be overridden by command-line arguments:
    - `REPORT_EMAIL_TO`: The email address to send reports to. Can be overridden by `--mail-to`.
    - `REPORT_EMAIL_FROM`: The "From" address for the email report. Can be overridden by `--mail-from`.
    - `LOG_FILE`: The path to the log file (ensure the directory is writable).
    - `DISK_USAGE_WARNING_THRESHOLD`: The percentage of disk usage (e.g., 90) at which a warning will be triggered. Can be overridden by `--disk-threshold`.
    - `REQUIRE_SMARTCTL`: Set to `true` (default) if `smartctl` is a mandatory dependency. Set to `false` if you want the script to proceed with only `df -h` checks when `smartctl` is not available. Can be overridden by `--smartctl`.
    - `IGNORE_FILESYSTEMS`: A space-separated list of filesystem types or mount points to ignore from usage checks (e.g., `devfs tmpfs`).

### Usage

To run the script manually, execute it with the required arguments:

```bash
./DiskMon --mail-to admin@example.net --disk-threshold 90 --smartctl true
```

If no arguments are provided, the script will display its usage information and exit.

For automated monitoring, it is highly recommended to run the script as a cron job. For example, to run the check daily at 2 AM, add the following to your crontab (as root):

```crontab
0 2 * * * /path/to/your/DiskMon --mail-to admin@example.net --disk-threshold 90
```

To view all available options:
```bash
./DiskMon --help
```

### Sample Email Report

The email report is formatted for readability and provides a quick summary followed by detailed information for each disk.

```
Subject: ⚠️ [Disk Monitoring] on your-server - 2025-10-24 - WARNING (2 Warnings)

=== Filesystem Usage on your-server ===
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1        28G   12G   15G  45% /
devtmpfs        3.9G     0  3.9G   0% /dev
...

=== Filesystem Usage Warnings ===
  - ⚠️ Filesystem /mnt/data (/dev/sdb1) is 92% full (WARNING!)

=== SMART Health Status ===

----------------------------------------------------
💽 Disk: /dev/ada0 (Type: SATA SSD, Interface: SATA, FormFactor: M.2)
----------------------------------------------------

Device Model: Samsung SSD 860 EVO M.2 250GB
Firmware Version: RVT24B6Q
Serial Number: S413NS0R220757L
Capacity: 250,059,350,016 bytes [250 GB]
Health: PASSED
Temperature: 35°C
Power On Hours: 38518 (Approx. 4.4 years of operation)
Total Data Written: 4.23 TB
Power Cycles: 140 (Normal)

----------------------------------------
✅ No SMART errors logged

Critical Attributes:
  - ✅ Reallocated_Sector_Ct: 0 (OK)
  - ✅ Current_Pending_Sector_Ct: 0 (OK)
  - ✅ Offline_Uncorrectable: 0 (OK)
  - ✅ UDMA_CRC_Error_Count: 0 (OK)

----------------------------------------------------
💽 Disk: /dev/nvme0 (Type: NVMe SSD, Interface: PCIe NVMe, FormFactor: M.2/U.2)
----------------------------------------------------

Device Model: Samsung SSD 980 PRO 250GB
Firmware Version: 4B2QGXA7
Serial Number: S5GZNJ0RC17077B
Capacity: 250,059,350,016 bytes [250 GB]
Health: PASSED
Temperature: 30°C
Power On Hours: 31539 (Approx. 3.6 years of operation)
Total Data Written: 31.6 TB
Power Cycles: 21 (Normal)
NVMe Version: 1.3
Percentage Used: 95%
  -> NAND Health: 5%
Data Units Written: 31.6 TB
Data Units Read: 20.8 TB
Unsafe Shutdowns: 15
Controller Busy Time: 1436 minutes

----------------------------------------
✅ No SMART errors logged

Critical Attributes (NVMe):
  - Media and Data Integrity Errors: 0 (OK)
  - Percentage Used: 95% (WARNING!)

----------------------------------------------------
💽 Disk: /dev/sdb (Type: HDD, Interface: SATA/SAS, FormFactor: 3.5 inches)
----------------------------------------------------

Device Model: ST4000VN008-2DR166
Firmware Version: SC60
Serial Number: ZGY8N5H8
Capacity: 4,000,787,030,016 bytes [4.00 TB]
Health: PASSED
Temperature: 28°C
Power On Hours: 27746 (Approx. 3.2 years of operation)
Total Data Written: 2.15 TB
Power Cycles: 54 (Normal)
Load Cycle Count: 8647

----------------------------------------
⚠️ SMART Errors or Selftests present (see details)

Critical Attributes:
  - ⚠️ Reallocated_Sector_Ct: 275 (WARNING!)
  - ✅ Current_Pending_Sector_Ct: 0 (OK)
  - ✅ Offline_Uncorrectable: 0 (OK)
  - ✅ UDMA_CRC_Error_Count: 0 (OK)


=== Summary ===
WARNING: Found 2 warning(s) on disks (e.g., high attribute values or SMART disabled).
```
