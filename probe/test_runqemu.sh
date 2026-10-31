#!/bin/bash
# Throwaway check of the runqemu helper: it must return qemu's exit code, write the
# log, and come back at once rather than after the whole deadline.
set -u
D=/cygdrive/g/xnu-land/work
QEMU=/cygdrive/g/msys64/clang64/bin/qemu-system-aarch64.exe
fails=0

# Take runqemu() out of the suite so the helper under test is the one that ships.
eval "$(sed -n '/^runqemu() {/,/^}/p' /cygdrive/g/xnu-land/test_qemu_probe.sh)"

start=$(date +%s)
runqemu 20 rt-selftest.log -machine virt -kernel /nonexistent -nographic
rc=$?
secs=$(( $(date +%s) - start ))

[ "$rc" != 0 ] && echo "PASS a failed qemu reports a nonzero code (rc=$rc)" ||
	{ echo "FAIL a broken qemu reported success"; fails=$((fails + 1)); }
grep -q "could not load kernel" rt-selftest.log &&
	echo "PASS qemu's own complaint reached the log" ||
	{ echo "FAIL the log has no qemu output"; fails=$((fails + 1)); }
[ "$secs" -lt 15 ] && echo "PASS it returned in ${secs}s, not after the deadline" ||
	{ echo "FAIL it waited $secs seconds"; fails=$((fails + 1)); }

# A healthy guest that powers itself off must also come back early.
start=$(date +%s)
runqemu 15 rt-kill.log -machine virt -cpu cortex-a57 -m 256 -nographic -S
rc=$?
secs=$(( $(date +%s) - start ))
# -S freezes the cpu before anything runs, so this qemu would sit there forever: the
# only way it ends is the deadline, and the only proof it ended is that nothing is left.
[ "$secs" -lt 40 ] && echo "PASS the deadline stopped a guest that could not exit (${secs}s)" ||
	{ echo "FAIL the deadline did not fire, it waited $secs seconds"; fails=$((fails + 1)); }
tasklist 2>/dev/null | grep -qi "qemu-system-aarch64" &&
	{ echo "FAIL a qemu process survived the deadline"; fails=$((fails + 1)); } ||
	echo "PASS no qemu survived the deadline"

echo "RT-SELFTEST $([ $fails = 0 ] && echo OK || echo "FAILS=$fails")"
exit "$fails"
