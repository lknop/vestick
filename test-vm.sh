#!/usr/bin/env bash
# Boot the VEyage image in QEMU under UEFI (boots out/veyage.img through GRUB).
# Requires qemu-system-x86_64. Console comes to your terminal; quit with Ctrl-A x.

set -euo pipefail

OUT="${OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out}"
MEM="${MEM:-1024}"
SMP="${SMP:-2}"

KVM=()
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    KVM=(-enable-kvm -cpu host)
else
    echo "Note: /dev/kvm unavailable, falling back to TCG emulation (slow)" >&2
fi

IMG="${IMG:-$OUT/veyage.img}"
[[ -f "$IMG" ]] || { echo "Missing $IMG — run ./build.sh first" >&2; exit 1; }
# UEFI firmware: split CODE (read-only) + VARS (writable copy per run).
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_TPL="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
[[ -f "$OVMF_CODE" && -f "$OVMF_VARS_TPL" ]] || \
    { echo "OVMF firmware not found (apt install ovmf)" >&2; exit 1; }
VARS_RW=$(mktemp --suffix=.fd)
cp "$OVMF_VARS_TPL" "$VARS_RW"
trap 'rm -f "$VARS_RW"' EXIT
exec qemu-system-x86_64 "${KVM[@]}" \
    -machine q35 \
    -m "$MEM" -smp "$SMP" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$VARS_RW" \
    -drive "file=$IMG,format=raw,if=virtio" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -nographic -no-reboot -serial mon:stdio
