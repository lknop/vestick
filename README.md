# VEstick

Minimal Debian Trixie + Proxmox VE image for USB stick or SD card. Read-only base, persistent overlay, tmpfs for chatty paths.

## What this is

A build pipeline that produces a Debian 13 (Trixie) image with:

- **Squashfs base + f2fs overlay** — base is never modified at runtime; writes (config edits, `apt install`, package state) land in the f2fs upper layer, which is exactly the diff from the shipped image.
- **Tmpfs for chatty paths** — logs, caches, perf graphs, and similar regenerable state in RAM.
- **Minimal package set** — `debootstrap --variant=minbase` + a hand-picked list, `--no-install-recommends`. No `man-db`, `cron`, `os-prober`, `popularity-contest`.
- **Proxmox VE on top** — fetched from the `pve-no-subscription` repo at build time. 
- **Remote logging by default** — `journald Storage=volatile`, off-box via a build-time-selectable shipper (rsyslog, `systemd-journal-upload`, or Fluent Bit).

## What this is not

VEstick is an **independent project**, not affiliated with, endorsed by, or sponsored by Proxmox Server Solutions GmbH. "Proxmox" and the Proxmox logo are trademarks of Proxmox Server Solutions GmbH.

This repository contains build scripts and configuration only.

Read-only-root debian + curated-package approach inspired by [Voyage Linux](http://linux.voyage.hk/) (long-defunct). No voyage code was used. The actual implementation modeled after openwrt (squashfs root + f2fs overlay).

## Architecture at a glance

| Layer | Filesystem | Examples |
|---|---|---|
| Image-immutable | squashfs (compressed, RO) | `/usr`, `/lib`, kernel, initrd, distro `/etc` defaults |
| Persistent | f2fs (overlay upper) | any operator edit, `apt install`, `/etc/network/`, SSH host keys, `/var/lib/pve-cluster/` |
| Volatile | tmpfs | `/var/log`, `/var/cache`, `/var/tmp`, `/tmp`, `/var/lib/rrdcached`, `/var/lib/systemd`, `/var/lib/{vz,pve-manager,postfix}` |

The overlay upper *is* the diff between the running system and the shipped image — useful for diagnostics and drift monitoring.

VM and container storage belongs **off the boot media** (separate disk, NFS, iSCSI, Ceph). `/var/lib/vz` on a USB stick is not a good idea regardless of root-filesystem setup.

## Build host requirements

- Debian or Ubuntu on **amd64**. PVE has no aarch64 target, so the build host must be x86_64. macOS aarch64 hosts: use a Lima x86_64 VM (QEMU-emulated, slow) or an amd64 LXC/VM elsewhere.
- Root (or sudo) access.
- ~8 GB free disk for the chroot + output image.
- Build deps: `debootstrap squashfs-tools rsync curl gpg ca-certificates dosfstools qemu-utils gdisk grub-pc-bin grub-efi-amd64-bin ovmf`.
- Loop devices and KVM. Inside a Proxmox LXC build host, pass through `/dev/loop[0-N]`, `/dev/loop-control`, `/dev/kvm` plus the relevant cgroup permissions.

## Quickstart

```sh
sudo INCLUDE_PROXMOX=0 ./build.sh    # Debian-only build
./test-vm.sh                         # UEFI boot in QEMU
```

`test-vm.sh` defaults to `MODE=image` (UEFI boot of `out/vestick.img`). `MODE=direct` boots `out/rootfs.squashfs` via QEMU's `-kernel`/`-initrd` for faster iteration.

Environment variables:

| Variable | Default | Notes |
|---|---|---|
| `INCLUDE_PROXMOX` | `1` | `0` for a Debian-only build (no Proxmox repo, Debian kernel) |
| `LOG_SHIPPER` | `rsyslog` | `rsyslog` \| `journal-upload` \| `fluent-bit` \| `none` |
| `SUITE` | `trixie` | Debian release codename |
| `MIRROR` | `http://deb.debian.org/debian` | Debian apt mirror |
| `PVE_MIRROR` | `http://download.proxmox.com/debian/pve` | Proxmox repo |
| `WORK` | `./work` | Build chroot location |
| `OUT` | `./out` | Output image location |

## Prebuilt images

Every push to `main` and every PR runs `.github/workflows/build.yml`, building both flavors on a clean `ubuntu-24.04` runner. `vestick-debian.img` and `vestick-pve.img` (plus `.sha256`) ship as workflow artifacts (14-day retention).

Pushing a `v*` tag also attaches both images to a GitHub Release. Useful for `dd`-to-USB without a build host:

```sh
gh release download vX.Y.Z --pattern 'vestick-pve.img*'
sha256sum -c vestick-pve.img.sha256
sudo dd if=vestick-pve.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## Logging shipper choice

`journald` is RAM-only (`Storage=volatile`); a shipper carries logs off-box.

| Shipper | Protocol | Best fit |
|---|---|---|
| `rsyslog` (default) | syslog UDP/TCP/TLS, RELP | Graylog, Splunk syslog input, anything legacy |
| `systemd-journal-upload` | journal-export over HTTPS | Setups with a `systemd-journal-remote` receiver |
| `fluent-bit` | journald → syslog/Loki/Elasticsearch/… | Modern observability stacks |

`systemd-journal-upload` only talks to `systemd-journal-remote`. Pick `rsyslog` for anything else.

## Layout

```
build.sh                   Top-level build script
test-vm.sh                 Boot the built image in QEMU (UEFI / direct kernel)
packages/                  Package lists (one per line, `#` for comments)
  base.list                Minimal Debian additions on top of minbase
  kernel-debian.list       Debian kernel (used when INCLUDE_PROXMOX=0)
  proxmox.list             Proxmox VE essentials (used when INCLUDE_PROXMOX=1)
  logging-rsyslog.list     Logging shipper packages (one per profile)
  logging-journal-upload.list
  logging-fluent-bit.list
overlay/                   Files merged into chroot before squashing
  etc/systemd/journald.conf.d/volatile.conf
  etc/overlayroot.conf
  usr/local/bin/vestick-diag  Boot-time mount-topology dump (init=… debug)
out/                       Build artifacts (gitignored)
  rootfs.squashfs          The read-only root layer
  vmlinuz, initrd.img      Extracted from the chroot for direct kernel boot
  vestick.img               Bootable UEFI disk image (GPT: ESP + rootfs + overlay)
```

## Disk image layout

The `vestick.img` produced by `build.sh` is GPT-partitioned for UEFI:

| # | Type | Size | Notes |
|---|---|---|---|
| 1 | EFI System (FAT32, label `EFI`) | 128 MB | `BOOTX64.EFI` (self-contained, built with `grub-mkstandalone`), `vmlinuz`, `initrd.img` |
| 2 | rootfs (raw squashfs) | sized to fit | the read-only root, mounted by the kernel at boot |
| 3 | overlay (f2fs, label `overlay`) | 256 MB initial; resized to fill device on first boot | the overlay upper layer — captures every persistent write |

## Documentation

- [docs/architecture.md](docs/architecture.md) — design decisions: runtime model, overlayroot patch, UEFI boot path, GPT layout, write boundaries.
- [docs/roadmap.md](docs/roadmap.md) — phase-by-phase status.
- [docs/build-internals.md](docs/build-internals.md) — package rationale, overlayroot patch details, LXC build-env quirks. Read before touching the chroot, initramfs, loop devices, or `/dev` handling.

## License

[AGPL-3.0-or-later](LICENSE), matching Proxmox VE's license.

## Acknowledgments

Voyage Linux for the original idea of a tight, read-only Debian on flash media.
OpenWrt for the actual overlay filesystem logic.
