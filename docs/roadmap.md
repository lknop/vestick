# VEyage roadmap

Phase-by-phase plan with current status. Update **after** each milestone is committed.

## Status snapshot (2026-05-06)

- Phase 1 (Debian base squashfs build): ✅ done
- Phase 2 (kernel + initramfs + read-only root via overlayroot): ✅ done
- Phase 3 (UEFI bootable disk image): ✅ done
- Phase 4 (state-partition wiring + auto-resize): 🚧 in progress
- Phase 5 (Proxmox VE layer): not started
- Phase 6 (USB-stick deploy + real hardware test): not started
- Phase 7 (size reduction): not started
- Phase 8 (CI / GitHub Actions reproducible build): not started

## Phase 1 — Debian base squashfs

Done in `b70ce65`. `INCLUDE_PROXMOX=0 ./build.sh` produces an 86 MB squashfs of Debian Trixie minbase + `base.list` + a logging shipper. No kernel; not bootable on its own. Used as the foundation for later phases.

## Phase 2 — Kernel + RO root

Done in `b888ccf`. Adds `linux-image-amd64`, `systemd-sysv`, `dbus`, `overlayroot`, `e2fsprogs`, `busybox`. Patches overlayroot's init-bottom hook (see `docs/architecture.md`). Pre-generates SSH host keys at build time. Exports `vmlinuz` and `initrd.img` to `out/` for direct kernel boot. `MODE=direct ./test-vm.sh` boots end-to-end.

## Phase 3 — UEFI disk image

Done in `b888ccf`. `build.sh::build_image` produces `out/veyage.img`: GPT with ESP + raw squashfs partition + ext4 state partition. Self-contained `BOOTX64.EFI` built via `grub-mkstandalone`. `MODE=image ./test-vm.sh` (default) boots via OVMF.

## Phase 4 — State partition wiring + auto-resize 🚧

**Goal:** the ext4 state partition is created today but nothing uses it. Wire it up so persistent state survives reboots, and grow it to fill the actual disk on first boot (so we can `dd` a small image to a large USB).

**Sub-tasks:**

1. **Mount unit** `mnt-state.mount` — mounts `/dev/disk/by-label/state` at `/mnt/state` early. Needs `ConditionPathExists` so it skips cleanly if the partition is absent.
2. **First-boot resize** — `growpart` + `resize2fs` to extend the state partition to fill the underlying disk. Run *before* `mnt-state.mount`. Adds `cloud-guest-utils` (provides `growpart`) to `base.list`.
3. **First-boot init service** `veyage-state.service` — populates `/mnt/state` skeleton from squashfs the first time, regenerates per-host SSH keys (replacing the build-time keys), then bind-mounts persisted paths over the running rootfs every boot. Marker file `/mnt/state/.veyage-initialized` gates the init step.
4. **Initial bind set:** `/etc/network`, `/etc/ssh`, `/var/lib/pve-cluster`, `/var/lib/rrdcached`. The Proxmox-specific paths only bind when their target exists, so this works pre-Phase-5 without breaking.

**Acceptance:** boot the image → reboot → SSH host key fingerprint is the same on second boot, fresh log says "veyage-state: bound …" lines on first boot only.

**Why before Proxmox:** Proxmox's `pve-cluster.service` writes config to `/var/lib/pve-cluster/`. Without persistence, every reboot wipes it and the cluster forgets itself. Doing state wiring first means Phase 5's Proxmox install just works.

## Phase 5 — Proxmox VE layer

**Goal:** `INCLUDE_PROXMOX=1 ./build.sh` produces an image with Proxmox installed and the web UI / API up after first boot.

**Sub-tasks:**

1. `configure_apt`: add Proxmox apt repo (`download.proxmox.com/debian/pve trixie pve-no-subscription`) and the GPG signing key. Repo URL and key are fetched at build time, never bundled.
2. `install_packages`: `proxmox.list` (already drafted) gets installed when `INCLUDE_PROXMOX=1`. Includes `proxmox-ve`, `proxmox-default-kernel` (replaces `linux-image-amd64`), `lvm2`, `thin-provisioning-tools`, `open-iscsi`, `postfix`.
3. State binds expand: add `/var/lib/pve-cluster`, `/var/lib/rrdcached`, `/etc/pve` (FUSE-mounted from `/var/lib/pve-cluster`).
4. systemd ordering: `pve-cluster.service` etc. must be `After=veyage-state.service`.
5. Initial config: blank `/etc/network/interfaces` with a sane `vmbr0` template, `/etc/hostname` from kernel cmdline or DHCP, root password set via cloud-init or first-boot prompt.
6. Verify: boot the image, log in, `pvesh get /version` returns sane data, `https://<ip>:8006` shows the web UI.

**Open questions:**
- Stay with Debian kernel (boots Proxmox userspace) for first iteration, or jump straight to `proxmox-default-kernel`? Proxmox kernel adds ZFS support and a few KVM/AppArmor patches.
- Postfix vs nullmailer for outgoing notification mail? Proxmox recommends postfix; nullmailer is smaller.

## Phase 6 — USB-stick deploy + hardware test

**Goal:** confirm the image boots on real hardware (not just QEMU).

**Sub-tasks:**
1. Document `dd if=out/veyage.img of=/dev/sdX bs=4M status=progress conv=fsync` for write to USB.
2. Boot a physical machine from the USB; verify state-partition resize fires; verify Proxmox web UI reachable.
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

**Goal:** every push triggers a from-scratch build on a clean amd64 runner; the produced `veyage.img` becomes a release artifact.

**Sub-tasks:**
1. `.github/workflows/build.yml` using the `ubuntu-24.04` runner.
2. Enable nested virtualization for KVM-accelerated test boot (or accept TCG slowness).
3. Run `./test-vm.sh` to verify the produced image at least reaches the login prompt.
4. Publish `out/veyage.img` and `SHA256SUMS` to a GitHub Release on tagged commits.
5. Publish `INCLUDE_PROXMOX=1` and `INCLUDE_PROXMOX=0` variants separately.

## Cross-cutting backlog (any phase)

- Add `LOG_SHIPPER=vector` profile (currently `fluent-bit` covers the modern stack)
- Network configuration: ship a default `/etc/network/interfaces` skeleton with `vmbr0` for Proxmox, instead of the empty default
- Unprivileged builds: investigate whether the build can run unprivileged given `unshare`/`fakeroot`
- Secure Boot signing: longer-term, sign GRUB and kernel with a project key so SB users don't have to disable it
