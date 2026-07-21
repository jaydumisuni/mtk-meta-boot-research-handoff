# TTG Boot META Golden Gate Evidence - 2026-07-21

## Result

An authorized observed-product run transitioned the test phone from MediaTek Preloader to Kernel META, after which TTG attached independently through the native D4 MetaCore path.

Sanitized proof chain:

```text
VID_0E8D PID_2000 / Preloader / COM3
  -> VID_0E8D PID_2007 / Kernel META / COM4
  -> SP_META_ConnectInMetaModeByUSB returned 0
  -> SP_META_GetTargetVerInfo_r returned 0
  -> SP_META_GetChipID_r returned 0
```

Non-unique target metadata confirmed:

- Platform: MT6789
- Build date: Thu Sep 4 13:04:01 CST 2025
- Software branch: alps-mp-s0.mp1.rc-V17.23_reallytek.s0mp1rc.k61v1.64.bsp_P24

## Standalone TTG Status

The TTG raw helper reliably catches PID_2000 and reaches both observed Preloader protocol branches:

- `ADVEMETA` receives `ATEMEVDX`.
- `METAMETA` receives `METASLA`; `SLASTART` then receives `METAFORB`.

The remaining gap is the final serial timing and handle-lifetime behavior that causes Kernel META to remain enumerated as PID_2007. No vendor executable, DLL, database, account material, session data, or proprietary binary is included in this repository.

## Privacy Boundary

The evidence excludes IMEI, serial number, fingerprint, full Windows device-instance IDs, NVRAM/NVDATA contents, credentials, tokens, cookies, activation material, and customer data. The golden gate reads only META state, platform/build metadata, and chipset identity.
