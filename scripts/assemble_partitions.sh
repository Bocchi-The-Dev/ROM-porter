#!/usr/bin/env bash
# assemble_partitions.sh <stock_unpacked_dir> <target_unpacked_dir> <result_dir>
set -euo pipefail

STOCK_DIR="$1"
TARGET_DIR="$2"
RESULT_DIR="$3"
mkdir -p "$RESULT_DIR"

# lpunpack sometimes names images with an "_a" slot suffix on A/B devices (system_a.img)
# instead of the plain name (system.img). find_partition() copes with either.
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

copy_partition() {
  local dir="$1"
  local name="$2"
  local required="$3"   # "required" or "optional"
  local src
  src="$(find_partition "$dir" "$name")"
  if [ -n "$src" ]; then
    cp "$src" "$RESULT_DIR/${name}.img"
    echo "Copied $name.img from $(basename "$dir")"
  elif [ "$required" = "required" ]; then
    echo "ERROR: required partition '$name' not found in $dir"
    exit 1
  else
    echo "Skipping optional partition '$name' — not present in $dir"
  fi
}

echo "--- From STOCK: vendor + dlkm partitions ---"
copy_partition "$STOCK_DIR" "vendor"        required
copy_partition "$STOCK_DIR" "system_dlkm"   optional
copy_partition "$STOCK_DIR" "odm"           optional
copy_partition "$STOCK_DIR" "vendor_dlkm"   optional
copy_partition "$STOCK_DIR" "odm_dlkm"      optional

echo "--- From TARGET: system + system_ext + product ---"
copy_partition "$TARGET_DIR" "system"       required
copy_partition "$TARGET_DIR" "system_ext"   required
copy_partition "$TARGET_DIR" "product"      required

echo "Result Port Rom folder now contains:"
ls -la "$RESULT_DIR"
