# Assemble an Arch Linux root for land (Redmi 3S) inside the Arch Linux ARM
# arm64 container.  Runs as root in the container; /work/rootfs is the host's
# runner temp, /work/eos is this directory mounted read-only.
#
# The kernel is not built here.  The phone boots the 4.19.325-Mi8937v2 Image that
# already ships inside the LineageOS 18 boot image, with the cmdline written by
# mkbootcmd.py: root=/dev/mmcblk0p49 rw console=tty0 fbcon=map:1.  Which is why
# the device kernel package gets dropped again after pacstrap installs it.
set -euo pipefail

ROOT=/work/rootfs

pacman -Sy --noconfirm arch-install-scripts >/dev/null

mkdir -p "$ROOT"
# -K skips the free-space check (the runner reports the container's own limits),
# -c never installs downgraded packages, -d ignores the repo's device kernel
# preference.  base is bash, coreutils, filesystem, pacman, systemd, util-linux.
pacstrap -Kcd "$ROOT" base

# The ALARM image's own kernel targets a different board and the phone takes
# neither: the LOS boot image already has the Image, the DTB and the ramdisk
# layout, so a kernel in the root would only be a lie about what is running.
for k in linux linux-aarch64 linux-ck; do
  pacman -r "$ROOT" -Rns --noconfirm "$k" >/dev/null 2>&1 || true
done

if [ "${EOS:-0}" = 1 ]; then
  # EndeavourOS is Arch plus their repository and tooling, so the layer is a
  # repo header.  Backed up first: a [endeavouros] section that does not answer
  # makes every later pacman -S fail too, because -S synchronizes all repos.
  cp "$ROOT/etc/pacman.conf" /tmp/pacman.conf.orig
  rc=0
  {
    printf '\n[endeavouros]\nSigLevel = PackageRequired\nServer = https://mirror.endeavouros.info/endeavouros/repo/endeavouros/$arch\n' \
      >> "$ROOT/etc/pacman.conf"
    pacman -r "$ROOT" -Sy --noconfirm
    pacman -r "$ROOT" -S --noconfirm endeavouros-mirrorlist eos-base eos-settings
  } || rc=$?
  if [ "$rc" != 0 ]; then
    echo "endeavouros repo is not usable for aarch64 (rc=$rc); keeping a plain Arch root"
    cp /tmp/pacman.conf.orig "$ROOT/etc/pacman.conf"
    pacman -r "$ROOT" -Rns --noconfirm endeavouros-mirrorlist eos-base eos-settings >/dev/null 2>&1 || true
  fi
fi

if [ "${DESKTOP:-0}" = 1 ]; then
  # No Adreno 308 driver exists anywhere, so the desktop is X over fbdev plus
  # llvmpipe: the same framebuffer the kernel console writes to (fbcon=map:1).
  pacman -r "$ROOT" -S --noconfirm xorg-server xorg-xinit xf86-video-fbdev mesa \
    xfce4 xfce4-goodies lightdm lightdm-gtk-greeter
  systemctl --root "$ROOT" enable lightdm
fi

# This phone is a bench device with no keyboard attached to it: an empty root
# password and autologin on tty1 are the difference between a session and a
# brick, and are not a security boundary in any case.
sed -i 's/^root:[^:]*/root::/' "$ROOT/etc/shadow"
mkdir -p "$ROOT/etc/systemd/system/getty@tty1.service.d"
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear tty1 linux\n' \
  > "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"

# systemd 25x expects a newer kernel than 4.19 in places.  The first milestone
# boots with init=/bin/sh, which needs nothing from it; if systemd refuses to
# start, the fix is an older init, not a newer kernel.
echo "root built: $(du -sh "$ROOT" | cut -f1)"
ls "$ROOT"
