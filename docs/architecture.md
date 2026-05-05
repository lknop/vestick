# VEyage architecture

Settled design decisions for the VEyage build, in one place. Update this when you change direction; do not let it lie about what the code does.

## Goal

A minimal Debian Trixie image with a read-only root filesystem, designed as a base for Proxmox VE running from USB stick or SD card. Inspired by Voyage Linux in *spirit only* (curated package set + clear write boundaries) — none of Voyage's runtime mechanics survive.

## Runtime model

- **Read-only squashfs** as the lower layer of the root filesystem (`/`).
- **tmpfs upper** stacked via `overlayroot` (Debian package), mounted by an initramfs `init-bottom` hook before `pivot_root`. Result: `/` looks fully writable to PID 1, but writes go to RAM and vanish on reboot.
- **Persistent ext4 state partition** mounted at `/mnt/state`, with selected paths bind-mounted into the rootfs so they survive reboots (network config, SSH host keys, Proxmox cluster state, etc.).
- **journald with `Storage=volatile`** — logs live in RAM and are forwarded off-box via a chosen shipper (rsyslog default).

`systemd.volatile=overlay` was tried first and **does not work for a squashfs root** — systemd-volatile-root can't remount-overlay a squashfs from PID 1. We use overlayroot's initramfs-time approach instead.

### Why overlayroot, with a patch

Overlayroot's `init-bottom` hook contains:
```sh
if [ "${cmdline_ro}" = "true" ]; then
    mount -o remount,ro "$ROOTMNT"
fi
```
Squashfs *requires* the kernel cmdline `ro` flag at mount time. The unpatched hook then forwards `ro` to the overlay, locking the running system in read-only mode. Every systemd unit using `StateDirectory=` or `LogsDirectory=` (chrony, systemd-logind, sshd-keygen, …) fails with EROFS and the system limps along with no logind, no SSH, no NTP.

`build.sh::configure_readonly` sed-removes that line. **This patch is essential — do not undo it without an alternative.**

## Boot path (UEFI only)

| Stage | What happens |
|---|---|
| UEFI firmware | finds `/EFI/BOOT/BOOTX64.EFI` on the FAT32 ESP (label `EFI`) |
| GRUB | self-contained binary built with `grub-mkstandalone` (modules + `grub.cfg` baked in); `search --label EFI --set=root` to pivot from its memdisk to the real ESP |
| Linux kernel | EFI stub-loaded with cmdline `root=PARTUUID=… rootfstype=squashfs ro …` |
| initramfs | mounts the squashfs via the `root=` PARTUUID, then `init-bottom/overlayroot` stacks tmpfs over it |
| systemd PID 1 | starts in the overlay-rooted environment; `mnt-state.mount` mounts state at `/mnt/state`; `veyage-state.service` does first-boot init + bind mounts; rest of multi-user starts |

BIOS boot is intentionally not supported — modern Proxmox-target hardware is UEFI.

`grub-install --removable` was tried and produces a thin BOOTX64.EFI that hunts for modules on the ESP at runtime — it does not reliably embed `--modules=`. `grub-mkstandalone` is the better choice.

## Disk image layout

GPT, partitioned by `sgdisk`:

| # | Type | Label | Size | Contents |
|---|---|---|---|---|
| 1 | EFI System (FAT32) | `EFI` | 128 MB | `BOOTX64.EFI`, `vmlinuz`, `initrd.img` |
| 2 | Linux fs (raw squashfs) | `rootfs` | sized to fit | The read-only root layer; mounted by the kernel as squashfs |
| 3 | Linux fs (ext4) | `state` | small initially | Persistent state; **resized on first boot to fill the disk** |

The squashfs partition has no filesystem wrapping it — the squashfs *is* the partition contents. The kernel mounts it directly via `root=PARTUUID=… rootfstype=squashfs`.

## Write boundaries

Three categories of state, with explicit destinations:

| Category | Destination | Examples |
|---|---|---|
| Image-immutable | RO squashfs | `/usr`, `/lib`, kernel, initrd, distro `/etc` defaults |
| Persistent across reboots | ext4 state partition, bind-mounted into rootfs | `/etc/network/`, `/etc/ssh/` (per-host keys), `/var/lib/pve-cluster/`, `/var/lib/rrdcached/`, eventually `/etc/hostname`, `/var/lib/dpkg/`, `/var/lib/apt/` |
| Ephemeral | tmpfs (overlay upper) | `/var/log` (journald `Storage=volatile`), `/tmp`, `/run`, `/var/cache` |

VM and container storage (`/var/lib/vz`) belongs **off the boot media** — separate disk, NFS, iSCSI, Ceph. A USB stick is not the right place for VM disks regardless of how clever the rootfs is.

## Build approach

- **Host:** privileged Proxmox LXC running Debian Trixie with `features: nesting=1,keyctl=1`, plus `/dev/kvm` and `/dev/loop[0-N]` + `/dev/loop-control` passed through.
- **Pipeline:** `debootstrap --variant=minbase` → write apt sources → install packages with `--no-install-recommends` → apply overlay tree → patch overlayroot → `ssh-keygen -A` → `update-initramfs -u -k all` → export kernel/initrd → `mksquashfs` → assemble GPT image with offset-based loop devices → `grub-mkstandalone` BOOTX64.EFI.
- **Two profiles** controlled by `INCLUDE_PROXMOX`:
  - `INCLUDE_PROXMOX=0` (current default for testing) — Debian + `linux-image-amd64`, no Proxmox repo
  - `INCLUDE_PROXMOX=1` (Phase 4, not implemented) — adds Proxmox apt repo + `proxmox-ve` metapackage + `proxmox-default-kernel`

Skip `proxmox-boot-tool` — that's for ZFS-on-root or systemd-boot setups.

## Distribution stance

- The repo contains build scripts and configuration only. Proxmox packages are fetched from `download.proxmox.com` at build time, never bundled.
- Default to the `pve-no-subscription` apt repo. Document how to switch to enterprise.
- Same approach for `non-free-firmware`: fetched from Debian's repo, not bundled.
- Trademark: README must state this is an independent project, not endorsed by Proxmox Server Solutions GmbH. The project name "VEyage" is a homage to Voyage Linux + Proxmox VE; no Proxmox branding is used.

## License

AGPL-3.0-or-later, matching Proxmox VE.
