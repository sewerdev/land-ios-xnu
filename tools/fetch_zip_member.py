#!/usr/bin/env python3
"""Fetch one member out of a remote ZIP (an IPSW) by HTTP range.

IPSWs store their big DMGs uncompressed, so the member can be pulled without
downloading the whole archive.  Only the central directory at the tail is read
first, then the member's data is streamed in chunks.

usage: fetch_zip_member.py URL MEMBER OUT [--verify N]
       fetch_zip_member.py URL MEMBER --locate        # print offset and size only
"""
import os
import struct
import sys
import urllib.error
import urllib.request

CHUNK = 1 << 26            # 64 MiB per request: fewer round trips, resumable
EOCD_SIG = 0x06054b50
ZIP64_EOCD_SIG = 0x06064b50
CENTRAL_SIG = 0x02014b50


def http(url, start=None, end=None):
    req = urllib.request.Request(url)
    if start is not None:
        req.add_header('Range', 'bytes=%d-%d' % (start, end))
    with urllib.request.urlopen(req, timeout=180) as r:
        return r.read(), int(r.headers.get('Content-Length', 0)), r.headers


def remote_size(url):
    req = urllib.request.Request(url, method='HEAD')
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers['Content-Length'])


def parse_central(url, total):
    tail, _, _ = http(url, max(0, total - 66000), total - 1)
    i = tail.rfind(struct.pack('<I', EOCD_SIG))
    if i < 0:
        raise SystemExit('no end-of-central-directory in the last 64 KiB')
    cd_size = struct.unpack_from('<I', tail, i + 12)[0]
    cd_off = struct.unpack_from('<I', tail, i + 16)[0]
    if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF:
        # zip64: the 20-byte locator sits right before the classic EOCD and its
        # 8-byte field at locator+8 is the offset of the 64-bit record.
        loc_off = struct.unpack_from('<Q', tail, i - 20 + 8)[0]
        rec, _, _ = http(url, loc_off, loc_off + 87)
        if struct.unpack_from('<I', rec, 0)[0] != ZIP64_EOCD_SIG:
            raise SystemExit('zip64 end-of-central-directory signature missing')
        cd_size = struct.unpack_from('<Q', rec, 40)[0]
        cd_off = struct.unpack_from('<Q', rec, 48)[0]
    central, _, _ = http(url, cd_off, cd_off + cd_size - 1)
    entries = []
    p = 0
    while p + 46 <= len(central) and struct.unpack_from('<I', central, p)[0] == CENTRAL_SIG:
        hn, ln, ce = struct.unpack_from('<HHH', central, p + 28)
        ex, cm = struct.unpack_from('<HH', central, p + 30)
        uncomp = struct.unpack_from('<I', central, p + 24)[0]
        comp = struct.unpack_from('<I', central, p + 20)[0]
        hdr = struct.unpack_from('<I', central, p + 42)[0]
        name = central[p + 46:p + 46 + hn].decode('utf-8', 'replace')
        if uncomp == 0xFFFFFFFF or comp == 0xFFFFFFFF or hdr == 0xFFFFFFFF:
            # APPNOTE: the zip64 extra field repeats, in this order and only for
            # the fields whose 32-bit value was 0xFFFFFFFF, the uncompressed
            # size, the compressed size and the local header offset.
            extra = central[p + 46 + hn:p + 46 + hn + ex]
            e = 0
            while e + 4 <= len(extra):
                tag, sz = struct.unpack_from('<HH', extra, e)
                if tag == 0x0001:
                    q = e + 4
                    if uncomp == 0xFFFFFFFF:
                        uncomp = struct.unpack_from('<Q', extra, q)[0]
                        q += 8
                    if comp == 0xFFFFFFFF:
                        comp = struct.unpack_from('<Q', extra, q)[0]
                        q += 8
                    if hdr == 0xFFFFFFFF:
                        hdr = struct.unpack_from('<Q', extra, q)[0]
                        q += 8
                e += 4 + sz
        entries.append((name, hdr, uncomp))
        p += 46 + hn + ln + ce
    return entries


def member_data_offset(url, hdr_off):
    hdr, _, _ = http(url, hdr_off, hdr_off + 29)
    if hdr[:4] != b'PK\x03\x04':
        raise SystemExit('local header signature missing at %d' % hdr_off)
    method = struct.unpack_from('<H', hdr, 8)[0]
    hn, ln = struct.unpack_from('<HH', hdr, 26)
    if method != 0:
        raise SystemExit('member is compressed (method %d); a range fetch needs a stored member' % method)
    return hdr_off + 30 + hn + ln


def main():
    args = [a for a in sys.argv[1:]]
    url, member = args[0], args[1]
    total = remote_size(url)
    entries = parse_central(url, total)
    hit = [e for e in entries if e[0] == member]
    if not hit:
        print('%d members, %s not among them; first ones: %s' % (
            len(entries), member, ', '.join(n for n, _, _ in entries[:8])))
        return 1
    name, hdr_off, uncomp = hit[0]
    start = member_data_offset(url, hdr_off)
    if '--locate' in args:
        print('%s: header %d data %d size %d' % (name, hdr_off, start, uncomp))
        return 0
    out = args[args.index('--verify') + 1] if '--verify' in args else None
    if out is None:
        out = args[2]
    done = os.path.getsize(out) if os.path.exists(out) else 0
    if done > uncomp:
        os.remove(out)
        done = 0
    print('%s -> %s: %d/%d bytes' % (name, out, done, uncomp), flush=True)
    with open(out, 'ab') as f:
        while done < uncomp:
            step = min(CHUNK, uncomp - done)
            blob, _, _ = http(url, start + done, start + done + step - 1)
            if len(blob) != step:
                raise SystemExit('short read at %d: %d of %d' % (done, len(blob), step))
            f.write(blob)
            done += len(blob)
            print('  %d/%d (%.1f%%)' % (done, uncomp, 100.0 * done / uncomp), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
