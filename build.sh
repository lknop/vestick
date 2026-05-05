#!/usr/bin/env bash
# VEyage build — minimal Debian Trixie + Proxmox VE on a read-only root.
# Run as root on an amd64 Debian/Ubuntu host. See README.md for env vars.

set -euo pipefail

ARCH="${ARCH:-amd64}"
SUITE="${SUITE:-trixie}"
LOG_SHIPPER="${LOG_SHIPPER:-rsyslog}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
PVE_MIRROR="${PVE_MIRROR:-http://download.proxmox.com/debian/pve}"
PVE_SUITE="${PVE_SUITE:-$SUITE}"
WORK="${WORK:-$PWD/work}"
OUT="${OUT:-$PWD/out}"
CHROOT="$WORK/chroot"

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/packages"
OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/overlay"

log()  { printf '[VEyage] %s\n' "$*" >&2; }
fail() { printf '[VEyage] ERROR: %s\n' "$*" >&2; exit 1; }

read_pkg_list() {
    # Print packages from a list file, skipping blanks and # comments.
    local f="$1"
    [[ -f "$f" ]] || fail "Package list missing: $f"
    grep -vE '^\s*(#|$)' "$f"
}

check_prereqs() {
    log "Checking prerequisites"
    [[ $EUID -eq 0 ]] || fail "Must run as root"
    [[ "$(uname -m)" == "x86_64" ]] || fail "Build host must be x86_64 (got $(uname -m))"
    for cmd in debootstrap mksquashfs chroot rsync; do
        command -v "$cmd" >/dev/null || fail "Missing command: $cmd"
    done
    case "$LOG_SHIPPER" in
        rsyslog|journal-upload|fluent-bit|none) ;;
        *) fail "Unknown LOG_SHIPPER: $LOG_SHIPPER" ;;
    esac
}

bootstrap_base() {
    log "debootstrap --variant=minbase $SUITE -> $CHROOT"
    # TODO: debootstrap --variant=minbase --arch="$ARCH" "$SUITE" "$CHROOT" "$MIRROR"
}

configure_apt() {
    log "Configuring apt sources (Debian + non-free-firmware + Proxmox)"
    # TODO: write $CHROOT/etc/apt/sources.list.d/debian.sources with main + non-free-firmware
    # TODO: write $CHROOT/etc/apt/sources.list.d/pve-no-subscription.sources
    # TODO: install Proxmox repo signing key into $CHROOT/etc/apt/keyrings/
    # TODO: chroot apt-get update
}

install_packages() {
    log "Installing packages (base + proxmox + logging:$LOG_SHIPPER)"
    local lists=("$PKG_DIR/base.list" "$PKG_DIR/proxmox.list")
    [[ "$LOG_SHIPPER" != "none" ]] && lists+=("$PKG_DIR/logging-$LOG_SHIPPER.list")
    # TODO: mapfile -t pkgs < <(for f in "${lists[@]}"; do read_pkg_list "$f"; done)
    # TODO: chroot apt-get install -y --no-install-recommends "${pkgs[@]}"
}

apply_overlay() {
    log "Applying rootfs overlay from $OVERLAY_DIR"
    # TODO: rsync -a "$OVERLAY_DIR/" "$CHROOT/"
    # TODO: apply $LOG_SHIPPER-specific overlay (overlay-$LOG_SHIPPER/) if present
}

configure_readonly() {
    log "Configuring read-only root behavior"
    # TODO: install/configure overlayroot OR drop initramfs-tools hook for overlayfs
    # TODO: write fstab with squashfs lower, RW partition for state, tmpfs for /var/log /tmp /var/cache
    # TODO: write-redirect rules for /var/lib/pve-cluster, /etc/network, /etc/ssh/host_keys
}

generate_initramfs() {
    log "Regenerating initramfs"
    # TODO: chroot update-initramfs -u -k all
}

cleanup_chroot() {
    log "Cleaning chroot before pack"
    # TODO: chroot apt-get clean
    # TODO: rm -rf $CHROOT/var/lib/apt/lists/*
    # TODO: truncate -s 0 $CHROOT/etc/machine-id        # regenerated on first boot
    # TODO: rm -f $CHROOT/etc/ssh/ssh_host_*            # regenerated to RW slice on first boot
    # TODO: rm -rf $CHROOT/var/cache/* $CHROOT/tmp/*
}

pack_squashfs() {
    log "Packing squashfs to $OUT/rootfs.squashfs"
    # TODO: mksquashfs "$CHROOT" "$OUT/rootfs.squashfs" -comp zstd -noappend
}

build_image() {
    log "Assembling bootable image (ESP + RW state + squashfs)"
    # TODO: create raw disk image, partition (GPT: ESP fat32 + ext4 RW state)
    # TODO: install GRUB to ESP, generate grub.cfg pointing at the squashfs
    # TODO: copy squashfs into the image
}

main() {
    check_prereqs
    mkdir -p "$WORK" "$OUT"
    bootstrap_base
    configure_apt
    install_packages
    apply_overlay
    configure_readonly
    generate_initramfs
    cleanup_chroot
    pack_squashfs
    build_image
    log "Done. Output in $OUT/"
}

main "$@"
