#!/usr/bin/env bash
# download_input.sh <url> <dest_dir>
# Downloads a firmware file (.pac / .img / .bin) from a direct URL into dest_dir/input.<ext>
set -euo pipefail

URL="$1"
DEST_DIR="$2"
mkdir -p "$DEST_DIR"

# Guess extension from the URL. Falls back to sniffing content if the URL has no clean extension
# (e.g. signed/expiring download links with query strings).
EXT="$(basename "$URL" | sed -n 's/.*\.\([a-zA-Z0-9]\+\)\(\?.*\)\?$/\1/p' | tr '[:upper:]' '[:lower:]')"

case "$EXT" in
  pac|img|bin)
    OUT="$DEST_DIR/input.$EXT"
    ;;
  *)
    OUT="$DEST_DIR/input.download"
    ;;
esac

echo "Downloading $URL -> $OUT"
curl -L --fail --retry 3 -o "$OUT" "$URL"

# If we couldn't tell the type from the URL, sniff it now.
if [ "$EXT" != "pac" ] && [ "$EXT" != "img" ] && [ "$EXT" != "bin" ]; then
  HEADER_HEX="$(head -c 4 "$OUT" | xxd -p)"
  case "$HEADER_HEX" in
    "78563412"|"78563411")
      # Common SPD .pac magic variants
      mv "$OUT" "$DEST_DIR/input.pac"
      echo "Sniffed as .pac"
      ;;
    *)
      mv "$OUT" "$DEST_DIR/input.img"
      echo "Could not confirm .pac magic — assuming raw super.img/super.bin. If extraction fails, this file wasn't a .pac."
      ;;
  esac
fi

echo "Contents of $DEST_DIR:"
ls -la "$DEST_DIR"
