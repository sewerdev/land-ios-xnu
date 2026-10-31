"""Build a qemu initramfs out of the real phone initramfs.

The point is to run the *same* /init that goes into the phone's boot image, on the
same ext4 image that is on its userdata, on a machine that is not the phone.  The
phone's initramfs is self-contained (busybox, musl, fbprint), so the only thing the
test copy needs on top of it is a kernel that can see a disk and an ext4 driver, and
the Alpine virt kernel has ext4 and virtio_blk as modules rather than built in.

Those modules are taken from the same package as the kernel that boots them, and are
uncompressed here because busybox insmod is not promised to handle .ko.gz.

usage: mkqemu_initrd.py OUT.cpio.gz
"""
import gzip
import io
import os
import sys

W = os.path.dirname(os.path.abspath(__file__))
PHONE = os.path.join(W, '..', 'initrd.cpio.gz')
MODS = os.path.join(W, 'apk', 'lib', 'modules', '6.18.59-0-virt')
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(W, 'qemu-initrd.cpio.gz')

# Load order matters: ext4 refers to symbols from crc16, mbcache and jbd2, and a
# block device has to exist before anything can be mounted on it.
NEEDED = [
    'kernel/lib/crc/crc16.ko.gz',
    'kernel/fs/mbcache.ko.gz',
    'kernel/fs/jbd2/jbd2.ko.gz',
    'kernel/fs/ext4/ext4.ko.gz',
    'kernel/drivers/block/virtio_blk.ko.gz',
    'kernel/net/core/failover.ko.gz',
    'kernel/drivers/net/net_failover.ko.gz',
    'kernel/drivers/net/virtio_net.ko.gz',
]

WRAPPER = '''#!/bin/sh
# Test harness entry: load what the phone's kernel already has built in, then run
# the real probe unchanged.
PATH=/bin:/sbin
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mkdir -p /dev/block 2>/dev/null
for m in crc16 mbcache jbd2 ext4 virtio_blk failover net_failover virtio_net; do
	insmod /kmod/$m.ko 2>/dev/null
done
echo "QEMU-HARNESS modules loaded, disks: $(ls /dev/vd* 2>/dev/null | tr '\\n' ' ')" > /dev/kmsg 2>/dev/null
exec /probe/init
'''

ino = [80000]


def rec(mode, data, name):
    ino[0] += 1
    nb = name.encode() + b'\0'
    hdr = b'070701' + b''.join(
        b'%08X' % v for v in (ino[0], mode, 0, 0, 1, 1924500000, len(data),
                              0, 0, 0, 0, len(nb), 0))
    out = hdr + nb
    out += b'\0' * (-len(out) % 4)
    out += data
    return out + b'\0' * (-len(data) % 4)


def main():
    base = gzip.decompress(open(PHONE, 'rb').read())
    t = base.rfind(b'TRAILER!!!')
    if t < 0:
        sys.exit('%s has no cpio trailer' % PHONE)
    body = base[:t - 110]

    b = io.BytesIO()
    b.write(body)
    for d in ('kmod', 'probe'):
        b.write(rec(0o040755, b'', d))
    for m in NEEDED:
        src = os.path.join(MODS, m)
        if not os.path.exists(src):
            sys.exit('missing module %s, extract the kernel package first' % src)
        data = gzip.decompress(open(src, 'rb').read())
        name = 'kmod/' + os.path.basename(m).replace('.gz', '')
        b.write(rec(0o100644, data, name))
        print('  + %s (%d bytes)' % (name, len(data)))
    probe = open(os.path.join(W, '..', 'initrd', 'init'), 'rb').read().replace(b'\r\n', b'\n')
    b.write(rec(0o100755, probe, 'probe/init'))
    b.write(rec(0o100755, WRAPPER.encode(), 'init'))
    b.write(rec(0, b'', 'TRAILER!!!'))

    raw = b.getvalue()
    open(OUT, 'wb').write(gzip.compress(raw, 6))
    print('%s: %d bytes raw, %d gz' % (OUT, len(raw), os.path.getsize(OUT)))


main()
