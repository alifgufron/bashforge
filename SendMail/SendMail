#!/usr/bin/env bash
#
# sendmail_mime_image.sh v1.1
# Simple Bash Sendmail Script with UTF-8 emoji, MIME detection, and attachments
#
# Usage:
# ./sendmail_mime_image.sh \
#   --to user@x --from me@x \
#   --subject "Notif 🧾" \
#   --body "Backup OK 🚀" \
#   [--image logo.png] \
#   [--attach file1.txt,file2.log] \
#   [--log /var/log/sendmail.log]

set -euo pipefail

VERSION="1.1"
BOUNDARY="===BOUNDARY_$(date +%s)_$$==="

# --- Default vars ---
TO=""; FROM=""; SUBJECT=""; BODY=""
IMAGE=""; ATTACH=""; LOG_FILE=""

# --- Show help ---
show_help() {
cat <<EOF
Usage: $0 --to <email> --from <email> --subject <text> --body <text> [options]

Options:
  --image <file>           Attach image (auto MIME type)
  --attach <f1,f2,...>     One or more attachments (comma separated)
  --log <file>             Save log of sent emails
  --help                   Show this help
  --version                Show version
EOF
}

# --- Parse CLI ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TO="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --subject) SUBJECT="$2"; shift 2 ;;
    --body) BODY="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --attach) ATTACH="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --help) show_help; exit 0 ;;
    --version) echo "$0 v$VERSION"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$TO" || -z "$FROM" || -z "$SUBJECT" || -z "$BODY" ]]; then
  show_help
  exit 1
fi

# --- Encode Subject (UTF-8 / emoji support) ---
ENCODED_SUBJECT="=?UTF-8?B?$(echo -n "$SUBJECT" | base64)?="

# --- Temp mail file ---
MAILFILE=$(mktemp)

# --- Function: encode file ---
encode_file() {
  FILE="$1"
  MIME=$(file --mime-type -b "$FILE" 2>/dev/null || echo "application/octet-stream")
  echo "--${BOUNDARY}"
  echo "Content-Type: ${MIME}; name=\"$(basename "$FILE")\""
  echo "Content-Transfer-Encoding: base64"
  echo "Content-Disposition: attachment; filename=\"$(basename "$FILE")\""
  echo
  base64 "$FILE" | fold -w 76
  echo
}

# --- Build email ---
{
  echo "From: ${FROM}"
  echo "To: ${TO}"
  echo "Subject: ${ENCODED_SUBJECT}"
  echo "MIME-Version: 1.0"
  echo "Content-Type: multipart/mixed; boundary=\"${BOUNDARY}\""
  echo
  echo "--${BOUNDARY}"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo "Content-Transfer-Encoding: 8bit"
  echo
  echo -e "$BODY"
  echo

  # --- Image attachment (if any) ---
  if [[ -n "$IMAGE" && -f "$IMAGE" ]]; then
    encode_file "$IMAGE"
  fi

  # --- Multiple attachments (comma separated) ---
  if [[ -n "$ATTACH" ]]; then
    IFS=',' read -ra FILES <<< "$ATTACH"
    for f in "${FILES[@]}"; do
      [[ -f "$f" ]] && encode_file "$f" || echo "⚠️ Skipping missing file: $f" >&2
    done
  fi

  echo "--${BOUNDARY}--"
} > "$MAILFILE"

# --- Send email ---
if sendmail -t < "$MAILFILE"; then
  echo "✅ Email sent to $TO"
  [[ -n "$LOG_FILE" ]] && echo "$(date '+%F %T') Sent email to $TO subj=\"$SUBJECT\"" >> "$LOG_FILE"
else
  echo "❌ Failed to send email"
fi

rm -f "$MAILFILE"
