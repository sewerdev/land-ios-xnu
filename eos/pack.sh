# Assemble an EndeavourOS root for land (Redmi 3S) inside the Arch Linux ARM
# arm64 container.  Runs as root in the container: /work/rootfs is the host's
# runner temp, /work/eos is this directory mounted read-only.
#
# No kernel is built or installed here on purpose.  The phone boots the
# 4.19.325-Mi8937v2 Image that already ships inside the LineageOS 18 boot image,
# with the cmdline that mkbootcmd.py writes into that image:
#
#   root=/dev/mmcblk0p49 rw init=/bin/sh console=tty0 fbcon=map:1
#
# which is why the device kernel pacstrap would otherwise pull in gets dropped
# again below.
set -euo pipefail

ROOT=/work/rootfs

# The runner creates this directory as uid 1001 and the container installs into
# it as root, which makes every path under it "owned by 1001" to systemd's
# canonicalizer and leaves the tree unreadable to the unprivileged du that runs
# after this script.
mkdir -p "$ROOT"
chown 0:0 "$ROOT"
chmod 755 "$ROOT"

# pacman --root changes where packages land but not which config file is read:
# without --config it keeps using the container's own /etc/pacman.conf, so a
# repository appended to the root's copy is simply not there when it
# synchronizes.  That is exactly what happened on the last run, where the sync
# listed core, extra, alarm and aur and then every EndeavourOS package came back
# "target not found".
pm() {
  pacman -r "$ROOT" --config "$ROOT/etc/pacman.conf" "$@"
}

# The whole EndeavourOS ARM repository, package files and .db included, is
# served from this tree.  mirror.endeavouros.info does not resolve and the tree
# has no endeavouros.db.sig, so the tree URL is the server and the repository
# cannot ask for a required database signature.
EOSREPO=${EOSREPO:-https://raw.githubusercontent.com/endeavouros-team/repo/master/endeavouros/aarch64}

# Landlock is what actually stops pacman here, twice over, and it is not a
# Docker seccomp problem: qemu-user does not implement the landlock syscalls, so
# pacman inside the arm64 container sees "Landlock is not supported by the
# kernel" on the very first transaction.  The same is true on the phone, whose
# 4.19 kernel predates Landlock (5.13) entirely, so the option goes into the
# config of both the container and the root and stays there.  It is written into
# /etc/pacman.conf rather than passed as --disable-sandbox because pacstrap
# parses its own argv with getopts and dies on an unknown long option: the run
# before this one ended with "pacstrap: invalid option -- 'd'".
for conf in /etc/pacman.conf; do
  grep -q '^DisableSandbox' "$conf" || sed -i '/^\[options\]/a DisableSandbox' "$conf"
done

# The imported tarball has no initialised keyring, so this comes before the
# first transaction that has to verify a signature.
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Sy --noconfirm arch-install-scripts >/dev/null

# -K initializes the target's package database and copies the host keyring in,
# -c keeps the downloaded packages in the target cache so the on-device pacman
# has something to work from.  base is bash, coreutils, filesystem, pacman,
# systemd, util-linux.
pacstrap -Kc "$ROOT" base
grep -q '^DisableSandbox' "$ROOT/etc/pacman.conf" ||
  sed -i '/^\[options\]/a DisableSandbox' "$ROOT/etc/pacman.conf"

# The ALARM image kernel is for a different board and the LOS boot image already
# carries the kernel that will actually run, so a kernel in the root would only
# be a claim about something that is not there.
for k in linux linux-aarch64 linux-ck linux-eos-arm; do
  pm -Rns --noconfirm "$k" >/dev/null 2>&1 || true
done

if [ "${EOS:-0}" = 1 ]; then
  # The EndeavourOS layer proper.  Backed up before touching pacman.conf: a
  # repository line that nothing answers makes every later transaction fail,
  # because -S synchronizes all repositories at once.
  cp "$ROOT/etc/pacman.conf" /tmp/pacman.conf.orig
  printf '\n[endeavouros]\nSigLevel = Optional TrustAll\nServer = %s\n' "$EOSREPO" \
    >> "$ROOT/etc/pacman.conf"
  pm -Sy --noconfirm
  # One package per transaction, in dependency order.  A single -S of the whole
  # list is all-or-nothing, and eos-base and eos-settings do not exist for
  # aarch64 at all, so that command would fail and take the layer with it.
  rc=0
  for p in endeavouros-keyring endeavouros-mirrorlist endeavouros-branding \
           eos-bash-shared eos-apps-info eos-log-tool eos-rankmirrors \
           eos-update eos-reboot-recommended yay paru; do
    if pm -S --noconfirm "$p"; then
      echo "eos layer: $p ok"
    else
      echo "eos layer: $p failed"
      rc=1
    fi
  done
  if [ "$rc" != 0 ]; then
    echo "endeavouros layer incomplete, keeping what landed"
  fi
  if [ -f "$ROOT/usr/share/pacman/keyrings/endeavouros.gpg" ]; then
    # Trust the EndeavourOS signing key inside the root, so a pacman run on the
    # phone verifies these packages instead of being told to trust everything.
    arch-chroot "$ROOT" pacman-key --populate endeavouros ||
      echo "could not populate the endeavouros keyring in the root"
    sed -i '/^\[endeavouros\]/,/^\[/{s/^SigLevel = .*/SigLevel = Optional/}' \
      "$ROOT/etc/pacman.conf"
    # Nothing in the aarch64 repository provides /etc/os-release: on x86_64 that
    # is eos-base, and eos-base was never built for arm.  A root that came out of
    # this build with the EndeavourOS repository, keyring and tooling in it should
    # say so, and the boot probe reads this file to report what it found.
    cat >"$ROOT/etc/os-release" <<'OSR'
NAME="EndeavourOS ARM"
VERSION="rolling"
ID=endeavouros
ID_LIKE="arch arm"
PRETTY_NAME="EndeavourOS ARM (land)"
HOME_URL="https://endeavouros.com"
SUPPORT_URL="https://forum.endeavouros.com"
BUG_REPORT_URL="https://github.com/endeavouros-team/repo/issues"
ARCH_DIST_INFO=rolling
OSR
    ln -sf ../usr/share/endeavouros/endeavouros-logo.svg \
      "$ROOT/usr/share/pixmaps/endeavouros-logo.svg" 2>/dev/null || true
  fi
fi

# What a distro without these is not worth booting for on a phone that has no
# keyboard, no serial and no VT: busybox for mdev and the applets an init needs,
# openssh in case USB networking ever comes up, an editor, a viewer, git for the
# AUR helpers, and e2fsprogs because resize2fs has to be runnable from inside the
# root and not only from TWRP.
EXTRA=${EXTRA:-busybox openssh vim htop git e2fsprogs}
for x in $EXTRA; do
  if pm -S --noconfirm "$x"; then
    echo "extra: $x ok"
  else
    echo "extra: $x failed"
  fi
done

# PID 1 for this root on land's stock kernel.  That kernel has no CONFIG_FHANDLE,
# no cgroup device or pids controller, no POSIX mqueue and no autofs, and systemd
# refuses to run without name_to_handle_at, so on this board systemd can be
# installed and used for its tools but it cannot be init.  This script is what the
# boot probe hands the phone over to instead.
#
# It also has to leave a way back.  Nothing here can be typed into, and if the
# phone simply stayed up there would be no way to reach it without a button, so a
# watchdog returns it to recovery after a quarter of an hour unless
# /root/land-stay says the boot is being driven over adb.
cat >"$ROOT/landinit.sh" <<'LANDINIT'
#!/bin/sh
PATH=/usr/bin:/usr/sbin:/bin:/sbin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
mount -t tmpfs shm /dev/shm 2>/dev/null
[ -e /dev/console ] || mknod /dev/console c 5 1 2>/dev/null
. /etc/os-release 2>/dev/null
echo "LANDINIT ${PRETTY_NAME:-EndeavourOS} up, kernel $(uname -r)" >/dev/console 2>&1
echo "LANDINIT packages: $(pacman -Q 2>/dev/null | wc -l)" >/dev/console 2>&1
if [ -e /root/land-stay ]; then
	echo "LANDINIT /root/land-stay present, no automatic return to recovery" >/dev/console 2>&1
else
	(
		sleep 900
		echo recovery >/sys/reboot/cmd 2>/dev/null
		reboot -f
	) &
	echo "LANDINIT returning to recovery in 15 minutes" >/dev/console 2>&1
fi
while :; do
	/bin/sh </dev/console >/dev/console 2>&1
	sleep 5
done
LANDINIT
chmod 755 "$ROOT/landinit.sh"

if [ "${DESKTOP:-0}" = 1 ]; then
  # There is no Adreno 308 driver anywhere, so the desktop is X over fbdev plus
  # llvmpipe, on the same framebuffer the kernel console already uses.
  pm -S --noconfirm xorg-server xorg-xinit xf86-video-fbdev mesa \
    xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
  systemctl --root "$ROOT" enable lightdm
fi

# A bench phone with no keyboard: an empty root password and autologin on tty1
# are the difference between a session and a brick, and are not a security
# boundary in any case.
# alpm determines free space by reading mount points, and it looks at /etc/mtab
# first; the filesystem package does not create that link, so a pacman transaction
# started inside this root fails before it downloads anything.
ln -sfn /proc/mounts "$ROOT/etc/mtab"

sed -i 's/^root:[^:]*/root::/' "$ROOT/etc/shadow"
mkdir -p "$ROOT/etc/systemd/system/getty@tty1.service.d" \
         "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/run" "$ROOT/tmp"
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear tty1 linux\n' \
  > "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"

# systemd 25x assumes a newer kernel than 4.19 in a few places, so the first
# boot uses init=/bin/sh.  If systemd refuses to start, the answer is an older
# init, not a newer kernel.
echo "root built: $(du -sh "$ROOT" | cut -f1)"
echo "eos packages in the root:"
pm -Q | grep -iE 'endeavouros|^eos|^yay|^paru' || echo "  none"
ls "$ROOT"
