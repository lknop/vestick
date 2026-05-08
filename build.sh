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
    # Bind the chroot path to itself so it becomes a real mount point.
    # Proxmox's kernel postinst calls proxmox-boot-tool, which re-execs
    # itself under `unshare --mount` and tries to set MS_PRIVATE on /. If
    # the chroot's / is just a directory subtree (not a mount), that
    # MS_PRIVATE call fails with EINVAL and the install errors out. This
    # silently worked on Proxmox-LXC build hosts (looser namespace
    # defaults) but breaks on a clean Ubuntu VM such as a GitHub Actions
    # runner. make-rshared so subsequent unshare propagation tweaks work.
    if ! mountpoint -q "$CHROOT"; then
        mount --bind "$CHROOT" "$CHROOT"
        mount --make-rshared "$CHROOT"
    fi
    mount -t proc proc "$CHROOT/proc"
    mount -t sysfs sys "$CHROOT/sys"
    # rbind so /dev/pts comes along — apt's maintainer scripts allocate ptys.
    # make-rslave so umount inside the chroot doesn't propagate to the host.
    mount --rbind /dev "$CHROOT/dev"
    mount --make-rslave "$CHROOT/dev"
}

umount_chroot() {
    # Best-effort; called from EXIT trap so don't fail the build.
    # -Rl: recursive + lazy so an LXC-passed-through /dev/.lxc/sys (which we
    # can't unmount cleanly inside the container) doesn't leave stuck mounts
    # that block rm -rf of the chroot on the next bootstrap_base. One -Rl
    # on $CHROOT also catches the bind-to-self introduced in mount_chroot.
    umount -Rl "$CHROOT" 2>/dev/null || true
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
    for cmd in debootstrap mksquashfs chroot rsync sgdisk grub-install mkfs.fat mkfs.f2fs losetup wget; do
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
        # Fetch the Proxmox release key at build time — never bundled in this repo
        # (we ship the recipe; user's build pulls Proxmox bits direct from upstream).
        local pve_key_url="https://enterprise.proxmox.com/debian/proxmox-release-${PVE_SUITE}.gpg"
        local pve_key_path="/etc/apt/keyrings/proxmox-release-${PVE_SUITE}.gpg"
        log "Fetching Proxmox release key: $pve_key_url"
        mkdir -p "$CHROOT/etc/apt/keyrings"
        wget -qO "$CHROOT$pve_key_path" "$pve_key_url" \
            || fail "Failed to fetch Proxmox release key from $pve_key_url"
        [[ -s "$CHROOT$pve_key_path" ]] \
            || fail "Proxmox release key is empty: $CHROOT$pve_key_path"
        cat > "$CHROOT/etc/apt/sources.list.d/pve-no-subscription.sources" <<EOF
Types: deb
URIs: $PVE_MIRROR
Suites: $PVE_SUITE
Components: pve-no-subscription
Signed-By: $pve_key_path
EOF
    fi
    mount_chroot
    chroot_run apt-get update
}

install_packages() {
    local lists=("$PKG_DIR/base.list")
    if [[ $INCLUDE_PROXMOX -eq 1 ]]; then
        lists+=("$PKG_DIR/proxmox.list")
    else
        lists+=("$PKG_DIR/kernel-debian.list")
    fi
    [[ "$LOG_SHIPPER" != "none" ]] && lists+=("$PKG_DIR/logging-$LOG_SHIPPER.list")
    log "Installing packages from: ${lists[*]}"
    local pkgs=() f p
    for f in "${lists[@]}"; do
        [[ -f "$f" ]] || fail "Package list missing: $f"
        while IFS= read -r p; do
            case "$p" in ''|\#*) continue ;; esac
            pkgs+=("$p")
        done < "$f"
    done
    log "Package count: ${#pkgs[@]}"
    # --force-confold: keep our pre-written conffiles (e.g. update-initramfs.conf)
    # rather than failing on the conffile prompt that DEBIAN_FRONTEND alone won't suppress.
    chroot_run apt-get install -y --no-install-recommends \
        -o Dpkg::Options::=--force-confold \
        -o Dpkg::Options::=--force-confdef \
        "${pkgs[@]}"
}

apply_overlay() {
    log "Applying rootfs overlay from $OVERLAY_DIR"
    rsync -a "$OVERLAY_DIR/" "$CHROOT/"
    # TODO: apply $LOG_SHIPPER-specific overlay (overlay-$LOG_SHIPPER/) if present
}

configure_readonly() {
    log "Configuring read-only root behavior"
    # Modules required to mount a squashfs root and stack overlayfs.
    cat > "$CHROOT/etc/initramfs-tools/modules" <<'EOF'
squashfs
overlay
loop
ext4
f2fs
virtio_blk
virtio_pci
virtio_net
EOF
    chmod 0755 "$CHROOT/etc/initramfs-tools/hooks/veyage-f2fs"
    # Patch overlayroot's init-bottom hook: drop the `mount -o remount,ro $ROOTMNT`
    # call that fires whenever the kernel cmdline contains `ro`. Squashfs requires
    # `ro` at the kernel mount step, but the overlay we stack on top must stay rw
    # — otherwise systemd's StateDirectory= / LogsDirectory= mkdirs all fail
    # (chrony, systemd-logind, sshd-keygen all break).
    local hook="$CHROOT/usr/share/initramfs-tools/scripts/init-bottom/overlayroot"
    if [[ -f "$hook" ]] && grep -q 'remount,ro "$ROOTMNT"' "$hook"; then
        sed -i 's|^\(\s*\)mount -o remount,ro "\$ROOTMNT"|\1: # VEyage: skip remount,ro — keep overlay rw\n\1true|' "$hook"
    fi
    # No build-time SSH host keys: ssh.service has an ExecStartPre drop-in
    # that runs `ssh-keygen -A` (idempotent) before each start, so the keys
    # are generated on first boot against the target device's own entropy.
    # /etc/ssh sits on the persistent f2fs overlay, so they persist after.
    rm -f "$CHROOT/etc/ssh/"ssh_host_*
}

generate_initramfs() {
    if ! ls "$CHROOT/boot/"vmlinuz-* >/dev/null 2>&1; then
        log "No kernel installed, skipping initramfs"
        return
    fi
    # Kernel-postinst already created the initramfs during install_packages;
    # re-run to pick up overlay/ files (e.g. /etc/initramfs-tools/modules,
    # /etc/overlayroot.conf) applied after install.
    log "Updating initramfs to include overlay/ changes"
    chroot_run update-initramfs -u -k all
}

prepare_runtime() {
    log "Preparing runtime: cleaning build leftovers, enabling veyage units"

    # Build-time leftovers that would otherwise re-trigger work on every boot:
    #   - interfaces.new: ifupdown's atomic-rename file from the initial
    #     network config write; pvenetcommit picks it up at every boot.
    #   - alternatives/*.dpkg-tmp: from interrupted maintainer-script runs.
    rm -f "$CHROOT/etc/network/interfaces.new"
    rm -f "$CHROOT/etc/alternatives/"*.dpkg-tmp

    chroot_run systemctl enable \
        veyage-firstboot.service \
        veyage-network-init.service \
        veyage-overlay-resize.service 2>/dev/null || true
}

export_boot_artifacts() {
    # Pick the highest-versioned /boot/vmlinuz-*. Debian's linux-image-amd64
    # creates a /vmlinuz root symlink, but Proxmox's kernel doesn't — globbing
    # /boot handles both.
    local kern initrd suffix
    kern=$(ls -1 "$CHROOT"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
    if [[ -z "$kern" ]]; then
        log "No /boot/vmlinuz-* in chroot, skipping boot-artifact export"
        return
    fi
    suffix="${kern##*/vmlinuz-}"
    initrd="$CHROOT/boot/initrd.img-$suffix"
    [[ -f "$initrd" ]] || fail "Kernel $kern present but matching initrd $initrd missing"
    log "Exporting kernel + initrd to $OUT/ (kernel: $suffix)"
    cp -L "$kern"   "$OUT/vmlinuz"
    cp -L "$initrd" "$OUT/initrd.img"
}

cleanup_chroot() {
    log "Cleaning chroot before pack"
    chroot_run apt-get clean
    rm -rf "$CHROOT/var/lib/apt/lists/"*
    rm -rf "$CHROOT/var/cache/"* "$CHROOT/tmp/"* "$CHROOT/var/tmp/"*
    : > "$CHROOT/etc/machine-id"          # regenerated on first boot
    # SSH host keys: not shipped in the image. The ssh.service drop-in
    # runs ssh-keygen -A as ExecStartPre, generating fresh per-host keys
    # on first boot. They persist on the f2fs overlay.
    umount_chroot
}

pack_squashfs() {
    log "Packing squashfs to $OUT/rootfs.squashfs"
    rm -f "$OUT/rootfs.squashfs"
    # Exclude POSIX ACL xattrs (squashfs can't represent them, warns noisily)
    # while preserving security.capability so setcap'd binaries (e.g. ping) keep working.
    # Exclude *contents* of /dev /proc /sys but keep the directories themselves
    # (initramfs needs them as mount points for devtmpfs/procfs/sysfs at boot):
    # cleanup_chroot uses `umount -Rl` (needed because LXC's /dev/.lxc/sys
    # resists clean unmount), which can leave bind-mount contents visible to
    # mksquashfs and slow it down enormously while it tries to read
    # /proc/kcore, /dev/.lxc/proc/* etc.
    mksquashfs "$CHROOT" "$OUT/rootfs.squashfs" -comp zstd -noappend -no-progress \
        -xattrs-exclude '^system\.posix_acl_' \
        -wildcards -e 'dev/*' 'proc/*' 'sys/*'
    ls -lh "$OUT/rootfs.squashfs"
}

build_image() {
    local img="$OUT/veyage.img"
    local squashfs="$OUT/rootfs.squashfs"
    [[ -f "$squashfs" ]] || fail "Missing squashfs at $squashfs"
    [[ -f "$OUT/vmlinuz" && -f "$OUT/initrd.img" ]] || fail "Missing kernel/initrd in $OUT"

    # overlay_mb is just the image's initial size. veyage-overlay-resize
    # grows it on first boot via growpart + resize.f2fs, so we ship a small
    # image and let it expand on whatever USB/SD it's dd'd to.
    local squash_size_mb esp_mb=128 overlay_mb=256 total_mb
    squash_size_mb=$(( ( $(stat -c%s "$squashfs") + 1024*1024 - 1 ) / (1024*1024) ))
    total_mb=$(( esp_mb + squash_size_mb + overlay_mb + 4 ))
    log "Assembling bootable disk image: ESP ${esp_mb}M + rootfs ${squash_size_mb}M + overlay ${overlay_mb}M = ${total_mb}M"

    rm -f "$img"
    truncate -s "${total_mb}M" "$img"

    # GPT layout for UEFI boot:
    #   p1 ESP     (FAT32, EFI/BOOT/BOOTX64.EFI)
    #   p2 rootfs  (raw squashfs partition)
    #   p3 overlay (f2fs, persistent overlay upper)
    sgdisk --clear \
        --new=1:0:+${esp_mb}M --typecode=1:ef00 --change-name=1:ESP \
        --new=2:0:+${squash_size_mb}M --typecode=2:8300 --change-name=2:rootfs \
        --new=3:0:0           --typecode=3:8300 --change-name=3:overlay \
        "$img" >/dev/null

    local rootfs_partuuid
    rootfs_partuuid=$(sgdisk -i 2 "$img" | awk -F': ' '/Partition unique GUID/ {print tolower($2)}')

    # Map each partition to its own loop device by explicit offset+size, since
    # `losetup -P` partition-scanning doesn't populate /dev/loopNpM in many
    # LXC configurations and device-mapper (kpartx) is also typically blocked.
    _part_loop() {
        local n="$1" first size
        first=$(sgdisk -i "$n" "$img" | awk '/First sector/ {print $3}')
        size=$( sgdisk -i "$n" "$img" | awk '/Partition size/ {print $3}')
        losetup --offset $((first * 512)) --sizelimit $((size * 512)) -f --show "$img"
    }
    local lp_esp lp_root lp_overlay
    lp_esp=$(_part_loop 1)
    lp_root=$(_part_loop 2)
    lp_overlay=$(_part_loop 3)
    log "Partition loops: ESP=$lp_esp rootfs=$lp_root overlay=$lp_overlay"

    mkfs.fat -F32 -n EFI "$lp_esp" >/dev/null
    dd if="$squashfs" of="$lp_root" bs=4M conv=notrunc status=none
    # mkfs.f2fs -f for force (loop dev isn't recognized as flash without it).
    # Label "overlay" matches LABEL=overlay in /etc/overlayroot.conf.
    mkfs.f2fs -l overlay -f "$lp_overlay" >/dev/null

    local mnt; mnt=$(mktemp -d)
    mount "$lp_esp" "$mnt"
    mkdir -p "$mnt/boot" "$mnt/EFI/BOOT"
    cp "$OUT/vmlinuz"   "$mnt/boot/vmlinuz"
    cp "$OUT/initrd.img" "$mnt/boot/initrd.img"

    # Build a self-contained EFI binary with grub-mkstandalone. Unlike
    # `grub-install --removable` (which just plants a thin BOOTX64.EFI that
    # tries to load modules off the ESP at runtime), mkstandalone bakes
    # GRUB + all required modules + our grub.cfg into one file, so UEFI
    # firmware can boot it with no other dependencies on the partition.
    local tmp_cfg
    tmp_cfg=$(mktemp)
    cat > "$tmp_cfg" <<EOF
set timeout=2
set default=0

# grub-mkstandalone bakes this config into a memdisk, so GRUB's root starts
# pointed at the embedded fs. Switch to the ESP (FAT label "EFI") to find
# /boot/vmlinuz and /boot/initrd.img before loading them.
search --no-floppy --label EFI --set=root

menuentry 'VEyage' {
    linux /boot/vmlinuz root=PARTUUID=$rootfs_partuuid rootfstype=squashfs ro console=ttyS0 console=tty0 panic=10
    initrd /boot/initrd.img
}
EOF

    log "Building standalone GRUB EFI binary"
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$mnt/EFI/BOOT/BOOTX64.EFI" \
        --modules='part_gpt fat ext2 normal linux configfile echo search search_fs_uuid search_label test reboot halt all_video gfxterm gfxterm_background loadenv' \
        --locales='' --themes='' --fonts='' \
        "boot/grub/grub.cfg=$tmp_cfg" >/dev/null
    rm -f "$tmp_cfg"

    umount "$mnt"
    rmdir "$mnt"
    losetup -d "$lp_esp" "$lp_root" "$lp_overlay"

    log "Bootable image: $img ($(ls -lh "$img" | awk '{print $5}'))"
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
    prepare_runtime
    export_boot_artifacts
    cleanup_chroot
    pack_squashfs
    build_image
    log "Done. Output in $OUT/"
    log "To boot in QEMU:  ./test-vm.sh"
}

main "$@"
