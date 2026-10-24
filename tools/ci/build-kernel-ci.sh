#!/usr/bin/env bash
# CI half of tools/prepare.sh: sources + toolchains + Churro kernel + kABI check, from the inputs
# tools/ci/kernel-inputs.sh extracted (no recovery image needed). Mirrors prepare.sh steps 2-3
# (same cache layout and kernel cache key): keep the two in sync when prepare.sh changes.
# Output: a .tar.zst that tools/ci/import-kernel.sh unpacks into the local cache, where
# prepare.sh then finds the kernel and skips building it.
# Usage: tools/ci/build-kernel-ci.sh <inputs dir> <out .tar.zst> [kernel profile=generic]
set -euo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
IN=$(realpath "$1") TARBALL=$(realpath -m "$2") PROF=${3:-generic}
C=${CHURRO_CACHE:-/var/cache/churro}; mkdir -p "$C"
log() { echo ">> $*"; }
# ci.android.com rate-limits (429): retry with backoff, and never leave a partial file behind
fetch() {
  local i; for i in 1 2 3 4 5; do curl -fsSL -o "$2.part" "$1" && { mv "$2.part" "$2"; return 0; }; sleep $((i * 20)); done
  rm -f "$2.part"; echo "download failed: $1" >&2; return 1
}
G="https://android.googlesource.com"
for f in ikconfig release gki-certs.pem; do [ -s "$IN/$f" ] || { echo "missing $IN/$f (run tools/ci/kernel-inputs.sh)" >&2; exit 1; }; done

# --- 1. kernel identity (from the extracted inputs instead of the image) ---
REL=$(cat "$IN/release"); BID=${REL##*-ab}; log "image kernel $REL (GKI build $BID)"
[ -f "$C/manifest_$BID.xml" ] || fetch "https://ci.android.com/builds/submitted/$BID/kernel_x86_64/latest/raw/manifest_$BID.xml" "$C/manifest_$BID.xml"
rev() { grep -oE "<project [^>]*name=\"$1\"[^>]*" "$C/manifest_$BID.xml" | grep -oE 'revision="[^"]+"' | cut -d'"' -f2; }
CLANG_NAME=clang-$(grep -oE 'based on r[0-9a-z]+' "$IN/ikconfig" | head -1 | cut -d' ' -f3)
RUST_VER=$(grep -oE 'rustc [0-9.]+' "$IN/ikconfig" | head -1 | cut -d' ' -f2)
RUST_BUILD=$(grep -oE 'Toolchain version [0-9]+' "$IN/ikconfig" | head -1 | awk '{print $3}')
PAHOLE=v$(grep -oE 'CONFIG_PAHOLE_VERSION=[0-9]+' "$IN/ikconfig" | cut -d= -f2 | sed -E 's/^([0-9])([0-9]+)$/\1.\2/')

# --- 2. sources + toolchains (= prepare.sh step 2) ---
S=$C/src-$BID; mkdir -p "$S"
fetch_tar() {
  local i; for i in 1 2 3; do curl -fsSL -o "$2.tgz" "$1" && break; [ $i = 3 ] && return 1; sleep 5; done
  rm -rf "$2.tmp" && mkdir -p "$2.tmp" && tar -xzmf "$2.tgz" -C "$2.tmp" && rm -f "$2.tgz" && mv "$2.tmp" "$2"
}
[ -d "$S/common" ] || { log "kernel/common @ $(rev kernel/common)"; fetch_tar "$G/kernel/common/+archive/$(rev kernel/common).tar.gz" "$S/common"; }
[ -d "$S/clang" ] || { log "$CLANG_NAME"; fetch_tar "$G/platform/prebuilts/clang/host/linux-x86/+archive/$(rev platform/prebuilts/clang/host/linux-x86)/$CLANG_NAME.tar.gz" "$S/clang"; }
if [ ! -d "$S/rust" ]; then
  RREV=$(rev platform/prebuilts/rust-toolchain/linux-x86)
  for d in $(curl -fsSL "$G/platform/prebuilts/rust-toolchain/linux-x86/+/$RREV/?format=JSON" | tail -c +5 | grep -oE "\"$RUST_VER[^\"]*\"" | tr -d '"' | sort -r); do
    fetch_tar "$G/platform/prebuilts/rust-toolchain/linux-x86/+archive/$RREV/$d.tar.gz" "$S/rust-$d"
    if "$S/rust-$d/bin/rustc" --version | grep -q "$RUST_BUILD"; then mv "$S/rust-$d" "$S/rust"; log "rust $d"; break; fi
    rm -rf "$S/rust-$d"
  done
  [ -d "$S/rust" ] || { echo "no rust toolchain matching build $RUST_BUILD" >&2; exit 1; }
fi
mkdir -p "$S/bin"
[ -x "$S/bin/bindgen" ] || { curl -fsSL "$G/platform/prebuilts/clang-tools/+/$(rev platform/prebuilts/clang-tools)/linux-x86/bin/bindgen?format=TEXT" | base64 -d > "$S/bin/bindgen.tmp"
  chmod +x "$S/bin/bindgen.tmp"; mv "$S/bin/bindgen.tmp" "$S/bin/bindgen"; }
[ -x "$S/bin/pahole" ] || PAHOLE_VER=$PAHOLE bash "$HERE/tools/build-pahole.sh" "$S/bin"
df -h "$C" | tail -1

# --- 3. Churro kernel + kABI check (= prepare.sh step 3, same cache key) ---
. "$HERE/versions.env"
KH=$({ cat "$HERE/kmod/profiles/$PROF.conf" "$HERE/kmod/build-kernel.sh" "$HERE"/kmod/patches/*.patch 2>/dev/null; echo "$ARCH_LINUX_CONFIG_TAG"; } | md5sum | cut -c1-8)
K=$C/kernel-$PROF-$BID-$KH
log "kernel cache key $KH -> $K"
[ -f "$K/kernel" ] || CHURRO_GKI_CERTS=$IN/gki-certs.pem bash "$HERE/kmod/build-kernel.sh" "$S/common" "$S/clang" "$S/rust" "$S/bin" "$IN/ikconfig" "$REL" "$PROF" "$K"
SV=$S/common/out-kernel-$PROF/Module.symvers
[ -f "$K/Module.symvers" ] || cp "$SV" "$K/"
[ -f "$C/vmlinux.symvers-$BID" ] || fetch "https://ci.android.com/builds/submitted/$BID/kernel_x86_64/latest/raw/vmlinux.symvers" "$C/vmlinux.symvers-$BID"
bad=$(awk 'NR==FNR {crc[$2]=$1; next} ($2 in crc) && crc[$2] != $1 {n++; if (n<=5) print "   CRC differs: " $2 > "/dev/stderr"} END {print n+0}' \
      "$C/vmlinux.symvers-$BID" "$SV")
log "kABI check: $bad of $(wc -l < "$C/vmlinux.symvers-$BID") GKI exports differ"
[ "$bad" = 0 ] || { echo "kABI broken: the image's prebuilt modules won't load. Fix the profile ($PROF)." >&2; exit 1; }

# --- package: exactly the two paths prepare.sh looks at ---
printf 'CI_BID=%s\nCI_KH=%s\nCI_PROF=%s\nCI_REL=%s\n' "$BID" "$KH" "$PROF" "$REL" > "$C/ci-build.env"
mkdir -p "$(dirname "$TARBALL")"
tar -C "$C" -cf - ci-build.env "kernel-$PROF-$BID-$KH" "src-$BID/common/out-kernel-$PROF/Module.symvers" | zstd -q -T0 -10 -o "$TARBALL" -f
log "packed $(du -h "$TARBALL" | cut -f1): $TARBALL"
