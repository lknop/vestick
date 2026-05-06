#!/usr/bin/env bash
# VEyage build (voyage-flavor branch) — Debian Trixie + optional Proxmox VE
# on a normal ext4 root mounted ro by default. See docs/voyage-flavor.md.
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
ROOT_MNT="$WORK/root"

# Disk layout. IMG_MB sets total size; ESP+pmxcfs are fixed, root takes the
# rest. Operator grows the root partition with growpart on first boot if
# the image is dd'd to a larger device.
IMG_MB="${IMG_MB:-4096}"
ESP_MB="${ESP_MB:-128}"
PMXCFS_MB="${PMXCFS_MB:-256}"

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/packages"
OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/overlay"

log()  { printf '[VEyage] %s\n' "$*" >&2; }
fail() { printf '[VEyage] ERROR: %s\n' "$*" >&2; exit 1; }

# Track loop devices and partition→loop mapping for the EXIT cleanup.
declare -a LOOPS=()
declare -A LOOP_FOR=()

cleanup() {
    # Recursive lazy umount catches the bind-to-self plus all nested
    # pseudo-fs and the ESP bind. Then free the loop devices. Best-effort —
    # called from EXIT so don't fail the build.
    if [[ -n "${ROOT_MNT:-}" ]] && mountpoint -q "$ROOT_MNT" 2>/dev/null; then
        umount -Rl "$ROOT_MNT" 2>/dev/null || true
    fi
    local lp
    for lp in "${LOOPS[@]}"; do
        losetup -d "$lp" 2>/dev/null || true
    done
}

check_prereqs() {
    log "Checking prerequisites"
    [[ $EUID -eq 0 ]] || fail "Must run as root"
    [[ "$(uname -m)" == "x86_64" ]] || fail "Build host must be x86_64 (got $(uname -m))"
    for cmd in debootstrap rsync sgdisk mkfs.fat mkfs.ext4 losetup wget blkid; do
        command -v "$cmd" >/dev/null || fail "Missing command: $cmd"
    done
    case "$LOG_SHIPPER" in
        rsyslog|journal-upload|fluent-bit|none) ;;
        *) fail "Unknown LOG_SHIPPER: $LOG_SHIPPER" ;;
    esac
}

create_image() {
    local img="$OUT/veyage.img"
    log "Creating ${IMG_MB} MB disk image at $img"
    rm -f "$img"
    truncate -s "${IMG_MB}M" "$img"
    local root_mb=$((IMG_MB - ESP_MB - PMXCFS_MB - 4))
    [[ $root_mb -gt 0 ]] || fail "IMG_MB=$IMG_MB too small for ESP+pmxcfs+rootfs layout"
    sgdisk --clear \
        --new=1:0:+${ESP_MB}M     --typecode=1:ef00 --change-name=1:ESP \
        --new=2:0:+${root_mb}M    --typecode=2:8300 --change-name=2:rootfs \
        --new=3:0:0               --typecode=3:8300 --change-name=3:pmxcfs \
        "$img" >/dev/null
    printf '%s\n' "$img"
}

setup_loops() {
    local img="$1"
    # Map each partition by explicit offset+size. `losetup -P` partition
    # scanning isn't reliable in many LXC build envs; explicit offset works
    # everywhere. (See feedback memory on LXC image-build quirks.)
    local n first size lp
    for n in 1 2 3; do
        first=$(sgdisk -i "$n" "$img" | awk '/First sector/ {print $3}')
        size=$( sgdisk -i "$n" "$img" | awk '/Partition size/ {print $3}')
        lp=$(losetup --offset $((first * 512)) --sizelimit $((size * 512)) -f --show "$img")
        LOOPS+=("$lp")
        LOOP_FOR[$n]="$lp"
    done
    log "Loops: ESP=${LOOP_FOR[1]} root=${LOOP_FOR[2]} pmxcfs=${LOOP_FOR[3]}"
}

format_partitions() {
    log "Formatting ESP / rootfs / pmxcfs"
    mkfs.fat -F32 -n EFI "${LOOP_FOR[1]}" >/dev/null
    mkfs.ext4 -L rootfs -F -q "${LOOP_FOR[2]}"
    mkfs.ext4 -L pmxcfs -F -q "${LOOP_FOR[3]}"
}

mount_root() {
    rm -rf "$ROOT_MNT"
    mkdir -p "$ROOT_MNT"
    mount "${LOOP_FOR[2]}" "$ROOT_MNT"
}

bootstrap_base() {
    log "debootstrap --variant=minbase $SUITE -> $ROOT_MNT"
    debootstrap --variant=minbase --arch="$ARCH" "$SUITE" "$ROOT_MNT" "$MIRROR"
}

mount_pseudo() {
    # Bind the rootfs mount to itself + make-rshared so that nested
    # `unshare --mount` invocations from package postinst scripts can
    # manipulate propagation. Proxmox's kernel postinst hits this; without
    # the bind+rshared it dies with EINVAL on a clean Ubuntu VM (e.g.
    # GitHub Actions runner). See feedback memory.
    mount --bind "$ROOT_MNT" "$ROOT_MNT"
    mount --make-rshared "$ROOT_MNT"
    mount -t proc proc "$ROOT_MNT/proc"
    mount -t sysfs sys "$ROOT_MNT/sys"
    # rbind so /dev/pts comes along — apt's maintainer scripts allocate ptys.
    # make-rslave so umount inside the chroot doesn't propagate to the host.
    mount --rbind /dev "$ROOT_MNT/dev"
    mount --make-rslave "$ROOT_MNT/dev"
    # Bind the ESP into the chroot so grub-install can write to it and so
    # the kernel postinst's update-grub sees a real /boot/efi.
    mkdir -p "$ROOT_MNT/boot/efi"
    mount "${LOOP_FOR[1]}" "$ROOT_MNT/boot/efi"
}

chroot_run() {
    chroot "$ROOT_MNT" /usr/bin/env -i \
        HOME=/root \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        DEBIAN_FRONTEND=noninteractive \
        LC_ALL=C \
        "$@"
}

configure_apt() {
    log "Writing apt sources (Debian$( [[ $INCLUDE_PROXMOX -eq 1 ]] && echo ' + Proxmox' ))"
    cat > "$ROOT_MNT/etc/apt/sources.list" <<EOF
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
        mkdir -p "$ROOT_MNT/etc/apt/keyrings"
        wget -qO "$ROOT_MNT$pve_key_path" "$pve_key_url" \
            || fail "Failed to fetch Proxmox release key from $pve_key_url"
        [[ -s "$ROOT_MNT$pve_key_path" ]] \
            || fail "Proxmox release key is empty: $ROOT_MNT$pve_key_path"
        cat > "$ROOT_MNT/etc/apt/sources.list.d/pve-no-subscription.sources" <<EOF
Types: deb
URIs: $PVE_MIRROR
Suites: $PVE_SUITE
Components: pve-no-subscription
Signed-By: $pve_key_path
EOF
    fi
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
    chroot_run apt-get install -y --no-install-recommends \
        -o Dpkg::Options::=--force-confold \
        -o Dpkg::Options::=--force-confdef \
        "${pkgs[@]}"
}

apply_overlay() {
    log "Applying rootfs overlay from $OVERLAY_DIR"
    # --chown=root:root so files don't carry the host user's uid (the build
    # rsync from a Mac left files owned by uid 501 in earlier builds, and
    # systemd warns about non-root unit ownership).
    rsync -a --chown=root:root "$OVERLAY_DIR/" "$ROOT_MNT/"
}

write_fstab() {
    log "Writing /etc/fstab (root=ro, pmxcfs=rw, tmpfs for ephemeral paths)"
    local root_uuid esp_uuid pmxcfs_uuid
    root_uuid=$(blkid -s UUID -o value "${LOOP_FOR[2]}")
    esp_uuid=$(blkid -s UUID -o value "${LOOP_FOR[1]}")
    pmxcfs_uuid=$(blkid -s UUID -o value "${LOOP_FOR[3]}")
    cat > "$ROOT_MNT/etc/fstab" <<EOF
# / mounted ro by default. Use \`remountrw\` to make changes,
# \`remountro\` when done. auto-remount-ro.timer flips it back after
# 10 min of unattended rw to limit power-loss exposure.
UUID=$root_uuid  /                    ext4  ro,errors=remount-ro,noatime  0  1
UUID=$esp_uuid    /boot/efi            vfat  defaults,noatime               0  2
UUID=$pmxcfs_uuid /var/lib/pve-cluster ext4  defaults,noatime,nofail        0  2

# Volatile mounts. Logs go to RAM (journald is Storage=volatile via the
# overlay drop-in; rsyslog forwards off-box). rrdcached on tmpfs trades
# lost-on-reboot perf graphs for ~80% less routine flash write rate.
#
# /var/lib/systemd is tmpfs because logind's StateDirectory= would
# otherwise fail on a ro root. Decision documented in
# docs/voyage-flavor.md — for a Proxmox-on-USB use case the only
# user-visible effect of losing this dir on reboot is that anacron-style
# systemd timers (apt-daily, fstrim, e2scrub_all) re-fire once per boot
# until next scheduled hour, all benign here. systemd-creds-encrypted
# secrets and timesyncd state DO matter generally but neither applies
# to this build.
tmpfs            /tmp                 tmpfs nodev,nosuid,size=512M           0  0
tmpfs            /var/tmp             tmpfs nodev,nosuid,size=128M           0  0
tmpfs            /var/log             tmpfs nodev,nosuid,size=128M           0  0
tmpfs            /var/lib/rrdcached   tmpfs nodev,nosuid,size=128M,mode=755  0  0
tmpfs            /var/lib/systemd     tmpfs nodev,nosuid,size=64M            0  0
# /var/cache treated as fully regenerable per FHS — apparmor recompiles
# its policy cache (~seconds), apt cache is irrelevant on a ro-root host.
tmpfs            /var/cache           tmpfs nodev,nosuid,size=128M,mode=755  0  0
# postfix's chroot (queue_directory) and data dir (data_directory) both
# need to be writable on every start: postfix-script (re)creates queue
# dirs and master writes its lock file. Ownership for /var/lib/postfix is
# fixed by overlay/etc/tmpfiles.d/veyage-postfix.conf after mount.
tmpfs            /var/spool/postfix   tmpfs nodev,nosuid,size=64M,mode=755   0  0
tmpfs            /var/lib/postfix     tmpfs nodev,nosuid,size=16M,mode=755   0  0
EOF
    # Pre-create the mount points so systemd doesn't have to.
    mkdir -p "$ROOT_MNT/boot/efi" \
             "$ROOT_MNT/var/lib/pve-cluster" \
             "$ROOT_MNT/var/lib/rrdcached" \
             "$ROOT_MNT/var/tmp" \
             "$ROOT_MNT/var/cache" \
             "$ROOT_MNT/var/spool/postfix" \
             "$ROOT_MNT/var/lib/postfix"
}

install_grub() {
    log "Installing GRUB (x86_64-efi, --removable for no-NVRAM-entry boot)"
    # Standard Debian-managed bootloader: apt can update grub-efi-amd64
    # during a remountrw window, no custom mkstandalone trickery. --removable
    # plants BOOTX64.EFI so any UEFI firmware boots it without touching NVRAM
    # (essential for "dd to a USB stick on machine A, boot on machine B").
    #
    # --modules= is critical here. grub-install's default builds a thin EFI
    # stub that expects to load further modules from /EFI/<name>/x86_64-efi/
    # on the ESP at runtime — but with --removable that directory isn't
    # populated, so the stub can't read ext4 to find /boot/grub/grub.cfg
    # and drops to `grub rescue> error: unknown filesystem`. Baking the
    # essentials into the stub avoids that. Cost: BOOTX64.EFI ~1 MB instead
    # of ~150 KB.
    chroot_run grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --bootloader-id=VEyage \
        --removable \
        --no-nvram \
        --recheck \
        --modules='part_gpt fat ext2 normal linux configfile echo search search_fs_uuid search_fs_file search_label test true regexp gettext loadenv all_video gfxterm gfxterm_background reboot halt'
    # Console: ttyS0 first, tty0 last so /dev/console = tty0 — best for
    # bare-metal-with-monitor users; serial users still see kernel printk
    # because both consoles are listed. /etc/default/grub is for the
    # operator's future update-grub runs — we don't run update-grub at
    # build time (see why below).
    cat > "$ROOT_MNT/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=2
GRUB_DISTRIBUTOR=VEyage
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0 console=tty0 panic=10"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
EOF

    # Hand-write grub.cfg instead of running update-grub. /etc/grub.d/10_linux
    # has a loop-AES-era guard that `exit 0`s silently when GRUB_DEVICE is
    # /dev/loopN backed by a regular file (build.sh:51 of 10_linux). At
    # build time the chroot's root *is* exactly that, so update-grub
    # produces a kernel-less menu and the image won't boot. After install
    # on a real device the operator's `update-grub` (during a remountrw
    # window after `apt upgrade`-ing the kernel) works normally because
    # the root is then /dev/sdaN, not a loop.
    local kver root_uuid
    kver=$(ls -1 "$ROOT_MNT"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|.*/vmlinuz-||')
    [[ -n "$kver" ]] || fail "No /boot/vmlinuz-* in chroot — kernel install failed?"
    root_uuid=$(blkid -s UUID -o value "${LOOP_FOR[2]}")
    log "Writing minimal /boot/grub/grub.cfg (kernel=$kver, root UUID=$root_uuid)"
    mkdir -p "$ROOT_MNT/boot/grub"
    cat > "$ROOT_MNT/boot/grub/grub.cfg" <<EOF
# Minimal grub.cfg written by VEyage's build.sh because update-grub's
# 10_linux script silently bails out on loop-mounted root at build time.
# After first dd to a real device, \`update-grub\` (run during a
# remountrw window after \`apt upgrade\` of grub-efi-amd64 or the kernel)
# regenerates this file in the standard Debian style.

set timeout=2
set default=0

insmod part_gpt
insmod ext2
insmod search
insmod search_fs_uuid

if loadfont \$prefix/fonts/unicode.pf2 ; then
    insmod gfxterm
    set gfxmode=auto
    terminal_output gfxterm
fi

search --no-floppy --fs-uuid --set=root $root_uuid

menuentry 'VEyage' {
    linux /boot/vmlinuz-$kver root=UUID=$root_uuid ro console=ttyS0 console=tty0 panic=10
    initrd /boot/initrd.img-$kver
}
EOF
}

prepare_first_boot() {
    log "Preparing for first boot (machine-id reset, ssh host keys)"
    # Empty machine-id triggers ConditionFirstBoot=yes for systemd-firstboot
    # on the first boot of each dd'd USB stick — gives unique IDs per device.
    : > "$ROOT_MNT/etc/machine-id"
    # Pre-generate SSH host keys so sshd starts on first boot. Operators who
    # care can regenerate them after first boot:
    #   remountrw && rm /etc/ssh/ssh_host_* && ssh-keygen -A && remountro
    if [[ -d "$ROOT_MNT/etc/ssh" ]] && ! ls "$ROOT_MNT/etc/ssh/"ssh_host_*_key >/dev/null 2>&1; then
        chroot_run ssh-keygen -A
    fi
}

cleanup_image() {
    log "Cleaning apt cache + tmp dirs"
    chroot_run apt-get clean
    rm -rf "$ROOT_MNT/var/lib/apt/lists/"*
    rm -rf "$ROOT_MNT/var/cache/"* "$ROOT_MNT/tmp/"* "$ROOT_MNT/var/tmp/"*

    log "Masking services that fight ro-root (grub-common, pvenetcommit)"
    # grub-common writes /boot/grub/grubenv "recordfail" each boot; we don't
    # use the menu-failure-counter feature, panic=10 covers boot failure.
    chroot_run systemctl mask grub-common.service
    # pvenetcommit moves /etc/network/interfaces.new -> interfaces; on ro
    # root any rename in /etc fails. Network changes happen via remountrw
    # in this design, so this committer has no useful job here.
    chroot_run systemctl mask pvenetcommit.service 2>/dev/null || true

    log "Removing build-time leftovers that block ro-root boot"
    # ifupdown's atomic-rename file from initial network config write
    rm -f "$ROOT_MNT/etc/network/interfaces.new"
    # update-alternatives' atomic-temp files (left over from an interrupted
    # alternatives run during a maintainer script — these provoke
    # update-alternatives to retry the cleanup at every boot)
    rm -f "$ROOT_MNT/etc/alternatives/"*.dpkg-tmp

    # pve-firewall's ExecStartPre invokes `update-alternatives --set` on every
    # boot, which writes /etc/alternatives/*.dpkg-tmp even when the target is
    # already correct (--set always rewrites). Pre-set them here so the
    # default state matches what pve-firewall wants, and a drop-in in the
    # overlay clears the ExecStartPre list so the runtime --set never runs.
    if [[ -x "$ROOT_MNT/usr/sbin/iptables-legacy" ]]; then
        log "Pre-setting iptables/ebtables/ip6tables alternatives to legacy"
        chroot_run update-alternatives --set ebtables /usr/sbin/ebtables-legacy
        chroot_run update-alternatives --set iptables /usr/sbin/iptables-legacy
        chroot_run update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
        # Re-clean dpkg-tmp produced by the --set above.
        rm -f "$ROOT_MNT/etc/alternatives/"*.dpkg-tmp
    fi
}

main() {
    check_prereqs
    mkdir -p "$WORK" "$OUT"
    trap cleanup EXIT

    local img
    img=$(create_image)
    setup_loops "$img"
    format_partitions
    mount_root
    bootstrap_base
    mount_pseudo
    configure_apt
    install_packages
    apply_overlay
    write_fstab
    install_grub
    prepare_first_boot
    cleanup_image

    log "Done. Output: $img ($(ls -lh "$img" | awk '{print $5}'))"
    log "To boot in QEMU:  ./test-vm.sh"
}

main "$@"
