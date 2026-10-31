#!/bin/bash
# Regression test: run the phone's boot probe off the phone.
#
# Every fix to the probe used to cost a flash, a reboot and a wait for the device to
# come back, and the probe can only be judged by running it: the last three bugs
# (dangling /sbin symlinks, /tmp not being a directory, the cache partition being
# f2fs) were all invisible until something actually executed the script.  So this
# runs the same /init, against the same ext4 image that sits on the phone's userdata,
# under qemu-system-aarch64, and asserts on what it reports.
#
# The verdict is read back through the dip journal image, which is the same channel
# the probe uses on the phone, so the test exercises the reporting path too.
#
# usage: test_qemu_probe.sh [path-to-eos-rootfs.img]
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
W=/cygdrive/g/xnu-land
D=$W/work
PY=/cygdrive/c/Users/Egorka/AppData/Local/Programs/Python/Python312/python.exe
QEMU=/cygdrive/g/msys64/clang64/bin/qemu-system-aarch64.exe
KERNEL=$D/apk/boot/vmlinuz-virt
# qemu here is a Windows binary, so every path handed to it has to be a
# Windows path: a /cygdrive/... string exits with rc=1 before the guest starts.
IMG=${1:-$D/../eos_41179507696/eos-rootfs.img}
fails=0

note() { echo "$*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
good() { echo "PASS $*"; }

# A deadline that actually works, and a wait that actually ends.  `timeout N qemu.exe`
# kills the bash job and leaves the Windows process running, so a guest that reached
# its targets and simply stayed there hung the whole suite forever.  Feeding Ctrl-A x
# to the -nographic monitor makes qemu quit by itself, but then the shell has to wait
# for its own sleeper before the pipeline closes, which would make every scenario cost
# its full deadline even when the guest powered off in a minute.  runqemu.ps1 starts the
# process, waits on it and kills it at the deadline, and reads its arguments from a file
# because quoting them through a PowerShell -Command string lost the child exit code.
runqemu() { # runqemu <seconds> <logfile> <qemu args...>
	local secs=$1 log=$2
	shift 2
	local a rc
	: >"$D/$log.args"
	for a in "$@"; do
		printf '%s\n' "$a" >>"$D/$log.args"
	done
	powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$D/runqemu.ps1")" \
		-Exe "$(cygpath -w "$QEMU")" -ArgsFile "$(cygpath -w "$D/$log.args")" \
		-Ms "$((secs * 1000))" >"$D/$log" 2>&1
	rc=$?
	rm -f "$D/$log.args"
	return "$rc"
}

[ -x "$QEMU" ] || { echo "NO-QEMU $QEMU"; exit 2; }
[ -f "$KERNEL" ] || { echo "NO-KERNEL $KERNEL: unpack linux-virt.apk into work/apk first"; exit 2; }
IMG=$(cygpath -w "$IMG")
KERNEL=$(cygpath -w "$KERNEL")
[ -f "$(cygpath -u "$IMG")" ] || { echo "NO-IMG $IMG"; exit 2; }

cd "$D" || exit 2
note "building the images"
"$PY" ../mkinitrd.py ../initrd.cpio.gz >/dev/null || { echo "mkinitrd failed"; exit 2; }
"$PY" ../check_initrd.py ../initrd.cpio.gz | tail -1
"$PY" ../mkbootimg.py --base-boot "G:/land-shim/stock/los18-boot.img" \
	--ramdisk ../initrd.cpio.gz \
	--cmdline "console=tty0 fbcon=map:1 keep_bootcon loglevel=8 root=/dev/mmcblk0p49 rw rootwait androidboot.hardware=qcom androidboot.dtbo_idx=0" \
	--out ../land-eos-boot.img >/dev/null || { echo "mkbootimg failed"; exit 2; }
"$PY" mkqemu_initrd.py qemu-initrd.cpio.gz >/dev/null || { echo "mkqemu_initrd failed"; exit 2; }
"$PY" ../check_initrd.py qemu-initrd.cpio.gz | tail -1

rm -f dip.bin qemu-console.log cache.img
dd if=/dev/zero of=dip.bin bs=1M count=1 2>/dev/null
dd if=/dev/zero of=cache.img bs=1M count=64 2>/dev/null
"/cygdrive/c/Program Files/platform-tools/mke2fs.exe" -F -q -L landcache cache.img 2>/dev/null

note "booting the probe under qemu"
runqemu 600 qemu-console.log -machine virt -cpu cortex-a57 -smp 2 -m 2048 -nographic -no-reboot \
	-kernel "$KERNEL" -initrd qemu-initrd.cpio.gz \
	-append "console=ttyAMA0 landroot=/dev/vda landcache=/dev/vdb landjournal=/dev/vdc landnoreboot" \
	-drive file="$IMG",if=virtio,snapshot=on \
	-drive file=cache.img,if=virtio \
	-drive file=dip.bin,if=virtio
rc=$?
[ "$rc" = 0 ] || [ "$rc" = 124 ] || bad "qemu exited $rc"
grep -q "reboot: Power down" qemu-console.log && good "probe reached the end and powered off" ||
	bad "probe never powered off (rc=$rc)"

# Read the verdict back the same way the phone is read: the dip journal image.
"$PY" - dip.bin <<'PY'
import re
import sys
d = open('dip.bin', 'rb').read()
txt = d[1024:].split(b'\0')[0].decode('utf8', 'replace')
lines = txt.splitlines()
code = [l for l in lines if l.startswith('CODE=')]
pkgs = [l for l in lines if l.startswith('packages:')]
osr = [l for l in lines if l.startswith('os-release:')]
err = [l for l in lines if l.startswith('chroot error:')]
print('dip journal %d bytes, %s' % (len(txt), code[-1] if code else 'NO CODE LINE'))
for l in pkgs + osr:
    print('  ', l)
if err and err[0].strip() != 'chroot error:':
    print('  !', err[0])
sys.exit(0 if code and 'EOS-ROOT-OK' in code[-1] else 1)
PY
[ $? = 0 ] && good "dip journal says the EndeavourOS root is usable" ||
	bad "dip journal did not report EOS-ROOT-OK"

grep -q ": not found" qemu-console.log && bad "a command was missing during the boot" ||
	good "every applet the probe used existed"
grep -q "EndeavourOS ARM" qemu-console.log && good "os-release read from the real root" ||
	bad "os-release never appeared"

echo "TEST-QEMU-PROBE $([ $fails = 0 ] && echo OK || echo "FAILS=$fails")"

# Second scenario: the same root, but with a network, and asked to prove it is still
# a package manager.  qemu's user mode networking gives the guest DNS and egress
# through 10.0.2.3, so this really reaches the Arch and EndeavourOS mirrors.
note "booting again with a network for the package test"
rm -f dip.bin cache.img
dd if=/dev/zero of=dip.bin bs=1M count=1 2>/dev/null
dd if=/dev/zero of=cache.img bs=1M count=64 2>/dev/null
"/cygdrive/c/Program Files/platform-tools/mke2fs.exe" -F -q -L landcache cache.img 2>/dev/null
runqemu 1300 qemu-pkgtest.log -machine virt -cpu cortex-a57 -smp 2 -m 2048 -nographic -no-reboot \
	-kernel "$KERNEL" -initrd qemu-initrd.cpio.gz \
	-append "console=ttyAMA0 landroot=/dev/vda landcache=/dev/vdb landjournal=/dev/vdc landnoreboot landpkgtest" \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	-drive file="$IMG",if=virtio,snapshot=on \
	-drive file=cache.img,if=virtio \
	-drive file=dip.bin,if=virtio
rc=$?
[ "$rc" = 0 ] || [ "$rc" = 124 ] || bad "pkg test qemu exited $rc"

"$PY" - dip.bin <<'PY'
import sys
d = open('dip.bin', 'rb').read()
txt = d[1024:].split(b'\0')[0].decode('utf8', 'replace')
lines = txt.splitlines()
body = '\n'.join(lines)
if 'package test' not in body:
    print('NO package test section in the journal')
    sys.exit(1)
start = body.index('package test')
seg = body[start:]
required = [(':: Synchronizing', 'repository sync'),
            ('Packages (1) tree', 'package resolution and signature acceptance')]
optional = [('tree-version: tree v', 'the installed binary runs')]
for probe, what in required + optional:
    if probe in seg:
        print('PASS %s reached the journal' % what)
    elif (probe, what) in optional:
        # The mirror is reached through qemu's user mode networking under full
        # emulation, so whether a 40 KiB download lands inside the scenario window
        # is a property of that link, not of the root.
        print('NOTE %s did not finish this run' % what)
missing = [what for probe, what in required if probe not in seg]
if missing:
    print('FAIL no %s in the journal' % ', '.join(missing))
    print('   --- captured ---')
    print('\n'.join(seg.splitlines()[:26]))
sys.exit(1 if missing else 0)
PY
if [ $? = 0 ]; then
	good "EndeavourOS inside the root reached its mirrors and resolved a package"
else
	bad "package test did not complete"
fi
grep -qE "signature|Key .* could not be looked up|invalid or corrupt" qemu-pkgtest.log &&
	bad "a signature problem showed up" || good "no signature problems during the install"

# Third scenario: hand the root over to systemd.  On the phone this is the open
# question (4.19 against systemd 25x), but the mechanics of it, moving /dev /proc
# /sys into the new root, mounting cgroup and executing switch_root, can be checked
# here, and a failure that shows up in qemu never has to cost a phone boot.
note "booting again with the systemd handoff"
rm -f dip.bin cache.img
dd if=/dev/zero of=dip.bin bs=1M count=1 2>/dev/null
dd if=/dev/zero of=cache.img bs=1M count=64 2>/dev/null
"/cygdrive/c/Program Files/platform-tools/mke2fs.exe" -F -q -L landcache cache.img 2>/dev/null
runqemu 240 qemu-systemd.log -machine virt -cpu cortex-a57 -smp 2 -m 2048 -nographic -no-reboot \
	-kernel "$KERNEL" -initrd qemu-initrd.cpio.gz \
	-append "console=ttyAMA0 landroot=/dev/vda landcache=/dev/vdb landjournal=/dev/vdc landsystemd" \
	-netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
	-drive file="$IMG",if=virtio,snapshot=on \
	-drive file=cache.img,if=virtio \
	-drive file=dip.bin,if=virtio

grep -q "handing the phone to systemd" qemu-systemd.log &&
	good "the probe handed the root over" || bad "the probe never handed over"
grep -qE "systemd\[1\]: (Detected|Early|Mounting|Reached|Startup|target|Graphical)" qemu-systemd.log &&
	good "systemd became pid 1 and started doing work" ||
	bad "systemd did not come up"
grep -qE "Reached target|Startup is finished|Default target" qemu-systemd.log &&
	good "systemd reached its targets" ||
	note "no target line in the captured window"
grep -qE "Failed to mount /sys/fs/cgroup|cgroup.*not supported" qemu-systemd.log &&
	bad "cgroup handoff failed" || good "cgroup mounted for systemd"

# init, which is what the phone's kernel can actually run as pid 1.
note "booting again with the root's own init"
rm -f dip.bin cache.img
dd if=/dev/zero of=dip.bin bs=1M count=1 2>/dev/null
dd if=/dev/zero of=cache.img bs=1M count=64 2>/dev/null
"/cygdrive/c/Program Files/platform-tools/mke2fs.exe" -F -q -L landcache cache.img 2>/dev/null
runqemu 240 qemu-init.log -machine virt -cpu cortex-a57 -smp 2 -m 2048 -nographic -no-reboot \
	-kernel "$KERNEL" -initrd qemu-initrd.cpio.gz \
	-append "console=ttyAMA0 landroot=/dev/vda landcache=/dev/vdb landjournal=/dev/vdc landinit" \
	-device virtio-gpu-pci \
	-drive file="$IMG",if=virtio,snapshot=on \
	-drive file=cache.img,if=virtio \
	-drive file=dip.bin,if=virtio
if grep -q "LANDINIT" qemu-init.log; then
	good "landinit.sh became pid 1 and reported itself"
	grep -E "LANDINIT" qemu-init.log | head -3 | sed 's/^/  /'
elif grep -q "handing the phone to the root's own init" qemu-init.log; then
	bad "the probe tried the handover but landinit never spoke"
else
	note "no landinit.sh in this root yet: rebuild it with the pack.sh that ships one"
fi
# The phone has no console to read afterwards, so what matters is that the root's
# init reached the raw journal on its own, without the initramfs still around.
"$PY" - dip.bin <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
rec = d[200 * 512:200 * 512 + 512].split(b'\0')[0].decode('utf8', 'replace')
if not rec.startswith('LANDINIT up'):
	print('FAIL no landinit journal record (got %r)' % rec[:60])
	sys.exit(1)
print('PASS the root reported to the journal by itself: %s' % rec)
sys.exit(0 if 'panel=ok' in rec else 2)
PY
rc=$?
[ $rc = 0 ] && good "the root painted its own status onto a real framebuffer"
[ $rc = 2 ] && { bad "landinit ran but the panel did not take the drawing"; fails=$((fails + 1)); }
[ $rc = 1 ] && fails=$((fails + 1))

# The one guard that keeps a broken userdata from rebooting the phone forever is read
# out of the raw journal, so it can be tested by writing the journal by hand: a start
# record with no matching handback is exactly what a hung boot leaves behind.
note "booting again with a hung attempt already in the journal"
rm -f dip.bin cache.img
dd if=/dev/zero of=dip.bin bs=1M count=1 2>/dev/null
dd if=/dev/zero of=cache.img bs=1M count=64 2>/dev/null
"/cygdrive/c/Program Files/platform-tools/mke2fs.exe" -F -q -L landcache cache.img 2>/dev/null
printf 'LANDPROBE-START n=3 cache=none nodes=vda vdb vdc\n' >work-rec5
dd if=work-rec5 of=dip.bin bs=512 count=1 seek=5 conv=notrunc 2>/dev/null
rm -f work-rec5
runqemu 240 qemu-stuck.log -machine virt -cpu cortex-a57 -smp 2 -m 2048 -nographic -no-reboot \
	-kernel "$KERNEL" -initrd qemu-initrd.cpio.gz \
	-append "console=ttyAMA0 landroot=/dev/vda landcache=/dev/vdb landjournal=/dev/vdc" \
	-drive file="$IMG",if=virtio,snapshot=on \
	-drive file=cache.img,if=virtio \
	-drive file=dip.bin,if=virtio
grep -q "never reached its handback, refusing to reboot again" qemu-stuck.log &&
	good "the journal guard noticed the hung attempt" ||
	bad "the guard did not read the journal: a hung board would reboot forever"
grep -qE "powering off for a human|reboot: Power down" qemu-stuck.log &&
	good "a stuck board powers off instead of looping" ||
	bad "the stuck path did not power off"
grep -q "handing the phone" qemu-stuck.log &&
	bad "a stuck probe still tried a handover" || good "a stuck probe never handed over"
echo "TEST-QEMU-PROBE $([ $fails = 0 ] && echo ALL-OK || echo "FAILS=$fails")"
exit "$fails"
