"""Plan the write of a packed ext4 image onto land's userdata.

The runner packs the root with `mkfs.ext4 -d`, which produces a 6 GiB file whose
holes are the blocks nothing was ever written to.  Writing all of it to eMMC costs
about ten minutes and the phone cannot even see most of it:

  - the data, the primary group descriptors and the first backups run to about
    1.7 GiB,
  - sparse_super then leaves a single one-MiB island of backup superblock and
    group descriptors at the start of each of groups 16, 17, 25, 27 and 32,
    scattered out to 4 GiB,
  - everything past the last island is a hole.

A free-block count from the superblock cannot answer this: it is a count, not the
highest allocated block number, and mkfs marks each group's own metadata used in
that group's bitmap.  So the image is scanned for the blocks that hold anything at
all, which is exactly what has to be there for the filesystem to be byte-identical
to what mkfs wrote.

usage: imgparts.py IMAGE.img > plan.txt   (caches the plan next to the image)
"""
import os
import sys

B = 1 << 20
img = sys.argv[1]
plan_path = img + '.plan'

if os.path.exists(plan_path) and os.path.getsize(plan_path) < 4096:
    sys.stdout.write(open(plan_path).read())
    sys.exit(0)

size = os.path.getsize(img)
f = open(img, 'rb')
runs = []
cur = None
i = 0
while True:
    c = f.read(B)
    if not c:
        break
    nz = bool(c.strip(b'\0'))
    if nz and cur is None:
        cur = i
    if not nz and cur is not None:
        runs.append((cur, i))
        cur = None
    i += 1
if cur is not None:
    runs.append((cur, i))

if not runs:
    sys.exit('%s contains nothing but holes' % img)

# Everything that starts in the first 1.5 GiB is the body of the filesystem, and
# the 16 MiB of holes inside it is cheaper to write as zeros than to treat as a
# special case.  The prefix ends past the last block of that body plus a margin,
# because mkfs lays each group's bitmaps and inode table at the start of that
# group and a prefix that stops at the last nonzero byte can cut one in half.
front_end = max(b for a, b in runs if a < 1536)
prefix = min((front_end + 16) * B, size)
out = ['PREFIX %d' % prefix]
for a, b in runs:
    if a * B >= prefix:
        out.append('EXTRA %d %d' % (a * B, (b - a) * B))
out.append('TOTAL %d' % size)
plan = '\n'.join(out) + '\n'
open(plan_path, 'w').write(plan)
sys.stdout.write('scanned %s: %d runs, first ends at %d MiB\n' %
                 (os.path.basename(img), len(runs), runs[0][1]))
sys.stdout.write(plan)
