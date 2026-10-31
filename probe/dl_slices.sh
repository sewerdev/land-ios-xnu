#!/bin/bash
# Fetch a GitHub Actions artifact zip in parallel byte ranges.
#
# One connection to artifact storage is throttled on this link (measured 0.11 MB/s
# on a 3.38 GiB root image = eight hours), the endpoint answers Range requests, and
# gh's own downloader stalls at zero bytes on a zip this size.  Python's urllib
# cannot validate the redirect chain here at all (CERTIFICATE_VERIFY_FAILED), so
# every slice is a curl with its own resume: -C - combined with -r continues inside
# the range, and --retry-all-errors rides out a dropped connection.
#
# usage: GHA_TOKEN=$(gh auth token) dl_slices.sh <api-zip-url> <out.zip> <size> [slices]
set -u
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
url=${1:?url}
out=${2:?out}
size=${3:?size}
n=${4:-12}
[ -n "${GHA_TOKEN:-}" ] || { echo "GHA_TOKEN is empty"; exit 1; }

chunk=$(( (size + n - 1) / n ))
dir=$out.parts
mkdir -p "$dir"
for i in $(seq 0 $((n - 1))); do
	a=$(( i * chunk ))
	b=$(( a + chunk - 1 ))
	[ "$b" -ge "$size" ] && b=$(( size - 1 ))
	f=$dir/$(printf %03d "$i").bin
	# A finished slice must not be handed to curl again: with -C - and nothing left
	# to fetch it fails the range, and --retry would spin on that for hours.
	if [ -f "$f" ] && [ "$(stat -c %s "$f")" = "$(( b - a + 1 ))" ]; then
		continue
	fi
	curl -sS -L --fail --retry 400 --retry-delay 5 --retry-all-errors \
		-H "Authorization: Bearer $GHA_TOKEN" -r "$a-$b" -C - -o "$f" "$url" &
done
wait

have=0
for i in $(seq 0 $((n - 1))); do
	f=$dir/$(printf %03d "$i").bin
	[ -f "$f" ] || { echo "slice $i missing"; exit 1; }
	have=$(( have + $(stat -c %s "$f") ))
done
[ "$have" = "$size" ] || { echo "slices add up to $have, expected $size"; exit 1; }

# Written in slice order, which is zip order: each slice is a contiguous byte
# range of the archive, not an archive member.
: > "$out"
for i in $(seq 0 $((n - 1))); do
	cat "$dir/$(printf %03d "$i").bin" >> "$out"
done
echo "wrote $out ($have bytes)"
rm -rf "$dir"
