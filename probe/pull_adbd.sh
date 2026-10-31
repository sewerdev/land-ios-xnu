#!/bin/bash
# Copy adbd and the libraries it needs out of the Android system partition.
#
# The LineageOS 18 kernel for land has CONFIG_USB_CONFIGFS=y and CONFIG_USB_F_FS=y
# (functionfs) built in, which is what Android's adb uses: the kernel exposes an
# empty function and adbd supplies the descriptors and the endpoint traffic.  So a
# boot of our own can carry adb, but only if it carries the adbd binary and the
# shared libraries it links against, and those live in /system on the phone.  TWRP
# mounts p24 for us, so this is a one-time copy while the phone is in recovery.
#
# What lands in G:\xnu-land\adbd\ gets packed into the initramfs by mkinitrd.py, so
# the probe can bring up the gadget itself and the phone becomes reachable over adb
# with nobody near the buttons.
#
# usage: pull_adbd.sh
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
W=/cygdrive/g/xnu-land
D=$W/adbd
NM=/cygdrive/g/Android/Sdk/ndk/26.1.10909125/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe

st=$(adb get-state 2>/dev/null || true)
[ "$st" = recovery ] || { echo "NOT-IN-TWRP state=${st:-none}"; exit 1; }
mkdir -p "$D"

# adbd may sit in /system/bin or, on a system-as-root layout, under /system/system.
bin=$(adb shell 'for p in /system/bin/adbd /system/system/bin/adbd; do [ -f "$p" ] && echo $p && break; done' |
	tr -d '\r' | head -1)
[ -n "$bin" ] || { echo "NO-ADBD in the mounted system"; exit 1; }
echo "adbd is $bin"
adb pull "$bin" "$(cygpath -w "$D/adbd")" >/dev/null || { echo "PULL-FAILED"; exit 1; }

# The library list is read out of the ELF rather than guessed: DT_NEEDED gives the
# sonames and PT_INTERP gives the linker, and those are all that has to travel.
interp=$("$NM" -l "$(cygpath -w "$D/adbd")" 2>/dev/null |
	grep -oE "Requesting program interpreter: [^]]+" | sed 's/.*: //')
libs=$("$NM" -d "$(cygpath -w "$D/adbd")" 2>/dev/null |
	grep -oE "Shared library: \[[^]]+\]" | sed 's/.*\[//; s/\]//')
echo "interpreter: ${interp:-none}"
echo "needs: $(echo "$libs" | tr '\n' ' ')"

# Write a device-side script that finds each soname, because a 64-bit Android build
# keeps its libraries under lib64 while the 32-bit ones live under lib, and the
# runtime is sometimes in an APEX.
{
	echo 'for l in '"$(echo "$libs" | tr '\n' ' ')"' '"${interp:-}"'; do'
	echo '  [ -z "$l" ] && continue'
	echo '  n=${l##*/}'
	echo '  for d in /system/lib64 /system/lib /apex/com.android.runtime/lib64 /apex/com.android.runtime/lib /system/system/lib64 /system/system/lib /system/system/apex/com.android.runtime/lib64; do'
	echo '    if [ -f "$d/$n" ]; then echo "$d/$n"; break; fi'
	echo '  done'
	echo 'done'
} >"$D/findlibs.sh"

adb push "$(cygpath -w "$D/findlibs.sh")" /tmp/findlibs.sh >/dev/null
paths=$(adb shell 'sh /tmp/findlibs.sh' | tr -d '\r' | grep '^/')
got=0
miss=0
for p in $paths; do
	f=${p##*/}
	[ -s "$D/$f" ] && { echo "  have $f"; continue; }
	if adb pull "$p" "$(cygpath -w "$D/$f")" >/dev/null 2>&1; then
		echo "  got $f from $p"
		got=$((got + 1))
	else
		echo "  MISS $f ($p)"
		miss=$((miss + 1))
	fi
done
adb shell 'rm -f /tmp/findlibs.sh' >/dev/null

# Anything the linker was asked for that no path produced is a hole in the initramfs
# that would only show up as adbd refusing to start on the phone.
for l in $libs; do
	f=${l##*/}
	[ -s "$D/$f" ] || { echo "  STILL-MISSING $f"; miss=$((miss + 1)); }
done

ls -l "$D" | tail -14
echo "ADBD-PULLED files=$(ls "$D" | wc -l) new=$got missing=$miss"
[ "$miss" = 0 ] || echo "ADBD-INCOMPLETE adbd will not start without the missing pieces"
