#!/usr/bin/env bash
# get_super.sh <raw_input_dir> <out_dir>
# raw_input_dir must contain exactly one file: input.pac OR input.img OR input.bin
# Writes out_dir/super.img
set -euo pipefail

RAW_DIR="$1"
OUT_DIR="$2"
mkdir -p "$OUT_DIR"

INPUT_FILE="$(find "$RAW_DIR" -maxdepth 1 -type f -name 'input.*' | head -n1)"
if [ -z "$INPUT_FILE" ]; then
  echo "ERROR: no input file found in $RAW_DIR"
  exit 1
fi

case "$INPUT_FILE" in
  *.pac)
    echo "Input is a .pac — running pacextractor"
    PAC_WORKDIR="$(mktemp -d)"
    cp "$INPUT_FILE" "$PAC_WORKDIR/"
    PAC_NAME="$(basename "$INPUT_FILE")"

    # pacextractor is invoked from its own directory (./pacextractor file.pac) per your usage note.
    # We run it from a temp workdir and search both ./output/ next to the binary AND next to the .pac,
    # since different builds of pacextractor drop output in different places.
    BIN_ABS="$(realpath bin/pacextractor)"
    (cd "$PAC_WORKDIR" && "$BIN_ABS" "$PAC_NAME")

    FOUND="$(find "$PAC_WORKDIR" "$(dirname "$BIN_ABS")" -maxdepth 3 -type f \( -iname 'super.img' -o -iname 'super.bin' \) 2>/dev/null | head -n1)"
    if [ -z "$FOUND" ]; then
      echo "ERROR: pacextractor ran but no super.img/super.bin was found."
      echo "Searched under: $PAC_WORKDIR and $(dirname "$BIN_ABS")"
      echo "Full extracted listing for debugging:"
      find "$PAC_WORKDIR" "$(dirname "$BIN_ABS")" -maxdepth 3
      exit 1
    fi
    echo "Found super partition at: $FOUND"
    cp "$FOUND" "$OUT_DIR/super.img"
    ;;

  *.img|*.bin)
    echo "Input is already a raw super image — copying as-is"
    cp "$INPUT_FILE" "$OUT_DIR/super.img"
    ;;

  *)
    echo "ERROR: unrecognized input file extension: $INPUT_FILE"
    exit 1
    ;;
esac

echo "Ready: $OUT_DIR/super.img ($(du -h "$OUT_DIR/super.img" | cut -f1))"
