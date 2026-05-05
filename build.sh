#!/usr/bin/env bash
# VEyage build — minimal Debian Trixie + Proxmox VE on a read-only root.
# Run as root on an amd64 Debian/Ubuntu host. See README.md for env vars.

set -euo pipefail

ARCH="${ARCH:-amd64}"
SUITE="${SUITE:-trixie}"
LOG_SHIPPER="${LOG_SHIPPER:-rsyslog}"
INCLUDE_PROXMOX="${INCLUDE_PROXMOX:-1}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.debian.org/debian-security}"
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

mount_chroot() {
    mount -t proc proc "$CHROOT/proc"
    mount -t sysfs sys "$CHROOT/sys"
    # rbind so /dev/pts comes along — apt's maintainer scripts allocate ptys.
    # make-rslave so umount inside the chroot doesn't propagate to the host.
    mount --rbind /dev "$CHROOT/dev"
    mount --make-rslave "$CHROOT/dev"
}

umount_chroot() {
    # Best-effort; called from EXIT trap so don't fail the build.
    umount -R "$CHROOT/dev" "$CHROOT/sys" "$CHROOT/proc" 2>/dev/null || true
}

chroot_run() {
    chroot "$CHROOT" /usr/bin/env -i \
        HOME=/root \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        "$@"
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
    if [[ -e "$CHROOT" ]]; then
        log "Existing chroot at $CHROOT — removing before re-bootstrap"
        umount_chroot
        rm -rf "$CHROOT"
    fi
    mkdir -p "$CHROOT"
    debootstrap --variant=minbase --arch="$ARCH" "$SUITE" "$CHROOT" "$MIRROR"
}

configure_apt() {
    log "Writing apt sources (Debian$( [[ $INCLUDE_PROXMOX -eq 1 ]] && echo ' + Proxmox' ))"
    cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free-firmware
deb $SECURITY_MIRROR $SUITE-security main contrib non-free-firmware
EOF
    if [[ $INCLUDE_PROXMOX -eq 1 ]]; then
        # TODO: install Proxmox release signing key into $CHROOT/etc/apt/keyrings/
        # TODO: write $CHROOT/etc/apt/sources.list.d/pve-no-subscription.sources
        log "Proxmox repo configuration not yet implemented (Phase 2)"
    fi
    mount_chroot
    chroot_run apt-get update
}

install_packages() {
    local lists=("$PKG_DIR/base.list")
    [[ $INCLUDE_PROXMOX -eq 1 ]] && lists+=("$PKG_DIR/proxmox.list")
    [[ "$LOG_SHIPPER" != "none" ]] && lists+=("$PKG_DIR/logging-$LOG_SHIPPER.list")
    log "Installing packages from: ${lists[*]}"
    local pkgs=()
    while IFS= read -r p; do pkgs+=("$p"); done < <(for f in "${lists[@]}"; do read_pkg_list "$f"; done)
    log "Package count: ${#pkgs[@]}"
    chroot_run apt-get install -y --no-install-recommends "${pkgs[@]}"
}

apply_overlay() {
    log "Applying rootfs overlay from $OVERLAY_DIR"
    rsync -a "$OVERLAY_DIR/" "$CHROOT/"
    # TODO: apply $LOG_SHIPPER-specific overlay (overlay-$LOG_SHIPPER/) if present
}

configure_readonly() {
    log "Configuring read-only root behavior"
    # TODO: install/configure overlayroot OR drop initramfs-tools hook for overlayfs
    # TODO: write fstab with squashfs lower, RW partition for state, tmpfs for /var/log /tmp /var/cache
    # TODO: write-redirect rules for /var/lib/pve-cluster, /etc/network, /etc/ssh/host_keys
}

generate_initramfs() {
    if ! ls "$CHROOT/boot/"vmlinuz-* >/dev/null 2>&1; then
        log "No kernel installed, skipping initramfs"
        return
    fi
    log "Regenerating initramfs"
    chroot_run update-initramfs -u -k all
}

cleanup_chroot() {
    log "Cleaning chroot before pack"
    chroot_run apt-get clean
    rm -rf "$CHROOT/var/lib/apt/lists/"*
    rm -rf "$CHROOT/var/cache/"* "$CHROOT/tmp/"* "$CHROOT/var/tmp/"*
    : > "$CHROOT/etc/machine-id"          # regenerated on first boot
    rm -f "$CHROOT/etc/ssh/ssh_host_"*    # regenerated onto the RW slice on first boot
    umount_chroot
}

pack_squashfs() {
    log "Packing squashfs to $OUT/rootfs.squashfs"
    rm -f "$OUT/rootfs.squashfs"
    # Exclude POSIX ACL xattrs (squashfs can't represent them, warns noisily)
    # while preserving security.capability so setcap'd binaries (e.g. ping) keep working.
    mksquashfs "$CHROOT" "$OUT/rootfs.squashfs" -comp zstd -noappend -no-progress \
        -xattrs-exclude '^system\.posix_acl_'
    ls -lh "$OUT/rootfs.squashfs"
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
    trap umount_chroot EXIT
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
