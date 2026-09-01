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
# EROFS superblock magic is 0xE0F5E1E2 (little-endian), stored on-disk at byte
# offset 1024 as the reversed byte sequence e2 e1 f5 e0.
is_erofs() {
  local img="$1"
  local magic
  magic="$(dd if="$img" bs=1 skip=1024 count=4 2>/dev/null | xxd -p)"
  [ "$magic" = "e2e1f5e0" ]
}

# ext4 magic is 0xEF53 (little-endian), stored at byte offset 0x438 (1080) as 53 ef.
is_ext4() {
  local img="$1"
  local magic
  magic="$(dd if="$img" bs=1 skip=1080 count=2 2>/dev/null | xxd -p)"
  [ "$magic" = "53ef" ]
}

extract_image() {
  local img="$1"
  local out="$2"
  mkdir -p "$out"
  if is_erofs "$img"; then
    echo "$(basename "$img") detected as EROFS"
    fsck.erofs --extract="$out" "$img" > /dev/null
  elif is_ext4 "$img"; then
    echo "$(basename "$img") detected as ext4 — extracting via loop mount"
    local mnt
    mnt="$(mktemp -d)"
    sudo mount -o loop,ro "$img" "$mnt"
    # -aX preserves perms/timestamps/xattrs (including security.selinux) where the
    # source mount exposes them; SELinux contexts on Android ext4 images are stored
    # as xattrs so this carries them across, but there's no e2fsdroid here to verify
    # them against a policy — spot-check with `getfattr -d` on a few files if in doubt.
    sudo rsync -aX "$mnt/" "$out/"
    sudo umount "$mnt"
    sudo chown -R "$(id -u):$(id -g)" "$out"
    rmdir "$mnt"
  else
    echo "ERROR: $(basename "$img") is neither EROFS nor ext4 (unrecognized superblock)."
    echo "First bytes at offset 1024 (erofs check) and 1080 (ext4 check) didn't match either magic."
    exit 1
  fi
}

# Tracks which format each image was, set by extract_image via a side-channel file,
# so repack_image can rebuild in the same format it extracted.
FMT_FILE="$WORK/fmt_map"
: > "$FMT_FILE"

extract_image_tracked() {
  local img="$1"
  local out="$2"
  local key="$3"
  if is_erofs "$img"; then
    echo "$key=erofs" >> "$FMT_FILE"
  elif is_ext4 "$img"; then
    echo "$key=ext4" >> "$FMT_FILE"
  fi
  extract_image "$img" "$out"
}

repack_image() {
  local src_dir="$1"
  local out_img="$2"
  local mount_point="$3"   # e.g. /system or /vendor — cosmetic but matches AOSP convention
  local key="$4"

  local fmt
  fmt="$(grep "^${key}=" "$FMT_FILE" | tail -n1 | cut -d= -f2)"

  if [ "$fmt" = "ext4" ]; then
    echo "Repacking $key as ext4"
    local size_bytes
    size_bytes="$(du -sb "$src_dir" | cut -f1)"
    # 25% headroom for filesystem overhead/metadata, rounded up to a 4K block.
    local target_bytes=$(( size_bytes + size_bytes / 4 + 4096 ))
    truncate -s "$target_bytes" "$out_img"
    mke2fs -q -t ext4 -O ^has_journal,^resize_inode -F "$out_img"
    local mnt
    mnt="$(mktemp -d)"
    sudo mount -o loop,rw "$out_img" "$mnt"
    sudo rsync -aX "$src_dir/" "$mnt/"
    sudo umount "$mnt"
    rmdir "$mnt"
    echo "Repacked -> $out_img ($(du -h "$out_img" | cut -f1))"
  else
    mkfs.erofs --quiet -zlz4hc,9 --mount-point="$mount_point" "$out_img" "$src_dir"
    echo "Repacked -> $out_img ($(du -h "$out_img" | cut -f1))"
  fi
}

# --- system.img ------------------------------------------------------------
echo "=== Patching system.img ==="
extract_image_tracked "$RESULT_DIR/system.img" "$SYS_EXTRACT" "system"

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
repack_image "$SYS_EXTRACT" "$RESULT_DIR/system.img" "/system" "system"

# --- vendor.img --------------------------------------------------------
echo "=== Patching vendor.img ==="
extract_image_tracked "$RESULT_DIR/vendor.img" "$VEND_EXTRACT" "vendor"

TARGET_VENDOR_IMG="$TARGET_UNPACKED/vendor.img"
if [ ! -f "$TARGET_VENDOR_IMG" ]; then
  TARGET_VENDOR_IMG="$TARGET_UNPACKED/vendor_a.img"
fi
if [ ! -f "$TARGET_VENDOR_IMG" ]; then
  echo "ERROR: could not find vendor.img or vendor_a.img in $TARGET_UNPACKED"
  exit 1
fi
extract_image "$TARGET_VENDOR_IMG" "$TARGET_VEND_EXTRACT"

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
repack_image "$VEND_EXTRACT" "$RESULT_DIR/vendor.img" "/vendor" "vendor"

echo "=== Patching complete ==="
