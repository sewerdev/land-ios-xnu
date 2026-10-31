#!/bin/bash
# Put the EndeavourOS root built by eos-rootfs.yml onto land's userdata and make
# the phone boot it.
#
# Why the write is split up the way it is:
#   - userdata is mmcblk0p49, 26301931008 bytes, and the packed image is a 6 GiB
#     file.  Only about 1.7 GiB of it holds anything: mkfs.ext4 -d leaves every
#     block it never wrote as a hole, and the free-block count in the superblock
#     is a count, not the highest block number, so imgparts.py scans the image for
#     the regions that actually contain bytes.  The prefix and the few scattered
#     backup-superblock islands are written and the holes are not, then resize2fs,
#     which TWRP ships, grows the filesystem to the whole partition on the phone.
#   - the tmpfs TWRP mounts at /tmp is 1.3 GiB, so nothing larger than 512 MiB is
#     ever staged there: each part is pushed, written and deleted before the next.
#   - gh's own artifact download stalls on multi-gigabyte zips; dl_slices.sh does
#     the same endpoint in sixteen byte ranges at 9 MB/s instead of 0.11.
#
# usage: ship_eos.sh [--run <id>] [--boot] [--yes]
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
GH=/cygdrive/g/qoder-addiction/ghbin/bin/gh.exe
REPO=sewerdev/land-ios-xnu
W=/cygdrive/g/xnu-land
PY=/cygdrive/c/Users/Egorka/AppData/Local/Programs/Python/Python312/python.exe
SER=/dev/block/mmcblk0p49

run=""
boot=0
yes=0
while [ $# -gt 0 ]; do
	case "$1" in
	--run) run=$2; shift 2 ;;
	--boot) boot=1; shift ;;
	--yes) yes=1; shift ;;
	*) echo "unknown argument: $1"; exit 2 ;;
	esac
done

if [ -z "$run" ]; then
	run=$("$GH" run list -R "$REPO" --workflow eos-rootfs.yml --status success \
		--limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)
fi
[ -n "${run:-}" ] || { echo "NO-RUN no successful eos-rootfs run yet"; exit 1; }
echo "run $run"

art=$("$GH" api "repos/$REPO/actions/runs/$run/artifacts" \
	--jq '.artifacts[]|select(.name=="eos-rootfs")|"\(.id) \(.size_in_bytes)"' \
	2>/dev/null | head -1)
set -- $art
aid=${1:-}
asize=${2:-}
[ -n "$aid" ] && [ -n "$asize" ] || { echo "NO-ARTIFACT run $run has no eos-rootfs artifact"; exit 1; }
echo "artifact $aid, $asize bytes compressed"

d=$W/eos_$run
mkdir -p "$d"
zip=$d/eos-rootfs.zip
if [ ! -s "$zip" ] || [ "$(stat -c %s "$zip")" != "$asize" ]; then
	GHA_TOKEN="$("$GH" auth token)" bash "$W/dl_slices.sh" \
		"https://api.github.com/repos/$REPO/actions/artifacts/$aid/zip" \
		"$(cygpath -w "$zip")" "$asize" 16 || { echo "DOWNLOAD-FAILED"; exit 1; }
fi

imggz=$d/eos-rootfs.img.gz
if [ ! -s "$imggz" ]; then
	"$PY" - "$(cygpath -w "$zip")" "$(cygpath -w "$imggz")" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
n = [x for x in z.namelist() if x.endswith('eos-rootfs.img.gz')]
if not n:
    sys.exit('members: %r' % (z.namelist()[:10],))
open(sys.argv[2], 'wb').write(z.read(n[0]))
print('extracted', n[0])
PY
fi
[ -s "$imggz" ] || { echo "NO-IMG-GZ"; exit 1; }

img=$d/eos-rootfs.img
if [ ! -s "$img" ]; then
	gunzip -c "$imggz" >"$img" || { echo "GUNZIP-FAILED"; exit 1; }
fi
echo "image $img $(stat -c %s "$img") bytes"

# ext2/3/4's on-disk magic is 0xEF53, 56 bytes into the superblock, and the
# superblock starts at byte 1024 of the filesystem.
"$PY" - "$(cygpath -w "$img")" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(2048)
m = int.from_bytes(d[1024 + 56:1024 + 58], 'little')
print('ext4 magic %04x label %r' %
      (m, d[1024 + 120:1024 + 136].split(b'\0')[0].decode('latin1')))
sys.exit(0 if m == 0xEF53 else 'not an ext4 superblock')
PY
[ $? = 0 ] || exit 1

plan=$d/plan.txt
[ -s "$plan" ] || "$PY" "$(cygpath -w "$W/imgparts.py")" "$(cygpath -w "$img")" >"$plan" || { echo "NO-PLAN"; exit 1; }
echo "plan:"
cat "$plan"

if [ "$yes" != 1 ]; then
	echo "verified; re-run with --yes to write it to userdata (this replaces whatever is on /data)"
	exit 0
fi

# Raw block writes only happen with userdata unmounted, which is recovery.
st=$(adb get-state 2>/dev/null || true)
[ "$st" = recovery ] || { echo "NOT-IN-TWRP state=${st:-none}"; exit 1; }

# TWRP mounts userdata as /data on its own once it can read it, and writing an
# image over a mounted filesystem corrupts the live one instead of replacing it:
# the run before this check wrote the root under a mounted /data, e2fsck then said
# "cannot continue, aborting", resize2fs resized it online and df reported 16E used.
# So nothing is written until the partition is demonstrably not mounted anywhere.
mounted=$(adb shell 'mount | grep -c mmcblk0p49' | tr -dc '0-9')
if [ "${mounted:-0}" != 0 ]; then
	echo "userdata is mounted $mounted time(s), unmounting"
	adb shell 'umount /data 2>/dev/null; umount /mnt/vendor/userdata 2>/dev/null;
		umount /dev/block/mmcblk0p49 2>/dev/null; umount /chk 2>/dev/null' >/dev/null
	mounted=$(adb shell 'mount | grep -c mmcblk0p49' | tr -dc '0-9')
	[ "${mounted:-0}" = 0 ] || { echo "USERDATA-BUSY still mounted, refusing to write"; exit 1; }
fi
echo "userdata unmounted, writing"

# splitrange <from-mib> <to-mib> <stem>: cut the range into 512 MiB parts
splitrange() {
	"$PY" - "$(cygpath -w "$img")" "$1" "$2" "$(cygpath -w "$3")" <<'PY'
import sys
img, a, b, base = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4])
f = open(img, 'rb')
f.seek(a * 1024 * 1024)
left = (b - a) * 1024 * 1024
i = 0
while left > 0:
    with open('%s.%03d' % (base, i), 'wb') as dst:
        n = min(512 * 1024 * 1024, left)
        w = 0
        while w < n:
            c = f.read(min(1 << 20, n - w))
            if not c:
                break
            dst.write(c)
            w += len(c)
    left -= w
    i += 1
print('  split into %d part(s)' % i)
PY
}

# writediv <local-stem> <offset-mib>: push each <stem>.NNN part, write it at
# offset + 512*index, then drop both copies so /tmp never holds more than one.
writediv() {
	local f=$1 off=$2 n=0 p
	for p in $(ls "$f".* 2>/dev/null); do
		echo "  push $(basename "$p") $(stat -c %s "$p") bytes to ${off}+${n} MiB"
		adb push "$(cygpath -w "$p")" /tmp/part.img >/dev/null ||
			{ echo "PUSH-FAILED $p"; return 1; }
		adb shell "dd if=/tmp/part.img of=$SER bs=1M seek=$((off + n)) conv=notrunc; rm -f /tmp/part.img" 2>&1 |
			tr -d '\r' | tail -1
		rm -f "$p"
		n=$((n + 512))
	done
	adb shell sync
	return 0
}

prefix_mib=$(awk '/^PREFIX/{print int($2/1048576)}' "$plan")
echo "writing the first ${prefix_mib} MiB"
splitrange 0 "$prefix_mib" "$d/pre" || exit 1
writediv "$d/pre" 0 || exit 1

# The backup superblocks and group descriptors mkfs wrote into later block
# groups.  A few MiB each, and without them the filesystem on the phone is not
# the filesystem mkfs made.
while read -r _ off_mib len_mib; do
	echo "writing island at ${off_mib} MiB (${len_mib} MiB)"
	splitrange "$off_mib" "$((off_mib + len_mib))" "$d/one" || exit 1
	writediv "$d/one" "$off_mib" || exit 1
done < <(awk '/^EXTRA/{print $1, int($2/1048576), int($3/1048576)}' "$plan")

# The journal is the one part of a freshly packed image that a scan for nonzero
# bytes cannot find: mkfs writes its superblock and leaves the other 16383 blocks
# zero, which is a hole in the file and whatever the phone had there before.  The
# kernel then refuses the mount with EINVAL and resize2fs refuses to run, so
# e2fsck has to recreate it before anything else is tried.
echo "checking the filesystem on the phone"
adb shell 'mkdir -p /chk; umount /chk 2>/dev/null;
	mount -t ext4 -o ro,noload /dev/block/mmcblk0p49 /chk && echo MOUNT-NOLOAD-OK || echo MOUNT-BAD;
	ls /chk | tr "\n" " "; echo; head -3 /chk/etc/os-release 2>/dev/null;
	umount /chk 2>/dev/null' | tr -d '\r'

echo "repairing the journal and growing to the whole partition"
adb shell 'e2fsck -f -p /dev/block/mmcblk0p49 2>&1 | tail -4;
	e2fsck -f -p /dev/block/mmcblk0p49 2>&1 | tail -2;
	resize2fs /dev/block/mmcblk0p49 2>&1 | tail -2;
	mount -t ext4 /dev/block/mmcblk0p49 /chk && echo MOUNT-RW-OK;
	df -h /chk | tail -1; umount /chk' | tr -d '\r'

if [ "$boot" = 1 ]; then
	echo "writing the probe boot image"
	adb push "$(cygpath -w "$W/land-eos-boot.img")" /tmp/land-eos-boot.img >/dev/null ||
		{ echo "BOOT-PUSH-FAILED"; exit 1; }
	adb shell "dd if=/tmp/land-eos-boot.img of=/dev/block/by-name/boot bs=1M; rm -f /tmp/land-eos-boot.img; sync" 2>&1 |
		tr -d '\r' | tail -2
	echo "BOOT-FLASHED"
fi
echo "SHIP-DONE"
