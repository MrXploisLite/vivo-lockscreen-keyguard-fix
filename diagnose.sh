#!/usr/bin/env sh
# diagnose.sh — read-only health check for the vivo/OriginOS lockscreen
#
# Detects the "Kesalahan program layar kunci" / "Screen lock program error"
# condition and tells you the exact next action. Changes NOTHING on the device.
#
#   sh diagnose.sh
#
# Requires: adb on PATH, USB debugging enabled, device authorised.

set -u

PKG=com.vivo.systemuiplugin

# Git Bash / MSYS rewrites absolute POSIX paths handed to Windows binaries,
# which breaks `adb shell ls /system/...`.
MSYS_NO_PATHCONV=1
export MSYS_NO_PATHCONV

if [ "$(adb get-state 2>/dev/null)" != "device" ]; then
	echo "FATAL: no authorised device. Check USB debugging + the RSA prompt." >&2
	exit 1
fi

line=$(adb shell "dumpsys package $PKG" 2>/dev/null | grep -E '^ +User 0:' | head -1)
enabled=$(printf '%s' "$line" | sed -n 's/.*\(enabled=[0-9]\).*/\1/p')
stopped=$(printf '%s' "$line" | sed -n 's/.*\(stopped=[a-z]*\).*/\1/p')

focus=$(adb shell "dumpsys window" 2>/dev/null \
	| sed -n 's/.*mCurrentFocus=.*\(com\.[a-z0-9._]*\/[a-zA-Z0-9._$]*\).*/\1/p')

printf 'package    : %s\n' "$PKG"
printf 'User 0     : %s %s\n' "${enabled:-?}" "${stopped:-?}"
printf 'focus      : %s\n' "${focus:-?}"
printf '\n'

case "$enabled" in
enabled=3)
	cat <<'EOF'
VERDICT: BROKEN — lockscreen plugin is DISABLED_USER

The vivo keyguard never loads, so Android falls back to the bare AOSP
lockscreen and shows the "Kesalahan program layar kunci" dialog.

FIX:
  adb shell "cmd package enable --user 0 com.vivo.systemuiplugin"
  adb reboot
EOF
	exit 2
	;;
enabled=1)
	if [ "$stopped" = "stopped=true" ]; then
		cat <<'EOF'
VERDICT: LATENT — enabled but never started

FIX:
  adb reboot
EOF
		exit 3
	fi
	cat <<'EOF'
VERDICT: HEALTHY

The plugin is enabled and running. If the dialog is still on screen,
it is a stale window — reboot once to clear it.
EOF
	exit 0
	;;
*)
	echo "VERDICT: INCONCLUSIVE — could not read package state (root needed?)." >&2
	exit 1
	;;
esac
