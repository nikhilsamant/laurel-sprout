# Ubuntu Touch — Xiaomi Mi A3 (laurel_sprout)

Halium 11 / Ubuntu Touch 24.04 port for the Xiaomi Mi A3 (`laurel_sprout`,
SoC sm6125/trinket), built on the LineageOS 23.2 kernel (4.14).

## Working

- [x] Boots to UI, GPU acceleration, hardware video playback
- [x] Display, manual & auto brightness, touchscreen, auto-rotation
- [x] Secure lockscreen
- [x] RIL: calls, SMS, MMS, PIN unlock, call audio routing, in-call volume, dual SIM
- [x] Mobile data (4G / 5G), VoLTE
- [x] Wi-Fi, Bluetooth (+ BT audio), flight mode, hotspot
- [x] GPS, proximity, accelerometer / gyroscope
- [x] Audio: earpiece, loudspeaker, microphone, volume keys
- [x] Cameras (front & back): photo, video, switch, flash
- [x] Notification LED, vibration, flashlight
- [x] Battery percentage, online & offline charging, RTC time, shutdown / reboot
- [x] Battery life — stable and long-lasting on 24.04-1.x
- [x] SD card
- [x] ADB and MTP over USB, USB mode switching from Settings; SSH after `sudo systemctl enable --now ssh` (see [`DEVELOPMENT.md`](DEVELOPMENT.md#usb-connectivity-adb--ssh))
- [x] UBports recovery (adb + fastbootd), OTA updates, factory reset
- [x] AppArmor, Anbox/Waydroid patches, Waydroid & Libertine

## Not working yet

- [ ] VoLTE does not re-register after an LTE dropout until the next reboot
- [ ] Double-tap to wake — control path fixed, unverified (touch-firmware fault on the test unit)
- [ ] Fingerprint — sensor activation solved (bypasses a touch-firmware fault confirmed present on stock MIUI too); see [`DEVELOPMENT.md`](DEVELOPMENT.md#fingerprint-fod)

## Won't fix (hardware / UT limitation)

- [ ] NFC
- [ ] FM radio — no FM chip on the board (none in the device tree; the WCN3990 has no FM receiver)
- [ ] Wireless charging
- [ ] Wired external monitor — USB-C 2.0 only
- [ ] 90 Hz / 120 Hz refresh rates — UT limitation

## Untested

- [ ] Wireless external monitor, long-uptime stability

## Build

The build tree lives in the `ut-builder-amd64` container at
`/tmp/device-xiaomi-laurel_sprout`; everything ignored by `.gitignore` is
downloaded or generated there.

```
docker exec ut-builder-amd64 bash -c 'cd /tmp/device-xiaomi-laurel_sprout && ./build.sh -k'
```

`-k` builds the kernel / boot image only. Changes under `overlay/` ship in the
rootfs tarball and need a full rootfs build and reflash.

## Kernel

`https://gitlab.com/ubports/porting/community-ports/android11/xiaomi-mi-a3/kernel-xiaomi-laurel_sprout`,
branch `halium-11` (fork of `lineage-23.2`, 4.14-openela).

## Layout

| Path | Purpose |
|---|---|
| `deviceinfo` | Device / kernel / boot-image definition |
| `build.sh` | Thin wrapper; clones the UBports build tools into `build/` |
| `overlay/` | Overlay store — merged into the rootfs tarball |
| `ramdisk-recovery-overlay/` | Files injected into the recovery ramdisk |

## More

[`DEVELOPMENT.md`](DEVELOPMENT.md) — the full porting log: kernel fixes, graphics
bring-up, overlay-store mechanics, battery / thermal investigation, USB
connectivity, flashlight, system-partition sizing / OTA, the AppArmor patch set
and known open issues.

## Credits

- The UBports team and the Halium project
