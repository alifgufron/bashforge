# InfluxDB Backup Script

## Description
This Bash script provides a robust and flexible solution for backing up InfluxDB databases. It is designed to run automatically (e.g., via cron) or manually, featuring validation, detailed email notifications, and retention management.

## Key Features
-   **Flexible Backup:** Automatically backs up all databases (with exclusions) or specific databases.
-   **Unique File Naming:** Each backup file is given a unique ID (`db_name-YYYY-MM-DD_UNIQUEID.tar.ext` or `db_name-YYYY-MM-DD-UNIQUEID/` for uncompressed) to support multiple backups within a day.
-   **Organized Directory Structure:** Backups are stored in a `HOST/YEAR/` structure for easy organization.
-   **Efficient Compression:** Uses `tar` and your chosen compression tool (`gzip`, `bzip2`, `xz`, `zstd`).
-   **Retention Management:** Automatically deletes old backups based on a configured count, sorted by modification time. Set `RETENTION_COUNT=0` to disable cleanup entirely.
-   **Configuration Validation:** Checks critical settings at startup to prevent failures.
-   **Dependency Checks:** Ensures all necessary tools are available.
-   **Detailed Email Notifications:** Sends comprehensive backup status reports (start, success, failure) with file sizes, locations, and lists of old backups.
-   **Flexible Restore Functionality:** Allows easy selection and restoration of backups, supporting **both compressed archive files and uncompressed backup directories**.
-   **Execution Mode Detection:** Adjusts console output when run interactively or via cron (INFO messages only in interactive console, ERROR/FATAL always).
-   **Lock File:** Prevents simultaneous script execution.
-   **Secure Temporary Directory:** Temporary directories for InfluxDB dumps are created within `PATH_BCKP` and automatically cleaned up.

## Prerequisites
-   Bash shell
-   Accessible InfluxDB server
-   `influx` and `influxd` CLI tools installed and available in PATH
-   `sendmail` configured for email delivery
-   Your chosen compression tool (`gzip`, `bzip2`, `xz`, `zstd`)
-   Standard Linux/BSD utilities: `du`, `df`, `find`, `rm`, `tar`, `sort`, `cut`, `stat`, `basename`, `mktemp`, `base64`, `cp` (for uncompressed restore)

## Installation & Setup
1.  **Clone Repository:** (If the script is in a repository)
    ```bash
    git clone https://github.com/your-repo/BashScript4life.git
    cd BashScript4life/BackupInflux
    ```
2.  **Create Configuration File:** Copy the sample configuration file:
    ```bash
    cp backup-influx.conf.sample backup-influx.conf
    ```
3.  **Edit Configuration:** Open `backup-influx.conf` with your favorite text editor and adjust parameters according to your InfluxDB environment. Ensure `PATH_BCKP` is a valid and writable directory.
4.  **Set Permissions:** Make sure the script is executable:
    ```bash
    chmod +x backup-influx.sh
    ```

## Configuration (`backup-influx.conf`)
Some important parameters you need to adjust:
-   `HOST`, `BACKUP_PORT`, `QUERY_PORT`: InfluxDB connection details.
-   `INFLUX_USER`, `INFLUX_PASS`: InfluxDB credentials (if required).
-   `BACKUP_ALL_DATABASES`: `yes` to back up all, `no` for specific databases.
-   `DATABASE`: Array of specific databases if `BACKUP_ALL_DATABASES="no"`.
-   `EXCLUDE_DATABASES`: Array of databases to exclude if `BACKUP_ALL_DATABASES="yes"`.
-   `PATH_BCKP`: **Absolute directory** for storing backup files.
-   `COMPRESS_BACKUP`: `yes` to compress, `no` to not compress.
-   `COMPRESSION_TYPE`: `gzip`, `bzip2`, `xz`, or `zstd`.
-   `RETENTION_COUNT`: Number of backups to keep (0 to disable cleanup).
-   `MIN_DISK_SPACE_GB`: Minimum required free disk space.
-   `MAIL_TO`, `MAIL_FROM`, `NOTIFY_ON_START`: Email notification settings.

## Usage

### 1. Performing a Backup
Run the script by providing your configuration file:
```bash
./backup-influx.sh backup-influx.conf
```
If you do not provide a configuration file name, the script will look for `backup-influx.conf` by default.

### 2. Performing a Restore
To restore a database from a backup:
```bash
./backup-influx.sh restore backup-influx.conf
```
The script will display a list of available backups (both compressed files and uncompressed directories). You will be prompted to select a backup and provide a new target database name.

## Logging
All script activities are logged to `/var/log/custom/influx_dump_HOST.log` (for backups) or `/var/log/custom/influx_restore_HOST.log` (for restores).

## Email Notifications
The script will send email notifications to the configured `MAIL_TO` for the initial status and a final report (success/failure) of the backup process.

---