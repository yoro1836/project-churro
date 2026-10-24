#!/usr/bin/env bash
# SELinux: Mesa finds GPUs with libdrm (drmGetDevices2), which reads the GPU's PCI ID files in
# sysfs, in every app. Google labels those files sysfs_gpu (readable by apps, SurfaceFlinger...)
# only at the Intel iGPU's fixed slot 00:02.0. Same label here for function 0 of any device behind
# a PCIe bridge, where discrete GPUs sit, and of any root-bus device (QEMU puts virtio-gpu at
# 00:04.0: without it libdrm can't read its uevent and Mesa finds no DRM device) (genfscon
# wildcards: the policy has genfs_seclabel_wildcard). SSDs/NICs at such slots get it too: their
# ID files merely become readable by the graphics domains. Domain 0 only (consumer PCs). Init
# compiles the policy.
set -euo pipefail
T=$1; S=$T/etc/selinux
{ echo "; Project Churro gpu-nouveau: PCI ID files of GPUs anywhere on domain 0, for Mesa's device enumeration"
  for a in vendor device subsystem_vendor subsystem_device revision config uevent; do
    echo "(genfscon sysfs \"/devices/pci0000:00/0000:00:*/0000:*:00.0/$a\" (u object_r sysfs_gpu ((s0) (s0))))"
    echo "(genfscon sysfs \"/devices/pci0000:00/0000:00:??.0/$a\" (u object_r sysfs_gpu ((s0) (s0))))"
  done; } >> "$S/vendor_sepolicy.cil"
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256
echo "   vendor: SELinux: GPU PCI ID files readable wherever the GPU sits (precompiled policy removed)"
