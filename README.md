# VEyage

Minimal Debian Trixie image with a read-only root filesystem, designed as a base for Proxmox VE running from a USB stick or SD card.

> **Status (`voyage-flavor` branch).** Boots end-to-end in QEMU under UEFI. Full Proxmox stack — `pmxcfs`, `pveproxy`, `pvedaemon`, `pvestatd`, `pvescheduler`, `pve-firewall` — comes up clean on a `ro`-mounted root: `systemctl is-system-running` returns `running`, the failed-units list is empty, and the journal contains zero "Read-only file system" errors. Steady-state writes hit only the dedicated `/var/lib/pve-cluster` ext4 partition (Proxmox cluster state, by design) and `/var/lib/lxcfs` (FUSE-virtual, no real I/O).

## What this is

A small build pipeline that produces a Debian 13 (Trixie) image with:

- **Read-only root, normal ext4** — the rootfs is just a regular ext4 filesystem mounted `ro`. To make persistent changes the operator runs `remountrw`, edits, then `remountro` (or lets the auto-revert timer flip it back after 10 min). No squashfs, no overlayfs, no separate state partition with bind mounts.
- **Curated minimal package set** — `debootstrap --variant=minbase` plus a hand-picked list, installed with `--no-install-recommends`. No `man-db`, no `cron`, no `os-prober`, no `popularity-contest`.
- **Proxmox VE on top** — fetched from the Proxmox `pve-no-subscription` apt repository at build time (not bundled in this repo).
- **Remote logging by default** — `journald` runs with `Storage=volatile`; logs leave the box via a build-time-selectable shipper (`rsyslog` forwarding, `systemd-journal-upload`, or Fluent Bit).

This branch went back to the original [Voyage Linux](http://svn.voyage.hk/repos/voyage/trunk/) mental model: the system is read-only normally, the operator flips it briefly to make changes. Compared to the `main` branch's squashfs+overlayroot design, this is roughly one-fifth the project-specific code, has normal-Debian operator UX (`apt upgrade` works in place during a rw window), and avoids the per-path "did I add it to PERSIST_PATHS?" surprise. It trades away atomic upgrades and squashfs's read-perf benefit on slow flash. See [docs/voyage-flavor.md](docs/voyage-flavor.md) for the full tradeoff matrix.

## What this is not

VEyage is an **independent project**. It is not affiliated with, endorsed by, or sponsored by Proxmox Server Solutions GmbH. "Proxmox" and the Proxmox logo are trademarks of Proxmox Server Solutions GmbH. This repository contains build scripts and configuration only — Proxmox packages are downloaded from the Proxmox apt repository during the build, not redistributed here.

The name "VEyage" is a nod to the long-defunct Voyage Linux project, which inspired the read-only-root and curated-package approach. No Voyage code is used.

## Operator workflow

```sh
# Make a config change
remountrw                # flip / to rw, arms a 10-min auto-revert timer
vi /etc/network/interfaces
remountro                # cancel timer, flip / back to ro
systemctl restart networking

# Apt upgrade
remountrw
apt update && apt upgrade -y
remountro
reboot                   # changes persist
```

If the operator forgets `remountro`, a one-shot systemd timer flips `/` back to `ro` automatically after 10 min of unattended rw — bounding power-loss exposure to that window. The timeout is overridable via `REMOUNT_RW_TIMEOUT=<systemd time spec>` in the `remountrw` invocation.

## Architecture at a glance

| Layer | Mount | Notes |
|---|---|---|
| ext4 (ro) | `/` | Mounted `ro,errors=remount-ro,noatime` by default. `remountrw` flips on demand. |
| ext4 (rw) | `/var/lib/pve-cluster` | Dedicated 256 MB partition. pmxcfs's sqlite cluster store — must be writable. |
| tmpfs | `/var/lib/{systemd,rrdcached,pve-manager,vz,postfix}` | Service runtime state that's recreatable on each boot. |
| tmpfs | `/var/{cache,spool/postfix,log,tmp}`, `/tmp` | Caches and ephemeral data. `journald` is `Storage=volatile`. |
| tmpfs | `/etc/hosts` (bind-mount) | Generated each boot from current primary IP, so pmxcfs's hostname resolution works for both static-IP and DHCP hosts without on-flash writes. |

VM and container storage should live **off the boot media** (separate disk, NFS, iSCSI, Ceph, etc.) — `/var/lib/vz` is a tmpfs placeholder; it exists so `pvestatd`'s probes succeed but it's not real persistent storage. Reconfigure `/etc/pve/storage.cfg` (during a `remountrw` window or via the Proxmox UI, since `/etc/pve` is the FUSE mount and always writable) to point at real storage.

## Build host requirements

- Debian or Ubuntu on **amd64**. Proxmox VE has no aarch64 build target, so the build host (or a VM/LXC on it) must be x86_64. macOS aarch64 hosts can use a Lima x86_64 VM (slow, QEMU-emulated) or an amd64 LXC/VM elsewhere.
- Root (or sudo) access.
- ~12 GB free disk for the build chroot and output image (the default 8 GB image plus the chroot under `WORK`).
- Build packages: `debootstrap rsync curl gpg ca-certificates dosfstools qemu-utils gdisk grub-efi-amd64-bin ovmf`.
- **Loop devices and KVM** must be available. Inside a Proxmox LXC build host, this means passing through `/dev/loop[0-N]`, `/dev/loop-control`, `/dev/kvm` and the relevant cgroup permissions.

## Quickstart

```sh
sudo INCLUDE_PROXMOX=1 ./build.sh    # full Proxmox build (default)
./test-vm.sh                         # boots out/veyage.img in QEMU under UEFI
```

`./test-vm.sh` runs a full UEFI boot of `out/veyage.img` through GRUB. The QEMU command line includes a virtio-net NIC by default so the network stack actually has something to bring up.

Environment variables (build):

| Variable | Default | Notes |
|---|---|---|
| `INCLUDE_PROXMOX` | `1` | `0` for a Debian-only build (no Proxmox repo, Debian kernel) |
| `LOG_SHIPPER` | `rsyslog` | `rsyslog` \| `journal-upload` \| `fluent-bit` \| `none` |
| `SUITE` | `trixie` | Debian release codename |
| `MIRROR` | `http://deb.debian.org/debian` | Debian apt mirror |
| `PVE_MIRROR` | `http://download.proxmox.com/debian/pve` | Proxmox repo |
| `IMG_MB` | `8192` | Total image size in MB. ESP+pmxcfs are fixed (128 + 256), root takes the rest. PVE build needs ~3.5 GB unpacked plus apt-upgrade headroom; Debian-only fits in much less but the default keeps both flavors on one knob. |
| `WORK` | `./work` | Build chroot location |
| `OUT` | `./out` | Output image location |

## First boot

On the first boot of each freshly-`dd`'d image, three `oneshot` services run inside an automatic `remountrw` window before the rootfs is flipped back to `ro`:

1. **`veyage-firstboot`** — runs `systemd-firstboot --prompt-hostname --prompt-root-password` against the console, then generates `/root/.ssh/id_rsa` (Proxmox's `pvecm updatecerts` needs it on every boot; we generate per-machine here so we don't ship a single shared key). Sentinel `/var/lib/veyage/firstboot-done` gates re-runs.
2. **`veyage-network-init`** — interactive picker that lists physical interfaces and writes a `vmbr0` stanza into `/etc/network/interfaces`, bridging the chosen NIC. Skipped if `vmbr0` is already declared.
3. **`veyage-resize-root`** — `growpart` + `resize2fs` so the rootfs fills whatever larger device the image was `dd`'d to. Sentinel `/var/lib/veyage/resized` gates re-runs.

After firstboot, on every subsequent boot, **`veyage-hosts-init`** runs as a regular oneshot: it asks the kernel routing table for the current primary IPv4 address (works for both static and DHCP), writes `/run/hosts`, and bind-mounts that over `/etc/hosts`. This satisfies pmxcfs's "must resolve my hostname to a non-loopback IP" requirement without writing to the read-only `/etc`.

## Prebuilt images

`.github/workflows/build.yml` builds both the Debian-only and the `INCLUDE_PROXMOX=1` variants on a fresh `ubuntu-24.04` runner and uploads `veyage-debian.img` / `veyage-pve.img` (plus `.sha256`) as workflow artifacts (14-day retention). Triggers: pushes to `main`, tags `v*`, every PR, and manual `workflow_dispatch`.

Pushing a tag `v*` additionally creates a GitHub Release with both images attached (subject to GitHub's 2 GB per-file cap). Useful for `dd`-to-USB without setting up a build host:

```sh
gh release download vX.Y.Z --pattern 'veyage-pve.img*'
sha256sum -c veyage-pve.img.sha256
sudo dd if=veyage-pve.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## Logging shipper choice

`journald` is set to `Storage=volatile` so the boot media takes no log writes. One of three shippers carries logs off the box:

| Shipper | Speaks | Best fit |
|---|---|---|
| `rsyslog` (default) | syslog UDP/TCP/TLS, RELP | ESXi migrants, Graylog, Splunk syslog input, anything legacy |
| `systemd-journal-upload` | journal-export over HTTPS to `systemd-journal-remote` | Green-field setups with a journal-remote receiver |
| `fluent-bit` | journald → syslog/Loki/Elasticsearch/etc. | Modern observability stacks |

`systemd-journal-upload` is **not** interoperable with Graylog/Splunk/rsyslog — its receiver must be `systemd-journal-remote`. Pick `rsyslog` if you have any other syslog endpoint.

## Disk image layout

The `veyage.img` produced by `build.sh` is GPT-partitioned for UEFI:

| # | Type | Size | Notes |
|---|---|---|---|
| 1 | EFI System (FAT32, label `EFI`) | 128 MB | `BOOTX64.EFI` (built with `grub-install --removable --modules=...`), kernel + initrd live on partition 2 in `/boot/`. |
| 2 | rootfs (ext4, label `rootfs`) | sized to fit | The read-only root. Mounted `ro,errors=remount-ro,noatime` per `/etc/fstab`. |
| 3 | pmxcfs (ext4, label `pmxcfs`) | 256 MB | Mounted at `/var/lib/pve-cluster`, the only on-disk persistent state pmxcfs writes during normal operation. |

GRUB's `BOOTX64.EFI` is built with all the modules it needs (`part_gpt fat ext2 normal linux configfile search search_fs_uuid …`) embedded so it can chainload the kernel without a separate `/EFI/<id>/x86_64-efi/` module directory — boots cleanly on any UEFI firmware after a `dd` to a fresh device.

## Layout

```
build.sh                                Top-level build script
test-vm.sh                              Boot the built image in QEMU (UEFI / direct kernel)
packages/                               Package lists (one per line, `#` for comments)
  base.list                             Minimal Debian additions on top of minbase
  kernel-debian.list                    Debian kernel (used when INCLUDE_PROXMOX=0)
  proxmox.list                          Proxmox VE essentials (used when INCLUDE_PROXMOX=1)
  logging-{rsyslog,journal-upload,fluent-bit}.list
overlay/                                Files merged into the rootfs at build time
  etc/systemd/journald.conf.d/
    volatile.conf                       Storage=volatile so logs stay in RAM
  etc/systemd/system/
    veyage-firstboot.service            One-shot wizard: hostname, root pw, ssh-keygen
    veyage-network-init.service         One-shot wizard: pick NIC, write vmbr0 stanza
    veyage-resize-root.service          One-shot: growpart + resize2fs
    veyage-hosts-init.service           Per-boot: write /run/hosts, bind-mount over /etc/hosts
    pve-cluster.service.d/              Drop-in: After=veyage-hosts-init
    pve-firewall.service.d/             Drop-in: clear ExecStartPre (no boot-time alternatives churn)
    pveproxy.service.d/                 Drop-in: clear ExecStartPost (no boot-time pveupdate)
  etc/tmpfiles.d/
    veyage-postfix.conf                 chown postfix:postfix on tmpfs /var/lib/postfix
    veyage-pve-vz.conf                  Seed /var/lib/vz subdirs (dump, images, template/...)
    veyage-rrdcached.conf               Seed /var/lib/rrdcached/db/pve-{node,storage,vm,ct}-9.0
  usr/local/sbin/
    remountrw / remountro               The rw/ro switch
    veyage-firstboot                    Runs systemd-firstboot + ssh-keygen
    veyage-network-init                 Interactive vmbr0 picker
    veyage-resize-root                  growpart + resize2fs
    veyage-hosts-init                   Detect primary IP, write /run/hosts, bind over /etc/hosts
out/                                    Build artifacts (gitignored)
  veyage.img                            Bootable UEFI disk image (GPT: ESP + rootfs + pmxcfs)
```

## Documentation

- [docs/voyage-flavor.md](docs/voyage-flavor.md) — design rationale for this branch and the tradeoff matrix vs. the `main` squashfs+overlay design.
- [docs/architecture.md](docs/architecture.md) — settled design decisions on the original (squashfs+overlay) branch. Reference for context, but most of it doesn't apply here.
- [docs/build-internals.md](docs/build-internals.md) — non-obvious gotchas with reasons (LXC build env quirks, the `proxmox-boot-tool` chroot bind, GRUB `--removable` modules). Read this before changing anything that touches the chroot, the initramfs, loop devices, or `/dev` handling.
- [docs/roadmap.md](docs/roadmap.md) — phase-by-phase plan with current status (mostly tracks the `main` branch).

## License

[AGPL-3.0-or-later](LICENSE), matching Proxmox VE's license.

## Acknowledgments

Voyage Linux for the original idea of a tight, read-only Debian on flash media — and for the `remountrw` / `remountro` ergonomics this branch deliberately mimics.
