# Xiaomi Mi A3 (laurel_sprout) — development notes

Porting log for the Halium 11 / Ubuntu Touch port of the Xiaomi Mi A3
(`laurel_sprout`, SoC sm6125/trinket), built on the LineageOS kernel. This is the
long-form "why" behind every workaround in this repo — kernel fixes, graphics
bring-up, the battery/thermal investigation, USB, flashlight, the AppArmor patch
set and the open issues. For the feature status and build command, see
[`README.md`](README.md).

This directory holds **only** the hand-maintained config. The build tree lives in
the `ut-builder-amd64` Docker container at `/tmp/device-xiaomi-laurel_sprout`;
everything ignored by `.gitignore` is downloaded or generated there.

## Layout

| Path | Purpose |
|---|---|
| `deviceinfo` | Device/kernel/boot-image definition consumed by the build tools |
| `deviceinfo.bak-preUT` | Pre-Ubuntu-Touch baseline, kept for diffing |
| `build.sh` | Thin wrapper; clones the UBports build tools into `build/` |
| `overlay/` | Overlay store — merged into the rootfs tarball (see below) |
| `ramdisk-recovery-overlay/` | Files injected into the recovery ramdisk |

Build inside the container (do **not** delete it):

```
docker exec ut-builder-amd64 bash -c 'cd /tmp/device-xiaomi-laurel_sprout && ./build.sh -k'
```

`-k` builds the kernel/boot image only. Changes under `overlay/` ship in the
**rootfs tarball**, so they need a full rootfs build and reflash.

## Kernel

`https://gitlab.com/ubports/porting/community-ports/android11/xiaomi-mi-a3/kernel-xiaomi-laurel_sprout`,
branch `halium-11` (fork of `lineage-23.2`, 4.14.357-openela).

Five fixes were required to boot Ubuntu Touch. Each was invisible until the
previous one was cleared:

| Commit | Fix |
|---|---|
| `66632eaa6fd8` | `scripts/Makefile.lib`: unguarded DTC check flags rejected by `dtc_ext` |
| `6688f94545df` | `init/initramfs.c`: `skip_initramfs` discarded the Halium ramdisk on this A/B device, booting Android instead → fastboot |
| `d78aa5164806` | `security/apparmor/lsm.c`: `enabled` param rendered `1` instead of `Y`, so LXC loaded the **nop** LSM driver and the container died in `MountExtraFilesystems()` |
| `5af97296b43b` | `f_mtp.c`: NULL deref in `alloc_inst_mtp_ptp()` when PTP is created without MTP |
| `fe96dade9ab3` | `f_mtp.c`: double `misc_register()` on the static `mtp_device` corrupted the global `misc_list` (`misc_register` does `INIT_LIST_HEAD` on a live node), killing the *next* caller |
| `3436c28506a8` | `waitid(P_PIDFD)`: the tree backported `pidfd_open` but not `P_PIDFD`, so GLib probed pidfd, succeeded, then got `-EINVAL` from every `waitid()` -- breaking **every GLib child watch on the system**. lightdm died instantly and Lomiri never launched. Backport of upstream `3695eae5fee0` |

The last two are triggered because Ubuntu Touch brings up the configfs USB
gadget before the container starts, so Android init re-creates functions that
already exist.

### Config chain

`deviceinfo_kernel_defconfig` composes, in order:

```
vendor/trinket-perf_defconfig  vendor/xiaomi-trinket.config  vendor/laurel_sprout.config  halium.config
```

`halium.config` (in the kernel repo, `arch/arm64/configs/`) is the Ubuntu Touch
delta. It sets `CONFIG_LSM` **explicitly** — the defconfig step materialises that
string into `.config` before AppArmor is enabled, so the
`if DEFAULT_SECURITY_APPARMOR` Kconfig default is never re-evaluated by the later
`oldconfig` pass. Validated with mer-kernel-check: 0 errors.

## Overlay store

`deviceinfo_use_overlaystore="true"`. At build time everything under
`overlay/system/` is relocated to `system/opt/halium-overlay/`; on device
`mount-halium-overlay` walks `/opt/halium-overlay/` and bind-mounts each file
onto `/`. So:

```
overlay/system/android/vendor/etc/init/vndservicemanager.rc      (this repo)
  -> /opt/halium-overlay/android/vendor/etc/init/vndservicemanager.rc
  -> bind-mounted over /android/vendor/etc/init/vndservicemanager.rc
```

The bind target must already exist or the overlay silently skips it — **unless**
the directory carries a marker file
([UBports docs, Overlay file method](https://docs.ubports.com/en/latest/porting/configure_test_fix/Overlay.html)):

| Marker in a directory | Effect on the destination directory |
|---|---|
| `.halium-overlay-dir` | merged with overlayfs; overlay files win on collision, underlying files stay visible, **new files and subdirectories are added** |
| `.halium-override-dir` | replaces it outright; the underlying contents become inaccessible |
| neither | each file is bind-mounted individually, so its target must already exist |

The docs add one constraint: the destination must be neither writable nor a
mount point itself.

That escape hatch is why `overlay/system/etc/ofono/` in this repo ships a
`.halium-overlay-dir` — `/etc/ofono/binder.d/qti.conf` does not exist on the
base rootfs, so a plain bind mount would have been a no-op. The reference port
`fairphone-fp4` does exactly the same for the same directory.

`overlay/system/usr/lib/systemd/system/` carries the same marker, which is why
the two systemd customisations here are additive drop-ins rather than
replacements:

| File | Adds |
|---|---|
| `lightdm.service.d/99-laurel-sprout-device-hacks.conf` | `After=`/`Wants=device-hacks.service`, so the composer is up before lomiri-system-compositor starts |
| `usb-moded.service.d/00-laurel-sprout-unbind-udc.conf` | the `ExecStartPre` that unbinds the configfs gadget from its UDC |
| `multi-user.target.wants/ssh.service` | enables sshd, which ships `disabled` on the base rootfs (see [USB connectivity](#usb-connectivity-adb--ssh)) |
| `adbd.service.d/10-laurel-sprout-wait-ffs.conf` | an `ExecStartPost` that holds adbd's activation until its FunctionFS descriptors are written (see [Mode switches racing adbd](#mode-switches-racing-adbd)) |

Both used to *replace* a stock drop-in (`ubuntu-touch-session.conf` and
`ubports-usb-moded-configurator.conf` respectively) and therefore had to carry a
verbatim copy of its content — `OOMScoreAdjust=-1000` in one,
`After=sys-kernel-config.mount` plus
`ExecStartPre=/usr/libexec/ubports-usb-moded-configurator` in the other — which
would have drifted silently the next time upstream changed them. The stock files
now supply their own content again. The reference port `fairphone-fp4` marks the
same directory, to drop a new `dummy_cacert.service` into it.

Two things about the usb-moded one are load-bearing:

- the `00-` prefix — systemd applies drop-ins in lexicographic order and
  `ExecStartPre` is a list that accumulates, so this file has to sort before
  `ubports-usb-moded-configurator.conf` for the unbind to run before the
  configurator (`'0'` 0x30 < `'u'` 0x75);
- the empty `ExecStartPre=` reset is kept, so the resulting list is exactly
  `[unbind, configurator]` — byte-identical to what the replacing version
  produced.

Check both with `systemctl cat lightdm.service` / `systemctl cat
usb-moded.service` on the first boot after this lands. If the merge did not take
effect the port loses its USB gadget, which per the notes above means recovery is
the only way back in.

Note: `/var/lib/lxc/android/pre-start.d/` is **not** usable on this device.
`pre-start.sh` guards it with `[ -w $LXC_ROOTFS_PATH ]`, and the container rootfs
is mounted read-only, so none of those snippets ever run.

### `vndservicemanager.rc`

The stock `/vendor/bin/vndservicemanager` aborts with
`Check failed: selinux_status_open(true ) >= 0`. libselinux needs
`/sys/fs/selinux/status`, but this kernel runs AppArmor as the exclusive LSM
(required for LXC), so the stacking code clears `selinux_enabled` and
`init_sel_fs()` never registers selinuxfs. That check can never pass.

With it dead, vndbinder has no context manager, so vendor processes — notably
`android.hardware.graphics.composer@2.4-service` — spin forever in
`defaultServiceManager()` (`BR_DEAD_REPLY`) and never register their HIDL
services. The override points the service at `/system/bin/servicemanager`, the
same upstream program built without the SELinux check, which takes the binder
driver as an argument.

### `time_daemon`

The clock reset to 1970 on every reboot. The cause is not a missing mechanism —
Ubuntu Touch already ships one, `timekeeper.service`
(`/usr/sbin/timekeeper`, "keep/restore RTC offset for Qualcomm devices",
`ExecStart=timekeeper restore` / `ExecStop=timekeeper store`, enabled by
preset). It works. Android's `/vendor/bin/time_daemon` then undoes it.

The PM6125 RTC cannot be written from here: the SPMI arbiter refuses writes to a
peripheral this execution environment does not own, which is why kernel commit
`153f6457f452` reverted the `qcom,qpnp-rtc-write` attempt. So the counter reads
epoch+uptime, and `time_daemon` — whose other half, the offset store Android
pairs it with, is not running here — pushes exactly that onto the system clock.

Measured on device 2026-09-06, one boot:

```
timekeeper.service       ActiveEnterTimestamp  Sun 2026-09-06 13:14:24 IST   <- correct
systemd-logind.service   ActiveEnterTimestamp  Sun 2026-09-06 13:14:25 IST   <- correct
/vendor/bin/time_daemon  started               boot+14.5s   (PID 2142)
NetworkManager.service   ActiveEnterTimestamp  Sat 1970-01-17 05:00:37 IST   <- boot+19s
lightdm.service          ActiveEnterTimestamp  Sat 1970-01-17 05:00:37 IST
```

`05:00:37` is the RTC counter's own value at boot+19s, so something read the
hardware RTC and called `settimeofday` with it, four and a half seconds after
`time_daemon` started. Everything after that point runs at 1970, and
`systemd-timesyncd` then re-stamps `/var/lib/systemd/timesync/clock` with the
bogus time, which destroys systemd's rollback floor for the *next* boot as well.

The fix is the reference ports': overlay the binary with a non-executable file so
init cannot exec it, and issue `ctl.stop time_daemon` from `device-hacks` to
break the restart loop that follows. The bind target
(`/android/vendor/bin/time_daemon`, `-rwxr-xr-x root:2000 42336`) already exists,
so no `.halium-overlay-dir` marker is needed.

Check on the first boot after this lands:

```
pgrep -af time_daemon                     # must print nothing
timedatectl                               # local time must be real, not 1970
systemctl status timekeeper               # active (exited), plausible timestamp
ls -l /var/lib/systemd/timesync/clock     # mtime must not be 1970
```

The first boot after flashing still starts from whatever offset the last
shutdown stored, so it may need one NTP sync (Wi-Fi — mobile-data DNS does not
resolve on this device) to become correct; the point is that it now *stays*
correct across the reboot after that.

Not yet verified on device. Unknown: whether anything else wanted `time_daemon`
— GPS and NITZ are the candidates. fp4 and fp5 both live without it and neither
README says what it cost them.

## Graphics / Lomiri bring-up

The display pipeline is proven to work end to end. From
`/var/log/lightdm/unity-system-compositor.log`:

```
Selected driver: ubports:android2 (version 1.8.0)
android/server: hotplug_hook(0, 0, connected, primary)
GLRenderer: GL renderer: Adreno (TM) 610
GLRenderer: GL version: OpenGL ES 3.2
mirserver: Mir version 1.8.2
* Output 1: LVDS connected, used |_ Current mode 720x1560
```

So GPU, EGL/GLES, libhybris and the panel are all fine. Mir's
`ubports:android2` platform opens the HWC2 HAL **in-process** via
libhybris (`libhwc2_compat_layer`); it does *not* use the HIDL
`IComposer` service.

### Open: the composer HAL service

`vendor.hwcomposer-2-4` exits **1 after ~5.1s** under init, and never
registers `IComposer`. Confirmed via `lxc-attach` that it fails the same
way anywhere inside the container, and runs fine on the host.

The failure is **completely silent**: no stdout, no stderr (captured to a
file via `lxc-attach ... sh -c '... > file 2>&1'` -- 7 bytes, just
`EXIT=1`), nothing in logd, and `debug.exception-trace=1` shows no fault.
It is a clean `exit(1)`, not a crash.

Ruled out **by measurement**, not assumption -- do not re-investigate:

| Hypothesis | Disproved by |
|---|---|
| Device-node permissions | Fixed by the udev rules; service still fails. (Rules were still needed -- they got `IQtiAllocator` registering.) |
| Contention with Mir for the HWC HAL | Disabling the service makes it *worse*: USC then hangs waiting for the display hotplug callback until lightdm's 60s timeout. **Never add a `disabled` override for this service.** |
| DRM master held by USC | With lightdm stopped and USC gone, the composer still loops. |
| uid / gid / groups | `setpriv --reuid 1000 --regid 1003 --groups 1003,1027` (init's exact credentials) runs fine on the host. |
| AppArmor | Zero `apparmor="DENIED"`; all profiles load. A denial gives `EACCES`, not this. |
| `libtls-padding.so` (hybris TLS clobber) | Present and in the ldconfig cache; `LD_PRELOAD` gives no warning. |
| Broken vendor linker namespace | strace shows libraries resolving and `/dev/vndbinder` opening cleanly (`BINDER_VERSION`, `BINDER_SET_MAX_THREADS` both OK). |
| Thread creation failing (`joinRpcThreadpool` falling through to `return 1`) | Container processes have healthy thread counts: `logd`=6, `netmgrd`=9, `sensors.qti`=6. |

Also ruled out in a later pass:

| Hypothesis | Disproved by |
|---|---|
| Wrong/missing hardware properties | `ro.hardware=qcom`, `ro.board.platform=trinket`, and `hwcomposer.trinket.so` (417K) + `gralloc.trinket.so` are present in `/vendor/lib64/hw`. |
| Unresolvable VNDK deps under the vendor namespace | The `vndk` namespace searches `/apex/com.android.vndk.v30/lib64`, which is mounted with 287 libs; **all 44** `DT_NEEDED` entries of `hwcomposer.trinket.so` resolve (checked individually). |
| Missing display service dependencies | `vendor.qti.hardware.display.allocator` and `displayfeature` are running; `IQtiAllocator` and `IDisplayConfig` register. |

Note `/system/lib64/vndk-30` and `vndk-sp-30` do **not** exist on this
build -- that is expected here, the VNDK comes from the APEX instead.

Bionic linker debug (`setprop debug.ld.all dlerror,dlopen`) produces
**no output at all** for this service, while logging normally for other
processes. So it fails without any linker diagnostic.

No prior art exists: the Halium 9 port for this same device
(gitlab.com/ubports/porting/community-ports/android9/xiaomi-mi-a3) has
**no** composer workaround, because Android 9 loaded
`hwcomposer.trinket.so` directly via `hw_get_module()` and never needed a
composer *service*. This is Halium-11 specific.

**Warning about strace on this component.** Tracing produces an infinite
`clone(...) = ? ERESTARTNOINTR` storm and the process never dies. This is
a ptrace livelock, not the bug: `pthread_create` blocks all signals
(`rt_sigprocmask(SIG_BLOCK, ~[])`) then calls `clone`; ptrace sets
`TIF_SIGPENDING`, `copy_process()` returns `-ERESTARTNOINTR`, the kernel
restarts the syscall, forever. The identical artifact appears in a
`vndservicemanager` trace *after* its real (known) abort. strace cannot
observe this failure.

Untested remaining lead: a runtime `dlopen()` of a QTI display library
resolving differently under the vendor linker namespace. The strace never
reached that point because of the livelock above, and every successful
host run used an explicit `LD_LIBRARY_PATH`, which bypasses namespaces
entirely.

### Open: `/run/mir_socket`

Never created, so the session has nothing to connect to and no shell
starts. `MIR_SERVER_ENABLE_MIRCLIENT=1` *is* set in the compositor's
environment, so that is not the cause. Likely downstream of the composer
issue rather than independent.

## System partition sizing and OTA

This device installs Ubuntu Touch **to the system partition**, not to a rootfs
image inside userdata, because only the former gets OTA updates.

The partition is small and cannot be grown — there is no `super`:

```
fastboot getvar partition-size:system_a   ->  0xC0000000   = 3072 MiB
fastboot getvar partition-size:system_b   ->  0xC0000000   = 3072 MiB
fastboot getvar partition-size:super      ->  GetVar Variable Not found
```

`ramdisk-recovery-overlay/system/etc/recovery.fstab` confirms it: static A/B with
`slotselect`, no dynamic partitions.

Two independent settings have to agree on that 3072, and they are read by
different things:

| Setting | Read by | Effect if wrong |
|---|---|---|
| `deviceinfo_system_partition_size="3072M"` (`deviceinfo`) | `build/system-image-from-ota.sh`, at build time | sizes the ext4 image. Unset, it defaults to **3584M** and `fastboot flash system` dies partway through: `FAILED (remote: 'Error: Last flash failed : Volume Full')` |
| `ro.systemimage.system_partition_size=3072` (`ramdisk-recovery-overlay/prop.halium`) | the recovery's `system-image-upgrader`, in `ensure_system_partition_size()`, on install and on every delta OTA | too large and, with no `super` and no `ro.systemimage.use_lvm`, it falls into `resize_system_partition_in_super()`, which needs `/dev/block/by-name/super`, returns 1, and the upgrader exits 1 — **every OTA fails** |

So do **not** copy the `ro.systemimage.system_partition_size=4500` that
fairphone-fp4/fp5 ship. It is right for their hardware and fatal here. Setting it
equal to the real partition is what makes the upgrader log "System partition size
is sufficient, no LVM needed" and then, on delta updates, run
`check_and_enlarge_filesystem()` to keep the filesystem matched to the partition.

The recovery property only takes effect once the boot image is rebuilt —
`make-bootimage.sh` copies `ramdisk-recovery-overlay/*` into the recovery
ramdisk, and `deviceinfo_use_unified_recovery="true"` folds that into `boot.img`.
A rootfs-only rebuild will not pick it up.

### How much room is left

Measured on the 24.04-1.x build of 2026-09-01:

```
filesystem   3072 MiB
used         2847 MiB
free          225 MiB
```

That is about 7% headroom, and `mkfs.ext4` reserves 5% of the filesystem for root
on top (the OTA updater runs as root, so it can use it). It fits, but there is no
room for the rootfs to grow much. When it stops fitting the options, in the order
the recovery itself supports them, are:

1. `ro.systemimage.use_lvm=true` in the same `prop.halium` — UBports recovery
   then migrates the device to LVM and takes the extra space from userdata
   (`migrate_device_to_lvm()`). This is the sanctioned escape hatch for exactly
   this situation, and untested here.
2. Trim rootfs content.

## Reference port comparison

The UBports reference ports for the same Halium generation are the yardstick for
everything in this repo that is *not* a laurel_sprout-specific workaround:

| Port | Halium | Notes |
|---|---|---|
| [`android11/fairphone-4/fairphone-fp4`](https://gitlab.com/ubports/porting/reference-device-ports/android11/fairphone-4/fairphone-fp4) | 11 | closest match — QTI, `deviceinfo_use_overlaystore="true"` like us |
| `android11/fairphone-5/fairphone-fp5` | 11 | QTI, no overlay store |
| `android11/volla-phone-22/volla-mimameid` | 12 | MTK, no overlay store |

### Adopted from the reference

| What | Why it was missing-and-required |
|---|---|
| `etc/gbinder.conf` — `ApiLevel = 30` | libgbinder's compiled-in default is the pre-Android-9 `aidl` protocol *and* service manager on `/dev/binder` and `/dev/vndbinder`. Android 11 needs `aidl3` for both (see the API-level presets in libgbinder `src/gbinder_config.c`). Every host process that talks to the container over binder goes through this: ofono-binder-plugin, bluebinder, the pulseaudio droid modules. All three reference ports set it (30 / 30 / 32). |
| `etc/fscrypt.conf` | Copied verbatim from fp4. `hash_costs` are Argon2 parameters that `fscrypt setup` benchmarks per device — fp4 uses `time 4 / parallelism 4`, fp5 `8 / 8`, volla `10 / 8` — so fp4's conservative values are the starting point, not a final answer. |
| `etc/ofono/binder.d/qti.conf`, `etc/ofono/ril_subscription.conf`, `etc/ofono/.halium-overlay-dir` | The port had **no** ofono configuration at all. |
| `OfonoPlugin: binder`, `OfonoImplementsIms: true`, `FilesystemEncryption: true` in the deviceinfo yaml | Set by every reference port; none of them are device-tuned values. Without `OfonoPlugin` ofono looks for `/dev/socket/rild`, which Android 11 does not have. |
| `.halium-overlay-dir` on `usr/lib/systemd/system/`, and the lightdm and usb-moded customisations rewritten as additive drop-ins | fp4 marks the same directory. The two files here were replacing stock drop-ins and duplicating their content; they now only add what is theirs. See the overlay-store section above. |
| `android/vendor/bin/time_daemon` stub + `setprop ctl.stop time_daemon` in `device-hacks` | Both QTI reference ports disable Android's time_daemon (fp4 with this exact pair, fp5 via `vendor.time_daemon_HYBRIS_DISABLED` in its `init.qcom.usb.rc`). It is not log-noise suppression, which is how this table used to describe it: time_daemon overwrites the system clock with the raw PMIC RTC counter and undoes `timekeeper.service`'s restore. Measured cause of the clock resetting to 1970 on every reboot — see the `time_daemon` section above. |
| `CONFIG_FS_ENCRYPTION=y` in `halium.config` | Documentation only — already selected by `CONFIG_F2FS_FS_ENCRYPTION=y`, and ext4's fscrypt code is guarded on the same symbol. Stated explicitly because `ubports_fp4_defconfig` does. |

None of this is verified on device yet. First boot after these land, check:

```
cat /etc/gbinder.conf                 # must show ApiLevel = 30, not the stock file
ls /etc/ofono/binder.d/               # qti.conf must be there
device-info get OfonoPlugin           # must print binder
systemctl status ofono; ls /var/lib/ofono
```

If `/etc/gbinder.conf` still shows stock content, the base rootfs has no such
file to bind-mount over and it needs a `.halium-overlay-dir` beside it.

### Deliberately NOT adopted

| Reference has | Why not here |
|---|---|
| `CONFIG_BT_HCIVHCI=y` (`ubports_fp4_defconfig` sets it) | The reference confirms this **should** be on — see the long comment in `halium.config`. It is still off because enabling it bootlooped this device. Worth one retest now that `gbinder.conf` exists, since bluebinder is a libgbinder client and was previously running against the wrong protocol preset; and note the failing test insmod'ed an out-of-tree `hci_vhci.ko` into a running kernel rather than building it in, which is not the same thing. Retest only with a recovery path ready. |
| `etc/default/usb-moded.d/device-specific-config.conf` (USB vendor/product IDs) | fp4 uses Qualcomm's `05C6`; laurel_sprout's real IDs are unknown here. Getting them wrong breaks the USB gadget, and per the `usb-moded` drop-in in this repo that means no RNDIS, no adb, no SSH — recovery is then the only way in. Needs the values read off the device first. |
| `lib/udev/rules.d/99-android.rules` (`UDISKS_SYSTEM=0` on `mmcblk0*`) | fp4 has no eMMC, so the rule is inert there. On this device `mmcblk0` *is* internal storage, and `UDISKS_SYSTEM=0` marks a device as **not** a system device — i.e. it would expose every internal partition as a mountable drive in Files. Wrong direction. |
| `android/system/etc/prop.halium` (`debug.stagefright.ccodec=0` etc.) | Standard Halium media property, and cheap — but it needs a `.halium-overlay-dir` on `/android/system/etc`, which overlayfs-mounts a directory the container's init reads constantly. Not worth the boot risk while graphics bring-up is still open. |
| `usr/lib/NetworkManager/conf.d/*` (`wifi-wpa-psk-pmf-no-optional-ap=yes`) | A workaround for a specific AP-compatibility symptom. Add it if that symptom appears, not before. |
| `MirAndroidPlatform*` keys in the deviceinfo yaml | Per-GPU tuning. fp4/fp5 values were measured on their own hardware; copying them onto Adreno 610 is guesswork. |
| `RepowerdQtiPerfBooster: true`, `usr/share/repowerd/device-configs/config-default.xml` | Both QTI reference ports set them, so this is a likely future addition — but repowerd is not usefully running here yet, so there is nothing to validate against. |
| A prebuilt `vendor/bin/vndservicemanager` binary (fp4, fp5, volla all ship one) | This port solves the same problem without a blob, by pointing `vndservicemanager.rc` at `/system/bin/servicemanager`. Keep it that way. |
| `dummy_cacert.service` | fp4-specific log-noise suppression: it silences Android init failing to find a QCOM service for cacert management. Add only if the same restart loop shows up here. (The `time_daemon` half of this row **was** adopted — it turned out not to be cosmetic at all; see above.) |

### Where this port has no reference equivalent

The modem/Wi-Fi bring-up in `device-hacks` (holding `/dev/subsys_modem` open,
then writing `ON` to `/dev/wlan`) has no counterpart in the reference ports
because their devices do not need it. The *pattern* is normal, though — fp5 uses
`usr/lib/modules-load.d/wlan.conf` and volla a
`load-wlan-module.service` for the same "userspace must kick WLAN" job. If the
inline version in `device-hacks` ever needs to grow, a real systemd unit is the
shape to grow into.

Nothing else. The `gps.conf` overlay (stock file with `SUPL_HOST`/`SUPL_PORT`
uncommented) and the `net.dns1=127.0.1.1` property that had been set for the
container were **removed** in favour of strict parity: no reference port ships
either, and both were reaching past the reference on their own measurements. The
findings behind them still stand and are worth revisiting once cellular data
works — the container has no `resolv.conf` and no `net.dns*` properties, so
`xtra-daemon` cannot resolve `time.xtracloud.net`, and the stock `gps.conf` has
no AGPS server configured. Neither is a reason to diverge from the reference
today.

## Battery and thermal

Symptoms were fast drain with nothing running, and the device warming in use.
Measured over adb on 2026-09-01, kernel `4.14.357-openela-perf-g7b83e87aa868`,
3h35m uptime, 100% charge, plugged in.

### Measured: the device has never suspended

`/sys/power/suspend_stats/success` was **0** after 3h35m of uptime. Not "rarely
suspends" — never, not once.

repowerd's own startup log says why:

```
repowerd: DefaultDaemonConfig: Failed to create LibsuspendSystemPowerControl:
                               Failed to initialize libsuspend
repowerd: DefaultDaemonConfig: Trying LogindSystemPowerControl
```

repowerd carries Android's libsuspend compiled in — `/usr/sbin/repowerd`
contains the literal strings `/sys/power/autosleep`, `autosleep_detect`,
`/sys/power/wake_lock`, `/sys/power/wakeup_count` and `/sys/power/state`, and
`ldd` shows no `libsuspend.so` of its own. libsuspend probes
`/sys/power/autosleep` first, and **that node does not exist on this kernel**:
`CONFIG_PM_AUTOSLEEP` is `default n` in `kernel/power/Kconfig` and nothing in the
config chain sets it. `ls /sys/power/` confirms it — `state`, `wake_lock`,
`wake_unlock`, `wakeup_count` and `suspend_stats` are all there; `autosleep` is
not.

So repowerd falls back to logind, which manages the display but does not do
wakelock-driven opportunistic sleep. Cores still power-collapse in idle
(`cpuidle` C1 held ~86% of wall time), but the *system* never leaves the awake
state — the RPM never reaches XO shutdown or VDD-min and every subsystem stays
powered, including the MPSS that `device-hacks` deliberately holds up for Wi-Fi.

`CONFIG_PM_AUTOSLEEP=y` is now in `halium.config` with the reasoning. Whether it
alone is enough has to be confirmed by re-reading repowerd's log after flashing;
if libsuspend still fails, the next candidate is the `wakeup_count` fallback
path (both nodes present, both mode 0660 `system:system`).

### Measured: what never suspending actually costs

From upower's own history (`/var/lib/upower/history-{charge,rate}-17.dat`), a
continuous 111-minute screen-off discharge, 224 samples, nothing running,
bluebinder already stopped:

| | |
|---|---|
| mean discharge | **0.767 W** (~197 mA at 3.9 V) |
| range | 0.64 – 0.87 W, occasional 1.2 W spikes |
| charge curve | 99% → 93% in 4905s, i.e. **1% every 13.6 minutes** |
| implied runtime | ~20 hours from full, doing nothing at all |

For scale: a phone that suspends properly idles around 0.02–0.06 W. This is
**more than ten times** that.

It is not software burning cycles. Over a 60s window in the same state the
system was 1.8% busy across 8 cores, the top consumers were `kworker/u16:*` and
`systemd-udevd` servicing the 5-second thermal poll, and
`lomiri-system-compositor` did not appear at all — the compositor is correctly
idle with the display blanked. `/sys/power/suspend_stats/success` was still
**0** at 5h49m of uptime.

So the 0.767 W is simply the cost of an SoC that is fully awake with the screen
off: the RPM never reaches XO shutdown or VDD-min, and every PIL subsystem stays
resident. `cat /sys/bus/msm_subsys/devices/subsys*/state` at the time:

```
modem=ONLINE  adsp=ONLINE  cdsp=ONLINE  ipa_fws=ONLINE  venus=ONLINE  a610_zap=ONLINE
```

`venus` (video codec) and `cdsp` are powered with nothing decoding or computing;
on Android the media and compute HALs `subsystem_put()` them when idle. `modem`
is ONLINE because `device-hacks` deliberately pins it with `exec 9<
/dev/subsys_modem` — and note that at the time of this measurement `wlan0` was
`DOWN` and not associated, so the modem was being held up for a Wi-Fi link that
was not even in use.

This is the quantified case for `CONFIG_PM_AUTOSLEEP=y`. After that lands, the
pinned subsystems are the next thing to look at — they will limit how deep the
suspend can go.

One tempting comparison to *not* draw: the same history file contains an earlier
180-second discharge segment averaging 1.941 W, from before bluebinder was
stopped. It is 7 samples taken immediately after an unplug and the screen state
is unknown, so it is not a valid A/B against the 224-sample figure above. The
bluebinder win is established by the fork and CPU numbers below, not by that.

### After CONFIG_PM_AUTOSLEEP: it sleeps, but sleeping does not save power

The kernel change landed and did what it was supposed to. `/sys/power/autosleep`
now exists and reads `mem`, and `suspend_stats/success` went from **0 to 3443**.

Then the surprise. Comparing `/proc/uptime` (boottime, includes suspend) against
`CLOCK_MONOTONIC` from `/proc/timer_list` (excludes it):

```
boottime  : 36987.5 s
monotonic :  6168.2 s
SUSPENDED : 30819.3 s  = 83.3% of uptime
```

The device spends **83% of its life suspended** — and still drains 1% every
16.3 minutes (up from 1% per 13.6 min before, a ~20% gain). A phone suspended
83% of the night should be drawing single-digit milliamps on average. This one
is roughly **six times** higher than that.

So the problem is no longer "it never sleeps". It is that **entering suspend is
not putting the SoC into a low-power state.** Two numbers sharpen it:

```
30819.3s suspended / 3443 successes = 9.0s asleep per cycle
 6168.2s awake     / 3443 resumes   = 1.8s awake per cycle
```

A wake every ~11 seconds, roughly 8,300 times over a night, each with the fixed
cost of leaving power collapse and pulling DDR out of self-refresh — plus 17% of
the night simply awake.

**A lead that turned out to be minor, recorded so it is not re-chased.** The
wakeup-source ranking is dominated by two `NETLINK` sources (21188 and 19407
`wakeup_count`, next-highest `qrtr_0` at 11844), each paired with an `eventpoll`
of near-identical count. Their combined `prevent_suspend_time_ms` is 1596s —
**4.3% of uptime**. Real, worth cleaning up, but nowhere near enough to explain
the drain. `/proc/net/netlink` maps the uevent listeners to `ueventd`, `vold`,
`healthd`, `android.hardware.health@2.1`, `cnss-daemon`, `netmgrd`, `ipacm`,
`systemd-logind` and pid 1.

Related and genuinely free: exactly three thermal zones poll on a kernel timer,
all at 5000 ms, all `user_space` governor —

```
zone12  quiet-therm-adc      polling_delay=5000  temp=34497
zone16  camera-ftherm-adc    polling_delay=5000  temp=-8324   <- disconnected sensor
zone17  emmc-ufs-therm-adc   polling_delay=5000  temp=34923
```

They produce 36 of the 46 uevents per minute, and **nothing consumes them**:
`thermal-engine`'s active config (`/vendor/etc/thermal-engine-normal.conf`)
references one sensor, `xo-therm-adc` (zone 13), which already has
`polling_delay=0` and which thermal-engine samples itself at 1s/10s via sysfs.
Mitigation is unaffected — that is done by the separate `*-step` zones, which
are `step_wise` and interrupt-driven. `polling_delay` is root-writable, so this
is testable before committing to a `polling-delay = <0>` DT override.

**Named wakers.** `msm_show_resume_irq_mask=1` gives two kinds of line.
`gic_show_resume_irq` lists interrupts *pending* at resume; `pm_system_irq_wakeup`
names the one that actually caused it. Only the latter is attribution.

A first, 8-event sample showed `qg-fifo-done` and modem GLINK. A later 69-event
sample says something else entirely:

```
66 x  IRQ 52  ipa                      <- 96%
 1 x  IRQ 53  gsi                      (IPA's data mover)
 1 x  IRQ 225 qpnp_rtc_alarm
 1 x  IRQ 269 typec-cc-state-change    (the USB replug)
```

The replug is the *last* line in the sequence (8828.7s, after IPA wakes running
8735.6-8828.0s), so these are not a USB artifact — they happened on battery.
IRQ decode via the DT, remembering `GIC_SPI n` -> hwirq n+32: IRQ 293 = hwirq
100 = `glink_modem` (`GIC_SPI 68`), IRQ 20 = hwirq 226 = `rpm-glink`. IRQ 20 is
the busiest interrupt on the system (1.35M) and appears *pending* on nearly
every resume, but it is a consequence of waking, not a cause.

The two samples differ because the device state differed — `wlan0` was DOWN
during the first and associated during the second. Treat any single short
capture as a snapshot of one state, not the standing answer.

**IPA fires only out of suspend.** Measured over 60s plugged in and idle:
`irq 52 ipa +0`, `irq 53 gsi +0`, `rmnet_ipa0 rx +0 tx +0`. So this is not
background chatter — it is the IPA suspend-IRQ path, the interrupt IPA raises
when something arrives for an endpoint that was suspended.

`rmnet_ipa0` and `rmnet_data0` are `UP,LOWER_UP`, with `ipacm`, `ipacm-diag` and
`netmgrd` running, because `device-hacks` pins the MPSS for Wi-Fi and the modem
brings the rmnet data path up with it. The WLAN firmware explicitly denies
responsibility for the wakes — 131 `Non-WLAN triggered wakeup: UNSPECIFIED`
lines — which points at the cellular path rather than the Wi-Fi one.

**The A/B confirmed it.** Downing `rmnet_ipa0` and comparing wake attribution
either side of a kernel-log marker:

| | rmnet UP | rmnet DOWN |
|---|---|---|
| IPA wakes | 66 of 69 (96%) | **0 of 27** |
| top waker | `ipa` | `qg-fifo-done` (25 of 27) |
| suspend attempts | 1 per 4.2s | 1 per 21.7s |
| avg sleep duration | 9.0s | **40.8s** |
| suspend residency | 83.3% | **94.1%** |

Wi-Fi survived throughout — `wlan0` stayed associated and the modem stayed
`ONLINE`. That is the important structural point: **the MPSS pin and the rmnet
data path are separable.** Wi-Fi needs the modem for the WLFW QMI service; it
does not need the modem's data path.

Cellular data is genuinely in use here, so rmnet cannot simply be dropped. The
fix is `etc/NetworkManager/dispatcher.d/no-wait.d/50-laurel-sprout-rmnet-power`:
disable the WWAN radio when `wlan0` comes up, re-enable it when Wi-Fi goes away.

**Use the WWAN radio switch, not `ip link`.** The first version of this script
downed `rmnet_ipa0` with iproute2. It saved the power and broke mobile data:
rmnet runs through the IPA *hardware* datapath, `ipacm` programs IPA's
filter/route rules when a data call comes up, and yanking the netdev left those
rules stale. The link came back, the routing table looked perfect, and every
packet was silently dropped — which presents as `ERR_NAME_NOT_RESOLVED` in a
browser and sends you hunting DNS that was never the problem.

`nmcli radio wwan off/on` is the correct layer, the same one the Settings
mobile-data toggle drives. Round-tripped on device before the script was
written:

```
baseline   ril_0:connected     rmnet_data0 10.84.94.100/29   egress OK
wwan off   ril_0:unavailable   (no rmnet)                    egress FAIL
wwan on    ril_0:connected     rmnet_data1 10.91.191.97/30   egress OK
```

The *new* interface and *new* address on the way back is the point: the PDP
context is genuinely rebuilt rather than reused. That is what `ip link` could
never do.

**Verified end to end through the dispatcher**, both directions, from
`/run/rmnet-power.log`:

```
16:09:26 INVOKED iface=wlan0 action=up
  [up] wwan now=disabled
16:09:32 INVOKED iface=ril_0 action=down          (data path torn down)

16:13:13 INVOKED iface=wlan0 action=down
  [down] wwan now=enabled
16:13:14 INVOKED iface=rmnet_data1 action=up      (data path back, 1s later)
```

with traffic confirmed flowing on cellular afterwards — `egress TCP
1.1.1.1:443 OK`, `DNS google.com -> 142.250.146.101`, default route via
`rmnet_data1`. An intermediate cycle exercised the safeguard correctly too:
with the marker absent, the down path logged `bail: not disabled by us` and left
the radio alone, which is the intended refusal to undo a manual choice.

**The script must live in `dispatcher.d`, not `no-wait.d`.** This cost two
failed attempts. `no-wait.d` is documented, and the string is present in
`/usr/libexec/nm-dispatcher` right next to `pre-up.d` and `pre-down.d`, so it
looks like the obviously correct home for a script that must not block
NetworkManager. On this build NM never executes anything from it. The script sat
there installed, root-owned, executable, with NM firing dispatcher events, and
produced no output whatsoever — not even from an unconditional log line on the
first executable statement.

Proven by putting identical probes in both directories and toggling Wi-Fi:

```
15:54:08 PROBE[main] iface=wlan0 action=down
15:54:53 PROBE[main] iface=wlan0 action=dhcp4-change
15:54:53 PROBE[main] iface=wlan0 action=up
15:54:57 PROBE[main] iface=wlan0 action=dhcp6-change
```

`PROBE[nowait]` never fired. Ruled out first, in this order: install correctness
(mounted, `root:root 0755`), mount-namespace hiding (`PrivateMounts=no`,
`ProtectSystem=no` — no sandboxing at all on the dispatcher unit), NM not firing
(it fired 55s after install), and wrong guard values (`[up]` and `[enabled\n]`,
both pass). Do not "tidy" this back into `no-wait.d`.

Blocking NM is a non-issue in practice: everything slow happens in a detached
`systemd-run` transient unit, so the script returns in microseconds.

Three safeguards. It runs **detached** — NM's dispatcher is synchronous and
`nmcli` calls back into NM, which can deadlock it. It **settles 5s and
re-checks** that Wi-Fi is still up, so a flapping association cannot leave
mobile data switched off behind it. And it writes a **marker in `/run`** when
*it* disables WWAN, only re-enabling if that marker is present, so turning
mobile data off by hand is not silently undone; `/run` is tmpfs, so a reboot
starts neutral. Transient units are named per action — a single shared name let
a `down` arriving during an `up`'s settle collide and silently vanish.

It also keeps its own log at `/run/rmnet-power.log`. NM does not reliably
surface dispatcher stdout to the journal, which is exactly what made the
`no-wait.d` failure invisible.

`dispatcher.d` needs a `.halium-overlay-dir` marker: the directory already
exists and ships `02default_route_workaround`, so a new file has to merge in
rather than bind-mount over a non-existent target.

**With IPA gone, the next waker is the fuel gauge** — `qg-fifo-done`, 25 of 27
attributed resumes. That is the `qcom,qg-sleep-config` gap described below, now
promoted from hypothesis to the leading remaining cause, and fixed in
`laurel_sprout-trinket-battery.dtsi`.

**Drain has not improved.** Latest window: 79% -> 70% in 1.99h = 1% per 13.3
min, about 182 mA — no better than the 177 mA measured before autosleep existed,
despite 83% suspend residency. Suspend counters at the time: 5246 ok / 8505
failed.

**A concrete gap this exposed: QG never enters its sleep cadence.**
`qpnp-qg.c` has a dedicated S2 sleep state with its own, slower sampling —
`sleep_s2_fifo_length` (default 8), `sleep_s2_acc_length` (256),
`sleep_s2_acc_intvl_ms` (200). But it is only ever entered if a DT boolean is
present:

```c
4303:  if (chip->dt.qg_sleep_config) {
4304:      qg_dbg(... "Suspend: Forcing S2_SLEEP");
4305:      rc = qg_config_s2_state(chip, S2_SLEEP, true, true);
```

set from `of_property_read_bool(node, "qcom,qg-sleep-config")` at line 4101.
`laurel_sprout-trinket-battery.dtsi` sets **none** of `qcom,qg-sleep-config`,
`qcom,sleep-s2-fifo-length`, `qcom,sleep-s2-acc-length` or
`qcom,sleep-s2-acc-intvl-ms`. So the gauge stays in `S2_DEFAULT` across suspend,
sampling at the awake cadence the same file *does* set —
`qcom,s2-fifo-length = <4>` — and raising `qg-fifo-done` at that rate all night.

That is a plausible cause of a share of the ~9-second sleep cycles, in a file
this port owns. It is still a hypothesis: confirm it against a full night of
resume attribution before changing the DT.

**What is still needed to close this out.** Two instruments:

- `msm_show_resume_irq_mask` — already built in and runtime-writable at
  `/sys/module/msm_show_resume_irq/parameters/debug_mask` (0664). Set it to 1
  and `irq-gic.c` logs the pending GIC interrupt on every resume, naming what is
  ending each 9-second sleep. No rebuild. Note the device does not suspend at
  all while USB is attached, so it must be armed and then left unplugged.
- `CONFIG_QTI_RPM_STATS_LOG=y` — now in `halium.config`. Builds
  `drivers/soc/qcom/rpm_stats.o`, which reads the RPM's own accounting from SMEM
  and reports how many times and for how long the system reached VDD-min / XO
  shutdown. That is the direct answer to "did the SoC actually sleep, or did it
  only freeze userspace". Needs a rebuild.

The standing hypothesis, untested: subsystems that never power down. `modem`,
`cdsp` and `venus` were all `ONLINE` with the screen off, and `device-hacks`
pins the MPSS deliberately for Wi-Fi. Do not act on that until the RPM numbers
can be read.

### Measured: bluebinder was the only significant CPU consumer

Recorded for the record; **this port ships no fix for it** — it is being handled
separately. Two 60-second samples on an otherwise idle device, screen off,
identical method, `bluebinder.service` running and then stopped:

| Metric | running | stopped | |
|---|---|---|---|
| forks per 60s | **745** | **73** | −90% |
| CPU busy (jiffies, 8 cores) | 2150 | 757 | −65% |
| CPU busy | 4% | 1% | |
| top consumer | **PID 1 `/sbin/init`**, 278 | `kworker/u16:0`, 111 | |
| `dbus-daemon` | 159 | *gone* | |
| `systemd-journald` | 87 | *gone* | |
| `systemd-logind` | 53 | *gone* | |

`NRestarts` was 10354, then 10948 fourteen minutes later — 594 restarts in 829s,
0.72/s, sustained. PID 1, dbus, journald and logind did not merely drop, they
fell off the top-twelve entirely: every one of them was doing work only because
systemd was forking a process about once a second that exits immediately.

The cause is described in `arch/arm64/configs/halium.config`: no `/dev/vhci`
(`CONFIG_BT_HCIVHCI` is off because enabling it bootlooped the device), so
bluebinder exits ENODEV and systemd restarts it forever. On an idle phone with
the screen off, **systemd itself was the busiest process on the system**.

Note that stopping it does not change the idle power figure below — that
measurement was taken with bluebinder already stopped.

### What idle looks like with bluebinder gone

The residual 1% is ordinary housekeeping, not a second storm. `udevadm monitor`
over 20s shows a steady, regular stream and nothing else:

```
change /devices/virtual/thermal/thermal_zone{12,16,17}   every ~5s
change .../qcom,qpnp-smb5/power_supply/battery           every ~4-8s
```

Those are `thermal-engine` polling the ADC zones (12 `quiet-therm-adc`,
16/15 `skin-therm-adc`, 17 `emmc-ufs-therm-adc`) and the charger reporting. Each
uevent wakes udevd and lands deferred work on the unbound workqueue, which is
why the top three remaining consumers are `kworker/u16:*` (111+74+48 jiffies)
followed by `systemd-udevd` (73) and `servicemanager` (54). This is what the
same polling does on Android; it is not worth chasing.

It does matter for suspend, though: userspace freezes across a suspend, so
thermal-engine's 5s timer stops firing rather than waking the device — these
events are not a barrier to the autosleep fix above.

### Ruled out by measurement

Three plausible causes that turned out to be wrong on this device. They are
recorded because each one is a real defect on *some* Halium port and each looks
damning from the source alone.

| Hypothesis | Why it looked right | What the device says |
|---|---|---|
| cpufreq governor stuck on `performance` | Nothing in the config chain sets `CONFIG_CPU_FREQ_DEFAULT_GOV_*`, so `drivers/cpufreq/Kconfig`'s `default CPU_FREQ_DEFAULT_GOV_PERFORMANCE` is what gets built | Both policies run **schedutil**. `policy0/stats`: 116432 transitions and 84% of all time at the 614400 kHz minimum. Not a recent change — the distribution covers the whole uptime |
| `lpm_levels.sleep_disabled=1` pinning idle at WFI | It is on `/proc/cmdline`, and `cpu_power_select()` (`drivers/cpuidle/lpm-levels.c:702`) does return level 0 while set | Reads **`N`**. cpuidle C1 (power collapse) holds ~11154s of 12916s uptime on cpu0 |
| No skin thermal mitigation | 23 of 49 zones in `trinket-thermal.dtsi` declare `thermal-governor = "user_space"`, and nothing in this repo starts a thermal daemon | `/vendor/bin/thermal-engine` is **running** (pid 2333, `init.svc.thermal-engine=running`). All zones 33–40°C, every `cooling_device` at `cur_state=0` |

The common root of all three: **`sys.boot_completed=1` really is set in the
container** (`dev.bootcomplete=1` too), so
`/vendor/bin/init.qcom.post_boot.sh` — 276KB, 96 references to
`scaling_governor` and 34 to `sleep_disabled` — does run, and Android init
starts `thermal-engine` normally. The "Halium never completes boot so post_boot
never fires" failure mode does not apply to this port. Do not re-derive these
from the config files; check the device.

### Charge limit

Stops charging at a configurable state of charge and resumes below a lower one,
so the pack is not parked at 4.4 V all day.

**Where it lives in the overlay.**

```
overlay/system/usr/lib/systemd/system/
├── .halium-overlay-dir              (already present, pre-existing)
├── battery-charge-limit.service
└── battery-charge-limit.sh
```

That directory is the one in this repo already carrying a `.halium-overlay-dir`
marker, so the overlay store merges it with overlayfs rather than bind-mounting
files one by one — which is what lets *new* files land at all (a plain
bind-mount needs the target to already exist, and neither of these does). The
same mechanism the lightdm and usb-moded drop-ins rely on; see the overlay-store
section above.

The `.sh` sits next to the unit rather than in `/usr/bin` because no other
directory here has the marker and adding one to `/usr/bin` would overlayfs-mount
a directory of thousands of files for the sake of one script. systemd only loads
files with a recognised unit suffix, so a neighbouring `.sh` is inert to it.

It is *started* from `device-hacks` rather than enabled with a
`multi-user.target.wants` symlink — the same way the fairphone-fp4 reference port
starts its `dummy_cacert.service`. The `[Install]` section is present so
`systemctl enable` also works, but nothing in the image depends on it.

**Configuration — three layers, increasing precedence.**

| Layer | Path | Who writes it | Applies |
|---|---|---|---|
| 1 | `Environment=` in the unit | the port | 80% stop / 75% resume |
| 2 | `/etc/default/…`, `/etc/writable/…` | root | on restart |
| 3 | `~phablet/.config/battery-charge-limit` | **the user or the settings UI, no root** | within one poll (30s) |

Layer 3 is the one a person uses:

```
echo CHARGE_LIMIT=85 > ~/.config/battery-charge-limit
```

`CHARGE_RESUME` is optional and defaults to `CHARGE_LIMIT - 5`. `CHARGE_LIMIT=100`
disables limiting. Accepted range is 50–100; anything outside it, unparseable or
self-contradictory is ignored and the layer below stands. No restart, no sudo —
the script re-reads the file on every poll.

Layer 2 exists because layer 1 is baked into a ro image. `/etc/writable` is the
path that works: the rootfs is `ro` and only a handful of `/etc` subdirectories
are bind-mounted rw from userdata — `/etc/writable` is one, `/etc/default` is
not. `/etc/default` is kept first as the conventional location.

**Why layer 3 is not an EnvironmentFile.** That file is written by the
unprivileged user and read by a root service. As an `EnvironmentFile` its
contents could set *any* environment variable on that root process — `LD_PRELOAD`
being the obvious one — and `.`-sourcing it would execute it outright. Both are
privilege escalation from a user-writable path. The script parses it by hand
with a sed whose only capture group is `[0-9]\{1,3\}` anchored to end-of-line,
then range-checks the result, so the worst a hostile file can do is be ignored.
Verified against `CHARGE_LIMIT=80; rm -rf /` (rejected — trailing text fails the
anchor) and an `LD_PRELOAD=` line (ignored — only the two known keys are looked
for).

**Which sysfs knob.** `/sys/class/power_supply/battery/charging_enabled`. The
PMI632's `qpnp-smb5` battery power_supply advertises plenty of charging
properties, but `smb5_batt_prop_is_writeable()` accepts only a few, and of those
exactly two can stop a charge:

- `charging_enabled` → `vote(chg->chg_disable_votable, USER_VOTER, ...)`. Stops
  charging the cell; the input path stays up, so the phone runs off the charger.
- `input_suspend` → cuts the input entirely, so the phone *discharges* while
  plugged in. Wrong direction, and it cycles the pack.

Expect the indicator to read "not charging" at the limit while plugged in. That
is the mechanism working, not a fault.

**Why the script never reads the knob back.** The getter is
`!get_effective_result(chg->chg_disable_votable)` (`qpnp-smb5.c:1800`) — the
*effective* result across every voter, not just the `USER_VOTER` we write. A read
of 0 cannot distinguish "we stopped it" from "the thermal, JEITA or FCC-stepper
voter stopped it". So the loop decides `want=0/1` from capacity alone and asserts
it every poll. `vote()` is idempotent, so re-writing costs nothing, and if another
voter is independently holding charging off our vote queues behind theirs.

**Installing without a reflash.** `/etc/systemd/system` is a rw bind-mount from
userdata (`/dev/sda15`) with no `noexec`, so both files can be dropped there
root-owned and `systemctl enable`d, surviving reboots. Ownership must be
`root:root` — a root service must not exec a script the user can edit. Delete
those copies once a build carrying the overlay is flashed, so the overlay's copy
is the only one.

Pack health as measured: `cycle_count=1`, `charge_full=4030000` equal to
`charge_full_design`, `health=Good`. The cell is fine — this is about keeping it
that way.

### Charge limit: the settings UI

A **pure-QML** Lomiri System Settings plugin — no C++, no `.so`, no build step.
Sixteen of the shipped plugins already work this way (any `.settings` manifest
with no `"plugin"` key: about, bluetooth, wifi, sound, time-date, …), so this is
data files in the overlay and nothing more.

```
overlay/system/usr/share/lomiri-system-settings/
├── .halium-overlay-dir
├── charge-limit.settings
└── qml-plugins/charge-limit/PageComponent.qml
```

One marker, on `/usr/share/lomiri-system-settings/`. The
`qml-plugins/charge-limit/` subdirectory is new and comes along with it — the
same thing the `lightdm.service.d` and `usb-moded.service.d` drop-ins already do
under the marker on `usr/lib/systemd/system/`.

The page is **Charging**, under System, below Battery:

| Control | Behaviour |
|---|---|
| **Optimise Battery Charging** switch | On → limiting active. Off → the service is *stopped*, not merely idle |
| Percentage slider | 50–95% in 5% steps; greyed out, not hidden, while the switch is off |

The slider deliberately stops at 95. "No limit" is what the switch expresses; a
slider that could also mean it would give two controls for one state. The
service still honours a hand-written `CHARGE_LIMIT=100` as off, for people
editing the file directly.

**How an unprivileged page stops a root service.** It never talks to systemd.

```
switch OFF -> page writes CHARGE_ENABLED=0
              running service reads it on its next poll (<=30s),
              restores charging, exits 0
              Restart=on-failure, so the clean exit sticks: unit goes inactive

switch ON  -> page rewrites the same file
              battery-charge-limit.path is watching it and starts the service
```

No polkit rule, no D-Bus service, no setuid helper. The whole privilege boundary
is a file the user owns plus a parser that accepts three integer keys and
nothing else. Note the asymmetry when debugging: the *off* direction does not
depend on the `.path` unit at all, since the service polls the file itself. Only
the *on* direction does.

`battery-charge-limit.path` lists both `PathChanged=` and `PathModified=` on
purpose. `Qt.labs.settings` writes through QSettings, which saves atomically —
a temporary file renamed over the target. That is a rename in the parent
directory rather than a write to the watched inode, so the two directives cover
the settings page and an in-place edit over SSH alike.

`CHARGE_ENABLED` is parsed independently of `CHARGE_LIMIT`: an off switch is
honoured even if the limit value beside it is garbage. Verified on-device
against GNU sed 4.9, along with `CHARGE_ENABLED=0; reboot` (rejected — trailing
text fails the end-of-line anchor) and QSettings' `[General]` INI header
(ignored — it does not match the pattern).

`Qt.labs.settings` is present (`libqmlsettingsplugin.so`, Qt 5.15.13) and its
`Settings` type takes an explicit `fileName`, so the page writes exactly the
path the service already reads. The manifest sets `"visible-if-file-exists"`, so
the entry only appears when the limiter is actually installed.

The icon is `flash-on` — a bare lightning bolt from suru
`actions/scalable/flash-on.svg`, deliberately not a battery outline, so the
entry does not duplicate the Battery page's `battery-080` sitting directly above
it. Icon names resolve across contexts, not just `status/`: the shipped `reset`,
`gestures` and `info` entries are all `actions/scalable` too.

**`has-dynamic-visibility` must be `false` for a QML-only plugin.** This one
costs an evening if you guess. `true` means "ask the plugin object whether to
show this entry", and that object is the C++ plugin — so with no `"plugin"` key
there is nothing to ask and the entry is hidden *before the QML is ever loaded*,
which means the journal shows no error at all. The correlation across the 28
shipped manifests is exact:

| `has-dynamic-visibility` | QML-only | with C++ plugin |
|---|---|---|
| `false` | 16 | 5 |
| `true` | **0** | 7 |

Static gating is what `visible-if-file-exists` is for, and it works on its own
with `has-dynamic-visibility: false` — `system-update.settings` does exactly
that. Also set `"translations"`: every shipped manifest has it.

**Trying it without flashing.** There is no environment override for the plugin
path: `/usr/share/lomiri-system-settings/qml-plugins` is a hardcoded string in
`/usr/bin/lomiri-system-settings` and neither that binary nor
`libLomiriSystemSettings.so.1.3.2` references any `XDG_` variable. With the
rootfs `ro`, that leaves exactly one way to add a plugin to a running system:
shadow the directory. Copy it (~1.6M) somewhere writable, add the two files,
`mount --bind` the copy back over the top, restart System Settings. Read-only
usage, reversible with `umount`, and a reboot clears it regardless.

Pick the staging directory by probing, not by assuming. `/opt` looks like the
obvious spot and is **not** writable — it is on the ro rootfs, and only
`/opt/click.ubuntu.com` and `/opt/halium-overlay` are separate mounts under it.
`/userdata` works, `/tmp` works, `/home/phablet/.cache` works. The QML is written against the on-device
component sources (`SystemSettings/ListItems/Standard.qml`, `SingleControl.qml`,
and the `battery` plugin's page for import versions) but has **not been run** —
the bind-mount is how to find that out cheaply.

### Still open

- **Float voltage cannot be capped from userspace.** Holding the pack at ~4.1 V
  ages it far less than cycling it between 75% and 80% at 4.4 V
  (`qcom,fv-max-uv = <4400000>` in `laurel_sprout-trinket-battery.dtsi`,
  confirmed on device: `voltage_max=4400000`), but
  `smb5_batt_prop_is_writeable()` does not list
  `POWER_SUPPLY_PROP_VOLTAGE_MAX`, so `voltage_max` returns `-EPERM`. The setter
  itself exists and votes `BATT_PROFILE_VOTER` on `fv_votable`; only the
  writeable list is missing the case. A one-line kernel change would expose it.
- **Pinned PIL subsystems.** `venus`, `cdsp` and `ipa_fws` sit ONLINE
  indefinitely, and `device-hacks` pins `modem` on purpose for Wi-Fi. Once
  autosleep works these are the next candidates; releasing `venus` in particular
  looks free, since nothing on this port decodes video at idle. Needs measuring
  one at a time against the 0.767 W baseline.
- **repowerd environment.** fp4 ships `REPOWERD_BACKLIGHT_BACKEND=sysfs`
  and `REPOWERD_DISABLE_BOOSTER=true` because the Android lights HAL misbehaves
  with repowerd there. Whether that applies here is unmeasured, so it has not
  been copied — screen backlight is usually the largest single consumer once
  the above two are fixed. The auto-brightness curve is now shipped as
  `usr/share/repowerd/device-configs/config-LAUREL_SPROUT.xml`: repowerd loads
  `config-default.xml` (which sets `config_automatic_brightness_available`
  false) and then `config-<DeviceInfo name>.xml`, and `device-info` reports
  `LAUREL_SPROUT`. The curve is LineageOS's nits table mapped onto 0-255 with
  its own `2 nits = 1, 450 nits = 255` backlight line. The directory has a
  `.halium-overlay-dir` marker since the file is new. **Unverified on device.**

## USB connectivity (adb + SSH)

The port used to lose SSH about seven minutes into every boot, and adb only came
back after toggling Developer Mode off and on again. Both symptoms are one
mechanism.

### What was happening

`usb-moded.service` ships `Environment=USB_MODED_ARGS=-r`. That `-r` is rescue
mode: until usb-moded reaches `init_done` it forces the `developer_mode` profile
regardless of the saved mode. `developer_mode` is the only mode that brings up
the full rescue path --

| `developer_mode` does | via |
|---|---|
| assigns `10.15.19.82` to `usb0` itself | `network = 1`, `network_interface = usb0` |
| starts a DHCP server | appsync `developer_mode-udhcpd.ini` |
| **starts sshd on `10.15.19.82:8022`** | appsync `developer_mode-ssh.ini` -> `usb-moded-ssh.service` |

-- and that last row is the important one, because `ssh.service` itself is
`disabled` on the base rootfs. SSH on this port was never a service that was
running; it was a side effect of rescue mode.

When rescue mode expired, usb-moded applied the saved mode and both halves went
at once. Measured on a real boot:

```
[   13.5s] configfs-gadget gadget: high-speed config #1: c
[   13.8s] IPv6: ADDRCONF(NETDEV_CHANGE): usb0: link becomes ready
[  414.8s] android_work: sent uevent USB_STATE=DISCONNECTED
[  415.0s] android_work: sent uevent USB_STATE=CONFIGURED
```

`/var/lib/usb-moded/usb-moded.ini` was rewritten at that same moment to
`mode=charging_only_adb`. After it, `usb0` is DOWN -- it keeps the stale address,
which is why `ip addr` still looks plausible -- and nothing listens on 8022.

`charging_only_adb` does carry `ffs.adb`, so adb is nominally present. But the
transition re-enumerates the gadget under a different idProduct and the host does
not re-attach, which is why adb needed a Developer Mode off/on to force a fresh
mode request. On a second boot the toggle is already on, so it has to be turned
off first -- exactly the reported behaviour.

### The fix

| Change | Where |
|---|---|
| `CONFIG_USB_CONFIGFS_RNDIS=y` | `halium.config` in the kernel tree |
| default mode `rndis_adb` | `overlay/system/etc/usb-moded/90-device-specific-config.ini` |
| enable sshd | `overlay/system/usr/lib/systemd/system/multi-user.target.wants/ssh.service` |
| real VID/PIDs | `overlay/system/etc/default/usb-moded.d/device-specific-config.conf` |

`rndis_adb` is the only stock mode carrying both a network function and adb
(`sysfs_value = rndis,adb`, idProduct 9024).

The kernel change is what makes that mode honest. `vendor/trinket-perf_defconfig`
sets `CONFIG_USB_CONFIGFS_NCM=y` and never `CONFIG_USB_CONFIGFS_RNDIS`, so
`f_rndis` was not built and the boot log showed the configurator's first probe
failing:

```
ubports-usb-moded-configurator[1646]: mkdir: cannot create directory
  '/sys/kernel/config/usb_gadget/g1/functions/rndis.usb0': No such file or directory
```

It probes `rndis.usb0`, `ncm.usb0`, `ecm.usb0` in that order and takes the first
that works, so the port was silently running on NCM. That is fine for a Linux or
macOS host but breaks two things: Windows has no in-box CDC-NCM driver, and
`/usr/bin/usb-tethering` -- the script appsync starts for `rndis` and
`rndis_adb` -- hardcodes RNDIS. Its `usb_setup_configfs()` mkdirs
`functions/rndis.usb0` and only ever symlinks rndis functions; on an NCM-only
kernel those steps fail, and since the script is `#!/bin/bash` with no `-e` it
does not stop, carrying on to rewrite idVendor/idProduct and re-write the UDC on
the gadget usb-moded has just built.

sshd is enabled outright rather than given an `rndis_adb-ssh.ini` appsync entry.
An appsync entry would race: `rndis_adb` has `network = 0`, so the address is
added by `usb-moded-tethering.service` (also a `post` entry), and
`usb-moded-ssh.service` has `ListenAddress=10.15.19.82:8022` -- binding before
that address exists makes sshd exit 255, which its own
`RestartPreventExitStatus=255` then declines to retry. Enabling `ssh.service`
sidesteps the ordering entirely and also gives SSH over Wi-Fi. Note it listens on
port **22** on all interfaces (the base `sshd_config` sets no `Port` or
`ListenAddress`), not on 8022; `usb-moded-ssh.service` stays available on 8022
whenever rescue mode or `developer_mode` is active.

### Rescue mode is deliberately still on

`fairphone-fp4` sets `USB_MODED_ARGS=""` in its
`etc/default/usb-moded.d/device-specific-config.conf`, and the stock file's own
comment qualifies that with "Only do this if you're sure your device will boot".
It is left enabled here until one boot has confirmed that `rndis_adb` configures
cleanly, `usb0` holds `10.15.19.82`, sshd is listening and adb survives past the
seven-minute mark. Turning it off removes the last automatic way back in, and
this port has already lost its gadget once (see the unbind-udc drop-in).

### Mode switches racing adbd

After a reboot, or after any mode switch, adb could stay dead until Developer
Mode was toggled off and on (sometimes more than once). The journal shows the
same sequence every time it failed:

```
434.783 adbd: main.cpp:291 adbd started
434.784 usb_moded: /sys/kernel/config/usb_gadget/g1//UDC: write failure: No such device
434.785 adbd: usb_ffs.cpp:276 opening control endpoint /dev/usb-ffs/adb/ep0
434.818 usb_moded: mode setting failed, try charging_only
```

The appsync entries for the adb modes start `adbd.service` with
`systemd_wait = 1`, and usb-moded writes `UDC` as soon as the unit is active.
`adbd.service` is `Type=notify`, but adbd sends `READY=1` from `main()` before
its USB thread has opened `ep0` and written the descriptors. Binding a gadget
whose ffs function has no descriptors yet fails in
`ffs_do_functionfs_bind()` (`desc_ready ? 0 : -ENODEV`), so the mode fails and
usb-moded falls back to charging-only. The result depends on timing, which is
why it only sometimes failed.

The drop-in adds an `ExecStartPost` that waits (up to 5 s) for
`/dev/usb-ffs/adb/ep1`. The kernel creates the ep files in the same `ep0` write
that sets `desc_ready`, so once `ep1` exists the bind will succeed. With
`Type=notify`, systemd marks the unit active only after `ExecStartPost` exits,
so usb-moded's wait now covers the descriptor write.

### Applying it to a device that has already saved a mode

`/var/lib/usb-moded/usb-moded.ini` takes precedence over the shipped default and
lives on userdata, so it survives reflashing the rootfs:

```
sudo rm /var/lib/usb-moded/usb-moded.ini
```

## Flashlight

Two independent bugs, one on each side of the syscall boundary. Fixing either
alone leaves the torch dark.

### Where the torch lives

It is part of `ayatana-indicator-power`, not a separate app -- there is no
camera-app installed on this port at all.
`/usr/libexec/ayatana-indicator-power/ayatana-indicator-power-service` carries
two hardcoded lists of candidate sysfs nodes and pairs one from each:

| List | Candidates |
|---|---|
| torch | `torch-light`, `led:flash_torch`, `flashlight`, `torch-light0`, `torch-light1`, `led:torch_0`, `led:torch_1` |
| switch | `led:switch`, `led:switch_0`, `white:flash` |

The device exposes `led:flash_{0,1}`, `led:switch_{0,1}`, `led:torch_{0,1}` (all
from `leds-qpnp-flash-v2`, enabled by `vendor/trinket-perf_defconfig:536`) and
`torch-light0`, parented to `soc:qcom,camera-flash@0`.

### Bug 1 (kernel): the sysfs node never asserted the switch

`torch-light0` is registered by
`drivers/media/platform/msm/camera_v2/sensor/flash/msm_flash.c`, and its
`brightness_set` did exactly one thing:

```c
led_trigger_event(torch_trigger, value);
```

On a PMIC controller driven by `leds-qpnp-flash-v2` that is not enough.
`qpnp_flash_led_brightness_set()` routes `led:torch_N` to
`qpnp_flash_led_node_set()` -- which only programs the per-channel current --
and only `led:switch_N` to `qpnp_flash_led_switch_set()`. The emitter stays dark
until the switch is asserted.

The ioctl path in that same file already knows this. `msm_flash_low()` fires
every torch trigger and then unconditionally does

```c
led_trigger_event(flash_ctrl->switch_trigger, 1);
```

which is why the torch works through the Android camera HAL and did nothing from
sysfs. Confirmed on-device: `echo 200 > /sys/class/leds/torch-light0/brightness`
as root does not light the LED.

The fix adds a `switch_trigger` static beside the existing `torch_trigger`,
populates it in `msm_torch_create_classdev()` from `fctrl->switch_trigger`, and
fires it from `msm_torch_brightness_set()`. It is guarded, because the field is
only populated when the DT node supplies `qcom,switch-source` -- laurel_sprout
does, via `trinket-camera-sensor-qrd.dtsi`:

```
qcom,switch-source = <&pmi632_switch0 &pmi632_switch0>;
```

Only the sysfs classdev changes; `msm_flash_low()`/`msm_flash_high()` do not go
through it, so the camera HAL path is untouched.

### Bug 2 (permissions): the indicator cannot write the node

Every LED node is `root:root 0644` and the indicator runs as the unprivileged
`phablet` user, so the write fails with `EACCES` and is swallowed.

Nothing sets those permissions on the way past. Android's ueventd only chowns the
notification LEDs -- `/android/vendor/ueventd.rc:365-376` covers red, green and
blue and never the flash nodes, because on Android the torch goes through the
camera HAL rather than sysfs -- and the stock udev rules mention
`SUBSYSTEM=="leds"` only for `kbd_backlight` and `TAG+="seat"`.

`overlay/system/lib/udev/rules.d/71-laurel-sprout-torch.rules` hands
`torch-light{0,1}`, `led:torch_{0,1}` and `led:switch_{0,1}` to group `video`
(gid 44), which `phablet` already belongs to. It uses `RUN+=` rather than udev's
`GROUP=`/`MODE=` keys, because those apply only to device nodes under `/dev`, not
to sysfs attributes. The whole set is covered rather than just `torch-light0`
because which torch/switch pair the indicator settles on has not been observed
directly. That directory needed a new `.halium-overlay-dir` marker, since the
rule file does not exist on the base rootfs.

### Measured

Two writes as root, on the unpatched kernel:

```
echo 200 > /sys/class/leds/torch-light0/brightness      # LED stays dark
```

```
echo 100 > /sys/class/leds/led:torch_0/brightness       # LED lights
echo 1   > /sys/class/leds/led:switch_0/brightness
```

The first is the whole of what `msm_torch_brightness_set()` used to do, and it
does nothing. The second is what it does now. So the hardware, the regulator and
the current path are all fine, and the two fixes above are the whole story --
neither a `prepare` write nor any camera-side power-up is needed.

### Confirmed on device

With kernel `#23 SMP PREEMPT Wed Sep 2 13:14:15 UTC 2026` (the patch above) and
the udev rule active, the torch works from the indicator. The rule flips the
nodes as intended:

```
-rw-rw-r-- 1 root video /sys/class/leds/torch-light0/brightness
-rw-rw-r-- 1 root video /sys/class/leds/led:torch_0/brightness
-rw-rw-r-- 1 root video /sys/class/leds/led:switch_0/brightness
```

No restart of `ayatana-indicator-power` was needed, so it evidently checks
writability when it writes rather than caching a verdict at probe time.

### Testing the rule without a rebuild

`/etc/udev/rules.d` is a writable mount from userdata (`/dev/sda15`) and ships
empty, so the rule can be dropped straight in -- persisting across reboots,
though not across a userdata wipe:

```
sudo install -m 0644 -o root -g root 71-laurel-sprout-torch.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=leds
```

Note that `systemctl --user` over `adb shell` fails with "Failed to connect to
bus: No medium found" -- there is no session bus in that environment. It needs
the session pointed at explicitly:

```
XDG_RUNTIME_DIR=/run/user/32011 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/32011/bus \
  systemctl --user restart ayatana-indicator-power
```

## Fingerprint (FOD)

The Mi A3's sensor is a Goodix optical under-display unit (`goodix_fod`,
module `ofilm`), driven by a HIDL 2.1 stack: kernel driver
(`drivers/input/fingerprint/goodix_fod/gf_spi.c`) -> vendor HAL
(`/vendor/lib64/hw/fingerprint.goodix_fod.so`, backed by `libgf_hal.so`) ->
`android.hardware.biometrics.fingerprint@2.1-service` -> biometryd ->
Lomiri's fingerprint settings page.

**FOD does not work on stock either, on this unit.** A stock-ROM session
(2026-09-09, V12.0.26.0.RFQMIXM + Magisk root, the latest and correct
package for this device) established that there are *two stacked
failures*, and that this port had already reached stock parity before
hitting the second one. Neither is port-specific.

### Failure A: the touch controller never enables FOD (hard, not fixable in software)

`FTS_REG_FOD_EN` (`0xCF`) on the Focaltech FT3518 accepts writes at the
I2C level and discards them. Verified on stock, directly against
`fts_rw_reg`:

```
control (0xD0, gesture_en):  write 01 -> read back 01   STICKS
target  (0xCF, FOD_EN):      write 01/02/03 -> "success" -> read back 00
```

Tested in every state that matters: screen on; `Dozing` with gesture mode
confirmed active (`D0=01`); and with `/sys/class/touch/tp_dev/fod_status`
set to 1, which drives the driver's own `fts_fod_suspend()` ->
`fts_write_reg(FTS_REG_FOD_EN, ...)` path and logs
`CF register fod's bit set 1, CF register = 2` followed by
`Enter into FOD(suspend) successfully!` -- the driver's write returns OK
and the readback is still `00`.

`fts_fod_readdata()` (`focaltech_gesture.c`) opens with
`if ((ret < 0) || (buf[0] < 1) || (buf[0] > 3)) return 1;` on that
register, so with `0xCF` pinned at `0` **no `KEY_FOD` can ever be
emitted** by any software stack. CF bit0 = double-tap wake, bit1 = FOD.

Correction to an earlier reading: the dmesg line
`fts_ts_resume:resume CF register value retry write, CF register = %x`
prints the value *being written* (computed from
`tid->fod_status || tid->aod_status`, `|= lpwg_mode`), **not** a failed
readback. Seeing `= 0` there just means nothing had set `fod_status`. It
is not evidence of the defect; the direct register writes above are.

Suspected cause -- the touch module is not factory-programmed:

```
/proc/touchscreen/lockdown_info  ->  0000000000000000   (blank)
hardware_info = none,ft3518,fw:0x11     buildid = ffffff80-11
driver wants focaltech-ft3518-none.ini; ROM ships only -sumsung.ini
```

The IC itself is correct (`IC ID:0x5452` *is* the FT3518 per
`FTS_CHIP_TYPE_MAPPING`; `FTS_MODULE_ID 0x0000` means vendor-ID `0x00` is
expected, so neither is an anomaly). But the lockdown region that encodes
panel maker/colour/version is erased and the firmware is a generic `0x11`
build. Consistent with a replaced/reflashed display module carrying
generic Focaltech firmware without Xiaomi's FOD feature -- basic touch and
double-tap work, only FOD is absent. Not confirmed; the panel *is* the
expected `dsi_r692a9_gvo` (Visionox).

**This port's `KEY_FOD` injection is a working bypass, and it works on
stock too** -- injecting `EV_KEY 0x152` on `/dev/input/event2` (via
`sendevent`, or any writer; `phablet`/`shell` is in `android_input`)
produces, in the stock HAL:

```
I/FingerprintHal: [gf_finger_pressure_detecting_thread] touch panel detected finger down
```

Stock has no such bypass, which is why an unaided stock enrolment shows
one illuminate handshake and then a 60 s timeout (`error 3`): MIUI's own
software never sees a finger-down either.

### Root cause of Failure A: this port's own kernel flashed the touch IC

**The port kernel overwrote the genuine Xiaomi touch firmware with an invalid
placeholder.** `focaltech_touch_f9s/focaltech_config.h` shipped:

```c
#define FTS_AUTO_UPGRADE_EN    1                              /* flash every boot */
#define FTS_GET_MODULE_NUM     0                              /* no module-id check */
#define FTS_UPGRADE_FW_FILE    "include/firmware/fw_sample.i"
```

`fw_sample.i` is not a stub -- it is a real 271 KB firmware image, **version
0x11**, and upstream's own comment above that define reads *"you must replace
it with your own ... the sample one to be replaced is invalid"*. It never was.
`fts_fwupg_need_upgrade()` returns true on **any** version difference, in
either direction, so the first boot of a kernel built from this tree reflashed
the touch controller.

Proof, byte level (2026-09-09):

| | version @ `0x10E` | head |
|---|---|---|
| genuine, from stock `boot.img` kernel | `0x81` (comp `0x7E`) | `0221c802 b938e402` |
| `fw_sample.i` (this tree) | `0x11` (comp `0xEE`) | `0221c802 c8f7e402` |
| **the device** | **`0x11`** | -- |

Every Failure A symptom follows: `fw:0x11`, the lockdown region at flash
`0x1e000` erased to all-zero, `panel_maker = none`, the driver hunting a
nonexistent `focaltech-ft3518-none.ini`, and -- decisively -- `0xCF`
(`FTS_REG_FOD_EN`) unimplemented, so writes are ACKed and discarded. The
earlier "replaced display module" theory was wrong; the damage is
self-inflicted and, in principle, repairable.

Stock never repairs it: stock's auto-upgrade is gated off, so the device sits
on `0x11` indefinitely.

**Fixed in the kernel tree** (`halium-11`): `FTS_AUTO_UPGRADE_EN` set to `0`
and `FTS_UPGRADE_FW{,2,3}_FILE` repointed at a new
`include/firmware/fw_laurel_sprout_v81.i` carrying the genuine image.
**This was a port-wide hazard** -- any Mi A3 that booted a build from this
tree lost FOD the same way.

### Restoring the firmware: blocked in userspace

The genuine image is extracted and kept at
`device-backup/fts-firmware/fts_stock_ft3518_v81.bin` (49640 B, md5
`17c433f77584b4f03b6819a0d7281a95`; it appears 3x in the stock kernel as
`fw_file`/`fw_file2`/`fw_file3`, all identical).

`fts_upgrade_bin` reads it correctly but **cannot get the IC into the
bootloader**:

```
fts_read_file: file len:49640 read len:49640          <- file fine
fts_wait_tp_to_valid: TP Ready, Device ID = 0x54      <- fw "valid"
fts_fwupg_reset_to_boot: send 0xAA and 0x55 to FW     <- reset IS sent (reg 0xFC)
fts_fwupg_enter_into_boot: pram not supported, confirm in bootloader
fts_fwupg_get_boot_state: read boot id:0x0000         <- chip never answers
fts_ft5452_upgrade: enter into pramboot/bootloader fail, ret=-5
```

The placeholder firmware does not implement the `0xFC` reset-to-bootloader
command, so it cannot hand over control to be replaced. Tried and failed
identically: normal upgrade; upgrade from a clean state (`fod_status=0`,
screen on, gesture off); and three attempts immediately after a hardware GPIO
reset via `cat fts_hw_reset` (which runs `fts_reset_proc(0)`) to catch the ROM
boot window. Boot id read `0x0000` every time. `fts_force_upgrade` is a no-op
here -- `upgrade_func_ft5452` has no `.force_upgrade`, so it logs
"force_upgrade function is null" and returns.

Note `fts_boot_mode` reporting "tp is in boot mode" is a red herring: it
reflects `fw_is_running`, which is SPI-only and defaults to 0 on this I2C part.

No damage from the attempts -- the IC still answers (`chip id 0x54`), IRQ
enabled, touch working.

**Software repair is impossible on this unit: the touch controller cannot be
reset.** Four build/flash/test rounds settled this (2026-09-09/10). The patched
driver was verified running each time -- kernel `4.14.357-openela-perf-g<sha>`,
built from the fork's `fts-oneshot-repair`, with the genuine v0x81 image present
in the kernel and the placeholder absent (checked by searching the
gzip-decompressed kernel for both blobs).

Getting a log needed a trick worth remembering: `fastboot boot` is unavailable
(Xiaomi's ABL answers `unknown command`), and a Halium boot image gives no
usable userspace on a stock install. But on an A/B device **recovery lives
inside boot.img**, so flashing the repair kernel to `boot_b` and booting
*recovery* on that slot runs the patched driver and gives a working adb shell.

What the rounds showed:

| attempt | result |
|---|---|
| handshake immediately after `fts_reset_proc(0)` | `read boot id:0x0000` |
| 13 delays swept 0-40ms x 3 | 138 probes, **all** `0x0000`, `ret=0` |
| handshake blanketed 50ms (250 writes x 200us) x 5 resets | 2500 handshakes, `nak=0`, still `0x0000` |
| `vdd` regulator power cycle x 3 | `nak=0`, still `0x0000` |

The decisive line came from `fts_reset_line_check()`, which reads while holding
reset asserted:

```
reset line: held-low ret=2 (want <0), released ret=2 id=0x54
```

**The controller ACKs and returns chip id 0x54 while its reset line is held
low.** A part in reset cannot answer, so the reset GPIO does nothing here, and
the controller has never passed through mask ROM -- there was never a ROM
listening for the 0x55/0xAA handshake. The power cycle fails for the same class
of reason: `regulator_disable()` only drops a refcount, and the `vdd` rail is
evidently held up by another consumer (the panel is the obvious candidate; only
`vcc_i2c` is a dummy regulator on this board).

Note `FTS_DEBUG_EN` is **0** in this tree, so `FTS_DEBUG` compiles to nothing
and `fts_fwupg_get_boot_state()`'s boot id never prints. The repair branch sets
it to 1. `fts_log_level` is the IC's own log level and is unrelated -- raising
it does nothing for driver logging.

This explains the asymmetry that made the damage possible. Flashing *away* from
the genuine firmware worked because v0x81 implements the `0xFC`
reset-to-bootloader command and cooperatively hands over control; no hardware
reset is needed. Flashing *back* cannot work, because the placeholder does not
implement `0xFC` and the hardware reset that would bypass it is inert. A
one-way door: the part can be talked out of its firmware but not back into it.

The only remaining route is external -- an I2C programmer (CH341, bus pirate)
on the touch flex with the phone powered down, so the controller is genuinely
unpowered and comes up in mask ROM when the programmer powers it. That is a
hardware job and out of scope here.

**None of this touches Failure B.** Even a perfect firmware restore leaves the
`GF_ERROR_PREPROCESS_FAILED errno=1011` trustlet failure, which blocks
enrolment independently and reproduces on stock.

Remaining idea, untried: patch the driver to add a hardware-reset-into-romboot
recovery path (`fts_fwupg_reset_to_romboot()` already exists but is wired only
into the pramboot flow, which ft5452 does not use) and boot it non-permanently
via `fastboot boot`. Uncertain -- `fts_ft5452_upgrade()`'s flash routine targets
bootloader mode, not romboot.

### Failure B: the Goodix trustlet fails the preprocess command

With injection supplying finger-down, stock captures on every touch and
then fails identically to this port:

```
E/[GF_HAL][CaEntry]: [sendCommand] QSEE TEE execute command failed.
E/[GF_HAL][CaEntry]: [sendCommand] exit. err=GF_ERROR_PREPROCESS_FAILED, errno=1011
E/[GF_HAL][Algo]:    [enrollImage] exit. err=GF_ERROR_PREPROCESS_FAILED, errno=1011
```

Same errno 1011 this port saw across 260 attempts. Two things this
establishes:

- The error surfaces from `CaEntry::sendCommand` -- it is a **TEE-side
  command failure**, not the image-quality rejection it was read as.
- It reproduces **with no finger on the sensor at all**, so it is not
  about image content or capture quality.

It does *not*, on its own, prove the cause is missing calibration -- a
trustlet failing preprocess because it has no calibration parameters
would look exactly like this too. That remains the leading hypothesis.

### What is proven healthy (do not re-investigate)

Goodix's own factory test app ships on stock as
`/system/app/GfDisplayTest/GfDisplayTest.apk`
(`com.goodix.fingerprint.gftest.MainActivity`):

| Test | cmd | Result |
|---|---|---|
| SPI TEST | `0x621` | **Success** -- Sensor `0x1303`, PMIC `0x0ba9`, Flash `0x001342c8`, MCU `0x2` |
| RST/INT TEST | `0x620` | **Success** (`errorCode = 0`) |

So the optical sensor, its PMIC, flash, MCU, reset line and IRQ are all
good. Also verified healthy: the trustlet loads
(`QSEECOMAPI: Loaded image: APP id = 6`); HAL init is clean and resolves
`force_touch_path = /dev/input/event2`; TZ/keymaster work (PIN unlock);
`persist` is a **single, non-slotted** partition so A/B slot mistakes
cannot corrupt it; no SELinux denials against fingerprint/goodix/persist.

### Calibration data: it exists, in persist

The earlier "this sensor has never been calibrated" conclusion was drawn
from looking only at `/data/vendor/goodix/`. The real data is in persist:

```
/mnt/vendor/persist/goodix/BMatrix.so        1225980 B
/mnt/vendor/persist/goodix/caliParamsInfo.so  675620 B
/mnt/vendor/persist/goodix/chartbase.so        86068 B
```

All three are structurally valid -- each opens with a little-endian length
header whose value is exactly `filesize - 52` (`0x0012b4c8`, `0x000a4ef0`,
`0x00015000`) -- and are high-entropy, not zeroed. Backed up off-device.

`/data/vendor/goodix/{gf_cali,gf_data,factory_test}/` are still empty, and
the per-sensor `gf_cali/CaliParam/` set that `libgf_hal.so`'s path
templates point at does not exist. That set is the outstanding gap.

### Reaching Goodix test/calibration commands: use the supported path

`GfDisplayTest.apk` issues these commands through
`com.goodix.FingerprintService` ->
`IGoodixFingerprintDaemon::sendCommand`, and it round-trips cleanly
(observed for `0x620`/`0x621`). **This is the route to use.**

Do **not** resume the ptrace-injection-into-`fpservice` approach from the
earlier session (it crashed the HAL three times and killed it once). It
was solving a problem that has a normal solution, and it was aimed at
`testKbCalibration` on the strength of a calibration diagnosis that is no
longer established.

### Still open

- Whether the missing `/data/vendor/goodix/gf_cali/CaliParam/` set is what
  the trustlet's preprocess command is failing on. Untested.
- Generating that set is **blocked by a second, different gate**, tested
  2026-09-09. `SPMTActivity` in `GfDisplayTest.apk` is the factory
  calibration entry point and it runs: `SPI Test Succeed`, `MT_CHECK Test
  Succeed`, `SPI_RST_INT Test Succeed`, it renders the green capture spot
  at the FOD location (so illumination is fine), and it then prompts
  `请放置肉色砝码` -- "place the flesh-coloured weight", a Goodix factory
  fixture with known optical properties, not a finger.

  With a real finger on the spot **and `KEY_FOD` injected**, it fails:

  ```
  0x61 Flesh or Chart Down/up Timeout
  ```

  The HAL's `gf_finger_pressure_detecting_thread` logged the injected
  finger down/up each time, so the injection was delivered -- the
  calibration path simply does not accept it. **The `KEY_FOD` bypass
  works for the enrol/auth path but not for the factory calibration
  path**, which wants the sensor's own flesh/chart down-up detection.
  Nothing was written: persist md5s unchanged, `/data/vendor/goodix`
  still empty.

  So `CMD_MMI_OPTICAL_CALIBRATION_TEST` is not reachable this way, and
  calibration cannot currently be regenerated on this unit even with the
  supported client path. A proper calibration block would still leave the
  `0x61` detection gate to solve.
- Whether a generic-firmware touch module can be reflashed with Xiaomi's
  FOD-capable FT3518 firmware. The driver exposes `fts_upgrade_bin` and
  `fts_force_upgrade`, but the ROM ships no `.img` (only a `-sumsung`
  self-test `.ini`) and the kernel's bundled `FTS_UPGRADE_FW_FILE` is the
  `fw_sample.i` placeholder. No known good firmware source.
- **A firmware downgrade within Android 11 is a dead end.** Compared the
  V12.0.22.0.RFQMIXM firmware-only OTA against the V12.0.26.0.RFQMIXM
  fastboot package (2026-09-09): `modem` (`NON-HLOS.bin`, the partition
  mounted at `/vendor/firmware_mnt`, which carries the Goodix trustlet
  `gfcep`) and `tz` are **byte-identical** -- md5 `70a97c5ed07c437f...`
  (117198848 B) and `35b136b3fbd1d6a9...` (2007040 B). Both ship
  `Nicobar.LA.1.0-00182-STD.PROD-1` (2021-11-19). Other images differ
  only by block padding (the OTA `.img`s are padded, the fastboot
  `.mbn`/`.elf`s are not); `abl` differs for real but is irrelevant here.
  So the trustlet is unchanged across these builds and downgrading to
  V12.0.22.0 cannot affect errno 1011. The device reports `anti: 0`, so
  ARB does not block a downgrade -- but only V12.0.11.0.RFQMIXM
  (2021-06-15, firmware predating the 2021-11-19 meta-build) could
  actually change the variable, and it is not readily obtainable.

- Even if Failure B were solved, Failure A still needs the `KEY_FOD`
  injection bypass on any OS, plus `sys.panel.display=VXN` and
  `extCmd(COMMAND_NIT=10, PARAM_NIT_FOD=1)` paired at finger down/up.
  Vendor acquire codes observed on stock: `21` at enrol start, then
  `22`/`23` for down/up -- matching LineageOS's `UdfpsHandler` 22/23
  scheme, contrary to an earlier note here claiming 21 replaced them.

## Known open issues

- **Stale property area.** A failed container attempt leaves
  `/dev/__properties__` populated (host `/dev` is bind-mounted and
  survives teardown), making every retry SIGSEGV in
  `__system_property_area_init()` and masking the real error.
- **`pre-start.d` never runs.** `pre-start.sh` gates the whole directory
  on `[ -w $LXC_ROOTFS_PATH ]`, and the container rootfs is mounted
  read-only, so none of those snippets execute -- including
  `30-no-surface-flinger`. Anything that relies on them must be done
  through the overlay instead.
- **MTP.** `f_mtp` backs one static `mtp_device`, so only one configfs
  instance can exist (the `_mtp_dev` guard in `mtp_setup_configfs_dev()`
  returns `-EBUSY`). Android's `init.qcom.usb.rc` creates
  `g1/functions/mtp.gs0` at boot, and usb-moded's stock
  `function_mtp = mtp.mtp` then fails:
  `functions/mtp.mtp: mkdir failed: Device or resource busy`. The overlay's
  `90-device-specific-config.ini` sets `function_mtp = mtp.gs0` so both sides
  name the same instance; usb-moded skips the mkdir for a registered function
  and init's mkdir of an existing directory is `EEXIST`, so boot order no
  longer matters. **Unverified on device.** MTP is also only exposed in the
  `mtp` / `mtp_adb` modes; the default `rndis_adb` (see
  [USB connectivity](#usb-connectivity-adb--ssh)) carries no MTP function.
- **Double-tap to wake.** deviceinfo `DoubleTapToWake` pointed at
  `/etc/writable/dt2w_enable`, which does not exist, so repowerd logged
  `FsDoubleTapToWake: Invalid config path` and the settings toggle did
  nothing. It now points at `/sys/bus/i2c/devices/1-0038/fts_gesture_mode`
  (`1`/`0`, checked in `fts_ts_suspend()`). The wake itself is unverified:
  the maintainer's unit has the touch-firmware fault described under
  [Fingerprint (FOD)](#fingerprint-fod).
- **AppArmor mediation.** `/sys/kernel/security/apparmor/features/` lacks
  `dbus` and `network`, so Ubuntu Touch app confinement is incomplete.
  Note the AppArmor patch set at `glasskernel/for_apparmor` is
  robustness/security backports only and does **not** add these
  mediation types.
- **Device name.** The initrd logs `WARNING: Didn't find a device name`,
  so Halium device-specific config (including the
  `/usr/lib/lxc-android-config/70-$device.rules` lookup) is skipped.

## AppArmor patch set

Ubuntu Touch needs AppArmor socket mediation, which mainline 4.14 lacks
(upstream added `security/apparmor/net.c` in 4.17). Applied to the kernel
branch `apparmor-patches`:

| Source | Patches |
|---|---|
| `glasskernel/for_apparmor` (lineage-23.2 — our exact base) | 9 robustness/security backports: DFA bounds validation, memory leaks, namespace depth limit, double-free in `aa_replace_profiles()`, `->free_inode()` conversion, and the security fix *"unprivileged local user can do privileged policy management"* |
| Old Mi A3 Halium 9 kernel (same device, 4.14-native) | `query_label` forward-port; **socket mediation base** (hand-integrated); **af_unix mediation** |
| Nothing Phone 1 Halium 11 kernel (sm7325) | `add/use fns to print hash string hex value` |

Two integrations needed hand-work because our tree carries the LSM
stacking backport (`context.h` → `cred.h`, `context.o` → `task.o`, and a
restructured audit union):

- **socket mediation base** — 5 rejected hunks: `net.o` + `net_names.h`
  rules in the Makefile, the `net` struct in the audit union, `net.h`
  includes, and 362 lines of socket hooks. All 16
  `LSM_HOOK_INIT(socket_*)` registrations applied on their own.
- **af_unix** — `unix_state_lock_nested()` gained a lock-class argument
  in 4.14.357 (stable backport), so the Halium 9 one-arg calls would not
  compile. Replaced with `swap()` + `U_LOCK_SECOND`, matching the Nothing
  Phone 1 fix `787d4cb1348a`.

### Deliberately NOT applied — verified inapplicable to 4.14

Do not re-attempt these; each was checked against the tree:

| Patch | Why not |
|---|---|
| `match_char()` side-effect fix | `match_char` does not exist in 4.14 (5.x construct) |
| `differential encoding` verification fix | diff-encoding is a 5.x feature; absent here |
| `verify_dfa()` DEFAULT bounds | **already correct** — we have the unconditional `DEFAULT_TABLE(dfa)[i] >= state_count` check, and `MATCH_FLAG_DIFF_ENCODE` (the exemption that patch removes) does not exist |
| v2.x net rules compatibility | **not needed** — our `struct aa_net` is byte-identical to the `struct aa_net_compat` it would add, and `net.c` already uses it. The shim exists only for 5.x, which replaced the v2 implementation with DFA-based `AA_CLASS_NET` |
| raw policy blob compression + its rawdata race fixes | Conflicts with our `policy_unpack.c`; a storage optimisation plus fixes for the code it introduces, so the trio is skipped as a set |

All three DFA patches turn out to be consequences of the same 5.x
differential-encoding feature this tree does not carry.

### Verification status

Confirmed at build level: `net.o` and `af_unix.o` compile,
`net_names.h` generates, and `AA_SFS_DIR("network", ...)` is registered
in `apparmorfs.c`. `CONFIG_SECURITY_NETWORK=y`, and
`unix_stream_connect`/`unix_may_send` are declared in
`include/linux/lsm_hook_defs.h` with signatures matching the handlers.

**Not yet confirmed at runtime.** The check is that
`/sys/kernel/security/apparmor/features/network/` appears and that all
profiles still load with no `apparmor="DENIED"` entries.
