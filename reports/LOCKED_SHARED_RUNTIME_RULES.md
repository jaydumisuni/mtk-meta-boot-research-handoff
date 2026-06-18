# THETECHGUY LOCKED SHARED RUNTIME RULES

Any function that can be shared MUST be shared.

## Engine vs profile rule

A protocol/chipset family gets an engine.
A device/model/chip variant gets a profile.

Device is not engine.

Correct:
- SPD/Unisoc engine + SPD/612 profile
- MTK engine + MTK chip/device profile
- META engine + META service/device profile
- Qualcomm/DIAG engine + Qualcomm profile

Wrong:
- one engine per device
- one engine per model
- one separate SPD 612 engine for each 612 device
- combined MTK/META engine

## MTK vs META rule

MTK and META are not the same engine.

They may share lower-level USB/serial/port/logging helpers, but:
- MTK platform/chip flows use `app/runtime/engines/ttg_mtk_engine.ps1`
- META-mode/service flows use `app/runtime/engines/ttg_meta_engine.ps1`

Do not put all MTK and META behavior into one `ttg_mtk_meta_engine.ps1`.

## Required shared engine direction

Use shared engines for:
- ADB
- Fastboot
- MTP
- USB/serial
- SPD/Unisoc
- MTK
- META
- Qualcomm/DIAG
- logging
- backups
- reports
- command packs
- workers

## Migration rule

Before building more:
1. Audit what already works.
2. Mark useful scripts/functions.
3. Move working logic into shared runtime engines/profiles.
4. Keep button scripts small.
5. Retire duplicate hoods only after shared version passes validation.


