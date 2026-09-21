#!/usr/bin/env bash
# extract_ota.sh <ota_zip> <out_dir> [base_ota_zip]
# Handles full OTA zips:
#   - A/B OTA with payload.bin -> extracts system/system_ext/product via payload-dumper-go
#   - zips containing super.img directly -> copies it out as out_dir/super.img
# Incremental (delta) OTAs are detected early from OTA metadata AND from
# payload-dumper-go's output. They need the base FULL OTA's images passed via
# [base_ota_zip] (extracted to a temp dir and given to payload-dumper-go -old).
# Prints what it did; exits non-zero with a clear error otherwise.
set -euo pipefail

OTA_ZIP="$1"
OUT_DIR="$2"
BASE_OTA_ZIP="${3:-}"
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

fail_incremental_no_base() {
  echo ""
  echo "ERROR: this is an INCREMENTAL (delta) OTA, not a full OTA."
  echo "It contains only binary patches (your 68 MB zip vs GBs for a full"
  echo "ROM: product alone is ~1.8 GB) and needs the source images to apply"
  echo "them to. payload-dumper-go says:"
  echo "  'this is a delta payload; source images are required (pass -old)'."
  echo ""
  echo "Fix — pick ONE:"
  echo "  1) Use a FULL OTA zip instead (recommended). Same version, but the"
  echo "     full-size file (several GB). Re-run with that URL."
  echo "  2) Keep this incremental AND supply its base FULL OTA via the"
  echo "     workflow input 'base_ota_url' (or: extract_ota.sh ota.zip out/ base.zip)."
  echo "     The base must be the exact build named by this OTA's"
  echo "     META-INF/com/android/metadata 'pre-build' field."
  echo ""
  exit 1
}

echo "Listing OTA contents:"
unzip -l "$OTA_ZIP" | head -n 30

PAYLOAD_BIN="$(unzip -l "$OTA_ZIP" | awk '{print $4}' | grep -E '(^|/)payload\.bin$' | head -n1 || true)"
SUPER_IN_ZIP="$(unzip -l "$OTA_ZIP" | awk '{print $4}' | grep -iE '(^|/)super\.img$' | head -n1 || true)"

if [ -n "$PAYLOAD_BIN" ]; then
  echo "A/B OTA detected (payload.bin present)"

  # --- Early incremental check from OTA metadata (before touching payload.bin).
  # Full A/B OTAs have no pre-build/pre-device; incremental ones do, and often
  # carry ota-type=AB_INCREMENTAL. This gives a fast, clear failure instead of
  # a confusing payload-dumper-go error 10 minutes into the run.
  META_TXT="$(unzip -p "$OTA_ZIP" META-INF/com/android/metadata 2>/dev/null || true)"
  if [ -n "$META_TXT" ]; then
    echo "--- META-INF/com/android/metadata ---"
    echo "$META_TXT"
    echo "--- end metadata ---"
  fi
  PAYLOAD_PROPS="$(unzip -p "$OTA_ZIP" payload_properties.txt 2>/dev/null || true)"
  if [ -n "$PAYLOAD_PROPS" ]; then
    echo "--- payload_properties.txt ---"
    echo "$PAYLOAD_PROPS"
    echo "--- end payload_properties.txt ---"
  fi
  if echo "$META_TXT" | grep -qiE '^(pre-build|pre-device|ota-type=.*incremental)'; then
    echo "INCREMENTAL OTA detected from metadata (pre-build/pre-device present)."
    if [ -z "$BASE_OTA_ZIP" ]; then
      fail_incremental_no_base
    else
      echo "Base OTA supplied ($BASE_OTA_ZIP) — will apply delta on top of it."
    fi
  fi

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

  # Helper: run payload-dumper-go, capturing output so we can detect the
  # "delta needs -old" failure and re-run against base images instead of
  # dumping a raw stack trace on the user.
  # Usage: try_extract <extra_old_flag...> -- <pd_args...>
  OLD_FLAG=()
  if [ -n "$BASE_OTA_ZIP" ]; then
    BASE_DIR="$(mktemp -d)"
    echo "Extracting BASE full OTA ($BASE_OTA_ZIP) to $BASE_DIR ..."
    # payload-dumper-go accepts an OTA zip directly, no temp payload.bin needed.
    if ! "$PD_BIN" -o "$BASE_DIR" "$BASE_OTA_ZIP" 2>&1 | tee "$UNZIP_DIR/base_extract.log"; then
      echo "ERROR: failed to extract the BASE OTA. It must be a FULL OTA zip"
      echo "(payload.bin with full images), not another incremental."
      echo "Base extract log tail:"
      tail -n 20 "$UNZIP_DIR/base_extract.log" || true
      exit 1
    fi
    echo "Base images ready:"
    ls -la "$BASE_DIR"
    OLD_FLAG=(-old "$BASE_DIR")
  fi

  echo "Extracting system/system_ext/product from payload..."
  # -p takes a comma-separated partition list on v1.3+ and v2.x. If the
  # flag ever changes, fall back to a full extraction and pick what we need.
  PD_LOG="$UNZIP_DIR/pd_extract.log"
  run_pd() {
    # $@ = payload-dumper-go args after the binary name
    set +e
    "$PD_BIN" "$@" 2>&1 | tee "$PD_LOG"
    local rc=${PIPESTATUS[0]}
    set -e
    return $rc
  }
  if ! run_pd -o "$OUT_DIR" "${OLD_FLAG[@]}" -p "system,system_ext,product" "$UNZIP_DIR/payload.bin"; then
    if grep -qiE 'source images are required|delta.*payload|incremental|-old' "$PD_LOG"; then
      if [ ${#OLD_FLAG[@]} -eq 0 ]; then
        echo ""
        fail_incremental_no_base
      fi
      echo "'-p' selection failed even with -old; trying full extraction with -old..."
      run_pd -o "$OUT_DIR" "${OLD_FLAG[@]}" "$UNZIP_DIR/payload.bin" || {
        echo "ERROR: payload extraction failed even with base images."
        echo "The delta may use PUFFDIFF/ZUCCHINI/LZ4DIFF ops which"
        echo "payload-dumper-go cannot apply. Try a FULL OTA instead."
        exit 1
      }
    else
      echo "'-p' selection unsupported, extracting full payload instead..."
      run_pd -o "$OUT_DIR" "${OLD_FLAG[@]}" "$UNZIP_DIR/payload.bin" || exit 1
    fi
  fi
  rm -rf "$UNZIP_DIR"
  if [ -n "${BASE_DIR:-}" ]; then
    rm -rf "$BASE_DIR"
  fi
  # NOTE: BASE_DIR (if set) held full base images only for delta application;
  # it is removed here. OUT_DIR now holds the final (patched-base) images.

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
