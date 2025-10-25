# MySQL Backup Script

## Description
This Bash script provides a robust and flexible solution for backing up MySQL databases. It is designed to run automatically (e.g., via cron) or manually, featuring validation, detailed email notifications, and advanced retention management.

## Key Features
-   **Flexible Backup:** Automatically backs up all databases (with exclusions) or specific databases.
-   **Flexible Compression:** Option to enable or disable compression entirely (`COMPRESSION_ENABLED`).
-   **Configurable Compression Strategy:** If compression is enabled, choose between:
    -   `per_database`: Each database is compressed into its own archive (`DBNAME_UNIQUEID.tar.ext`).
    -   `per_job`: All successful database dumps from a single run are combined into one archive (`DD_UNIQUEID.tar.ext`).
-   **Unique File Naming:** Option to append a unique ID to backup filenames (`UNIQUE_ID_ENABLED="yes"`) to support multiple backups within a day. If `UNIQUE_ID_ENABLED="no"`, backup files for the same day will be overwritten.
-   **Retention Management:** Automatically deletes old backups based on a configured count, sorted by modification time. Set `RETENTION_COUNT=0` to disable cleanup entirely. **Note:** If `UNIQUE_ID_ENABLED="no"`, `RETENTION_COUNT` is ignored, and no old backups will be cleaned up.
-   **Detailed Email Notifications:** Sends comprehensive backup status reports (start, success, failure) with file sizes, locations, lists of old backups, and a list of **deleted old backups** (conditional on `UNIQUE_ID_ENABLED`).
-   **Execution Mode Detection:** Adjusts console output when run interactively or via cron (INFO messages only in interactive console, ERROR/FATAL always).
-   **Lock File:** Prevents simultaneous script execution.
-   **Secure Temporary Directory:** Temporary directories for SQL dumps are created within `BACKUP_PATH` and automatically cleaned up.
-   **Consistent Backups:** Uses `--single-transaction` for InnoDB tables to ensure data consistency without locking.

## Prerequisites
-   Bash shell
-   Accessible MySQL server
-   `mysqldump` and `mysql` CLI tools installed and available in PATH
-   `sendmail` configured for email delivery
-   Your chosen compression tool (`gzip`, `bzip2`, `xz`)
-   Standard Linux/BSD utilities: `du`, `df`, `find`, `rm`, `tar`, `sort`, `cut`, `stat`, `basename`, `mktemp`, `base64`

## Installation & Setup
1.  **Clone Repository:** (If the script is in a repository)
    ```bash
    git clone https://github.com/your-repo/BashScript4life.git
    cd BashScript4life/BackupMysql
    ```
2.  **Create Configuration File:** Copy the sample configuration file:
    ```bash
    cp mysql-backup.conf.sample mysql-backup.conf
    ```
3.  **Edit Configuration:** Open `mysql-backup.conf` with your favorite text editor and adjust parameters according to your MySQL environment. Ensure `BACKUP_PATH` is a valid and writable directory.
4.  **Set Permissions:** Make sure the script is executable:
    ```bash
    chmod +x BackupMysql.sh
    ```

## Configuration (`mysql-backup.conf`)
Some important parameters you need to adjust:
-   `MYSQL_USER`, `MYSQL_PASS`, `MYSQL_HOST`: MySQL connection details.
-   `BACKUP_ALL_DATABASES`: `yes` to back up all, `no` for specific databases.
-   `DATABASES`: Array of specific databases if `BACKUP_ALL_DATABASES="no"`.
-   `EXCLUDE_DATABASES`: Array of databases to exclude if `BACKUP_ALL_DATABASES="yes"`.
-   `BACKUP_PATH`: **Absolute directory** for storing backup files.
-   `COMPRESSION_ENABLED`: `yes` to enable compression, `no` to store raw `.sql` files.
-   `COMPRESSION_STRATEGY`: `per_database` or `per_job`. **Only relevant if `COMPRESSION_ENABLED="yes"`.**
-   `COMPRESSION_TYPE`: `gzip`, `bzip2`, or `xz`. **Only relevant if `COMPRESSION_ENABLED="yes"`.**
-   `UNIQUE_ID_ENABLED`: `yes` to append unique IDs to filenames (e.g., `db_UNIQUEID.sql` or `db_UNIQUEID.tar.gz`), `no` otherwise. If `no`, backup files for the same day will be overwritten.
-   `RETENTION_COUNT`: Number of backups to keep (0 to disable cleanup). **Note:** If `UNIQUE_ID_ENABLED="no"`, `RETENTION_COUNT` is ignored, and no old backups will be cleaned up.
-   `MIN_DISK_SPACE_GB`: Minimum required free disk space.
-   `MAIL_TO`, `MAIL_FROM`, `NOTIFY_ON_START`: Email notification settings.

## Usage

### Performing a Backup
Run the script by providing your configuration file:
```bash
./BackupMysql.sh mysql-backup.conf
```
If you do not provide a configuration file name, the script will look for `mysql-backup.conf` by default.

## Logging
All script activities are logged to `/var/log/custom/mysql_dump_HOST.log`.

## Email Notifications
The script will send email notifications to the configured `MAIL_TO` for the initial status and a final report (success/failure) of the backup process.

---
