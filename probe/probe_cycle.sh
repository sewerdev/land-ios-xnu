#!/bin/bash
# One probe cycle: put the boot probe on the phone, let it run, get it back, read
# what it saw.
#
# The phone boots this probe, the probe writes a journal to /cache, copies TWRP from
# recovery over boot and reboots, which brings adb back on the PC side.  So one
# command covers a reboot nobody has to touch: the phone returns to TWRP by itself
# and boot keeps the TWRP image afterwards, which is the state this script expects
# to find when it runs again.
#
# usage: probe_cycle.sh [--keep-boot] [tries]
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
W=/cygdrive/g/xnu-land
BOOT=$W/land-eos-boot.img
keep=0
tries=60
while [ $# -gt 0 ]; do
	case "$1" in
	--keep-boot) keep=1; shift ;;
	*) tries=$1; shift ;;
	esac
done

st=$(adb get-state 2>/dev/null || true)
echo "start state=${st:-none}"
[ "$st" = recovery ] || { echo "NOT-IN-TWRP: bring the phone back to TWRP first"; exit 1; }
[ -s "$BOOT" ] || { echo "NO-BOOT-IMAGE $BOOT"; exit 1; }

n=$(adb shell 'cat /cache/land-attempts 2>/dev/null' | tr -dc '0-9')
echo "attempts before this boot: ${n:-none}"

adb push "$(cygpath -w "$BOOT")" /tmp/land-eos-boot.img >/dev/null ||
	{ echo "PUSH-FAILED"; exit 1; }
adb shell 'dd if=/tmp/land-eos-boot.img of=/dev/block/by-name/boot bs=8388608;
	rm -f /tmp/land-eos-boot.img; sync;
	dd if=/dev/block/by-name/boot bs=8 count=1 2>/dev/null | od -An -c -N8' | tr -d '\r'

# TWRP's adbd answers a plain "adb reboot" by coming back to recovery, so the boot
# partition never runs.  Going through the bootloader and letting it reboot normally
# is what actually starts the image just written.
echo "rebooting into the probe through the bootloader"
adb reboot bootloader
i=0
until fastboot devices 2>/dev/null | grep -q .; do
	i=$((i + 1))
	[ "$i" -gt 30 ] && { echo "NO-FASTBOOT after 150s"; exit 1; }
	sleep 5
done
echo "in fastboot after $((i * 5))s"
fastboot reboot 2>&1 | tail -2

back=none
for i in $(seq 1 "$tries"); do
	st=$(adb get-state 2>/dev/null || true)
	[ "$st" = recovery ] && { back=recovery; break; }
	sleep 5
done
echo "after $((i * 5))s state=$back"
[ "$back" = recovery ] || { echo "NO-HANDBACK the probe did not bring the phone back"; exit 1; }

if [ "$keep" = 1 ]; then
	echo "BOOT-KEPT: leaving the TWRP copy in boot"
fi

N=$(adb shell 'cat /cache/land-attempts 2>/dev/null' | tr -dc '0-9')
echo "attempts file now: ${N:-none}"
[ -n "${N:-}" ] || { echo "NO-JOURNAL the probe never ran"; exit 1; }
j=$W/journal-$N.txt
adb shell "cat /cache/land-boot-$N.log" | tr -d '\r' >"$j"
echo "journal $j ($(grep -c '' "$j") lines)"
grep -E '^CODE=|^uname|^cmdline|^magic|^fs:|^os-release|^packages' "$j"
# If the root took over as pid 1, its own report is in the raw journal one record
# past everything the probe writes.
adb shell 'dd if=/dev/block/mmcblk0p33 bs=512 skip=200 count=1 2>/dev/null | tr -d "\000"' |
	tr -d '\r' | sed 's/^/init-record: /'
echo "--- dmesg tail ---"
grep -nE 'ERROR|error|panic|Call trace|EXT4-fs|mmc|fbcon|Console' "$j" | tail -14
