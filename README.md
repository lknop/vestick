# VEyage

Minimal Debian Trixie image with a read-only root filesystem, designed as a base for Proxmox VE running from USB stick or SD card.

> **Status: early development.** The build script is scaffolding; nothing produces a bootable image yet.

## What this is

A small, opinionated build pipeline that produces a Debian 13 (Trixie) image with:

- **Read-only root** — squashfs lower layer plus a tmpfs/overlay upper, so the running system never writes to the boot media outside a small persistent state slice.
- **Curated minimal package set** — `debootstrap --variant=minbase` plus a hand-picked list, installed with `--no-install-recommends`. No `man-db`, no `cron`, no `os-prober`, no `popularity-contest`.
- **Proxmox VE on top** — fetched from the Proxmox `pve-no-subscription` apt repository at build time (not bundled in this repo).
- **Remote logging by default** — `journald` runs with `Storage=volatile`; logs leave the box via a build-time-selectable shipper (rsyslog forwarding, `systemd-journal-upload`, or Fluent Bit).

## What this is not

VEyage is an **independent project**. It is not affiliated with, endorsed by, or sponsored by Proxmox Server Solutions GmbH. "Proxmox" and the Proxmox logo are trademarks of Proxmox Server Solutions GmbH. This repository contains build scripts and configuration only — Proxmox packages are downloaded from the Proxmox apt repository during the build, not redistributed here.

The name "VEyage" is a nod to the long-defunct [Voyage Linux](http://svn.voyage.hk/repos/voyage/trunk/) project, which inspired the read-only-root and curated-package approach. No Voyage code is used.

## Architecture at a glance

| Layer | Mount | Contents |
|---|---|---|
| RO squashfs | `/` (lower) | `/usr`, `/lib`, most of `/etc` — image-immutable |
| RW partition | mounted into `/var/lib/pve-cluster`, `/etc/network`, SSH host keys, etc. | Stateful Proxmox bits, persists across reboots |
| tmpfs | `/var/log`, `/var/cache`, `/tmp`, `/run` | Ephemeral, lost on reboot |

VM and container storage should live **off the boot media** (separate disk, NFS, iSCSI, Ceph) — `/var/lib/vz` on a USB stick is not a good idea regardless of how clever the root filesystem is.

## Build host requirements

- Debian or Ubuntu on **amd64**. Proxmox VE has no aarch64 build target, so the build host (or a VM/LXC on it) must be x86_64. macOS aarch64 hosts can use a Lima x86_64 VM (slow, QEMU-emulated) or an amd64 LXC/VM elsewhere.
- Root (or sudo) access.
- ~5 GB free disk for the build chroot and output image.
- Packages: `debootstrap squashfs-tools qemu-utils dosfstools` (more pinned in the build script).

## Quickstart

```sh
sudo ./build.sh
```

Environment variables:

| Variable | Default | Notes |
|---|---|---|
| `LOG_SHIPPER` | `rsyslog` | `rsyslog` \| `journal-upload` \| `fluent-bit` \| `none` |
| `SUITE` | `trixie` | Debian release codename |
| `MIRROR` | `http://deb.debian.org/debian` | Debian apt mirror |
| `PVE_MIRROR` | `http://download.proxmox.com/debian/pve` | Proxmox repo |
| `WORK` | `./work` | Build chroot location |
| `OUT` | `./out` | Output image location |

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
packages/                  Package lists (one per line, `#` for comments)
  base.list                Minimal Debian additions on top of minbase
  proxmox.list             Proxmox VE essentials
  logging-rsyslog.list     Logging shipper packages (one per profile)
  logging-journal-upload.list
  logging-fluent-bit.list
overlay/                   Files merged into chroot before squashing
  etc/systemd/journald.conf.d/volatile.conf
```

## License

[AGPL-3.0-or-later](LICENSE), matching Proxmox VE's license.

## Acknowledgments

Voyage Linux for the original idea of a tight, read-only Debian on flash media.
