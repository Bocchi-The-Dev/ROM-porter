#!/usr/bin/env bash
# patch_product.sh --product-img PATH --overlay-apk PATH
# Copies the given APK into product/overlay/ and repacks. No other changes.
set -euo pipefail

PRODUCT_IMG=""
OVERLAY_APK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --product-img) PRODUCT_IMG="$2"; shift 2 ;;
    --overlay-apk) OVERLAY_APK="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ ! -f "$OVERLAY_APK" ]; then
  echo "ERROR: overlay APK '$OVERLAY_APK' not found"
  exit 1
fi

WORK="$(mktemp -d)"
PROD_EXTRACT="$WORK/product"

is_erofs() {
  local img="$1"
  local magic
  magic="$(dd if="$img" bs=1 skip=1024 count=4 2>/dev/null | xxd -p)"
  [ "$magic" = "e2e1f5e0" ]
}

if ! is_erofs "$PRODUCT_IMG"; then
  echo "ERROR: $PRODUCT_IMG is not EROFS. This script only handles EROFS product images."
  exit 1
fi

mkdir -p "$PROD_EXTRACT"
sudo fsck.erofs --extract="$PROD_EXTRACT" "$PRODUCT_IMG" > /dev/null
sudo chown -R "$(id -u):$(id -g)" "$PROD_EXTRACT"

# Some product images have a top-level "product/" wrapper folder, others have
# content directly at the root. Detect rather than assume.
if [ -d "$PROD_EXTRACT/product" ]; then
  PROD_BASE="$PROD_EXTRACT/product"
else
  PROD_BASE="$PROD_EXTRACT"
fi
echo "Product root: $PROD_BASE"

OVERLAY_DIR="$PROD_BASE/overlay"
mkdir -p "$OVERLAY_DIR"
cp "$OVERLAY_APK" "$OVERLAY_DIR/$(basename "$OVERLAY_APK")"
echo "Copied $(basename "$OVERLAY_APK") into $OVERLAY_DIR (Headphone jack fix.)"

rm -f "$PRODUCT_IMG"
# See patch_system.sh for why -E legacy-compress is here — same kernel-compat reasoning.
mkfs.erofs --quiet -E legacy-compress -zlz4hc,9 --mount-point="/product" "$PRODUCT_IMG" "$PROD_EXTRACT"
echo "Repacked -> $PRODUCT_IMG ($(du -h "$PRODUCT_IMG" | cut -f1))"
