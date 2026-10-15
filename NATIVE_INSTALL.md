# Native install (built-in VPN + device pairing)

Settings › **Install Method** switches every install (Signed, Library, Sign sheet, notification deep link)
between **OTA** (itms-services over the AirShare domain, unchanged) and **Native** (straight to this device
through idevice — no domain, TLS cert or install prompt).

## What was added
- `Sources/Device/*` — connection manager, local VPN controller, on-device pairing (iOS 27+), keychain pairing
  store, "restore my VPN" shortcut handoff, `NativeInstaller` + progress banner.
- `AirShareDeviceTunnel/` — packet-tunnel extension (`<app id>.DeviceTunnel`) that reflects the loopback /32.
- `Native/Device/*` + `.github/scripts/*` — pinned idevice Rust source, pairing bridge, IDeviceKit overlays.
  `build.sh` fetches IDeviceKit (`fetch_devicekit.py`), patches it, builds `IDevice.xcframework`, then archives.
- Project: `AirShareDeviceTunnel` target embedded in the app, local `IDeviceKit` package (IDeviceSwift + IDevice).
- `unzip-drop.entitlements` / extension entitlements: `packet-tunnel-provider`.

## Requirements
- Sign the app AND the appex with a profile that authorizes Network Extensions → packet-tunnel-provider
  (same team, matching bundle-id prefix). Ad-hoc signing only preserves the request.
- Built-in pairing on-device: iOS 27+, Developer Mode, Local Network permission, one-time PIN.
  Older iOS: Manual Setup with an imported `pairingFile.plist` + your own local VPN.
- First CI run compiles Rust for device + simulator (slow); later runs reuse the cache.

## CI
`build-unsigned-ipa.yml` now also runs `test_native_cache.py`, caches the idevice build, and by default
ad-hoc signs with the entitlement files (input `adhoc_entitlements`) so the request survives into your signer.
