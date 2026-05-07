# VEyage

Minimal Debian Trixie image with a read-only base filesystem, designed as a Proxmox VE appliance for USB stick or SD card.

## What this is

A small, opinionated build pipeline that produces a Debian 13 (Trixie) image with:

- **Read-only squashfs base + persistent f2fs overlay** — the read-only base layer is never modified at runtime; all writes (config edits, `apt install`, package state) land in a flash-friendly f2fs upper layer that captures exactly the diff from the shipped image.
- **Tmpfs for chatty paths** — logs, caches, perf graphs, and similar regenerable state route to RAM so flash takes only the writes that actually need to persist.
- **Curated minimal package set** — `debootstrap --variant=minbase` plus a hand-picked list, installed with `--no-install-recommends`. No `man-db`, no `cron`, no `os-prober`, no `popularity-contest`.
- **Proxmox VE on top** — fetched from the Proxmox `pve-no-subscription` apt repository at build time (not bundled in this repo).
- **Remote logging by default** — `journald` runs with `Storage=volatile`; logs leave the box via a build-time-selectable shipper (rsyslog forwarding, `systemd-journal-upload`, or Fluent Bit).

## What this is not

VEyage is an **independent project**. It is not affiliated with, endorsed by, or sponsored by Proxmox Server Solutions GmbH. "Proxmox" and the Proxmox logo are trademarks of Proxmox Server Solutions GmbH. This repository contains build scripts and configuration only — Proxmox packages are downloaded from the Proxmox apt repository during the build, not redistributed here.

The name "VEyage" is a nod to the long-defunct [Voyage Linux](http://svn.voyage.hk/repos/voyage/trunk/) project, which inspired the read-only-root and curated-package approach. No Voyage code is used.

## Architecture at a glance

| Layer | Filesystem | Examples |
|---|---|---|
| Image-immutable | squashfs (compressed, RO) | `/usr`, `/lib`, kernel, initrd, distro `/etc` defaults |
| Persistent | f2fs (overlay upper) | any operator edit, `apt install`, `/etc/network/`, SSH host keys, `/var/lib/pve-cluster/` |
| Volatile | tmpfs | `/var/log`, `/var/cache`, `/var/tmp`, `/tmp`, `/var/lib/rrdcached`, `/var/lib/systemd`, `/var/lib/{vz,pve-manager,postfix}` |

The overlay upper is *exactly* the diff between the running system and the shipped image — useful for diagnostics and for monitoring drift.

VM and container storage should live **off the boot media** (separate disk, NFS, iSCSI, Ceph) — `/var/lib/vz` on a USB stick is not a good idea regardless of how clever the root filesystem is.

## Build host requirements

- Debian or Ubuntu on **amd64**. Proxmox VE has no aarch64 build target, so the build host (or a VM/LXC on it) must be x86_64. macOS aarch64 hosts can use a Lima x86_64 VM (slow, QEMU-emulated) or an amd64 LXC/VM elsewhere.
- Root (or sudo) access.
- ~5 GB free disk for the build chroot and output image.
- Packages on the build host: `debootstrap squashfs-tools rsync curl gpg ca-certificates dosfstools qemu-utils gdisk grub-pc-bin grub-efi-amd64-bin ovmf`.
- **Loop devices and KVM** must be available. Inside a Proxmox LXC build host, this means passing through `/dev/loop[0-N]`, `/dev/loop-control`, `/dev/kvm` and the relevant cgroup permissions. See `lxc.cgroup2.devices.allow` / `lxc.mount.entry` examples in the project notes.

## Quickstart

```sh
sudo INCLUDE_PROXMOX=0 ./build.sh    # Debian-only, boots cleanly today
./test-vm.sh                         # Boots the disk image in QEMU under UEFI
```

`./test-vm.sh` defaults to `MODE=image` (full UEFI boot of `out/veyage.img`). `MODE=direct` skips GRUB and uses QEMU's `-kernel` / `-initrd` against `out/rootfs.squashfs` for faster iteration.

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

Every push to `main` and every PR triggers `.github/workflows/build.yml`, which builds both the Debian-only and the `INCLUDE_PROXMOX=1` variants on a fresh `ubuntu-24.04` runner and uploads the resulting `veyage-debian.img` and `veyage-pve.img` (plus matching `.sha256` files) as workflow artifacts (14-day retention).

Pushing a tag (`v*`) additionally creates a GitHub Release with both images attached, no per-file size limit aside from GitHub's 2 GB cap. Useful for `dd`-to-USB without setting up a build host:

```sh
gh release download vX.Y.Z --pattern 'veyage-pve.img*'
sha256sum -c veyage-pve.img.sha256
sudo dd if=veyage-pve.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## Logging shipper choice

`journald` is set to RAM-only (`Storage=volatile`) so the boot media takes no log writes. One of three shippers carries logs off the box:

| Shipper | Speaks | Best fit |
|---|---|---|
| `rsyslog` (default) | syslog UDP/TCP/TLS, RELP | ESXi migrants, Graylog, Splunk syslog input, anything legacy |
| `systemd-journal-upload` | journal-export over HTTPS to `systemd-journal-remote` | Green-field setups with a journal-remote receiver |
| `fluent-bit` | journald → syslog/Loki/Elasticsearch/etc. | Modern observability stacks |

`systemd-journal-upload` is **not** interoperable with Graylog/Splunk/rsyslog — its receiver must be `systemd-journal-remote`. Pick `rsyslog` if you have any other syslog endpoint.

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
  usr/local/bin/veyage-diag  Boot-time mount-topology dump (init=… debug)
out/                       Build artifacts (gitignored)
  rootfs.squashfs          The read-only root layer
  vmlinuz, initrd.img      Extracted from the chroot for direct kernel boot
  veyage.img               Bootable UEFI disk image (GPT: ESP + rootfs + overlay)
```

## Disk image layout

The `veyage.img` produced by `build.sh` is GPT-partitioned for UEFI:

| # | Type | Size | Notes |
|---|---|---|---|
| 1 | EFI System (FAT32, label `EFI`) | 128 MB | `BOOTX64.EFI` (self-contained, built with `grub-mkstandalone`), `vmlinuz`, `initrd.img` |
| 2 | rootfs (raw squashfs) | sized to fit | the read-only root, mounted by the kernel at boot |
| 3 | overlay (f2fs, label `overlay`) | 256 MB initial; resized to fill device on first boot | the overlay upper layer — captures every persistent write |

## Documentation

- [docs/architecture.md](docs/architecture.md) — settled design decisions (RO model, overlayroot patch rationale, UEFI boot path, GPT layout, write boundaries).
- [docs/roadmap.md](docs/roadmap.md) — phase-by-phase plan with current status. Read this if you want to know what's done and what's next.
- [docs/build-internals.md](docs/build-internals.md) — non-obvious gotchas with reasons (required package rationale, the overlayroot patch, LXC build env quirks). Read this before changing anything that touches the chroot, the initramfs, loop devices, or `/dev` handling.

## License

[AGPL-3.0-or-later](LICENSE), matching Proxmox VE's license.

## Acknowledgments

Voyage Linux for the original idea of a tight, read-only Debian on flash media.
