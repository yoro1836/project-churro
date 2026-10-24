#!/usr/bin/env bash
# Put a kernel built by .github/workflows/churro-kernel.yml into the local Churro cache, so
# tools/prepare.sh (churro.sh auto) uses it and skips the kernel build (and the kernel source
# download). Checks that it was built from the same kmod/ files and Arch config tag as this
# checkout, i.e. that prepare.sh will compute the same cache key.
# Usage: sudo tools/ci/import-kernel.sh <churro-kernel.zip (artifact download) | churro-kernel.tar.zst>
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
A=$(realpath "${1:?usage: import-kernel.sh <churro-kernel.zip|.tar.zst>}")
C=${CHURRO_CACHE:-/var/cache/churro}
die() { echo "import-kernel: $*" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
case $A in *.zip) unzip -q -o "$A" -d "$T/zip"; A=$(ls "$T"/zip/*.tar.zst | head -1) ;; esac
[ -f "$A" ] || die "no .tar.zst found"
mkdir -p "$T/x"; zstd -dc "$A" | tar -C "$T/x" --no-same-owner -xf -
[ -f "$T/x/ci-build.env" ] || die "not a churro-kernel artifact"
. "$T/x/ci-build.env"   # CI_BID CI_KH CI_PROF CI_REL

. "$HERE/versions.env"
kh=$({ cat "$HERE/kmod/profiles/$CI_PROF.conf" "$HERE/kmod/build-kernel.sh" "$HERE"/kmod/patches/*.patch 2>/dev/null; echo "$ARCH_LINUX_CONFIG_TAG"; } | md5sum | cut -c1-8)
[ "$kh" = "$CI_KH" ] || die "built from other kmod/ files or Arch tag (CI $CI_KH, this checkout $kh): build the same commit you have here"
if [ -f "$HERE/ci-inputs/release" ] && [ "$(cat "$HERE/ci-inputs/release")" != "$CI_REL" ]; then
  die "kernel is for $CI_REL but ci-inputs/release says $(cat "$HERE/ci-inputs/release")"
fi

K=kernel-$CI_PROF-$CI_BID-$CI_KH SV=src-$CI_BID/common/out-kernel-$CI_PROF/Module.symvers
[ -f "$T/x/$K/kernel" ] && [ -f "$T/x/$SV" ] || die "artifact incomplete"
mkdir -p "$C" "$C/$(dirname "$SV")"
rm -rf "${C:?}/$K"; cp -a "$T/x/$K" "$C/"; cp "$T/x/$SV" "$C/$SV"
echo ">> imported $CI_REL ($K) into $C"
echo ">> next: sudo env TMPDIR=/var/tmp/churro OMP_NUM_THREADS=4 ./churro.sh auto <recovery.bin> churro.img"
echo "   (prepare.sh still downloads clang/rust/bindgen for the Mesa build, but skips the kernel)"
