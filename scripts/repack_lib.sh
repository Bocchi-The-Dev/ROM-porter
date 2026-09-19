#!/usr/bin/env bash
# repack_lib.sh — shared helpers for losslessly rebuilding EROFS partition images.
#
# Root cause it fixes: rebuilding with bare `mkfs.erofs` (no ownership/label
# staging) produces images where every file is root-owned, modes come from the
# extraction umask, and SELinux labels are missing entirely. Such images mount
# fine on a PC but bootloop on device (init/avc denials, apexd failures).
#
# Method (validated): snapshot uid/gid/mode/label of EVERY file from a
# read-only loop mount of the source image, extract, patch, re-apply the
# snapshot onto the tree (chown/chmod/setfattr), then rebuild with upstream
# mkfs.erofs and verify the result file-by-file before replacing the original.
#
# Requirements: sudo (passwordless on GH runners), kernel erofs support,
# mkfs.erofs/fsck.erofs (apt: erofs-utils), python3.
set -euo pipefail

# SUDO may be pre-set by callers (e.g. empty when already root).
SUDO="${SUDO:-sudo}"

# need_sudo: fail fast with a clear message when sudo isn't usable.
need_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    return 0
  fi
  if ! $SUDO -n true 2>/dev/null; then
    echo "ERROR: this script needs root (sudo) to mount images and preserve"
    echo "file ownership. Rerun as root or with passwordless sudo available."
    exit 1
  fi
  SUDO="sudo"
}

# img_uuid <image> — print the erofs filesystem UUID (superblock offset 1072).
img_uuid() {
  python3 -c "
import uuid, sys
buf = open('$1','rb').read(2048)
print(uuid.UUID(bytes=buf[1072:1088]))
"
}

# mount_ro <image> <mnt> — loop-mount read-only (needs sudo).
mount_ro() {
  $SUDO mkdir -p "$2"
  $SUDO mount -o loop,ro "$1" "$2"
}

umount_mnt() {
  $SUDO umount "$1" 2>/dev/null || true
}

# snapshot_metadata <mount_dir> <out_tsv>
# Writes TSV: relpath<TAB>uid<TAB>gid<TAB>mode-octal<TAB>selinux-label-or-'-'
snapshot_metadata() {
  local mnt="$1" out="$2"
  $SUDO python3 - "$mnt" "$out" << 'PYEOF'
import os, stat, sys
mnt, out = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    for dp, dn, fn in os.walk(mnt, followlinks=False):
        for n in dn + fn:
            full = os.path.join(dp, n)
            rel = os.path.relpath(full, mnt)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            try:
                lab = os.getxattr(full, "security.selinux").decode()
            except OSError:
                lab = "-"
            f.write("%s\t%d\t%d\t%o\t%s\n" % (rel, st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode), lab))
PYEOF
  # TSV is written as root (walked a sudo mount); hand it back to the caller.
  $SUDO chown "$(id -u):$(id -g)" "$out"
}

# stage_metadata <tree_dir> <snapshot_tsv>
# Applies recorded uid/gid/mode/label onto an extracted tree, then RE-READS
# everything and fails loudly on any mismatch. This is the fs_config equivalent:
# even if extraction or patching mangled ownership/modes (wrong umask, sed -i
# recreating files as root, stray chown), the image is always built with the
# source image's exact permissions — never whatever the tree happens to have.
# Symlinks are labeled but never chmodded (kernel ignores symlink perms anyway).
stage_metadata() {
  local tree="$1" snap="$2"
  $SUDO python3 - "$tree" "$snap" << 'PYEOF'
import os, stat, sys
tree, snap = sys.argv[1], sys.argv[2]
errors = []
applied = 0
for line in open(snap):
    line = line.rstrip("\n")
    if not line:
        continue
    rel, uid, gid, mode, lab = line.split("\t")
    p = os.path.join(tree, rel)
    try:
        st = os.lstat(p)
    except OSError:
        continue
    try:
        os.lchown(p, int(uid), int(gid))
    except OSError as e:
        errors.append("chown fail: %s: %s" % (rel, e))
        continue
    if not stat.S_ISLNK(st.st_mode):
        try:
            os.chmod(p, int(mode, 8))
        except OSError as e:
            errors.append("chmod fail: %s: %s" % (rel, e))
            continue
    if lab != "-":
        try:
            os.setxattr(p, "security.selinux", lab.encode(), follow_symlinks=False)
        except OSError as e:
            errors.append("label fail: %s: %s" % (rel, e))
            continue
    applied += 1
# Enforcement pass: re-read and fail on ANY remaining mismatch, so a broken
# tree can never silently bake wrong permissions into the image.
bad = 0
for line in open(snap):
    line = line.rstrip("\n")
    if not line:
        continue
    rel, uid, gid, mode, lab = line.split("\t")
    p = os.path.join(tree, rel)
    try:
        st = os.lstat(p)
    except OSError:
        continue
    if (st.st_uid, st.st_gid) != (int(uid), int(gid)):
        errors.append("owner mismatch after stage: %s" % rel)
        bad += 1
    if not stat.S_ISLNK(st.st_mode) and stat.S_IMODE(st.st_mode) != int(mode, 8):
        errors.append("mode mismatch after stage: %s" % rel)
        bad += 1
print("staged metadata for %d paths (%d error(s))" % (applied, len(errors)))
for e in errors[:10]:
    print("STAGE-ERROR:", e)
sys.exit(1 if errors else 0)
PYEOF
}

# label_new_file <tree_file> <reference_file_in_tree>
# Labels a newly added file like its neighbor (same label as reference).
label_new_file() {
  local dst="$1" ref="$2"
  local lab
  lab="$($SUDO getfattr -n security.selinux --only-values "$ref" 2>/dev/null || true)"
  if [ -z "$lab" ]; then
    echo "WARNING: reference $ref has no SELinux label; defaulting new file to system_file"
    lab="u:object_r:system_file:s0"
  fi
  $SUDO setfattr -n security.selinux -v "$lab" "$dst"
}

# snapshot_label <mount_relative_path> <snapshot_tsv>
# Prints the SELinux label recorded for a path at snapshot time (i.e. the
# ground-truth label from the source image). Prefer this over reading labels
# off the extracted tree: extraction does not reliably restore xattrs, so a
# tree-side lookup can come back empty even when the source file is labeled.
snapshot_label() {
  local rel="$1" snap="$2"
  awk -F'\t' -v want="$rel" '$1 == want { print $5; found=1; exit } END { if (!found) exit 1 }' "$snap"
}

# verify_repack <new_img> <orig_mount_dir> [ignore_prefix...]
# Mounts new_img and requires: zero unreadable inodes, zero metadata diffs
# (mode/uid/gid/label, symlinks excluded) outside the given ignore prefixes.
# Returns non-zero (and prints diffs) on any mismatch.
verify_repack() {
  local new_img="$1" orig_mnt="$2"
  shift 2
  local mnt
  mnt="$(mktemp -d)"
  mount_ro "$new_img" "$mnt"
  local rc=0
  $SUDO python3 - "$orig_mnt" "$mnt" "$@" << 'PYEOF' || rc=$?
import os, stat, sys
orig_mnt, new_mnt = sys.argv[1], sys.argv[2]
ignores = tuple(sys.argv[3:])
def snap(root):
    d = {}
    for dp, dn, fn in os.walk(root, followlinks=False):
        for n in dn + fn:
            p = os.path.join(dp, n)
            rel = os.path.relpath(p, root)
            try:
                st = os.lstat(p)
            except OSError:
                d[rel] = ("ERR",)
                continue
            try:
                lab = os.getxattr(p, "security.selinux").decode()
            except OSError:
                lab = "-"
            islink = stat.S_ISLNK(st.st_mode)
            d[rel] = (islink, oct(stat.S_IMODE(st.st_mode)), st.st_uid, st.st_gid, lab)
    return d
a, b = snap(orig_mnt), snap(new_mnt)
bad = 0
for k in sorted(set(a) | set(b)):
    if any(k == ig or k.startswith(ig.rstrip("/") + "/") for ig in ignores):
        continue
    if k not in a or k not in b:
        print("PATH-DIFF:", k, "only in", "orig" if k in a else "new")
        bad += 1
    elif a[k] != b[k]:
        # Symlink permission bits are kernel-ignored (stock images carry
        # arbitrary modes like 0644 on links while rebuilds store 0777), so
        # for symlinks only uid/gid/label must match.
        if a[k][0] and b[k][0] and a[k][2:] == b[k][2:]:
            pass
        else:
            print("META-DIFF:", k, a[k], "->", b[k])
            bad += 1
    elif b[k] == ("ERR",):
        print("UNREADABLE:", k)
        bad += 1
print("verify: %d problem(s)" % bad)
sys.exit(1 if bad else 0)
PYEOF
  umount_mnt "$mnt"
  rmdir "$mnt"
  return $rc
}
