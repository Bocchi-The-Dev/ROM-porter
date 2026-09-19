#!/usr/bin/env bash
# patch_display.sh --product-img PATH [--displayconfig-dir DIR]
# Installs the Infinix Smart 8 panel display configuration
# (product/etc/displayconfig/*.xml) to fix display-server crashes
# (SurfaceFlinger ArrayIndexOutOfBounds on empty/missing brightness maps)
# seen when donor ROM configs don't describe this panel.
#
# Files land with the exact attributes the stock ROM uses (0644 root:root,
# same SELinux label as neighboring displayconfig files). The image is rebuilt
# losslessly (see repack_lib.sh) and verified before replacing the original.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/repack_lib.sh"

PRODUCT_IMG=""
DC_DIR="$SCRIPT_DIR/../patches/displayconfig"
while [ $# -gt 0 ]; do
  case "$1" in
    --product-img) PRODUCT_IMG="$2"; shift 2 ;;
    --displayconfig-dir) DC_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[ -n "$PRODUCT_IMG" ] || { echo "ERROR: --product-img is required"; exit 1; }
[ -f "$PRODUCT_IMG" ] || { echo "ERROR: not found: $PRODUCT_IMG"; exit 1; }
[ -d "$DC_DIR" ] || { echo "ERROR: displayconfig dir not found: $DC_DIR"; exit 1; }

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
trap 'umount_mnt "$WORK/mnt" 2>/dev/null || true; $SUDO rm -rf "$WORK"' EXIT
PROD_EXTRACT="$WORK/product"
META_TSV="$WORK/meta.tsv"
MNT="$WORK/mnt"
OUT_TMP="$WORK/product.new.img"
ORIG_SIZE="$(stat -c%s "$PRODUCT_IMG")"
ORIG_UUID="$(img_uuid "$PRODUCT_IMG")"
echo "Source: $PRODUCT_IMG ($(du -h "$PRODUCT_IMG" | cut -f1), uuid=$ORIG_UUID)"

mount_ro "$PRODUCT_IMG" "$MNT"
snapshot_metadata "$MNT" "$META_TSV"
$SUDO fsck.erofs --extract="$PROD_EXTRACT" "$PRODUCT_IMG" > /dev/null

if $SUDO test -d "$PROD_EXTRACT/product"; then
  PROD_BASE="$PROD_EXTRACT/product"
else
  PROD_BASE="$PROD_EXTRACT"
fi
echo "Product root: $PROD_BASE"

DC_DST="$PROD_BASE/etc/displayconfig"
if ! $SUDO test -d "$DC_DST"; then
  # New dir: deterministic attrs (matches stock Smart 8 layout).
  $SUDO mkdir -p "$DC_DST"
  $SUDO chown 0:0 "$DC_DST"
  $SUDO chmod 0755 "$DC_DST"
fi

# Reference XML for owner/mode/label: prefer an existing displayconfig XML so
# the new files blend in exactly. Values come from the snapshot (ground truth
# from the source image), never from the extracted tree. Fallback is the stock
# Smart 8 attributes (verified on-device): 0:0/0644 system_file.
REF_XML_TREE="$($SUDO find "$DC_DST" -maxdepth 1 -name '*.xml' | head -n1 || true)"
REF_UID=0; REF_GID=0; REF_MODE=0644; REF_LAB="u:object_r:system_file:s0"
if [ -n "$REF_XML_TREE" ]; then
  REF_REL="${REF_XML_TREE#$PROD_EXTRACT/}"
  REF_REC="$(awk -F'\t' -v want="$REF_REL" '$1 == want { print $2, $3, $4, $5; exit }' "$META_TSV" || true)"
  if [ -n "$REF_REC" ]; then
    read -r REF_UID REF_GID REF_MODE REF_LAB <<< "$REF_REC"
    if [ "$REF_LAB" = "-" ]; then
      REF_LAB="u:object_r:system_file:s0"
    fi
  fi
fi
for SRC in "$DC_DIR"/*.xml; do
  [ -f "$SRC" ] || continue
  DST="$DC_DST/$(basename "$SRC")"
  $SUDO cp "$SRC" "$DST"
  $SUDO chown "$REF_UID:$REF_GID" "$DST"
  $SUDO chmod "$REF_MODE" "$DST"
  $SUDO setfattr -n security.selinux -v "$REF_LAB" "$DST"
  echo "Installed $(basename "$SRC")"
done

stage_metadata "$PROD_EXTRACT" "$META_TSV"
$SUDO mkfs.erofs --quiet -zlz4hc -T 0 -U "$ORIG_UUID" \
  --mount-point="/product" "$OUT_TMP" "$PROD_EXTRACT"
echo "Repacked -> temp image ($(du -h "$OUT_TMP" | cut -f1))"

$SUDO fsck.erofs "$OUT_TMP" > /dev/null
# (both flat and product/-wrapped layouts covered; parent dirs only ignored
# when they are newly created by this patch, so pre-existing content there
# is still verified file-by-file)
IGNORES=(
  "etc/displayconfig/display_port_0.xml"
  "etc/displayconfig/display_id_4619827259835644672.xml"
  "etc/displayconfig/display_id_12970367450567927216.xml"
  "product/etc/displayconfig/display_port_0.xml"
  "product/etc/displayconfig/display_id_4619827259835644672.xml"
  "product/etc/displayconfig/display_id_12970367450567927216.xml"
)
for D in etc product/etc product/etc/displayconfig etc/displayconfig; do
  if ! $SUDO test -e "$MNT/$D"; then
    IGNORES+=("$D")
  fi
done
verify_repack "$OUT_TMP" "$MNT" "${IGNORES[@]}"
umount_mnt "$MNT"

echo "Size: $ORIG_SIZE -> $(stat -c%s "$OUT_TMP") bytes"

mv "$OUT_TMP" "$PRODUCT_IMG"
trap - EXIT
$SUDO rm -rf "$WORK"
echo "Repacked -> $PRODUCT_IMG ($(du -h "$PRODUCT_IMG" | cut -f1))"
