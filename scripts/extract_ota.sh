#!/usr/bin/env bash
# extract_ota.sh <ota_zip> <out_dir>
# Handles full OTA zips:
#   - A/B OTA with payload.bin -> extracts system/system_ext/product via payload-dumper-go
#   - zips containing super.img directly -> copies it out as out_dir/super.img
# Prints what it did; exits non-zero with a clear error otherwise.
set -euo pipefail

OTA_ZIP="$1"
OUT_DIR="$2"
mkdir -p "$OUT_DIR"

# Pin a known-good payload-dumper-go release. v2.x tarballs are named:
#   payload-dumper-go_<ver>_linux_amd64.tar.gz  (contains ./payload-dumper-go)
PD_VER="2.0.2"
PD_URL="https://github.com/ssut/payload-dumper-go/releases/download/${PD_VER}/payload-dumper-go_${PD_VER}_linux_amd64.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="${PAYLOAD_DUMPER_TOOLS_DIR:-$REPO_ROOT/work/tools}"

ensure_payload_dumper() {
  local bin="$TOOLS_DIR/payload-dumper-go"
  if [ -x "$bin" ]; then
    echo "$bin"
    return 0
  fi
  echo "payload-dumper-go not found, downloading v$PD_VER ..." >&2
  mkdir -p "$TOOLS_DIR"
  local tgz="$TOOLS_DIR/payload-dumper-go.tar.gz"
  curl -L --fail --retry 3 -o "$tgz" "$PD_URL"
  tar -xzf "$tgz" -C "$TOOLS_DIR"
  rm -f "$tgz"
  chmod +x "$bin"
  echo "$bin"
}

echo "Listing OTA contents:"
unzip -l "$OTA_ZIP" | head -n 30

PAYLOAD_BIN="$(unzip -l "$OTA_ZIP" | awk '{print $4}' | grep -E '(^|/)payload\.bin$' | head -n1 || true)"
SUPER_IN_ZIP="$(unzip -l "$OTA_ZIP" | awk '{print $4}' | grep -iE '(^|/)super\.img$' | head -n1 || true)"

if [ -n "$PAYLOAD_BIN" ]; then
  echo "A/B OTA detected (payload.bin present)"
  PD_BIN="$(ensure_payload_dumper)"
  UNZIP_DIR="$(mktemp -d)"
  echo "Extracting payload.bin from OTA..."
  unzip -p "$OTA_ZIP" "$PAYLOAD_BIN" > "$UNZIP_DIR/payload.bin"

  echo "Payload partitions:"
  if "$PD_BIN" -l "$UNZIP_DIR/payload.bin" 2>/dev/null | head -n 40; then
    :
  else
    # older -l flag name or list unsupported; continue to extraction anyway
    echo "(partition listing unavailable, continuing)"
  fi

  echo "Extracting system/system_ext/product from payload..."
  # -p takes a comma-separated partition list on v1.3+ and v2.x. If the
  # flag ever changes, fall back to a full extraction and pick what we need.
  if ! "$PD_BIN" -o "$OUT_DIR" -p "system,system_ext,product" "$UNZIP_DIR/payload.bin"; then
    echo "'-p' selection unsupported, extracting full payload instead..."
    "$PD_BIN" -o "$OUT_DIR" "$UNZIP_DIR/payload.bin"
  fi
  rm -rf "$UNZIP_DIR"

  for NAME in system system_ext product; do
    if [ ! -f "$OUT_DIR/${NAME}.img" ]; then
      echo "ERROR: payload.bin did not contain partition '$NAME'."
      echo "Partitions actually extracted:"
      ls -la "$OUT_DIR"
      exit 1
    fi
  done
  echo "OTA partitions ready in $OUT_DIR:"
  ls -la "$OUT_DIR"/{system,system_ext,product}.img
elif [ -n "$SUPER_IN_ZIP" ]; then
  echo "OTA contains super.img directly ($SUPER_IN_ZIP) — extracting it"
  unzip -p "$OTA_ZIP" "$SUPER_IN_ZIP" > "$OUT_DIR/super.img"
  echo "Wrote $OUT_DIR/super.img"
else
  echo "ERROR: this zip is neither an A/B OTA (no payload.bin) nor does it"
  echo "contain super.img. Contents:"
  unzip -l "$OTA_ZIP" | head -n 40
  echo "Legacy block-based OTAs (system.new.dat.br) are not supported yet."
  exit 1
fi
