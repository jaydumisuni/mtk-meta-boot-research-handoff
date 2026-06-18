# THETECHGUY LOCKED ADB RULES

This project must use one shared ADB core:

app/core/ttg_adb_core.ps1

Do not copy/paste ADB handling into each button.

All ADB features must import the shared core and use these shared functions:
- TTG-ResolveAdbPath
- TTG-ResetAdbServer
- TTG-GetAdbDevices
- TTG-SelectSingleAdbDevice
- TTG-InvokeAdbRaw
- TTG-InvokeAdbShell
- TTG-GetProp
- TTG-GetSetting
- TTG-ReadDeviceSnapshot
- TTG-PrintDeviceSnapshot
- TTG-NewLogFile
- TTG-WriteBoth

Why:
- ADB server mismatch fixes must apply everywhere.
- Serial parsing fixes must apply everywhere.
- Device detection must behave the same for every button.
- Shell argument passing must never be rebuilt separately.
- UI buttons must call worker/background tasks, not block the Python UI thread.
- Every action must log into the logs folder.
- Dangerous/write/service commands must use approved command packs or explicit worker modules, not hidden UI code.

When adding a new ADB button:
1. Create a small tool script in app/tools.
2. Dot-source app/core/ttg_adb_core.ps1.
3. Use TTG-SelectSingleAdbDevice.
4. Use TTG-InvokeAdbShell / TTG-GetProp / TTG-GetSetting.
5. Do not create a separate adb parser.
6. Do not run long ADB operations directly on the UI thread.


