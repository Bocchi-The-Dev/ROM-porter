# Unisoc ROM Port — GitHub Action

Automates the port described in the Unisoc ROM porting guide: download stock + target
firmware, extract to `super.img`, split into partitions, merge (vendor/dlkm from stock,
system/system_ext/product from target), patch build.prop / SELinux / Transsion anti-crack,
and rebuild a flashable `super.img`.

## Repo layout expected

```
.github/workflows/rom-port.yml
scripts/download_input.sh
scripts/get_super.sh
scripts/assemble_partitions.sh
scripts/patch_rom.sh
scripts/build_super.py
bin/pacextractor      <- you add this (already have it)
bin/lpunpack           <- you add this
bin/lpmake             <- you add this
bin/lpdump             <- you add this
```

`bin/*` binaries are not committed here — add your Linux x86_64 builds and `git add -f`
them if `.gitignore` would otherwise exclude a `bin/` folder. They just need to be
executable Linux binaries; the workflow chmods them at runtime.

Where to get `lpunpack` / `lpmake` / `lpdump` if you don't already have them: they're
inside MIO-KITCHEN's own install directory (it bundles prebuilt copies), or as AOSP host
tool prebuilts from a super-image-utils style repo.

## Running it

Actions tab → **Unisoc ROM Port** → Run workflow, and fill in:

- **stock_rom_url** — direct link to your device's own firmware (`.pac`, `super.img`, or `super.bin`)
- **target_rom_url** — direct link to the donor ROM you're porting
- **device_codenames** — comma-separated, e.g. `P671L,P671LN` (matches `init.ums9230_<codename>.rc`)
- **partition_type** — `virtual-ab` for the Smart 8
- **patch_transsion_anticrack** — leave on for Itel/Infinix/Techno
- **sparse_output** — leave on unless you specifically want a raw image

Both URLs need to be direct, unauthenticated download links — the workflow just `curl`s
them, so anything behind a login wall (Google Drive interstitials, Needrom's click-through
page, etc.) won't work as-is. Grab the direct file link first.

Output: a `ported-super-img` artifact containing `final_super.img`, ready for
`fastboot flash super final_super.img`.

## Known limitations / things to double check

- **EROFS only.** `system.img`/`vendor.img` extraction and repacking assumes EROFS
  (typical for Android 12+ Unisoc ROMs). If your ROM's partitions are ext4, the patch
  step will fail fast with a clear message rather than silently mis-packing — ping me
  and I'll add an ext4 branch (loop-mount + `make_ext4fs`).
- **lpmake sizing** is derived from `lpdump --json` on the *stock* super.img
  (group size, device size, slot count). Print the generated `lpmake` command (it's
  logged in the "Rebuild super.img" step) and cross-check against your own `lpdump`
  output before flashing to a physical device.
- The workflow does **not** flash anything — that stays a manual `fastboot`/Spreadtrum
  Flash Tool step on your end, same as the guide's Step 10.
