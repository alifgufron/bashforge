# 📬 SendMail.sh (v1.1)

A simple Bash script to send emails via `sendmail` with support for **emoji**, **inline images**, and **attachments**, without needing extra libraries.

---

## ⚙️ Key Features

✅ Send emails directly from the CLI (no mail client needed).
✅ Supports **emoji/emoticons** in the *subject* and *body*.
✅ Supports **inline images** (images are displayed in the email body).
✅ Supports **attachments** (files are attached).
✅ All fields use **UTF-8 encoding**.
✅ No extra dependencies (just `sendmail`, `base64`, and `file`).

---

## 💻 Basic Usage

```bash
./SendMail.sh   --to "user@example.com"   --subject "Daily Report 🧾"   --body "Backup process successful 🚀\n\nRegards,\nServer01"
```

---

## 🖼️ Send with an Inline Image

```bash
./SendMail.sh   --to "user@example.com"   --subject "Server Status 🖥️"   --body "All systems running normally ✅"   --image "logo.png"
```

> 📎 The image will be included in the email and can appear in the email body (depending on the email client).

---

## 📎 Send with an Attachment

```bash
./SendMail.sh   --to "user@example.com"   --subject "Daily Log 🧾"   --body "Here is the daily system log:\n\nRegards,\nServer01"   --attach "/var/log/syslog.txt"
```

---

## 🧩 Send a Complete Email (Inline Image + Attachment)

```bash
./SendMail.sh   --to "user@example.com"   --subject "Backup Report 🗂️"   --body "The backup process has finished 🚀\n\nRegards,\nServer01"   --image "/opt/icons/server.png"   --attach "/var/log/backup.log"
```

---

## 🧠 Supported Arguments

| Argument    | Description |
|-------------|-------------|
| `--to`      | Recipient's email address |
| `--from`    | Sender's email address (defaults to `monitor@hibridge.net`) |
| `--subject` | Email subject (supports emoji) |
| `--body`    | Text message content (supports emoji and newlines `\n`) |
| `--image`   | Include an inline image (can be used multiple times) |
| `--attach`  | Attach a file (can be used multiple times) |

---

## 🧾 Example Email Output

```
Backup Report 🧾  
From: noreply@example.net  
To: user@example.com  

Backup process successful 🚀  

Regards,  
Server01
```

---

## 📦 System Requirements

- `/usr/sbin/sendmail`
- `base64`
- `file`
- `bash` or `sh` shell