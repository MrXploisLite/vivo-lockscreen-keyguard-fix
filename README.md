# Fixing "Kesalahan program layar kunci" on vivo / OriginOS

A phone stuck showing a lockscreen error banner, with a working PIN but missing every
vivo lockscreen feature. This is the diagnosis and the fix — **no root, no factory
reset, no data loss.**

> **⚠️ Kesalahan program layar kunci**
> Kini Anda hanya dapat menggesek ke atas dan memasukkan kata sandi untuk membuka
> kunci perangkat. Anda dapat menghubungi pusat layanan pelanggan resmi untuk
> mendapatkan bantuan.

Translation: *"Screen lock program error. You can now only swipe up and enter a
password to unlock the device. You can contact official customer service for
help."*

---

## TL;DR

```sh
adb shell "cmd package enable --user 0 com.vivo.systemuiplugin"
adb reboot
```

Two commands. That's the whole fix. Everything below is why.

---

## Root cause

`com.vivo.systemuiplugin` is **not a cosmetic plugin — it is vivo's entire keyguard
implementation.** Everything you'd recognise as an OriginOS lockscreen lives in it:
the clock, always-on display, lock-screen notifications, charging indicator, camera
shortcut.

It sits in `/system/priv-app/SystemUIPlugin/SystemUIPlugin.apk` (~95 MB) and is loaded
*into the `com.android.systemui` process* by the SystemUI plugin manager. Its code is
namespaced `com.vivo.systemuiplugin.keyguard.*` — `FullAodAnimationHelper`,
`NotificationAvoidInteractor`, `FullAodScreenProtector`.

When that package is **disabled**, SystemUI falls back to the stock AOSP keyguard.
The PIN still works, because the PIN lives in the framework's credential store and is
completely independent of the plugin. What you lose is every vivo feature — and
OriginOS shows you that error banner explaining the degraded state.

```sh
$ adb shell "dumpsys package com.vivo.systemuiplugin" | grep "User 0:"
User 0: ... enabled=3 ... stopped=true
#                  ^^^^^^^^ COMPONENT_ENABLED_STATE_DISABLED_USER
```

`enabled` values:

| value | meaning |
|---|---|
| `0` | `COMPONENT_ENABLED_STATE_DEFAULT` |
| `1` | `COMPONENT_ENABLED_STATE_ENABLED` ✅ |
| `2` | `COMPONENT_ENABLED_STATE_DISABLED` |
| `3` | `COMPONENT_ENABLED_STATE_DISABLED_USER` ❌ **this is the fault** |

### Why it gets disabled

OriginOS has self-healing logic that auto-disables a crashing SystemUI plugin so the
phone doesn't boot-loop. When the keyguard enters a bad state — force-pressed power
and volume buttons, an unclean shutdown while locked, a SystemUI crash — the plugin
gets flagged and disabled. **The self-heal is the cause, not the cure**: it protects
the system from a crash loop by degrading the lockscreen permanently until a reboot.

---

## Diagnosis

Confirm it before touching anything. Every command here is read-only.

```sh
# 1. Is the plugin disabled?
adb shell "dumpsys package com.vivo.systemuiplugin" | grep "User 0:"
#    enabled=3  →  confirmed

# 2. Is the keyguard actually showing?
adb shell "dumpsys activity activities" | grep "KeyguardShowing="
#    KeyguardShowing=true  →  yes

# 3. Is the window the stock AOSP one?
adb shell "dumpsys window" | grep mCurrentFocus
#    com.android.systemui:... u0 NotificationShade  →  AOSP, not the vivo plugin

# 4. Does the package actually exist and ship in the ROM?
adb shell pm path com.vivo.systemuiplugin
#    package:/system/priv-app/SystemUIPlugin/SystemUIPlugin.apk
```

Or just run the bundled script — read-only, prints a verdict and exit code:

```sh
sh diagnose.sh
# exit 0 = healthy, 2 = broken, 3 = latent (enabled but not started)
```

---

## The fix

```sh
# 1. Re-enable the plugin, scoped to the primary user
adb shell "cmd package enable --user 0 com.vivo.systemuiplugin"
#    → Package com.vivo.systemuiplugin new state: enabled

# 2. Reboot — mandatory, see below
adb reboot
```

Then `adb devices` once it's back (~35 s on the test device). The adb *server* runs on
your PC and never dies; only the on-device daemon restarts, so it reconnects on its
own. No reinstall, no re-pairing.

### Unlock with your PIN as normal.

---

## Two traps that waste your time

### Trap 1 — plain `pm enable` fails

```sh
$ adb shell pm enable com.vivo.systemuiplugin
Error: Shell does not have permission to access user 10
```

`pm enable` without `--user` iterates **every** user on the device, including vivo's
Private Space (user 10), which the shell user is not allowed to touch. The command
aborts and changes nothing. Use `cmd package enable --user 0`, which scopes the
operation to the primary user.

### Trap 2 — restarting SystemUI is not enough

```sh
$ adb shell am force-stop com.android.systemui   # SystemUI restarts
$ adb shell "dumpsys package com.vivo.systemuiplugin" | grep "User 0:"
User 0: ... enabled=1 ... stopped=true
#                                    ^^^^^^^^^^^^^ still never started
```

The package is enabled, SystemUI has restarted, and the plugin still never loads.
The plugin scan happens during **boot**, not when SystemUI restarts. Only a real
reboot loads it.

### Trap 3 — `logcat` is blind on these devices

vivo filters `logcat` hard for the shell user under SELinux. A full capture across a
SystemUI restart returns **three lines**. Don't build a debugging strategy around it —
`dumpsys` is your only reliable channel.

### Trap 4 — `screencap` returns black when the screen is off

A ~16 KB PNG that is a solid black frame means the display is off, not that the
lockscreen is broken. Check `dumpsys power | grep mWakefulness` first.

---

## Verification

```sh
# Plugin enabled AND running
adb shell "dumpsys package com.vivo.systemuiplugin" | grep "User 0:"
#    enabled=1 ... stopped=false   ← both conditions must hold

# Keyguard healthy
adb shell "dumpsys activity activities" | grep "KeyguardShowing="
#    KeyguardShowing=false   (once unlocked)

# Lock and look
adb shell input keyevent 26
```

The vivo lockscreen should render: lock glyph, OriginOS clock, notifications, charging
indicator, camera shortcut. **No error banner.**

---

## Rollback

Every step is reversible. Nothing touches your data, your apps, or your credential.

```sh
# Put the plugin back exactly as it was
adb shell "cmd package disable-user --user 0 com.vivo.systemuiplugin"
```

Nothing else needs undoing — `enable` flips one flag. No data was written at any point.

---

## Why this is safe

| Action | Touches `/data/data` | Resets app settings | Wipes credentials |
|---|---|---|---|
| `cmd package enable` | no | no | no |
| `adb reboot` | no | no | no |
| `am force-stop com.android.systemui` | no | no | no |

Commands explicitly **not** used anywhere in this fix, because they would destroy data:

- `pm clear <pkg>` — wipes app data
- `pm uninstall` — removes the app
- `settings put global` — can reset security settings
- `fastboot flash` / `recovery --wipe` — destroys the install
- `adb root` / `su` — unavailable on production builds anyway

---

## Requirements

- USB debugging enabled
- `adb` from [SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools) (37.0.1 tested)
- **No root.** This was verified on a stock, bootloader-locked, SELinux-Enforcing,
  `verifiedboot=green` production build with `adbd` refusing `adb root`:
  `adbd cannot run as root in production builds`

---

## Proven on

| | |
|---|---|
| Device | vivo Y29 4G (`V2434`) |
| Android | 16 (SDK 36), security patch 2026-08-01 |
| ROM | OriginOS, stock, unrooted |
| Serial | `10DFBL0KHN****` *(redacted)* |
| adb | 37.0.1-15733141 |

The `cmd package enable --user N` requirement and the reboot requirement are properties
of Android's package manager and the SystemUI plugin loader, so this should apply to
other vivo/OriginOS devices where the same disabled-plugin state occurs. Y-series, X-series
and iQOO are all plausible — check with `diagnose.sh` first.

---

## Bahasa Indonesia — ringkas

**Gejalanya:** muncul banner "Kesalahan program layar kunci". PIN masih bisa dibuka,
tapi semua fitur lockscreen vivo hilang (clock, AOD, notifikasi, kamera).

**Penyebabnya:** `com.vivo.systemuiplugin` — itu seluruh implementasi layar kunci vivo —
ke-disable sendiri (`enabled=3`) oleh mekanisme self-healing OriginOS. Android jatuh ke
lockscreen cadangan AOSP, makanya muncul banner itu.

**Perbaikannya:**

```sh
adb shell "cmd package enable --user 0 com.vivo.systemuiplugin"
adb reboot
```

**Dua jebakan:**
1. `pm enable` biasa **gagal** — error `Shell does not have permission to access user 10`.
   Harus pakai `cmd package enable --user 0`.
2. `am force-stop com.android.systemui` **nggak cukup** — plugin cuma di-load saat boot.
   Reboot wajib.

**Rollback:**

```sh
adb shell "cmd package disable-user --user 0 com.vivo.systemuiplugin"
```

Semua langkah reversible. Tidak ada satu pun data yang tersentuh.

---

## License

MIT — do what you want with it, just keep the credit.
