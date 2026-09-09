#!/usr/bin/env bash
# patch_system.sh --system-img PATH --transsion-anticrack true|false
# Patches build.prop + (optionally) the Transsion anti-crack block directly in-place
# on the given system.img. No vendor involvement at all.
set -euo pipefail

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

WORK="$(mktemp -d)"
SYS_EXTRACT="$WORK/system"

is_erofs() {
  local img="$1"
  local magic
  magic="$(dd if="$img" bs=1 skip=1024 count=4 2>/dev/null | xxd -p)"
  [ "$magic" = "e2e1f5e0" ]
}

if ! is_erofs "$SYSTEM_IMG"; then
  echo "ERROR: $SYSTEM_IMG is not EROFS. This script only handles EROFS system images."
  exit 1
fi

mkdir -p "$SYS_EXTRACT"
sudo fsck.erofs --extract="$SYS_EXTRACT" "$SYSTEM_IMG" > /dev/null
sudo chown -R "$(id -u):$(id -g)" "$SYS_EXTRACT"

# Some system images have a top-level "system/" wrapper folder (system-as-root
# layout), others have content directly at the root. Detect rather than assume.
if [ -d "$SYS_EXTRACT/system" ]; then
  SYS_BASE="$SYS_EXTRACT/system"
else
  SYS_BASE="$SYS_EXTRACT"
fi
echo "System root: $SYS_BASE"

BUILD_PROP="$SYS_BASE/build.prop"
if [ -f "$BUILD_PROP" ]; then
  sed -i \
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
    if grep -q "vfy_boot" "$INIT_RC"; then
      # Only drop vfy_boot lines that are standalone statements. Blind
      # `sed -i '/vfy_boot/d'` will happily delete one line out of a
      # multi-line `\`-continued init.rc block, which corrupts the
      # init language parse and can hard-bootloop the device before
      # the boot animation — with no logcat available to explain why.
      # Lines that are themselves a continuation, or that end in `\`
      # (starting/continuing a multi-line block), are left untouched
      # and flagged for manual review instead.
      awk '
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
      mv "$INIT_RC.tmp" "$INIT_RC"
      if [ -s "$INIT_RC.removed" ]; then
        echo "Removed $(wc -l < "$INIT_RC.removed") standalone vfy_boot line(s):"
        cat "$INIT_RC.removed"
      fi
      rm -f "$INIT_RC.removed"
      if grep -q "vfy_boot" "$INIT_RC"; then
        echo "WARNING: vfy_boot still present — left in place because it's part of a multi-line block. Inspect manually:"
        grep -n "vfy_boot" "$INIT_RC"
      fi
    else
      echo "No vfy_boot references in $INIT_RC — nothing to remove (expected on donors like A13 TranssionOS)"
    fi
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

SYS_SEPOLICY="$SYS_BASE/etc/selinux/system_sepolicy.cil"
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

# "Fix Brightness and Lag." — appends patches/system.prop's contents onto build.prop.
if [ -n "$SYSTEM_PROP_FILE" ]; then
  if [ -f "$SYSTEM_PROP_FILE" ]; then
    if [ -f "$BUILD_PROP" ]; then
      echo "" >> "$BUILD_PROP"
      echo "# --- Appended from $SYSTEM_PROP_FILE (Fix Brightness and Lag.) ---" >> "$BUILD_PROP"
      cat "$SYSTEM_PROP_FILE" >> "$BUILD_PROP"
      echo "Appended $SYSTEM_PROP_FILE onto $BUILD_PROP"
    else
      echo "WARNING: --system-prop given but build.prop wasn't found — nothing to append to"
    fi
  else
    echo "ERROR: --system-prop file '$SYSTEM_PROP_FILE' not found"
    exit 1
  fi
fi

rm -f "$SYSTEM_IMG"
# -E legacy-compress: forces the older on-disk EROFS layout (no "decompression
# in-place"/"compacted indexes", which need kernel >= 5.3). Unisoc/Transsion
# devices often run older forked kernels, and EROFS deliberately refuses to
# mount images with feature flags it doesn't recognize — this is the fix for
# "device never reaches bootanim" when that's the actual cause.
mkfs.erofs --quiet -E legacy-compress -zlz4hc,9 --mount-point="/system" "$SYSTEM_IMG" "$SYS_EXTRACT"
echo "Repacked -> $SYSTEM_IMG ($(du -h "$SYSTEM_IMG" | cut -f1))"
