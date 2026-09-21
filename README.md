# Rom porter
WARNING: THIS REPO IS FOR THE INFINIX SMART 8. NOT FOR GENERIC DEVICES.
OUTPUT FILES MAY BOOT ON SIMILAR DEVICES LIKE THE 40I OR FREEYOND M5A.

This is a script that *ATTEMPTS* to port a ROM to the infinix smart 8 via a github action runner
Its purpose is for those without PCs to still be able to port things they want

This tool is VIBECODED i'm not a dev. and it's a **WORK IN PROGRESS**
**Expect Softbricks!**

## Inputs
`target_rom_type` — what the download URL points to:
- `super.img` / `super.bin` — raw or sparse super partition (sparse auto-converted)
- `pac` / `pac.zip` — Spreadtrum PAC firmware (or zip containing the .pac)
- `ota` — FULL OTA zip only: A/B `payload.bin` (via payload-dumper-go, fetched at
  runtime) or a zip containing `super.img` directly. Incremental/delta OTAs
  (tens of MB, `pre-build` in `META-INF/com/android/metadata`, every payload
  partition marked `delta`) are rejected with a clear error unless you also
  supply `base_ota_url`.

`base_ota_url` (optional, OTA+deltas only) — direct URL for the BASE full OTA
that the incremental was built against (the exact build named in the delta's
`pre-build` metadata field). The delta is applied on top of it via
`payload-dumper-go -old`. If your OTA is ~68 MB while product alone is ~1.8 GB,
it is a delta: either find the full OTA (recommended) or supply its base here.

## What it does to the donor partitions
- `patch_system.sh`: debuggable props, optional Transsion anti-crack init.rc
  fix, optional system.prop append
- `patch_product.sh`: optional headphone-jack overlay APK
- `patch_display.sh`: installs the Smart 8 panel display configs — fixes
  display-server crashes on donors whose display configs have empty
  brightness maps
- All repacks preserve file owners, modes and SELinux labels from the source
  image, keep its UUID, verify the result file-by-file before replacing the
  original, and refuse to output an image bigger than the source (override
  with `ALLOW_GROWTH=1` if you know the target partition has slack)
