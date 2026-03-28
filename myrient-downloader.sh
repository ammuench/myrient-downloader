#!/bin/bash

# Enable job control for proper signal handling
set -m

# Usage:
#   ./myrient-downloader.sh platforms.txt exclude_patterns.txt
#   ./myrient-downloader.sh --verbose --base-url https://myrient.erista.me/files/Redump platforms.txt exclude_patterns.txt

BASE_URL="https://myrient.erista.me/files/No-Intro"
MAX_PARALLEL=5
VERBOSE=0

PLATFORMS_FILE=""
EXCLUDES_FILE=""
TOTAL_FILES=0
SUCCESS_COUNT=0
FAIL_COUNT=0

XARGS_PID=""

CLEANUP_DONE=0
INTERRUPTED=0

cleanup() {
  # Prevent multiple executions
  [[ "$CLEANUP_DONE" -eq 1 ]] && return
  CLEANUP_DONE=1
  
  # Only show interrupt messages and kill processes if interrupted
  if [[ "$INTERRUPTED" -eq 1 ]]; then
    echo ""
    echo "🛑 Interrupting downloads..."
    
    # Kill xargs and all its children if running
    if [[ -n "$XARGS_PID" ]]; then
      # Kill the entire process group
      kill -TERM -"$XARGS_PID" 2>/dev/null || true
      sleep 1
      # Force kill if still running
      kill -KILL -"$XARGS_PID" 2>/dev/null || true
    fi
    
    # Kill any remaining wget processes (catch-all for any that escaped process group kill)
    pkill wget 2>/dev/null || true

    # Wait for background jobs to finish silently (suppresses "[1]+ Terminated" messages)
    wait 2>/dev/null

    echo "✅ Cleanup complete"
  fi
  
  # Always clean up temporary files
  find . -name ".result.*" -delete 2>/dev/null
  
  # Exit with 130 if interrupted, otherwise let script exit normally
  [[ "$INTERRUPTED" -eq 1 ]] && exit 130
}

handle_interrupt() {
  INTERRUPTED=1
  cleanup
}

trap cleanup EXIT
trap handle_interrupt SIGINT SIGTERM

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)
      VERBOSE=1
      shift
      ;;
    --base-url)
      BASE_URL="$2"
      shift 2
      ;;
    *)
      if [[ -z "$PLATFORMS_FILE" ]]; then
        PLATFORMS_FILE="$1"
      elif [[ -z "$EXCLUDES_FILE" ]]; then
        EXCLUDES_FILE="$1"
      else
        echo "❌ Unknown argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "${PLATFORMS_FILE:-}" || -z "${EXCLUDES_FILE:-}" ]]; then
  echo "Usage: $0 [--verbose] [--base-url URL] platforms.txt exclude_patterns.txt"
  exit 1
fi

mapfile -t EXCLUDE_PATTERNS < "$EXCLUDES_FILE"

logv() {
  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "[VERBOSE] $*"
  fi
}

# Cross-platform file size
get_file_size() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f%z "$1"
  else
    stat -c%s "$1"
  fi
}

download_file() {
  PLATFORM_DIR="$1"
  FILE="$2"
  FILE_URL="$3"
  RESULT_FILE="${PLATFORM_DIR}/.result.$(date +%s%N)"

  DECODED_FILE=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('''$FILE'''))")
  LOCAL_PATH="${PLATFORM_DIR}/${DECODED_FILE}"
  COMPLETED_FILE="${PLATFORM_DIR}/.completed"

  logv "FILE: $FILE"
  logv "DECODED_FILE: $DECODED_FILE"
  logv "LOCAL_PATH: $LOCAL_PATH"
  logv "FILE_URL: $FILE_URL"

  if [[ -f "$COMPLETED_FILE" ]] && grep -Fxq "$FILE" "$COMPLETED_FILE" && [[ -s "$LOCAL_PATH" ]]; then
    echo "✅ Already complete: $FILE"
    return 0
  else
    touch "$COMPLETED_FILE"
  fi

  if [[ -s "$LOCAL_PATH" ]]; then
    REMOTE_SIZE=$(curl -sIL "$FILE_URL" | grep -i '^Content-Length:' | tail -1 | cut -d' ' -f2 | tr -d '\r')
    LOCAL_SIZE=$(get_file_size "$LOCAL_PATH" 2>/dev/null)
    logv "Existing file found. Remote size: $REMOTE_SIZE, Local size: $LOCAL_SIZE"

    if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" == "$LOCAL_SIZE" ]]; then
      echo "📏 Matched size, marking complete: $FILE"
      echo "$FILE" >> "$COMPLETED_FILE"
      return 0
    fi
  fi

  # Check if the remote file actually exists before downloading
  HTTP_STATUS=$(curl -sIL -o /dev/null -w '%{http_code}' "$FILE_URL")
  if [[ "$HTTP_STATUS" != "200" ]]; then
    echo "❌ Remote file not found (HTTP $HTTP_STATUS): $FILE"
    echo "fail" >> "$RESULT_FILE"
    return 0
  fi

  echo "⬇️  Downloading: $FILE"

  WGET_OUTPUT=$(mktemp)
  wget --continue \
       --tries=5 \
       --retry-connrefused \
       --timeout=30 \
       --waitretry=5 \
       -O "$LOCAL_PATH" \
       "$FILE_URL" 2>"$WGET_OUTPUT"
  WGET_EXIT=$?

  if [[ "$VERBOSE" -eq 1 ]]; then
    cat "$WGET_OUTPUT"
  fi
  rm -f "$WGET_OUTPUT"

  if [[ $WGET_EXIT -ne 0 ]]; then
    echo "❌ wget failed (exit code $WGET_EXIT): $FILE"
    echo "fail" >> "$RESULT_FILE"
    rm -f "$LOCAL_PATH"
    return 0
  fi

  if [[ -f "$LOCAL_PATH" ]]; then
    REMOTE_SIZE=$(curl -sIL "$FILE_URL" | grep -i '^Content-Length:' | tail -1 | cut -d' ' -f2 | tr -d '\r')
    LOCAL_SIZE=$(get_file_size "$LOCAL_PATH" 2>/dev/null)
    logv "After wget: Remote size: $REMOTE_SIZE, Local size: $LOCAL_SIZE"

    if [[ -n "$REMOTE_SIZE" && "$REMOTE_SIZE" == "$LOCAL_SIZE" && "$LOCAL_SIZE" -gt 0 ]]; then
      echo "✅ Download verified: $FILE"
      echo "$FILE" >> "$COMPLETED_FILE"
      echo "success" >> "$RESULT_FILE"
    else
      echo "⚠️  Size mismatch (local: ${LOCAL_SIZE:-?}, remote: ${REMOTE_SIZE:-?}): $FILE"
      echo "fail" >> "$RESULT_FILE"
    fi
  else
    echo "❌ File missing after download: $FILE"
    echo "fail" >> "$RESULT_FILE"
  fi
}

export -f download_file
export -f get_file_size
export -f logv

# Download files from a single directory listing, then recurse into subdirectories
process_directory() {
  local url="$1"
  local local_dir="$2"

  logv "Scanning: $url"

  local PAGE
  PAGE=$(curl -s "$url")

  # Find downloadable files in this directory
  local FILES
  FILES=$(echo "$PAGE" | grep -Eo 'href="[^"]+\.(zip|rar|7z|dat|txt)"' | cut -d'"' -f2)

  if [[ -n "$FILES" ]]; then
    local TMP_QUEUE
    TMP_QUEUE=$(mktemp)
    local QUEUED=0

    for FILE in $FILES; do
      SKIP=0
      for PATTERN in "${EXCLUDE_PATTERNS[@]}"; do
        if echo "$FILE" | grep -iq "$PATTERN"; then
          echo "⏭️  Skipping (excluded): $FILE"
          logv "Excluded by pattern: $PATTERN"
          SKIP=1
          break
        fi
      done
      [[ $SKIP -eq 1 ]] && continue

      echo "${local_dir}|||${FILE}|||${url}${FILE}" >> "$TMP_QUEUE"
      QUEUED=$((QUEUED + 1))
    done

    if [[ $QUEUED -gt 0 ]]; then
      echo "🚀 Downloading $QUEUED files in: $local_dir"
      cat "$TMP_QUEUE" | xargs -P $MAX_PARALLEL -I{} bash -c '
        line="{}"
        dir="${line%%|||*}"
        rest="${line#*|||}"
        file="${rest%%|||*}"
        url="${rest#*|||}"
        download_file "$dir" "$file" "$url"
      ' &

      XARGS_PID=$!
      wait $XARGS_PID 2>/dev/null || true
      XARGS_PID=""
    fi

    rm -f "$TMP_QUEUE"
  fi

  # Find subdirectories (relative links ending with /, excluding ../ ./ and absolute paths)
  local SUBDIRS
  SUBDIRS=$(echo "$PAGE" | grep -Eo 'href="[^"]+/"' | cut -d'"' -f2 | grep -v '^\.\.' | grep -v '^\.' | grep -v '^/' | grep -v '^http')

  for SUBDIR in $SUBDIRS; do
    # Skip query string links like ?C=N&O=A
    [[ "$SUBDIR" == *"?"* ]] && continue

    local DECODED_SUBDIR
    DECODED_SUBDIR=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('''${SUBDIR%/}'''))")
    local SUB_LOCAL="${local_dir}/${DECODED_SUBDIR}"
    mkdir -p "$SUB_LOCAL"

    echo "📂 Entering subdirectory: $DECODED_SUBDIR"
    process_directory "${url}${SUBDIR}" "$SUB_LOCAL"
  done
}

while IFS= read -r DIR_NAME || [[ -n "$DIR_NAME" ]]; do
  [[ -z "$DIR_NAME" || "$DIR_NAME" =~ ^# ]] && continue

  ENCODED_DIR=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$DIR_NAME'''))")
  FULL_URL="${BASE_URL%/}/${ENCODED_DIR}/"
  LOCAL_DIR="./$(basename "$DIR_NAME")"
  mkdir -p "$LOCAL_DIR"

  echo ""
  echo "🔍 Fetching list from: $FULL_URL"
  echo "📁 Local folder: $LOCAL_DIR"

  process_directory "$FULL_URL" "$LOCAL_DIR"

  # Summary for this platform
  echo "📊 Download Summary for: $DIR_NAME"
  echo "----------------------"

  SUCCESS_COUNT=$(find "$LOCAL_DIR" -name ".result.*" -exec cat {} + 2>/dev/null | grep -c "success" || true)
  FAIL_COUNT=$(find "$LOCAL_DIR" -name ".result.*" -exec cat {} + 2>/dev/null | grep -c "fail" || true)
  SUCCESS_COUNT=${SUCCESS_COUNT:-0}
  FAIL_COUNT=${FAIL_COUNT:-0}
  TOTAL_FILES=$((SUCCESS_COUNT + FAIL_COUNT))

  echo "🧾 Total attempted: $TOTAL_FILES"
  echo "✅ Completed:       $SUCCESS_COUNT"
  echo "❌ Errors:          $FAIL_COUNT"

  # Clean up result files
  find "$LOCAL_DIR" -name ".result.*" -delete

  find "$LOCAL_DIR" -name ".completed" -exec sort -u {} -o {} \;
  echo "✅ Done: $DIR_NAME"
  echo
done < "$PLATFORMS_FILE"

