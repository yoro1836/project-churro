#!/usr/bin/env bash
# Boot a Churro image in QEMU (UEFI/OVMF, KVM, NVMe disk, virtio-gpu) with serial log + QMP.
# Usage: tools/qemu-test.sh <image> [logdir]
#   serial 0 (ttyS0, Android's apgetty shell): $LOG/serial.sock + serial.log  -> tools/qemu-serial.sh
#   serial 1 (ttyS1, kernel console of the "debug" menu entries): $LOG/kernel.log
#   TPM=1 adds a swtpm-backed TPM 2.0 (tpm-tis), QEMU_EXTRA appends raw QEMU args,
#   GPU_ARGS replaces the display device (default virtio-gpu; "-vga std" = plain framebuffer,
#   i.e. the "no GPU driver" case: simpledrm + vgem + Mesa software rendering)
#   The image is not modified (QEMU snapshot: a first boot formats /data); SNAPSHOT=off keeps changes.
#   DISK_DEV=usb-storage boots it like a USB stick (default: NVMe). MEM sets guest RAM (default 6G).
#   VNC=none drops the VNC display (needed with a GL display: QEMU_EXTRA="-display gtk,gl=on").
set -euo pipefail
IMG=$1; LOG=${2:-/tmp/churro-qemu}; mkdir -p "$LOG"
# OVMF: Debian/Ubuntu names, else Arch/Fedora's edk2 package
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd OVMF_VARS=/usr/share/OVMF/OVMF_VARS_4M.fd
[ -f "$OVMF_CODE" ] || OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
cp "$OVMF_VARS" "$LOG/vars.fd"
TPMARGS=()
if [ "${TPM:-0}" = 1 ]; then
  mkdir -p "$LOG/tpm"
  swtpm socket --tpm2 --tpmstate dir="$LOG/tpm" --ctrl type=unixio,path="$LOG/swtpm.sock" --daemon
  TPMARGS=(-chardev socket,id=chrtpm,path="$LOG/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0)
fi
VNCARGS=(-vnc "${VNC:-127.0.0.1:5}"); [ "${VNC:-}" = none ] && VNCARGS=()
exec qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m ${MEM:-6G} \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$LOG/vars.fd" \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -drive if=none,id=d0,format=raw,file="$IMG",snapshot=${SNAPSHOT:-on} -device ${DISK_DEV:-nvme,serial=churro0},drive=d0 \
  ${GPU_ARGS:--device virtio-gpu-pci} \
  -netdev user,id=n0 -device e1000e,netdev=n0 "${TPMARGS[@]}" \
  -chardev socket,id=s0,path="$LOG/serial.sock",server=on,wait=off,logfile="$LOG/serial.log" -serial chardev:s0 \
  -serial file:"$LOG/kernel.log" -qmp unix:"$LOG/qmp.sock",server,nowait \
  -display none "${VNCARGS[@]}" ${QEMU_EXTRA:-}
