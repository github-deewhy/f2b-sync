#!/bin/bash
# =============================================================================
# f2b_sync.sh - fetch f2b_status.json from the remote Ubuntu server
#   1 SSH connection, timeouts, retries, JSON validation, atomic replace.
#
# Usage:  ./f2b_sync.sh [--notify] [--quiet] [--progress] [--help]
#   --notify    show a macOS notification with the result
#   --quiet     no human-readable terminal output (still written to the log)
#   --progress  emit machine-readable "@@PROGRESS pct msg" / "@@DONE code msg"
#               lines on stdout (used by the F2B Sync app window)
#
# Settings can be overridden in ~/.config/f2b_sync.conf (plain shell syntax)
# =============================================================================
set -u

# ---- Settings ---------------------------------------------------------------
REMOTE_USER="ubuntu"
REMOTE_HOST="your-server.example.com"
SSH_KEY="$HOME/.ssh/id_rsa"
REMOTE_CMD="./f2b.sh --json >&2"                 # runs in the remote home dir
REMOTE_FILE="/home/ubuntu/f2b_status.json"
LOCAL_DIR="$HOME/f2b"
LOCAL_NAME="f2b_status.json"
RETRIES=3
RETRY_DELAY=5
LOG_FILE="$HOME/Library/Logs/f2b_sync.log"
CONF="${F2B_CONF:-$HOME/.config/f2b_sync.conf}"
# -----------------------------------------------------------------------------

[ -f "$CONF" ] && . "$CONF"

NOTIFY=0; QUIET=0; PROGRESS=0
for arg in "$@"; do
  case "$arg" in
    --notify)   NOTIFY=1 ;;
    --quiet)    QUIET=1 ;;
    --progress) PROGRESS=1 ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")" "$LOCAL_DIR" 2>/dev/null
TMP="$LOCAL_DIR/.${LOCAL_NAME}.tmp.$$"
trap 'rm -f "$TMP"' EXIT

log() {
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null
  if [ "$QUIET" -eq 0 ]; then printf '%s\n' "$1"; fi
  return 0
}
emit() { if [ "$PROGRESS" -eq 1 ]; then printf '@@PROGRESS %s %s\n' "$1" "$2"; fi; return 0; }
emit_done() { if [ "$PROGRESS" -eq 1 ]; then printf '@@DONE %s %s\n' "$1" "$2"; fi; return 0; }

notify() {
  [ "$NOTIFY" -eq 1 ] || return 0
  osascript -e "display notification \"$1\" with title \"F2B Sync\" subtitle \"$REMOTE_HOST\"" >/dev/null 2>&1
}

validate_json() {
  if command -v jq >/dev/null 2>&1; then jq empty "$1" >/dev/null 2>&1
  elif /usr/bin/python3 -c 'pass' >/dev/null 2>&1; then /usr/bin/python3 -m json.tool "$1" >/dev/null 2>&1
  else plutil -lint "$1" >/dev/null 2>&1
  fi
}

# Reads ssh's stderr live: turns stage markers into progress, logs the rest.
stage_filter() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "@@STAGE connected") emit 35 "Connected - running f2b.sh on the server…" ;;
      "@@STAGE fetch")     emit 70 "Downloading status data…" ;;
      *) printf '%s\n' "$line" >> "$LOG_FILE" ;;
    esac
  done
}

emit 3 "Checking SSH key…"
if [ ! -f "$SSH_KEY" ]; then
  log "❌ SSH key not found: $SSH_KEY"; notify "SSH key not found"
  emit_done 1 "SSH key not found: $SSH_KEY"; exit 1
fi

log "▶ Sync started: ${REMOTE_USER}@${REMOTE_HOST}"
REMOTE_FULL="echo '@@STAGE connected' >&2; $REMOTE_CMD && echo '@@STAGE fetch' >&2 && cat $REMOTE_FILE"

attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
  : > "$TMP"
  emit 10 "Attempt $attempt/$RETRIES - connecting to $REMOTE_HOST…"
  ssh -i "$SSH_KEY" \
      -o BatchMode=yes -o ConnectTimeout=10 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
      "${REMOTE_USER}@${REMOTE_HOST}" "$REMOTE_FULL" 2> >(stage_filter) > "$TMP"
  ssh_rc=$?   # (stderr filter is opened BEFORE '> $TMP' so its stdout is ours, not the file)
  sleep 0.3   # let the stderr filter flush

  if [ "$ssh_rc" -eq 0 ] && [ -s "$TMP" ]; then
    emit 85 "Validating JSON…"
    if validate_json "$TMP"; then
      emit 95 "Saving file…"
      mv -f "$TMP" "$LOCAL_DIR/$LOCAL_NAME"
      size=$(wc -c < "$LOCAL_DIR/$LOCAL_NAME" | tr -d ' ')
      log "✅ Synced (attempt $attempt, ${size} bytes) → $LOCAL_DIR/$LOCAL_NAME"
      notify "Synced successfully (${size} bytes)"
      emit_done 0 "Synced on attempt $attempt ($size bytes). Saved to $LOCAL_DIR/$LOCAL_NAME"
      exit 0
    fi
    log "⚠️  Attempt $attempt/$RETRIES: invalid JSON received"
  else
    log "⚠️  Attempt $attempt/$RETRIES failed (ssh exit $ssh_rc)"
  fi

  if [ "$attempt" -lt "$RETRIES" ]; then
    emit 5 "Attempt $attempt failed - retrying in ${RETRY_DELAY}s…"
    sleep "$RETRY_DELAY"
  fi
  attempt=$((attempt + 1))
done

log "❌ Sync failed after $RETRIES attempts (existing file left untouched). Log: $LOG_FILE"
notify "Sync FAILED - see ~/Library/Logs/f2b_sync.log"
emit_done 1 "Failed after $RETRIES attempts. Your existing f2b_status.json was left untouched."
exit 1
