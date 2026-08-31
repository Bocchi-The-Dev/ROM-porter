#!/usr/bin/env bash
# patch_rom.sh --result-dir DIR --target-unpacked DIR --device-codenames "A,B" --transsion-anticrack true|false
set -euo pipefail

RESULT_DIR=""
TARGET_UNPACKED=""
DEVICE_CODENAMES=""
TRANSSION_ANTICRACK="true"

while [ $# -gt 0 ]; do
  case "$1" in
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --target-unpacked) TARGET_UNPACKED="$2"; shift 2 ;;
    --device-codenames) DEVICE_CODENAMES="$2"; shift 2 ;;
    --transsion-anticrack) TRANSSION_ANTICRACK="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

WORK="$(mktemp -d)"
SYS_EXTRACT="$WORK/system"
VEND_EXTRACT="$WORK/vendor"
TARGET_VEND_EXTRACT="$WORK/target_vendor"

# --- filesystem type detection -------------------------------------------
# EROFS superblock magic (0xE0F5E1E2, little-endian) sits at byte offset 1024.
is_erofs() {
  local img="$1"
  local magic
  magic="$(dd if="$img" bs=1 skip=1024 count=4 2>/dev/null | xxd -p)"
  [ "$magic" = "e0f5e1e2" ]
}

extract_image() {
  local img="$1"
  local out="$2"
  mkdir -p "$out"
  if is_erofs "$img"; then
    echo "$(basename "$img") detected as EROFS"
    fsck.erofs --extract="$out" "$img" > /dev/null
  else
    echo "ERROR: $(basename "$img") is NOT EROFS."
    echo "This workflow currently only automates EROFS system/vendor images."
    echo "Your ROM likely uses ext4 for this partition — the extract/repack steps"
    echo "need to be swapped to a loop-mount + make_ext4fs based approach."
    echo "Stopping here rather than silently producing a broken image."
    exit 1
  fi
}

repack_image() {
  local src_dir="$1"
  local out_img="$2"
  local mount_point="$3"   # e.g. /system or /vendor — cosmetic but matches AOSP convention
  mkfs.erofs --quiet -zlz4hc,9 --mount-point="$mount_point" "$out_img" "$src_dir"
  echo "Repacked -> $out_img ($(du -h "$out_img" | cut -f1))"
}

# --- system.img ------------------------------------------------------------
echo "=== Patching system.img ==="
extract_image "$RESULT_DIR/system.img" "$SYS_EXTRACT"

BUILD_PROP="$SYS_EXTRACT/system/build.prop"
if [ ! -f "$BUILD_PROP" ]; then
  BUILD_PROP="$(find "$SYS_EXTRACT" -maxdepth 2 -name build.prop | head -n1)"
fi
if [ -n "$BUILD_PROP" ] && [ -f "$BUILD_PROP" ]; then
  sed -i \
    -e 's/^ro\.debuggable=0$/ro.debuggable=1/' \
    -e 's/^ro\.force\.debuggable=0$/ro.force.debuggable=1/' \
    "$BUILD_PROP"
  echo "Patched build.prop at $BUILD_PROP"
else
  echo "WARNING: build.prop not found — skipping this patch"
fi

if [ "$TRANSSION_ANTICRACK" = "true" ]; then
  INIT_RC="$SYS_EXTRACT/system/etc/init/hw/init.rc"
  if [ -f "$INIT_RC" ]; then
    # Remove the vfy_boot line inside the anti-crack block
    sed -i '/vfy_boot/d' "$INIT_RC"

    # Insert an "on early-init" permissive block right after the BSP end marker,
    # unless we've already added it (idempotent re-runs).
    if ! grep -q "Force SELinux Permissive" "$INIT_RC"; then
      awk '
        { print }
        /BSP:add tran verify para NFRFP-22376 by wang.qin 20231228 end/ {
          print ""
          print "on early-init"
          print "    # Force SELinux Permissive"
          print "    write /sys/fs/selinux/enforce 0"
          print "    setenforce 0"
          print "    setprop ro.boot.selinux permissive"
        }
      ' "$INIT_RC" > "$INIT_RC.tmp" && mv "$INIT_RC.tmp" "$INIT_RC"
    fi
    echo "Patched Transsion anti-crack block in $INIT_RC"
  else
    echo "WARNING: init.rc not found at expected path — skipping anti-crack patch"
  fi
fi

SYS_SEPOLICY="$SYS_EXTRACT/system/etc/selinux/system_sepolicy.cil"
if [ -f "$SYS_SEPOLICY" ]; then
  if ! grep -q "allow system_init selinuxfs" "$SYS_SEPOLICY"; then
    {
      echo "(allow system_init selinuxfs (file (write)))"
      echo "(allow system_init kernel (security (setenforce)))"
    } >> "$SYS_SEPOLICY"
    echo "Patched $SYS_SEPOLICY"
  fi
else
  echo "system_sepolicy.cil not present — skipping (this is expected on some ROMs)"
fi

rm -f "$RESULT_DIR/system.img"
repack_image "$SYS_EXTRACT" "$RESULT_DIR/system.img" "/system"

# --- vendor.img --------------------------------------------------------
echo "=== Patching vendor.img ==="
extract_image "$RESULT_DIR/vendor.img" "$VEND_EXTRACT"
extract_image "$TARGET_UNPACKED/vendor.img" "$TARGET_VEND_EXTRACT" 2>/dev/null || \
  extract_image "$TARGET_UNPACKED/vendor_a.img" "$TARGET_VEND_EXTRACT"

# Copy target's selinux dir + passwd + group into result vendor (same relative paths)
rm -rf "$VEND_EXTRACT/vendor/etc/selinux"
cp -r "$TARGET_VEND_EXTRACT/vendor/etc/selinux" "$VEND_EXTRACT/vendor/etc/selinux"
cp "$TARGET_VEND_EXTRACT/vendor/etc/passwd" "$VEND_EXTRACT/vendor/etc/passwd"
cp "$TARGET_VEND_EXTRACT/vendor/etc/group" "$VEND_EXTRACT/vendor/etc/group"
echo "Copied target selinux/passwd/group into result vendor"

VEND_SEPOLICY="$VEND_EXTRACT/vendor/etc/selinux/vendor_sepolicy.cil"
if [ -f "$VEND_SEPOLICY" ]; then
  if ! grep -q "allow vendor_init selinuxfs" "$VEND_SEPOLICY"; then
    {
      echo "(allow vendor_init selinuxfs (file (write)))"
      echo "(allow vendor_init kernel (security (setenforce)))"
    } >> "$VEND_SEPOLICY"
    echo "Patched $VEND_SEPOLICY"
  fi
else
  echo "WARNING: vendor_sepolicy.cil not found after copying target selinux dir — check paths"
fi

IFS=',' read -ra CODENAMES <<< "$DEVICE_CODENAMES"
for CODE in "${CODENAMES[@]}"; do
  CODE_TRIMMED="$(echo "$CODE" | xargs)"
  RC_FILE="$VEND_EXTRACT/vendor/etc/init/hw/init.ums9230_${CODE_TRIMMED}.rc"
  if [ -f "$RC_FILE" ]; then
    if ! grep -q "SELinux Permissive Mode" "$RC_FILE"; then
      cat >> "$RC_FILE" << 'EOF'

# SELinux Permissive Mode

on early-init
    # Set SELinux to permissive mode
    write /sys/fs/selinux/enforce 0
    setenforce 0

on boot
    # Keep SELinux permissive after boot
    write /sys/fs/selinux/enforce 0
    exec u:r:su:s0 root root -- /system/bin/setenforce 0

on property:sys.boot_completed=1
    # Ensure permissive after boot complete
    write /sys/fs/selinux/enforce 0
EOF
    fi
    echo "Patched $RC_FILE"
  else
    echo "WARNING: $RC_FILE not found — check the codename you passed in device_codenames"
  fi
done

rm -f "$RESULT_DIR/vendor.img"
repack_image "$VEND_EXTRACT" "$RESULT_DIR/vendor.img" "/vendor"

echo "=== Patching complete ==="
