#!/usr/bin/env bash
# patch_product.sh --product-img PATH --overlay-apk PATH
# Copies the given APK into product/overlay/ and rebuilds the EROFS image
# *losslessly*: ownership, modes and SELinux labels are snapshotted from the
# source image and re-applied (the new APK is labeled like its neighbors),
# the original UUID is kept, and the result is verified file-by-file before it
# replaces the original. A rebuilt image bigger than the source is rejected
# unless ALLOW_GROWTH=1 (it may not fit its logical partition).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/repack_lib.sh"

PRODUCT_IMG=""
OVERLAY_APK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --product-img) PRODUCT_IMG="$2"; shift 2 ;;
    --overlay-apk) OVERLAY_APK="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[ -n "$PRODUCT_IMG" ] || { echo "ERROR: --product-img is required"; exit 1; }
[ -f "$OVERLAY_APK" ] || { echo "ERROR: overlay APK '$OVERLAY_APK' not found"; exit 1; }

need_sudo

is_erofs() {
  local magic
  magic="$(dd if="$1" bs=1 skip=1024 count=4 2>/dev/null | xxd -p)"
  [ "$magic" = "e2e1f5e0" ]
}

if ! is_erofs "$PRODUCT_IMG"; then
  echo "ERROR: $PRODUCT_IMG is not EROFS (only EROFS product images are supported)."
  exit 1
fi

WORK="$(mktemp -d)"
trap 'umount_mnt "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT
PROD_EXTRACT="$WORK/product"
META_TSV="$WORK/meta.tsv"
MNT="$WORK/mnt"
OUT_TMP="$WORK/product.new.img"
ORIG_SIZE="$(stat -c%s "$PRODUCT_IMG")"
ORIG_UUID="$(img_uuid "$PRODUCT_IMG")"
echo "Source: $PRODUCT_IMG ($(du -h "$PRODUCT_IMG" | cut -f1), uuid=$ORIG_UUID)"

# 1. Snapshot ground truth from a read-only mount.
mount_ro "$PRODUCT_IMG" "$MNT"
snapshot_metadata "$MNT" "$META_TSV"

# 2. Extract (as root so ownership survives; do NOT chown afterwards).
$SUDO fsck.erofs --extract="$PROD_EXTRACT" "$PRODUCT_IMG" > /dev/null

# Some product images have a top-level "product/" wrapper folder, others have
# content directly at the root. Detect rather than assume.
if [ -d "$PROD_EXTRACT/product" ]; then
  PROD_BASE="$PROD_EXTRACT/product"
else
  PROD_BASE="$PROD_EXTRACT"
fi
echo "Product root: $PROD_BASE"

# 3. Add the overlay APK (+x perms not needed for APKs; label it like neighbors).
OVERLAY_DIR="$PROD_BASE/overlay"
if ! $SUDO test -d "$OVERLAY_DIR"; then
  # New dir: deterministic attrs (matches stock Smart 8 layout).
  $SUDO mkdir -p "$OVERLAY_DIR"
  $SUDO chown 0:0 "$OVERLAY_DIR"
  $SUDO chmod 0755 "$OVERLAY_DIR"
fi
APK_NAME="$(basename "$OVERLAY_APK")"
$SUDO cp "$OVERLAY_APK" "$OVERLAY_DIR/$APK_NAME"
$SUDO chmod 0644 "$OVERLAY_DIR/$APK_NAME"
REF_APK="$($SUDO find "$OVERLAY_DIR" -maxdepth 1 -name '*.apk' ! -name "$APK_NAME" | head -n1 || true)"
if [ -n "$REF_APK" ]; then
  label_new_file "$OVERLAY_DIR/$APK_NAME" "$REF_APK"
else
  # No sibling APKs to copy the label from — fall back to the overlay dir label.
  DLBL="$($SUDO getfattr -n security.selinux --only-values "$OVERLAY_DIR" 2>/dev/null || echo u:object_r:system_file:s0)"
  $SUDO setfattr -n security.selinux -v "$DLBL" "$OVERLAY_DIR/$APK_NAME"
fi
echo "Copied $APK_NAME into $OVERLAY_DIR (Headphone jack fix.)"

# 4. Re-apply recorded owners/modes/labels, then rebuild to a TEMP file.
# (The new APK keeps the owner/mode/label set above.)
stage_metadata "$PROD_EXTRACT" "$META_TSV"
# See patch_system.sh for why -E legacy-compress is here — same kernel-compat reasoning.
$SUDO mkfs.erofs --quiet -E legacy-compress -zlz4hc,9 -T 0 -U "$ORIG_UUID" \
  --mount-point="/product" "$OUT_TMP" "$PROD_EXTRACT"
echo "Repacked -> temp image ($(du -h "$OUT_TMP" | cut -f1))"

# 5. Verify (the newly added APK is expected to differ — ignore just it).
$SUDO fsck.erofs "$OUT_TMP" > /dev/null
APK_REL="${OVERLAY_DIR#$PROD_EXTRACT/}/$APK_NAME"
IGNORES=("$APK_REL")
# Also ignore the overlay dir itself, but only when this patch created it —
# pre-existing dirs (and their other contents) are still verified file-by-file.
for D in overlay product/overlay; do
  if ! $SUDO test -e "$MNT/$D"; then
    IGNORES+=("$D")
  fi
done
verify_repack "$OUT_TMP" "$MNT" "${IGNORES[@]}"
umount_mnt "$MNT"

# 6. Size gate (see patch_system.sh for why).
NEW_SIZE="$(stat -c%s "$OUT_TMP")"
if [ "$NEW_SIZE" -gt "$ORIG_SIZE" ] && [ "${ALLOW_GROWTH:-0}" != "1" ]; then
  echo "ERROR: rebuilt image grew ($ORIG_SIZE -> $NEW_SIZE bytes) and would"
  echo "risk not fitting its partition. Aborting without touching the original."
  echo "Set ALLOW_GROWTH=1 in the environment to override (know your partition size)."
  exit 1
fi
if [ "$NEW_SIZE" -gt "$ORIG_SIZE" ]; then
  echo "WARNING: rebuilt image grew ($ORIG_SIZE -> $NEW_SIZE bytes) — allowed via ALLOW_GROWTH=1"
fi

mv "$OUT_TMP" "$PRODUCT_IMG"
trap - EXIT
rm -rf "$WORK"
echo "Repacked -> $PRODUCT_IMG ($(du -h "$PRODUCT_IMG" | cut -f1))"
