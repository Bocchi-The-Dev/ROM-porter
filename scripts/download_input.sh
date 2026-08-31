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
curl -L --fail --retry 3 -o "$OUT" "$URL"

echo "Contents of $DEST_DIR:"
ls -la "$DEST_DIR"
