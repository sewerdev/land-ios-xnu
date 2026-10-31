"""Check an initramfs cpio for the mistakes that only show up on the phone.

A dangling symlink inside a cpio is invisible to every tool that merely lists it:
7-Zip showed /sbin/chroot as a perfectly good entry, and the probe only found out
it had no chroot, no mdev and no reboot when it was running on the device with
nobody able to see the screen.  So the archive is checked here, before it is packed
into a boot image:

  - every symlink target resolves to something in the archive,
  - /init exists, is a regular file and is executable,
  - the interpreter named in its #! line exists and is executable,
  - the binaries the probe runs are present and executable.

usage: check_initrd.py initrd.cpio.gz   (exit 1 and a list on any problem)
"""
import gzip
import io
import os
import posixpath
import sys


def parse(data):
    entries = []
    i = 0
    while i + 110 <= len(data):
        if data[i:i + 6] != b'070701':
            return entries, 'lost the newc magic at byte %d' % i
        g = lambda o: int(data[i + o:i + o + 8], 16)
        mode, fsize, namesize = g(14), g(54), g(94)
        name = data[i + 110:i + 110 + namesize - 1].decode('utf8', 'replace')
        hr = 110 + namesize
        hr += (-hr) % 4
        body = data[i + hr:i + hr + fsize]
        entries.append((mode, name, body))
        if name == 'TRAILER!!!':
            return entries, None
        i += hr + fsize + ((-fsize) % 4)
    return entries, 'no TRAILER!!! record'


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'initrd.cpio.gz'
    raw = open(path, 'rb').read()
    data = gzip.decompress(raw) if raw[:2] == b'\x1f\x8b' else raw
    entries, err = parse(data)
    if err:
        print('CPIO-BROKEN', err)
        return 1

    by_name = {}
    for mode, name, body in entries:
        by_name[name] = (mode, body)

    def resolve(path):
        """Follow archive symlinks component by component.

        Alpine's initramfs is a merged-usr tree where /bin and /sbin are themselves
        symlinks, so a name like bin/sh only exists through usr/bin/sh, and a checker
        that compares strings would call that missing.
        """
        seen = 0
        parts = [x for x in path.split('/') if x and x != '.']
        out = []
        for part in parts:
            if part == '..':
                if out:
                    out.pop()
                continue
            out.append(part)
            cur = '/'.join(out)
            mode_body = by_name.get(cur)
            if mode_body and (mode_body[0] & 0o170000) == 0o120000:
                target = mode_body[1].decode('utf8', 'replace')
                seen += 1
                if seen > 8:
                    return cur
                # A relative link target is relative to the directory the link is in,
                # not to the root of the archive.
                if target.startswith('/'):
                    nxt = target.lstrip('/')
                else:
                    nxt = posixpath.normpath(posixpath.join(posixpath.dirname(cur), target))
                out = [x for x in resolve(nxt).split('/') if x]
        return '/'.join(out)

    problems = []

    # Symlinks: resolve relative to the directory the link is in.
    links = 0
    for mode, name, body in entries:
        if (mode & 0o170000) != 0o120000:
            continue
        links += 1
        target = body.decode('utf8', 'replace')
        if target.startswith('/'):
            want = target[1:]
        else:
            want = posixpath.normpath(posixpath.join(posixpath.dirname(name), target)).lstrip('/')
        if resolve(want) not in by_name:
            problems.append('dangling symlink %s -> %s (resolves to %s)' % (name, target, want))

    init = by_name.get('init')
    if init is None:
        problems.append('no /init in the archive')
    else:
        mode, body = init
        if not mode & 0o111:
            problems.append('/init is not executable (mode %o)' % (mode & 0o7777))
        if body.startswith(b'#!'):
            interp = body.split(b'\n', 1)[0][2:].strip().split(b' ')[0].decode()
            key = resolve(interp.lstrip('/'))
            if key not in by_name:
                problems.append('/init interpreter %s is not in the archive' % interp)
            elif not by_name[key][0] & 0o111:
                problems.append('/init interpreter %s is not executable' % interp)

    # The phone image keeps its applets in /bin and /sbin; the qemu test image is
    # Alpine's initramfs with the probe installed under /probe, so the same names are
    # looked for under that prefix.
    pre = 'probe/' if resolve('probe/init') in by_name else ''
    need = ['bin/busybox', 'bin/sh', 'bin/mount', 'bin/dd', 'bin/dmesg', 'bin/mknod',
            'bin/df', 'bin/fbprint', 'sbin/chroot', 'sbin/mdev', 'sbin/reboot',
            'sbin/switch_root', 'sbin/umount']
    if not pre:
        need += ['lib/ld-musl-aarch64.so.1', 'lib/libc.musl-aarch64.so.1']
    for n in need:
        # The qemu harness keeps the phone's own layout at /bin and adds the probe
        # under /probe, so either place counts as present.
        where = next((c for c in (n, pre + n) if resolve(c) in by_name), None)
        if where is None:
            problems.append('missing %s' % n)
        elif not by_name[resolve(where)][0] & 0o111 and 'musl' not in where:
            problems.append('%s is not executable' % where)

    # A file whose parent directory is not in the archive is dropped by the kernel's
    # unpacker without any message, which shows up much later as exec saying
    # "not found" for a file that lists fine.
    dirs = set(n for m, n, b in entries if (m & 0o170000) == 0o040000)
    for mode, name, body in entries:
        if not name or name == 'TRAILER!!!' or name == '.':
            continue
        parent = posixpath.dirname(name)
        while parent and parent not in dirs:
            if resolve(parent) in dirs:
                break
            problems.append('%s has no directory record for %s' % (name, parent))
            break

    print('records %d, symlinks %d, regular files %d' %
          (len(entries), links, sum(1 for m, n, b in entries if m & 0o170000 == 0o100000)))
    for p in problems:
        print('PROBLEM', p)
    if problems:
        print('INITRD-FAILS %d problems' % len(problems))
        return 1
    print('INITRD-OK')
    return 0


sys.exit(main())
