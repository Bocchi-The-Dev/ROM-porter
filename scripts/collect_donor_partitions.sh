#!/usr/bin/env bash
# collect_donor_partitions.sh <target_unpacked_dir> <result_dir>
set -euo pipefail

TARGET_DIR="$1"
RESULT_DIR="$2"
mkdir -p "$RESULT_DIR"

find_partition() {
  local dir="$1"
  local name="$2"
  if [ -f "$dir/${name}.img" ]; then
    echo "$dir/${name}.img"
  elif [ -f "$dir/${name}_a.img" ]; then
    echo "$dir/${name}_a.img"
  else
    echo ""
  fi
}

for NAME in system system_ext product; do
  SRC="$(find_partition "$TARGET_DIR" "$NAME")"
  if [ -z "$SRC" ]; then
    echo "ERROR: required partition '$NAME' not found in $TARGET_DIR"
    exit 1
  fi
  cp "$SRC" "$RESULT_DIR/${NAME}.img"
  echo "Copied ${NAME}.img from $(basename "$TARGET_DIR")"
done

echo "Result folder now contains:"
ls -la "$RESULT_DIR"
