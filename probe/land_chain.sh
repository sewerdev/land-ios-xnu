#!/bin/bash
# Everything that has to happen the moment the phone is back in TWRP, without
# anyone being asked twice.
#
# Order matters.  The recovery partition is read first because its kernel is the
# one with VT, fbcon and devtmpfs, which the boot probe needs to be worth anything
# on the panel.  Then one probe cycle runs: the boot image goes in, the phone boots
# it, journals to /cache and hands itself back.  Then the chroot smoke test runs,
# because that already answers whether EndeavourOS works on this hardware even
# while the native boot is still being fixed.
#
# usage: land_chain.sh [tries]
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
W=/cygdrive/g/xnu-land
tries=${1:-360}
LOCK=$W/.chain.lock

say() { echo "$(date +%H:%M:%S) $*" | tee -a "$W/chain.log"; }

# One chain at a time: a second runner would write the boot partition while the
# first one is still rebooting off it.
mkdir -p "$LOCK"
if [ -f "$LOCK/owner" ]; then
	stamp=$(cat "$LOCK/owner" 2>/dev/null)
	when=$(echo "$stamp" | awk '{print $2}')
	case "$when" in
	'' | *[!0-9]*) when=0 ;;
	esac
	if [ $(( $(date +%s) - when )) -lt 2400 ]; then
		say "chain already owned by '$stamp', standing down"
		exit 0
	fi
	say "taking over a lock left $(( ($(date +%s) - when) / 60 )) minutes ago"
fi
echo "$(cat /proc/$$/winpid 2>/dev/null || echo 0) $(date +%s)" >"$LOCK/owner"

st=none
for i in $(seq 1 "$tries"); do
	st=$(adb get-state 2>/dev/null || true)
	[ "$st" = recovery ] && break
	sleep 5
done
if [ "$st" != recovery ]; then
	say "no TWRP after $((i * 5))s, chain not run"
	rm -f "$LOCK/owner"
	exit 1
fi
say "TWRP is up after $((i * 5))s"

say "step 1: newest EndeavourOS root onto userdata"
bash "$W/ship_eos.sh" --yes --boot 2>&1 | tee -a "$W/chain.log" | tail -25

say "step 2: recovery partition"
bash "$W/pullrecovery.sh" 2>&1 | tee -a "$W/chain.log" | tail -4

say "step 3: probe cycle"
bash "$W/probe_cycle.sh" 60 2>&1 | tee -a "$W/chain.log" | tail -30

say "step 4: chroot smoke test"
bash "$W/eos_chroot.sh" -n 2>&1 | tee -a "$W/chain.log" | tail -40

# The last step is the one that answers the actual question: does EndeavourOS run as
# pid 1 on this phone.  It is switched on with a file on /cache, so nothing has to be
# reflashed to try it and nothing has to be reflashed to undo it.  The probe then
# hands over and the root's own init returns the phone to recovery on its own after
# fifteen minutes, so the wait below is that long plus the boot itself.
say "step 5: native boot through the root's own init"
adb shell 'mkdir -p /cache; echo native > /cache/land-init-boot; sync;
	ls -l /cache/land-init-boot' | tr -d '\r'
bash "$W/probe_cycle.sh" 240 2>&1 | tee -a "$W/chain.log" | tail -20
adb shell 'rm -f /cache/land-init-boot; sync' 2>&1 | tr -d '\r'

rm -f "$LOCK/owner"
say "CHAIN-DONE"
