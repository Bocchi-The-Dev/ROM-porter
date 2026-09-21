#!/usr/bin/env bash
# download_input.sh <url> <dest_dir> <type>
# type is one of: super.img | super.bin | pac | pac.zip | ota
# Downloads into dest_dir/input.<ext> using the extension that matches the declared type.
set -euo pipefail

URL="$1"
DEST_DIR="$2"
TYPE="$3"
mkdir -p "$DEST_DIR"

case "$TYPE" in
  super.img) EXT="img" ;;
  super.bin) EXT="bin" ;;
  pac)       EXT="pac" ;;
  pac.zip)   EXT="pac.zip" ;;
  ota)       EXT="zip" ;;
  *)
    echo "ERROR: unknown type '$TYPE' (expected super.img, super.bin, pac, pac.zip, or ota)"
    exit 1
    ;;
esac

OUT="$DEST_DIR/input.$EXT"
echo "Downloading $URL -> $OUT"

is_drive_url() {
  case "$1" in
    *://drive.google.com/*|*://drive.usercontent.google.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_html_file() {
  # Interstitial/error pages start with '<' (allow leading whitespace/BOM).
  local head
  head="$(head -c 16 "$1" | tr -d ' \t\r\n' || true)"
  case "$head" in
    \<*) return 0 ;;
    *) return 1 ;;
  esac
}

drive_download() {
  # Google Drive serves a "Virus scan warning" interstitial for large files.
  # Multi-connection downloaders (aria2c) just save that HTML page — which is
  # exactly the 2 KB "input.pac.zip" failure seen in CI. Drive links therefore
  # always go through single-connection curl with scan-warning bypass.
  local url="$1" out="$2"
  local cook
  cook="$(mktemp)"
  case "$url" in
    *confirm=*) : ;;
    *) url="${url}&confirm=t" ;;
  esac
  echo "Google Drive link detected — single-connection curl with scan-warning bypass"
  curl -L --fail --retry 3 -c "$cook" -o "$out" "$url"
  if is_html_file "$out"; then
    echo "Drive returned an interstitial page — extracting token and retrying..."
    local uuid
    uuid="$(grep -oE 'name="uuid" value="[^"]+"' "$out" | head -n1 | sed -E 's/.*value="([^"]+)".*/\1/' || true)"
    if [ -z "$uuid" ]; then
      # Fallback: token embedded directly in a download URL on the page.
      uuid="$(grep -oE 'uuid=[a-fA-F0-9-]+' "$out" | head -n1 | cut -d= -f2 || true)"
    fi
    if [ -z "$uuid" ]; then
      echo "ERROR: Drive interstitial page has no uuid token. Page head:"
      head -c 500 "$out"
      echo ""
      rm -f "$cook"
      return 1
    fi
    case "$url" in
      *uuid=*) : ;;
      *) url="${url}&uuid=${uuid}" ;;
    esac
    curl -L --fail --retry 3 -b "$cook" -c "$cook" -o "$out" "$url"
  fi
  rm -f "$cook"
}

if is_drive_url "$URL"; then
  drive_download "$URL" "$OUT"
elif command -v aria2c > /dev/null 2>&1; then
  # Multi-connection download — much faster than single-stream curl for large
  # files when the server supports range requests. Falls back to curl below
  # if aria2c isn't installed. (NOT used for Google Drive: see drive_download.)
  aria2c \
    --max-connection-per-server=8 \
    --split=8 \
    --min-split-size=1M \
    --continue=true \
    --retry-wait=3 \
    --max-tries=5 \
    --dir="$(dirname "$OUT")" \
    --out="$(basename "$OUT")" \
    "$URL"
else
  echo "aria2c not found, falling back to single-connection curl"
  curl -L --fail --retry 3 -o "$OUT" "$URL"
fi

# Post-download validation: a 2 KB HTML page must never silently pass as firmware.
if is_html_file "$OUT"; then
  echo "ERROR: downloaded file is an HTML page, not $TYPE firmware."
  echo "This usually means the host returned an interstitial (login wall,"
  echo "virus-scan warning, quota exceeded) instead of the file. Page head:"
  head -c 300 "$OUT"
  echo ""
  exit 1
fi
case "$EXT" in
  zip|pac.zip)
    if [ "$(head -c 2 "$OUT")" != "PK" ]; then
      echo "ERROR: expected a zip archive for type '$TYPE' but $OUT has no PK magic."
      exit 1
    fi
    ;;
esac

echo "Contents of $DEST_DIR:"
ls -la "$DEST_DIR"
