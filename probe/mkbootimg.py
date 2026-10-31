"""Assemble an Android boot image from parts.

The LineageOS 18 boot image for land has no console on the panel because its kernel
is built without CONFIG_VT and CONFIG_FRAMEBUFFER_CONSOLE, and without
CONFIG_DEVTMPFS it does not even create the nodes for the block devices.  TWRP draws
a GUI and runs adb, so the recovery image in that partition carries a kernel that
has all of it, and the cheapest way to get a readable distro boot is to keep TWRP's
kernel and put our own ramdisk and cmdline next to it.

Header version 0 (which is what both images use) is one 2048 byte block: sizes and
addresses in, then the name and the 512 byte cmdline, then the sections at page
boundaries in the order kernel, ramdisk, second stage.  Nothing signs it, so aboot
on this board takes it as long as the phone is unlocked, which it is.

usage:
  mkbootimg.py --base-boot RECOVERY.img --ramdisk initrd.cpio.gz \
      --cmdline "..." --out land-eos-boot.img [--kernel FILE]
"""
import argparse
import os
import struct
import sys


def unpack(path):
    b = open(path, 'rb').read()
    if b[:8] != b'ANDROID!':
        sys.exit('%s is not an Android boot image' % path)
    (ksize, kaddr, rsize, raddr, ssize, saddr, taddr, page, hv) = struct.unpack_from('<9I', b, 8)
    if page == 0 or page & (page - 1):
        sys.exit('bogus page size %d' % page)
    pad = lambda n: (n + page - 1) // page * page
    koff = page
    roff = koff + pad(ksize)
    soff = roff + pad(rsize)
    return dict(raw=b, page=page, ksize=ksize, kaddr=kaddr, rsize=rsize, raddr=raddr,
                ssize=ssize, saddr=saddr, taddr=taddr, hv=hv, name=b[44:60],
                cmdline=b[60:572].split(b'\0')[0].decode('latin1'),
                kernel=b[koff:roff][:ksize], ramdisk=b[roff:soff][:rsize],
                second=b[soff:soff + pad(ssize)][:ssize])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base-boot', required=True, help='image whose header, addresses and kernel to copy')
    ap.add_argument('--kernel', default=None, help='raw kernel Image to use instead of the base one')
    ap.add_argument('--ramdisk', required=True, help='cpio or cpio.gz to put in the ramdisk field')
    ap.add_argument('--cmdline', default=None)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    base = unpack(a.base_boot)
    page = base['page']
    pad = lambda n: (n + page - 1) // page * page
    kernel = open(a.kernel, 'rb').read() if a.kernel else base['kernel']
    ramdisk = open(a.ramdisk, 'rb').read()
    second = base['second']

    # Start from the base image's own header page and only change what differs:
    # the section sizes.  That keeps the load addresses, the board name, the id
    # and the extra block exactly as the working image had them.
    hdr = bytearray(base['raw'][:page])
    struct.pack_into('<9I', hdr, 8, len(kernel), base['kaddr'], len(ramdisk),
                     base['raddr'], len(second), base['saddr'], base['taddr'],
                     page, base['hv'])
    cmd = (a.cmdline if a.cmdline is not None else base['cmdline']).encode('latin1')
    hdr[60:572] = cmd[:511].ljust(512, b'\0')
    if len(hdr) != page:
        sys.exit('header came out %d bytes, page is %d' % (len(hdr), page))

    out = bytes(hdr)
    out += kernel.ljust(pad(len(kernel)), b'\0')
    out += ramdisk.ljust(pad(len(ramdisk)), b'\0')
    out += second
    open(a.out, 'wb').write(out)

    chk = unpack(a.out)
    print('%s: kernel %d ramdisk %d second %d page %d' %
          (a.out, chk['ksize'], chk['rsize'], chk['ssize'], chk['page']))
    print('cmdline %r' % chk['cmdline'])
    print('kernel first bytes %r, ramdisk %r' % (chk['kernel'][:4], chk['ramdisk'][:2]))
    print('total %d bytes, base was %d' % (os.path.getsize(a.out), len(base['raw'])))


main()
