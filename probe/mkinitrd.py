"""Build the land EOS probe initramfs.

An Android boot image's ramdisk is just a cpio.gz, and the 4.19 kernel in the
LineageOS 18 image unpacks it before it ever looks at the cmdline root, so a
probe script plus one binary is the whole initrd.  Alpine's busybox is used
instead of a hand-written C init because the applets the probe keeps needing
(mount, chroot, od, df) are already there, and the minirootfs carries the musl
it links against, so three files are enough to run a shell.

Symlinks are written into the cpio directly: this Windows filesystem will not
let tar create them, and a newc record is only a mode plus a target string.

usage: mkinitrd.py [OUT.cpio.gz]
"""
import gzip
import io
import os
import sys

W = os.path.dirname(os.path.abspath(__file__))
ALP = os.path.join(W, 'alp')
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(W, 'initrd.cpio.gz')

BIN_LINKS = [
    'sh', 'ash', 'cat', 'dd', 'df', 'echo', 'expr', 'grep', 'head', 'ls',
    'mkdir', 'mount', 'od', 'rm', 'sed', 'sleep', 'stat', 'sync', 'tail',
    'tr', 'uname', 'wc', 'cp', 'mv', 'date', 'pidof', 'kill', 'true', 'false',
    'dmesg', 'mknod', 'readlink', 'basename', 'dirname', 'du', 'find', 'printf',
    'timeout',
]
SBIN_LINKS = [
    'reboot', 'poweroff', 'halt', 'switch_root', 'pivot_root', 'umount', 'fsck',
    'blkid', 'insmod', 'lsmod', 'modprobe', 'getty', 'mdev', 'losetup',
    'chroot', 'blockdev', 'sendmail', 'ntpd', 'udhcpc', 'ip', 'ping', 'route',
    'ifconfig', 'nslookup', 'wget', 'traceroute',
]
DIRS = [
    'bin', 'dev', 'etc', 'lib', 'mnt', 'mnt/c', 'mnt/r', 'proc',
    'root', 'sbin', 'sys', 'tmp', 'usr', 'usr/sbin', 'var', 'var/run',
]

ino = [10]


def rec(mode, data, name, rdev=0):
    """One newc record: 110 byte header, name padded to 4, data padded to 4."""
    ino[0] += 1
    name = name + b'\0'
    hdr = b'070701' + b''.join(
        b'%08X' % v for v in (ino[0], mode, 0, 0, 1, 1924500000, len(data),
                              0, 0, (rdev >> 8) & 0xFF, rdev & 0xFF, len(name), 0))
    assert len(hdr) == 110, len(hdr)
    out = hdr + name
    out += b'\0' * (-len(out) % 4)
    out += data
    return out + b'\0' * (-len(data) % 4)


def main():
    b = io.BytesIO()
    for d in DIRS:
        b.write(rec(0o040755, b'', d.encode()))
    b.write(rec(0o100755, open(os.path.join(W, 'initrd', 'init'), 'rb').read()
                .replace(b'\r\n', b'\n'), b'init'))
    b.write(rec(0o100755, open(os.path.join(ALP, 'bin', 'busybox'), 'rb').read(),
                b'bin/busybox'))
    # The LOS 18 kernel has no VT and no fbcon, so the panel only shows what
    # is drawn into the framebuffer by hand.
    fb = os.path.join(W, 'work', 'fbprint')
    if os.path.exists(fb):
        b.write(rec(0o100755, open(fb, 'rb').read(), b'bin/fbprint'))

    b.write(rec(0o100755, open(os.path.join(ALP, 'lib', 'ld-musl-aarch64.so.1'),
                                'rb').read(), b'lib/ld-musl-aarch64.so.1'))
    b.write(rec(0o120777, b'ld-musl-aarch64.so.1', b'lib/libc.musl-aarch64.so.1'))
    for a in BIN_LINKS:
        b.write(rec(0o120777, b'busybox', ('bin/' + a).encode()))
    # The sbin links have to say ../bin/busybox: a symlink target is resolved
    # relative to the directory the link lives in, and busybox is in /bin, so a
    # plain 'busybox' target left /sbin/chroot, /sbin/mdev and /sbin/reboot
    # dangling and the probe reported 'chroot: not found' over adb on the phone.
    for a in SBIN_LINKS:
        b.write(rec(0o120777, b'../bin/busybox', ('sbin/' + a).encode()))

    raw = b.getvalue()
    raw += rec(0, b'', b'TRAILER!!!')
    gz = gzip.compress(raw, 9)
    open(OUT, 'wb').write(gz)
    print('cpio %d bytes, gz %d bytes, %d records' % (len(raw), len(gz), ino[0] - 10))


main()
