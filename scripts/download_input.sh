#!/usr/bin/env bash
# download_input.sh <url> <dest_dir> <type>
# type is one of: super.img | super.bin | pac | pac.zip
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
  *)
    echo "ERROR: unknown type '$TYPE' (expected super.img, super.bin, pac, or pac.zip)"
    exit 1
    ;;
esac

OUT="$DEST_DIR/input.$EXT"
echo "Downloading $URL -> $OUT"

if command -v aria2c > /dev/null 2>&1; then
  # Multi-connection download — much faster than single-stream curl for large
  # files when the server supports range requests (Google Drive's direct
  # download links generally do). Falls back to curl below if aria2c isn't
  # installed, so this is safe either way.
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

echo "Contents of $DEST_DIR:"
ls -la "$DEST_DIR"
