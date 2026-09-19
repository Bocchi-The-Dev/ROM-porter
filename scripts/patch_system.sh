#!/usr/bin/env bash
# patch_system.sh --system-img PATH --transsion-anticrack true|false [--system-prop FILE]
# Patches build.prop + (optionally) the Transsion anti-crack block, then rebuilds
# the EROFS image *losslessly*: ownership, modes and SELinux labels are snapshotted
# from the source image and re-applied, the original UUID is kept, and the result
# is verified file-by-file before it replaces the original. Rebuilt images that
# grow beyond the original size are rejected unless ALLOW_GROWTH=1 (a bigger image
# may not fit its logical partition and will bootloop).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/repack_lib.sh"

SYSTEM_IMG=""
TRANSSION_ANTICRACK="true"
SYSTEM_PROP_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --system-img) SYSTEM_IMG="$2"; shift 2 ;;
    --transsion-anticrack) TRANSSION_ANTICRACK="$2"; shift 2 ;;
    --system-prop) SYSTEM_PROP_FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[ -n "$SYSTEM_IMG" ] || { echo "ERROR: --system-img is required"; exit 1; }
[ -f "$SYSTEM_IMG" ] || { echo "ERROR: not found: $SYSTEM_IMG"; exit 1; }

need_sudo

is_erofs() {
  local magic
  magic="$(dd if="$1" bs=1 skip=1024 count=4 2>/dev/null | xxd -p)"
  [ "$magic" = "e2e1f5e0" ]
}

if ! is_erofs "$SYSTEM_IMG"; then
  echo "ERROR: $SYSTEM_IMG is not EROFS (only EROFS system images are supported)."
  echo "If your donor uses ext4, convert it first — blind repacking without"
  echo "SELinux labels produces an unbootable image."
  exit 1
fi

WORK="$(mktemp -d)"
trap 'umount_mnt "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT
SYS_EXTRACT="$WORK/system"
META_TSV="$WORK/meta.tsv"
MNT="$WORK/mnt"
OUT_TMP="$WORK/system.new.img"
ORIG_SIZE="$(stat -c%s "$SYSTEM_IMG")"
ORIG_UUID="$(img_uuid "$SYSTEM_IMG")"
echo "Source: $SYSTEM_IMG ($(du -h "$SYSTEM_IMG" | cut -f1), uuid=$ORIG_UUID)"

# 1. Snapshot ground truth (owners/modes/labels) from a read-only mount.
mount_ro "$SYSTEM_IMG" "$MNT"
snapshot_metadata "$MNT" "$META_TSV"

# 2. Extract (as root so ownership survives; do NOT chown afterwards).
$SUDO fsck.erofs --extract="$SYS_EXTRACT" "$SYSTEM_IMG" > /dev/null

# Some system images have a top-level "system/" wrapper folder (system-as-root
# layout), others have content directly at the root. Detect rather than assume.
if [ -d "$SYS_EXTRACT/system" ]; then
  SYS_BASE="$SYS_EXTRACT/system"
else
  SYS_BASE="$SYS_EXTRACT"
fi
echo "System root: $SYS_BASE"

# 3. Apply content patches (tree is root-owned; use sudo).
BUILD_PROP="$SYS_BASE/build.prop"
if [ -f "$BUILD_PROP" ]; then
  $SUDO sed -i \
    -e 's/^ro\.debuggable=0$/ro.debuggable=1/' \
    -e 's/^ro\.force\.debuggable=0$/ro.force.debuggable=1/' \
    "$BUILD_PROP"
  echo "Patched build.prop at $BUILD_PROP"
else
  echo "WARNING: build.prop not found — skipping this patch"
fi

if [ "$TRANSSION_ANTICRACK" = "true" ]; then
  INIT_RC="$SYS_BASE/etc/init/hw/init.rc"
  if [ -f "$INIT_RC" ]; then
    if $SUDO grep -q "vfy_boot" "$INIT_RC"; then
      # Only drop vfy_boot lines that are standalone statements. Blind
      # `sed -i '/vfy_boot/d'` will happily delete one line out of a
      # multi-line `\`-continued init.rc block, which corrupts the
      # init language parse and can hard-bootloop the device before
      # the boot animation — with no logcat available to explain why.
      # Lines that are themselves a continuation, or that end in `\`
      # (starting/continuing a multi-line block), are left untouched
      # and flagged for manual review instead.
      $SUDO awk '
        {
          is_continuation = (prev_ends_bslash == 1)
          ends_bslash = ($0 ~ /\\[[:space:]]*$/)
          if ($0 ~ /vfy_boot/ && !is_continuation && !ends_bslash) {
            print $0 > "/dev/stderr"
          } else {
            print $0
          }
          prev_ends_bslash = ends_bslash
        }
      ' "$INIT_RC" 1> "$INIT_RC.tmp" 2> "$INIT_RC.removed"
      $SUDO mv "$INIT_RC.tmp" "$INIT_RC"
      if [ -s "$INIT_RC.removed" ]; then
        echo "Removed $($SUDO wc -l < "$INIT_RC.removed") standalone vfy_boot line(s):"
        $SUDO cat "$INIT_RC.removed"
      fi
      $SUDO rm -f "$INIT_RC.removed"
      if $SUDO grep -q "vfy_boot" "$INIT_RC"; then
        echo "WARNING: vfy_boot still present — left in place because it's part of a multi-line block. Inspect manually:"
        $SUDO grep -n "vfy_boot" "$INIT_RC"
      fi
    else
      echo "No vfy_boot references in $INIT_RC — nothing to remove (expected on donors like A13 TranssionOS)"
    fi
    if ! $SUDO grep -q "Force SELinux Permissive" "$INIT_RC"; then
      $SUDO awk '
        { print }
        /BSP:add tran verify para NFRFP-22376 by wang.qin 20231228 end/ {
          print ""
          print "on early-init"
          print "    # Force SELinux Permissive"
          print "    write /sys/fs/selinux/enforce 0"
          print "    setenforce 0"
          print "    setprop ro.boot.selinux permissive"
        }
      ' "$INIT_RC" > "$INIT_RC.tmp" && $SUDO mv "$INIT_RC.tmp" "$INIT_RC"
    fi
    echo "Patched Transsion anti-crack block in $INIT_RC"
  else
    echo "WARNING: init.rc not found at expected path — skipping anti-crack patch"
  fi
fi

SYS_SEPOLICY="$SYS_BASE/etc/selinux/system_sepolicy.cil"
if [ -f "$SYS_SEPOLICY" ]; then
  if ! $SUDO grep -q "allow system_init selinuxfs" "$SYS_SEPOLICY"; then
    {
      echo "(allow system_init selinuxfs (file (write)))"
      echo "(allow system_init kernel (security (setenforce)))"
    } | $SUDO tee -a "$SYS_SEPOLICY" > /dev/null
    echo "Patched $SYS_SEPOLICY"
  fi
else
  echo "system_sepolicy.cil not present — skipping (this is expected on some ROMs)"
fi

# "Fix Brightness and Lag." — appends patches/system.prop's contents onto build.prop.
if [ -n "$SYSTEM_PROP_FILE" ]; then
  if [ -f "$SYSTEM_PROP_FILE" ]; then
    if [ -f "$BUILD_PROP" ]; then
      {
        echo ""
        echo "# --- Appended from $SYSTEM_PROP_FILE (Fix Brightness and Lag.) ---"
        cat "$SYSTEM_PROP_FILE"
      } | $SUDO tee -a "$BUILD_PROP" > /dev/null
      echo "Appended $SYSTEM_PROP_FILE onto $BUILD_PROP"
    else
      echo "WARNING: --system-prop given but build.prop wasn't found — nothing to append to"
    fi
  else
    echo "ERROR: --system-prop file '$SYSTEM_PROP_FILE' not found"
    exit 1
  fi
fi

# 4. Re-apply recorded owners/modes/labels, then rebuild (to a TEMP file —
# never delete the original before the replacement is verified).
stage_metadata "$SYS_EXTRACT" "$META_TSV"
# -E legacy-compress: forces the older on-disk EROFS layout (no "decompression
# in-place"/"compacted indexes", which need kernel >= 5.3). Unisoc/Transsion
# devices often run older forked kernels, and EROFS deliberately refuses to
# mount images with feature flags it doesn't recognize — this is the fix for
# "device never reaches bootanim" when that's the actual cause.
$SUDO mkfs.erofs --quiet -E legacy-compress -zlz4hc,9 -T 0 -U "$ORIG_UUID" \
  --mount-point="/system" "$OUT_TMP" "$SYS_EXTRACT"
echo "Repacked -> temp image ($(du -h "$OUT_TMP" | cut -f1))"

# 5. Verify before replacing: mountable, every inode readable, and all
# ownership/modes/labels identical to the source image (content edits don't
# affect this check — only metadata is compared).
# NOTE: $MNT (source image) is still mounted from step 1.
$SUDO fsck.erofs "$OUT_TMP" > /dev/null
verify_repack "$OUT_TMP" "$MNT"
umount_mnt "$MNT"

# 6. Size gate: a rebuilt image bigger than the source may not fit its logical
# partition (exact-fit partitions flash corrupt and drop straight to bootloader).
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

mv "$OUT_TMP" "$SYSTEM_IMG"
trap - EXIT
rm -rf "$WORK"
echo "Repacked -> $SYSTEM_IMG ($(du -h "$SYSTEM_IMG" | cut -f1))"
