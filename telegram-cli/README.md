# telegram-cli

A simple, robust Bash script to send messages, photos, and documents via the Telegram Bot API.

It supports command-line arguments, reading from `stdin`, and user-specific configuration files.

## Features

- Send text messages, photos, and documents.
- Emojis and HTML formatting supported in messages.
- Read message content from `stdin` for easy piping with other commands.
- Silent notifications.
- External configuration files (system-wide and per-user).

## Installation

For system-wide use, place the script in a directory included in your system's `PATH`.

```bash
# Copy the script to /usr/local/bin
sudo cp telegram-cli /usr/local/bin/

# Make it executable
sudo chmod +x /usr/local/bin/telegram-cli
```

## Configuration

The script loads configuration in the following order of priority:

1.  **Per-User Configuration (Recommended):**
    Create a file at `~/.config/telegram-cli.conf`. This allows each user on the system to have their own settings.

    *Example for user `foo`*: The file would be `/home/foo/.config/telegram-cli.conf`.
    *Example for user `bar`*: The file would be `/home/bar/.config/telegram-cli.conf`.

2.  **Global Configuration (Fallback):**
    Create a file at the same location as the script (e.g., `/usr/local/bin/telegram-cli.conf`). This is used if a per-user config is not found.


**Configuration File Content:**

Create the `.conf` file and add the following content, replacing the placeholder values with your actual credentials.

```ini
# ~/.config/telegram-cli.conf

# Get your Bot Token from Telegram's BotFather
BOT_TOKEN="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"

# Default Chat ID to send messages to (can be a user, group, or channel ID)
GROUP_ID="-1001234567890"
```

## Usage

**Sending a simple text message:**
```bash
telegram-cli --message "✅ System backup completed successfully."
```

**Sending a photo with a caption:**
```bash
telegram-cli --message "CPU usage graph" --photo "/path/to/cpu_usage.png"
```

**Sending a document:**
```bash
telegram-cli --message "Monthly report attached" --document "/path/to/report.zip"
```

**Piping command output to a message:**
```bash
# Send a list of running processes
ps aux | telegram-cli

# Send the last 10 lines of a log file
tail -n 10 /var/log/syslog | telegram-cli
```

**Sending a message silently:**
```bash
telegram-cli --message "Minor update applied." --silent
```

**Overriding the default Chat ID:**
```bash
telegram-cli --to "-100987654321" --message "This message is for a different group."
```
