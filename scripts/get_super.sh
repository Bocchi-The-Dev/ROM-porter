#!/usr/bin/env bash
# get_super.sh <raw_input_dir> <out_dir> <type>
# type is one of: super.img | super.bin | pac | pac.zip
# Writes out_dir/super.img
set -euo pipefail

RAW_DIR="$1"
OUT_DIR="$2"
TYPE="$3"
mkdir -p "$OUT_DIR"

INPUT_FILE="$(find "$RAW_DIR" -maxdepth 1 -type f -name 'input.*' | head -n1)"
if [ -z "$INPUT_FILE" ]; then
  echo "ERROR: no input file found in $RAW_DIR"
  exit 1
fi

run_pacextractor() {
  local pac_file="$1"
  local pac_workdir
  pac_workdir="$(mktemp -d)"
  cp "$pac_file" "$pac_workdir/"
  local pac_name
  pac_name="$(basename "$pac_file")"
  local pac_out="$pac_workdir/out"

  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local pacextractor="$repo_root/bin/pacextractor"
  if [ ! -x "$pacextractor" ]; then
    echo "ERROR: $pacextractor not found or not executable."
    echo "The repo must contain the pacextractor binary under bin/ (git keeps its +x bit)."
    exit 1
  fi

  # pacextractor usage: pacextractor [-d] [-c] firmware.pac [outdir].
  # Give it an explicit outdir so output location is deterministic (older notes
  # suggested running it from its own directory, but it honors CWD/outdir for
  # output — keep everything inside our workdir instead of polluting the repo).
  (cd "$pac_workdir" && "$pacextractor" "$pac_name" "$pac_out")

  echo "pacextractor output:"
  find "$pac_out" -maxdepth 2 | head -n 30

  # PAC layouts vary: super may appear as super.img, super.bin, or bare `super`.
  local found
  found="$(find "$pac_out" -maxdepth 3 -type f \( -iname 'super.img' -o -iname 'super.bin' -o -iname 'super' \) 2>/dev/null | head -n1)"
  if [ -z "$found" ]; then
    echo "ERROR: pacextractor ran but no super image was found."
    echo "If super came out under a different name, rename/copy it to super.img manually."
    exit 1
  fi
  echo "Found super partition at: $found"
  cp "$found" "$OUT_DIR/super.img"
}

case "$TYPE" in
  super.img|super.bin)
    echo "Type is $TYPE — copying as-is"
    cp "$INPUT_FILE" "$OUT_DIR/super.img"
    ;;

  pac)
    echo "Type is pac — running pacextractor directly"
    run_pacextractor "$INPUT_FILE"
    ;;

  pac.zip)
    echo "Type is pac.zip — unzipping to find the .pac first"
    UNZIP_DIR="$(mktemp -d)"
    unzip -q "$INPUT_FILE" -d "$UNZIP_DIR"

    PAC_INSIDE="$(find "$UNZIP_DIR" -type f -iname '*.pac' | head -n1)"
    if [ -z "$PAC_INSIDE" ]; then
      echo "ERROR: no .pac file found inside the zip. Contents:"
      find "$UNZIP_DIR" -type f
      exit 1
    fi
    echo "Found .pac inside zip: $PAC_INSIDE"
    run_pacextractor "$PAC_INSIDE"
    ;;

  *)
    echo "ERROR: unknown type '$TYPE' (expected super.img, super.bin, pac, or pac.zip;"
    echo "OTA zips go through scripts/extract_ota.sh instead)"
    exit 1
    ;;
esac

echo "Ready: $OUT_DIR/super.img ($(du -h "$OUT_DIR/super.img" | cut -f1))"

# Android sparse images can't be unpacked directly by lpunpack — detect and convert to raw.
# Sparse magic is 0xED26FF3A, stored little-endian as bytes 3A FF 26 ED at offset 0.
MAGIC="$(head -c 4 "$OUT_DIR/super.img" | xxd -p)"
if [ "$MAGIC" = "3aff26ed" ]; then
  echo "super.img is a sparse image — converting to raw with simg2img"
  mv "$OUT_DIR/super.img" "$OUT_DIR/super.sparse.img"
  simg2img "$OUT_DIR/super.sparse.img" "$OUT_DIR/super.img"
  rm -f "$OUT_DIR/super.sparse.img"
  echo "Converted: $OUT_DIR/super.img ($(du -h "$OUT_DIR/super.img" | cut -f1))"
else
  echo "super.img is already a raw (non-sparse) image"
fi
