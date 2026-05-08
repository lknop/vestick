# VEstick roadmap

Phase-by-phase plan with current status. Update **after** each milestone is committed.

## Status snapshot (2026-05-08)

- Phase 1 (Debian base squashfs build): ✅ done
- Phase 2 (kernel + initramfs + read-only root via overlayroot): ✅ done
- Phase 3 (UEFI bootable disk image): ✅ done
- Phase 4 (persistent overlay + first-boot resize + tmpfs volatile): 🟡 implemented, awaiting first end-to-end build/boot validation
- Phase 5 (Proxmox VE layer): 🟡 implemented (apt repo, kernel-export glob, static-IP network wizard, hostname/root-pw wizard); needs re-validation against the overlay layout
- Phase 6 (USB-stick deploy + real hardware test): not started
- Phase 7 (size reduction): not started
- Phase 8 (CI / GitHub Actions reproducible build): 🟡 wired (`.github/workflows/build.yml`); needs first push to verify the runner actually builds successfully

## Phase 1 — Debian base squashfs

`INCLUDE_PROXMOX=0 ./build.sh` produces an 86 MB squashfs of Debian Trixie minbase + `base.list` + a logging shipper. No kernel; not bootable on its own. Used as the foundation for later phases.

## Phase 2 — Kernel + RO root

Adds `linux-image-amd64`, `systemd-sysv`, `dbus`, `overlayroot`, `e2fsprogs`, `f2fs-tools`, `busybox`. Patches overlayroot's init-bottom hook (see `docs/architecture.md`). Pre-generates SSH host keys at build time. Exports `vmlinuz` and `initrd.img` to `out/` for direct kernel boot.

## Phase 3 — UEFI disk image

`build.sh::build_image` produces `out/vestick.img`: GPT with ESP + raw squashfs partition + f2fs overlay partition. Self-contained `BOOTX64.EFI` built via `grub-mkstandalone`. `MODE=image ./test-vm.sh` (default) boots via OVMF.

## Phase 4 — Persistent overlay + first-boot resize + tmpfs volatile

The f2fs partition created in Phase 3 is wired as the overlayfs upper layer (via `overlayroot.conf` `device:dev=LABEL=overlay,fstype=f2fs,mkfs=1`). All persistent writes — config edits, `apt install`, package state, `/etc/network/`, SSH host keys, `/var/lib/pve-cluster/` — land there automatically. `vestick-overlay-resize.service` runs once on first boot to grow the overlay partition + filesystem to fill the actual device. A small curated tmpfs list (`/etc/fstab` in the overlay tree) keeps continuously-rewritten regenerable paths in RAM (`/var/log`, `/var/cache`, `/var/lib/rrdcached`, etc.).

**Acceptance:** boot the image → `df` shows the overlay grown to fill the device → reboot → SSH host key fingerprint is the same on second boot.

**To validate:** end-to-end build + first/second boot of `INCLUDE_PROXMOX=0` and `INCLUDE_PROXMOX=1` against the new layout. The previous round of QEMU acceptance tests was run against an earlier persistence design and is no longer load-bearing.

## Phase 5 — Proxmox VE layer

`INCLUDE_PROXMOX=1 ./build.sh` produces an image with Proxmox installed and the web UI / API up after first boot.

**Sub-tasks:**

1. `configure_apt`: Proxmox apt repo (`download.proxmox.com/debian/pve trixie pve-no-subscription`) and the GPG signing key. Repo URL and key are fetched at build time, not checked into git.
2. `install_packages`: `proxmox.list` adds `proxmox-ve`, `proxmox-default-kernel` (replaces `linux-image-amd64`), `lvm2`, `thin-provisioning-tools`, `open-iscsi`, `postfix`.
3. First-boot wizard: `vestick-firstboot` (hostname + root password + NIC + static IP/CIDR + gateway + DNS; writes `/etc/network/interfaces` and `/etc/hosts` together — same shape as the stock Proxmox installer's network step).
4. SSH host keys: generated on first boot via `ssh.service` ExecStartPre (`ssh-keygen -A`, idempotent); persist on the f2fs overlay.
5. Verify: boot the image, log in, `pvesh get /version` returns sane data, `https://<ip>:8006` shows the web UI, second boot retains the configured hostname/password/network and unique SSH host keys.

**Open questions:**
- Stay with Debian kernel (boots Proxmox userspace) for first iteration, or jump straight to `proxmox-default-kernel`? Proxmox kernel adds ZFS support and a few KVM/AppArmor patches.
- Postfix vs nullmailer for outgoing notification mail? Proxmox recommends postfix; nullmailer is smaller.

## Phase 6 — USB-stick deploy + hardware test

**Goal:** confirm the image boots on real hardware (not just QEMU).

**Sub-tasks:**
1. Document `dd if=out/vestick.img of=/dev/sdX bs=4M status=progress conv=fsync` for write to USB.
2. Boot a physical machine from the USB; verify overlay-partition resize fires; verify Proxmox web UI reachable.
3. Document hardware caveats (UEFI Secure Boot — we don't sign GRUB, so SB must be off).

## Phase 7 — Size reduction

After Proxmox is up, the squashfs will be ~700 MB. Trimming opportunities:
- Remove or replace `postfix` with nullmailer (~30 MB)
- Drop `man-db` if any pulled in via Recommends (we use `--no-install-recommends`, so unlikely)
- Strip unused locales (`localepurge` or `dpkg --no-install-recommends` already saves most)
- Compress squashfs with `-comp zstd -Xcompression-level 22` (default level may be lower)
- Drop `groff-base`, `info`, `bsd-mailx` etc. if pulled
- Audit final package set against `apt-mark showmanual` vs Recommends bloat

## Phase 8 — CI / GitHub Actions

**Goal:** every push triggers a from-scratch build on a clean amd64 runner; the produced `vestick.img` becomes a release artifact.

**Sub-tasks:**
1. `.github/workflows/build.yml` using the `ubuntu-24.04` runner.
2. Enable nested virtualization for KVM-accelerated test boot (or accept TCG slowness).
3. Run `./test-vm.sh` to verify the produced image at least reaches the login prompt.
4. Publish `out/vestick.img` and `SHA256SUMS` to a GitHub Release on tagged commits.
5. Publish `INCLUDE_PROXMOX=1` and `INCLUDE_PROXMOX=0` variants separately.

## Cross-cutting backlog (any phase)

- Add `LOG_SHIPPER=vector` profile (currently `fluent-bit` covers the modern stack)
- Network configuration: ship a default `/etc/network/interfaces` skeleton with `vmbr0` for Proxmox, instead of the empty default
- Unprivileged builds: investigate whether the build can run unprivileged given `unshare`/`fakeroot`
- Secure Boot signing: longer-term, sign GRUB and kernel with a project key so SB users don't have to disable it
