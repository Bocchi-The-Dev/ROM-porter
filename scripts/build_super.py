#!/usr/bin/env python3
"""
build_super.py

Reads the partition-table metadata off the ORIGINAL stock super.img (via `lpdump --json`)
and uses it to rebuild a new super.img with lpmake, swapping in the patched partition images
from the Result Port Rom folder.

Assumes bin/lpdump and bin/lpmake exist in the repo (same pattern as pacextractor/lpunpack).

NOTE on accuracy: metadata_slots and the exact A/B flag set are inferred from lpdump's JSON
output plus the partition_type you chose. These are standard AOSP lpmake conventions, but
super.img layouts vary slightly across OEM forks (Transsion/Spreadtrum forks especially) —
treat the printed lpmake command as something to sanity-check against `lpdump` output for
your specific stock ROM before flashing, not as guaranteed-correct for every device.
"""
import argparse
import json
import os
import subprocess
import sys

PARTITION_FILES = [
    "system", "system_ext", "product",
    "vendor", "vendor_dlkm",
    "odm", "odm_dlkm",
    "system_dlkm",
]

LPDUMP_BIN = os.path.join("bin", "lpdump")
LPMAKE_BIN = os.path.join("bin", "lpmake")


def run(cmd):
    print("+", " ".join(cmd))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"--- {cmd[0]} failed (exit {result.returncode}) ---")
        print("stdout:", result.stdout)
        print("stderr:", result.stderr)
        raise subprocess.CalledProcessError(result.returncode, cmd, result.stdout, result.stderr)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock-super", required=True)
    ap.add_argument("--result-dir", required=True)
    ap.add_argument("--partition-type", required=True, choices=["a-only", "ab", "virtual-ab"])
    ap.add_argument("--output", required=True)
    ap.add_argument("--sparse", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(LPDUMP_BIN):
        print(f"ERROR: {LPDUMP_BIN} not found. Add an lpdump binary to bin/ (same as lpmake/lpunpack).")
        sys.exit(1)

    # Sanity-check the binary can actually run before trying to use it for real —
    # exit code 127 from lpdump itself (not "file not found") usually means it's a
    # dynamically-linked binary missing a shared library, or built for the wrong
    # architecture. `file` and `ldd` output here will show which.
    check = subprocess.run(["file", LPDUMP_BIN], capture_output=True, text=True)
    print(f"{LPDUMP_BIN}: {check.stdout.strip()}")
    ldd_check = subprocess.run(["ldd", LPDUMP_BIN], capture_output=True, text=True)
    if "not found" in ldd_check.stdout:
        print(f"WARNING: {LPDUMP_BIN} is missing shared libraries:")
        print(ldd_check.stdout)

    dump = run([LPDUMP_BIN, "--json", args.stock_super])
    try:
        meta = json.loads(dump.stdout)
    except json.JSONDecodeError:
        print("ERROR: could not parse lpdump --json output. Raw output was:")
        print(dump.stdout)
        sys.exit(1)

    block_devices = meta.get("block_devices", [])
    groups = meta.get("groups", [])
    if not block_devices or not groups:
        print("ERROR: lpdump output missing block_devices/groups — cannot infer super/group size.")
        print(json.dumps(meta, indent=2)[:2000])
        sys.exit(1)

    super_device = block_devices[0]
    super_name = super_device.get("name", "super")
    super_size = super_device["size"]

    main_group = groups[0]
    group_name = main_group.get("name", "main")
    group_size = main_group["maximum_size"]

    metadata_slots = meta.get("metadata_slot_count") or meta.get("metadata_slots") or 2
    metadata_size = meta.get("metadata_max_size", 65536)

    print(f"Super device: {super_name}, size={super_size}")
    print(f"Group: {group_name}, max_size={group_size}")
    print(f"Metadata slots: {metadata_slots}, metadata size: {metadata_size}")

    # Collect the partition images actually present in the result folder.
    images = {}
    for part in PARTITION_FILES:
        path = os.path.join(args.result_dir, f"{part}.img")
        if os.path.exists(path):
            images[part] = path
    if not images:
        print(f"ERROR: no partition images found in {args.result_dir}")
        sys.exit(1)

    print("Partitions to pack:", ", ".join(images.keys()))

    cmd = [
        LPMAKE_BIN,
        "--metadata-size", str(metadata_size),
        "--metadata-slots", str(metadata_slots),
        "--device", f"{super_name}:{super_size}",
        "--group", f"{group_name}:{group_size}",
    ]

    if args.partition_type in ("ab", "virtual-ab"):
        cmd.append("--auto-slot-suffixing")
    if args.partition_type == "virtual-ab":
        cmd.append("--virtual-ab")

    for part, path in images.items():
        size = os.path.getsize(path)
        cmd += ["--partition", f"{part}:readonly:{size}:{group_name}"]
        cmd += ["--image", f"{part}={path}"]

    if args.sparse:
        cmd.append("--sparse")

    cmd += ["--output", args.output]

    print("\nFinal lpmake command:")
    print(" ".join(cmd))
    subprocess.run(cmd, check=True)

    size_mb = os.path.getsize(args.output) / (1024 * 1024)
    print(f"\nDone: {args.output} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
