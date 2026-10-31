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

# --disable-sandbox on every transaction: pacman 6 drops to the alpm user
# through Landlock, and qemu-user does not implement the landlock syscalls, so
# inside an arm64 container on an x86_64 host pacman always sees "Landlock is not
# supported by the kernel" and refuses to run at all.  Docker seccomp settings do
# not matter here, the syscall never reaches the kernel.

ROOT=/work/rootfs
EOSREPO=${EOSREPO:-https://raw.githubusercontent.com/endeavouros-team/repo/master/endeavouros/aarch64}

pacman -Sy --noconfirm --disable-sandbox arch-install-scripts >/dev/null

mkdir -p "$ROOT"
# -K no free-space check, -c no downgrades, -d do not treat the repo's kernel as
# a dependency to satisfy.  base is bash, coreutils, filesystem, pacman,
# systemd, util-linux.
pacstrap -Kcd --disable-sandbox "$ROOT" base

# The ALARM image kernel is for a different board and the LOS boot image already
# carries the kernel that will actually run, so a kernel in the root would only
# be a claim about something that is not there.
for k in linux linux-aarch64 linux-ck; do
  pacman -r "$ROOT" -Rns --noconfirm --disable-sandbox "$k" >/dev/null 2>&1 || true
done

if [ "${EOS:-0}" = 1 ]; then
  # The EndeavourOS layer proper: their keyring, their mirrorlist, their
  # branding and tooling.  Backed up before touching pacman.conf, because a
  # [endeavouros] header that no mirror answers makes every later pacman -S fail
  # as well, -S synchronizes all repositories at once.
  cp "$ROOT/etc/pacman.conf" /tmp/pacman.conf.orig
  rc=0
  {
    printf '\n[endeavouros]\nSigLevel = Optional TrustAll\nServer = %s\n' "$EOSREPO" \
      >> "$ROOT/etc/pacman.conf"
    pacman -r "$ROOT" -Sy --noconfirm --disable-sandbox
    # Optional TrustAll, not PackageRequired: the .sig files in that tree are
    # made by the endeavouros key, and pulling the real keyring is the next
    # line, so the very first transaction has to be allowed to go unverified.
    pacman -r "$ROOT" -S --noconfirm --disable-sandbox endeavouros-keyring endeavouros-mirrorlist \
      endeavouros-branding eos-settings eos-base eos-bash-shared || true
    # Now trust the repo the way EndeavourOS does, for the packages installed
    # later on the phone.
    sed -i '/^\[endeavouros\]/,/^\[/{s/^SigLevel = .*/SigLevel = PackageRequired/}' "$ROOT/etc/pacman.conf"
    server=$(printf 'https://mirror.endeavouros.info/endeavouros/repo/endeavouros/$arch')
    sed -i "/^Server = $(printf '%s' "$EOSREPO" | sed 's/[&/\]/\\&/g')/c\\Server = $server" "$ROOT/etc/pacman.conf"
    pacman -r "$ROOT" -Sy --noconfirm --disable-sandbox
  } || rc=$?
  if [ "$rc" != 0 ]; then
    echo "endeavouros layer failed (rc=$rc), keeping the plain Arch root"
    cp /tmp/pacman.conf.orig "$ROOT/etc/pacman.conf"
  fi
fi

if [ "${DESKTOP:-0}" = 1 ]; then
  # There is no Adreno 308 driver anywhere, so the desktop is X over fbdev plus
  # llvmpipe, on the same framebuffer the kernel console already uses.
  pacman -r "$ROOT" -S --noconfirm --disable-sandbox xorg-server xorg-xinit xf86-video-fbdev mesa \
    xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
  systemctl --root "$ROOT" enable lightdm
fi

# A bench phone with no keyboard: an empty root password and autologin on tty1
# are the difference between a session and a brick, and are not a security
# boundary in any case.
sed -i 's/^root:[^:]*/root::/' "$ROOT/etc/shadow"
mkdir -p "$ROOT/etc/systemd/system/getty@tty1.service.d"
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear tty1 linux\n' \
  > "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"

# systemd 25x assumes a newer kernel than 4.19 in a few places, so the first
# boot uses init=/bin/sh.  If systemd refuses to start, the answer is an older
# init, not a newer kernel.
echo "root built: $(du -sh "$ROOT" | cut -f1)"
ls "$ROOT"
