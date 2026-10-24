#!/usr/bin/env bash
# Local half of the CI kernel build: pull the few small inputs the kernel build needs out of the
# recovery image, so the build itself can run on a GitHub runner (.github/workflows/churro-kernel.yml).
#   ci-inputs/ikconfig       the image kernel's own config (IKCONFIG)
#   ci-inputs/release        its release string (…-ab<GKI build id>)
#   ci-inputs/gki-certs.pem  the public GKI module-signing certificate(s) built into it
# Text only: no Google binary leaves the machine. Needs root (read-only loop device), little RAM.
# Usage: sudo tools/ci/kernel-inputs.sh <recovery.bin> [out dir=ci-inputs]
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
IMG=${1:?usage: kernel-inputs.sh <recovery.bin> [out dir]} OUT=${2:-$HERE/ci-inputs}
. "$HERE/lib/bootimg.sh"
die() { echo "kernel-inputs: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (losetup)"
for c in losetup sgdisk curl strings openssl od dd lz4 zstd xz gzip; do
  command -v "$c" >/dev/null || die "missing tool: $c (Debian/Ubuntu: gdisk curl binutils openssl lz4 zstd xz-utils)"
done

T=$(mktemp -d) L=""
cleanup() { if [ -n "$L" ]; then losetup -d "$L" 2>/dev/null || true; fi; rm -rf "$T"; }
trap cleanup EXIT
L=$(losetup -f --show -r -P "$IMG"); udevadm settle 2>/dev/null || sleep 1
n=$(sgdisk -p "$L" | awk '$NF == "boot_a" {print $1}'); [ -n "$n" ] || die "no boot_a partition in $IMG"
bootimg_extract "${L}p$n" "$T"
[ -s "$T/kernel" ] || die "boot_a has no kernel"

# same helper scripts and kernel tag as tools/prepare.sh. raw.githubusercontent.com rate-limits
# (HTTP 429), so: prepare.sh's cache, local kernel headers, git.kernel.org, then GitHub. The copy
# is also put in the cache, so prepare.sh (churro.sh auto) doesn't download it again later.
C=${CHURRO_CACHE:-/var/cache/churro}; mkdir -p "$C"
for t in extract-ikconfig extract-vmlinux; do
  got=""
  for f in "$C/$t" /usr/lib/modules/*/build/scripts/$t /usr/src/linux*/scripts/$t /usr/src/kernels/*/scripts/$t; do
    if [ -s "$f" ]; then cp "$f" "$T/$t"; got=$f; break; fi
  done
  if [ -z "$got" ]; then
    for u in "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/scripts/$t?h=v6.18" \
             "https://raw.githubusercontent.com/torvalds/linux/v6.18/scripts/$t"; do
      if curl -fsSL --retry 2 --retry-delay 3 "$u" -o "$T/$t" && [ -s "$T/$t" ]; then got=$u; break; fi
    done
  fi
  [ -n "$got" ] || die "can't get $t (put a copy at $C/$t: it is scripts/$t of any Linux source tree)"
  echo ">> $t: $got"
  [ -s "$C/$t" ] || cp "$T/$t" "$C/$t"
done
mkdir -p "$OUT"
bash "$T/extract-ikconfig" "$T/kernel" > "$OUT/ikconfig" || die "no IKCONFIG in the image kernel"
bash "$T/extract-vmlinux" "$T/kernel" > "$T/vmlinux" 2>/dev/null || die "can't decompress the image kernel"
REL=$(strings "$T/vmlinux" | grep -oE 'Linux version [^ ]+' | head -1 | cut -d' ' -f3 || true)
case $REL in *-ab[0-9]*) ;; *) die "unexpected kernel release '$REL' (no -ab<build id>)" ;; esac
echo "$REL" > "$OUT/release"
bash "$HERE/tools/extract-certs.sh" "$T/vmlinux" > "$OUT/gki-certs.pem"
grep -q BEGIN "$OUT/gki-certs.pem" || die "no signing certificate found in the image kernel"

# hand the files back to the user who ran sudo, so `git add` works without root
[ -z "${SUDO_UID:-}" ] || chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUT"
echo ">> $OUT: release $REL (GKI build ${REL##*-ab}), $(grep -c BEGIN "$OUT/gki-certs.pem") cert(s)"
echo ">> LTO: $(grep -E '^CONFIG_LTO_CLANG_(FULL|THIN)=y' "$OUT/ikconfig" || echo none)"
echo ">> next: git add ci-inputs && git commit && git push  (to your fork; the workflow starts on push)"
