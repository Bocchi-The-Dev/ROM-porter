#!/usr/bin/env python3
"""
build_super.py

Reads the partition-table metadata off the ORIGINAL stock super.img by parsing Android's
"liblp" on-disk format directly, then uses it to rebuild a new super.img with lpmake,
swapping in the patched partition images from the Result Port Rom folder.

This does NOT use `lpdump` — that tool pulls in a specific protobuf/abseil ABI for its
--json output that isn't reliably available as a system package, which turned into more
of a headache than it was worth. The LP metadata format itself is small, versioned, and
documented (AOSP system/core/fs_mgr/liblp), so we just read it ourselves with `struct`.
Verified against the AOSP source and the Kaitai Struct community spec
(https://formats.kaitai.io/android_super/) rather than from memory.

Only bin/lpmake is required now (not lpdump).

NOTE on accuracy: metadata_slots and the exact A/B flag set are inferred from the parsed
geometry plus the partition_type you chose. These are standard AOSP lpmake conventions, but
super.img layouts vary slightly across OEM forks (Transsion/Spreadtrum forks especially) —
treat the printed lpmake command as something to sanity-check before flashing, not as
guaranteed-correct for every device.
"""
import argparse
import os
import struct
import subprocess
import sys

LPMAKE_BIN = os.path.join("bin", "lpmake")

GEOMETRY_MAGIC = b"gDla"
HEADER_MAGIC = b"0PLA"
GEOMETRY_SIZE = 0x1000       # reserved block size for each geometry copy
GEOMETRY_PRIMARY_OFFSET = 0x1000
GEOMETRY_BACKUP_OFFSET = 0x2000
METADATA_REGION_OFFSET = 0x3000  # right after primary + backup geometry blocks

PARTITION_FILES = [
    "system", "system_ext", "product",
    "vendor", "vendor_dlkm",
    "odm", "odm_dlkm",
    "system_dlkm",
]


def read_geometry(f, offset):
    f.seek(offset)
    blob = f.read(GEOMETRY_SIZE)
    if blob[0:4] != GEOMETRY_MAGIC:
        return None
    struct_size, = struct.unpack_from("<I", blob, 4)
    # skip 32-byte checksum at offset 8
    metadata_max_size, metadata_slot_count, logical_block_size = struct.unpack_from("<III", blob, 8 + 32)
    return {
        "struct_size": struct_size,
        "metadata_max_size": metadata_max_size,
        "metadata_slot_count": metadata_slot_count,
        "logical_block_size": logical_block_size,
    }


def read_metadata_header(f, offset):
    f.seek(offset)
    # Header is at least 128 bytes (v1.0); read a bit more in case of an
    # extended header, we only use the fixed-position fields below anyway.
    blob = f.read(256)
    if blob[0:4] != HEADER_MAGIC:
        return None
    major_version, minor_version = struct.unpack_from("<HH", blob, 4)
    header_size, = struct.unpack_from("<I", blob, 8)
    # header_checksum: 32 bytes at offset 12
    tables_size, = struct.unpack_from("<I", blob, 12 + 32)
    # tables_checksum: 32 bytes at offset 48
    descriptors_offset = 12 + 32 + 4 + 32  # == 80
    # Table descriptor order on disk: partitions, extents, groups, block_devices
    # Each descriptor is 3x u4 = 12 bytes: (offset, num_entries, entry_size)
    partitions_desc = struct.unpack_from("<III", blob, descriptors_offset)
    extents_desc = struct.unpack_from("<III", blob, descriptors_offset + 12)
    groups_desc = struct.unpack_from("<III", blob, descriptors_offset + 24)
    block_devices_desc = struct.unpack_from("<III", blob, descriptors_offset + 36)
    return {
        "major_version": major_version,
        "minor_version": minor_version,
        "header_size": header_size,
        "tables_size": tables_size,
        "groups_desc": groups_desc,       # (offset, num_entries, entry_size)
        "block_devices_desc": block_devices_desc,
    }


def read_groups(f, slot_offset, header, blob_header_size):
    offset, num_entries, entry_size = header["groups_desc"]
    pos = slot_offset + header["header_size"] + offset
    f.seek(pos)
    groups = []
    for i in range(num_entries):
        entry = f.read(entry_size)
        name = entry[0:36].split(b"\x00", 1)[0].decode("utf-8", "replace")
        maximum_size, = struct.unpack_from("<Q", entry, 36 + 4)  # skip 36 name + 4 flags
        groups.append({"name": name, "maximum_size": maximum_size})
    return groups


def read_block_devices(f, slot_offset, header):
    offset, num_entries, entry_size = header["block_devices_desc"]
    pos = slot_offset + header["header_size"] + offset
    f.seek(pos)
    devices = []
    for i in range(num_entries):
        entry = f.read(entry_size)
        # first_logical_sector(8) + alignment(4) + alignment_offset(4) + size(8) + name(36) + flags(4)
        size, = struct.unpack_from("<Q", entry, 8 + 4 + 4)
        name = entry[24:24 + 36].split(b"\x00", 1)[0].decode("utf-8", "replace")
        devices.append({"name": name, "size": size})
    return devices


def parse_lp_metadata(path):
    with open(path, "rb") as f:
        geometry = read_geometry(f, GEOMETRY_PRIMARY_OFFSET)
        if geometry is None:
            print("Primary geometry magic mismatch, trying backup geometry...")
            geometry = read_geometry(f, GEOMETRY_BACKUP_OFFSET)
        if geometry is None:
            print("ERROR: could not find valid LP geometry (checked both primary and backup).")
            print("This file may not be a raw (unsparsed) super.img with dynamic partitions.")
            sys.exit(1)

        slot0_offset = METADATA_REGION_OFFSET
        header = read_metadata_header(f, slot0_offset)
        if header is None:
            print("ERROR: could not find valid LP metadata header at the primary metadata slot.")
            sys.exit(1)

        groups = read_groups(f, slot0_offset, header, header["header_size"])
        block_devices = read_block_devices(f, slot0_offset, header)

    return geometry, header, groups, block_devices


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

    if not os.path.exists(LPMAKE_BIN):
        print(f"ERROR: {LPMAKE_BIN} not found. Add an lpmake binary to bin/.")
        sys.exit(1)

    geometry, header, groups, block_devices = parse_lp_metadata(args.stock_super)

    if not block_devices:
        print("ERROR: no block devices found in parsed metadata.")
        sys.exit(1)
    super_device = block_devices[0]
    super_name = super_device["name"] or "super"
    super_size = super_device["size"]

    # Skip the reserved "default" group (0 max size, always present) if a real one exists.
    real_groups = [g for g in groups if g["name"] != "default"]
    main_group = real_groups[0] if real_groups else groups[0]
    group_name = main_group["name"] or "main"
    group_size = main_group["maximum_size"]

    metadata_slots = geometry["metadata_slot_count"]
    metadata_size = geometry["metadata_max_size"]

    print(f"Parsed from stock super.img:")
    print(f"  Super device: {super_name}, size={super_size}")
    print(f"  Group: {group_name}, max_size={group_size}")
    print(f"  Metadata slots: {metadata_slots}, metadata size: {metadata_size}")
    print(f"  All groups found: {[(g['name'], g['maximum_size']) for g in groups]}")
    print(f"  All block devices found: {[(d['name'], d['size']) for d in block_devices]}")

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
    run(cmd)

    size_mb = os.path.getsize(args.output) / (1024 * 1024)
    print(f"\nDone: {args.output} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    main()
