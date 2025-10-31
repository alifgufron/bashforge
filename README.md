# BashForge Script Collection

This repository contains a collection of useful Bash scripts for various administrative tasks. Each script is designed to be robust, configurable, and easy to use.

## Tools Overview

Below is a summary of the tools available in this collection.

### 1. [BackupInflux](./BackupInflux/)

A powerful script for backing up and restoring InfluxDB databases.

- **Features**: Automated backups, compression, retention policies, and email notifications.
- **Details**: See the [BackupInflux README](./BackupInflux/README.md) for full documentation.

### 2. [BackupMysql](./BackupMysql/)

A robust and highly configurable script for backing up MySQL databases.

- **Features**: Flexible backup strategies (per database or per job), configurable compression (enabled/disabled), customizable `mysqldump` options for compatibility, intelligent retention policies, output validation for dump integrity, and detailed email notifications (including log file path on failure).
- **Details**: See the [BackupMysql README](./BackupMysql/README.md) for full documentation. 

### 3. [SendMail](./SendMail/)

A simple but effective script for sending emails from the command line.

- **Features**: Supports attachments, inline images, and emojis without requiring extra libraries.
- **Details**: See the [SendMail README](./SendMail/README.md) for usage examples.

### 4. [telegram-cli](./telegram-cli/)

A command-line interface to send messages and files through the Telegram Bot API.

- **Features**: Send text, photos, or documents. Can be easily integrated into other scripts by piping output.
- **Details**: See the [telegram-cli README](./telegram-cli/) for setup and usage instructions.

### 5. [DiskMon](./DiskMon/)

A comprehensive script for monitoring hard disk health and filesystem usage.

- **Features**: Monitors SMART attributes for HDDs/SSDs, detects critical health issues, provides filesystem usage reports, and sends email notifications. Supports both Linux and BSD, with robust timeout mechanisms for `smartctl` and conditional dependency handling.
- **Details**: See the [DiskMon README](./DiskMon/README.md) for full documentation.
