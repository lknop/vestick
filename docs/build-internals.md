# Build internals & gotchas

Non-obvious things the build pipeline relies on, with the reasons. Read this before changing anything that touches the chroot, the initramfs, the loop devices, or `/dev` handling.

## Required packages and *why*

`packages/base.list` includes some entries that look weird without context:

| Package | Reason |
|---|---|
| `systemd-sysv` | minbase ships no init; without this, `run-init` errors `/sbin/init: No such file` and the kernel drops to the initramfs recovery shell. |
| `dbus` | `systemd-logind` depends on it; without it, logind won't activate. |
| `overlayroot` | The RW-overlay-over-RO-squashfs mechanism. Adds initramfs init-bottom hook. |
| `e2fsprogs` | overlayroot's initramfs hook unconditionally `copy_exec /sbin/mke2fs`. `mke2fs` is in `e2fsprogs`, which Proxmox's package set has as a `Recommends:` — `--no-install-recommends` drops it. Without `e2fsprogs`, the hook fails with `failed with return 1` and `update-initramfs -c -k <ver>` aborts during kernel install. |
| `busybox` | overlayroot's `init-bottom` script uses `grep`. Without `busybox` installed, mkinitramfs picks `klibc-utils` (klibc has no grep). The hook silently fails its overlay-availability check and falls through to `Failure: overlayroot: Unable to find a driver`. |

## The overlayroot patch

`/usr/share/initramfs-tools/scripts/init-bottom/overlayroot` line ~867:

```sh
if [ "${cmdline_ro}" = "true" ]; then
    mount -o remount,ro "$ROOTMNT" || log_fail "..."
fi
```

This is the *single most important workaround* in the build. The kernel cmdline has `ro` because squashfs requires it at mount time. The unpatched script then forwards that `ro` flag to the overlay, locking the *entire running system* in read-only mode. systemd unit setup that uses `StateDirectory=` or `LogsDirectory=` (chrony, systemd-logind, sshd-keygen, dozens more under Proxmox) all fail with `EROFS`. The system limps to a login prompt with most services dead.

`build.sh::configure_readonly` sed-removes this line. The substring trick (`ro` at end of cmdline so `${cmdline#* ro }` doesn't match the trailing-space pattern) does *not* work — overlayroot's check has additional logic that catches it.

If you're upgrading overlayroot and the patch's sed match changes, you'll need to refresh the sed expression. Test by booting the image and confirming `mount` shows the overlay options *without* `ro`.

## SSH host keys

Stock Debian's `openssh-server` postinst runs `ssh-keygen -A` at install time. In our build that lands in the chroot, so the keys would get baked into the squashfs and every dd'd device would ship identical keys (security problem).

The fix:

- **Build-time:** `configure_readonly` deletes `/etc/ssh/ssh_host_*` from the chroot. The squashfs ships with no keys.
- **Runtime:** `overlay/etc/systemd/system/ssh.service.d/veyage-keygen.conf` adds `ExecStartPre=/usr/bin/ssh-keygen -A` to `ssh.service`. `ssh-keygen -A` is idempotent — it only creates the keys that don't exist — so it runs once on first boot, and is a no-op on every subsequent start. `/etc/ssh` is on the persistent overlay, so the keys persist.

Don't be tempted to delete keys without the drop-in: stock Debian has no auto-regen-if-missing logic, and `ssh.service` would just fail to start.

## LXC build environment quirks

The build runs in a privileged Proxmox LXC. Many things "just work" on bare metal but not here. Workarounds, with reasons:

### 1. `losetup -P` doesn't populate `/dev/loopNpM`

The container's kernel won't expose partition device nodes for loop devices, even with the loop driver and `/dev/loop[0-N]` passed through.

**Workaround:** offset-based loop devices. For each partition, `losetup --offset $((first_sector*512)) --sizelimit $((sectors*512)) -f --show $img` returns a loop device pointing at that partition's bytes. `mkfs` / `dd` / `mount` work on it. See `build.sh::build_image` `_part_loop()` helper.

### 2. Device-mapper is blocked

`kpartx -a /dev/loop0` fails with `/dev/mapper/control: open failed: Operation not permitted`. So the alternative `kpartx`-based partition-mapping approach is also out.

### 2a. After LXC restart, passthrough device nodes come back as empty regular files

After rebooting (or restarting) the LXC, `/dev/loop[0-9]` and `/dev/kvm` may show up as empty regular files (`-rw-rw---- 0 bytes`) instead of block / character device nodes. The host's device passthrough wasn't reattached. Symptoms:

- `losetup` fails with `Inappropriate ioctl for device`
- `qemu -enable-kvm` fails with `failed to initialize kvm: Inappropriate ioctl for device`

Recovery (run on the LXC as root):
```
for i in 0 1 2 3 4 5 6 7; do rm -f /dev/loop$i; mknod /dev/loop$i b 7 $i; chmod 660 /dev/loop$i; done
rm -f /dev/loop-control; mknod /dev/loop-control c 10 237; chmod 660 /dev/loop-control
rm -f /dev/kvm; mknod /dev/kvm c 10 232; chmod 666 /dev/kvm
```

The right *durable* fix is on the Proxmox host running the LXC: ensure the device-passthrough rules survive container restart. Until then, this snippet recovers a working build environment in seconds.

### 3. `/dev` mishaps from recursive bind + umount

When the build chroot's `/dev` is bound from the LXC's `/dev` (`mount --rbind /dev`) and later `umount`d, the operation can damage the LXC's *own* `/dev`. After this, `/dev/fd` (a symlink to `/proc/self/fd`) and `/dev/pts` go missing on the host LXC. Symptoms:

- bash process substitution `<( ... )` fails: `/dev/fd/63: No such file or directory`
- apt's pty allocations log: `unlockpt (22: Invalid argument)`

Workarounds:
- Always pair `mount --rbind /dev` with `mount --make-rslave` on the chroot's `/dev`
- Use `umount -Rl` (lazy recursive) for chroot teardown — `umount -R` alone leaves stuck mounts that block subsequent `rm -rf "$CHROOT"`
- If `/dev/fd` is missing on the LXC: `ln -sf /proc/self/fd /dev/fd`
- Avoid `<( ... )` in build scripts — read files directly, so the build tolerates a half-broken `/dev`

### 4. `update_initramfs=no` only blocks `-u`, not `-c`

Setting `update_initramfs=no` in `/etc/initramfs-tools/update-initramfs.conf` does *not* prevent `update-initramfs -c -k <ver>` from running. The check only fires inside the `update()` function. Kernel postinst scripts call `-c` (create) on first install, so they bypass the suppression.

We don't actually need to suppress it — once `e2fsprogs` and `busybox` are installed, the overlayroot hook works under `update-initramfs -c -k all`. So we just let the kernel postinst trigger run normally.

### 5. `grub-install --removable` is unreliable

It produces a thin BOOTX64.EFI that searches the ESP for modules at runtime. Even with `--modules='part_gpt fat'`, those modules don't get reliably embedded — they end up as separate `.mod` files in `/boot/grub/x86_64-efi/`, and the runtime path that BOOTX64.EFI looks at doesn't include that location with our layout.

**Use `grub-mkstandalone --format=x86_64-efi --output=BOOTX64.EFI --modules='...' "boot/grub/grub.cfg=$cfg_path"` instead.** It builds a self-contained binary with everything embedded; the ESP needs nothing else.

The embedded `grub.cfg` runs in a memdisk-rooted environment, so add `search --no-floppy --label EFI --set=root` at the top to pivot to the real ESP before loading the kernel.

### 6. Required image-build packages

Beyond the standard build deps, the LXC needs: `gdisk` (sgdisk), `dosfstools` (mkfs.fat), `grub-pc-bin` and `grub-efi-amd64-bin` (GRUB modules — both target sets), `ovmf` (UEFI firmware for QEMU testing), `cloud-guest-utils` (growpart for first-boot resize).

## rtk and remote shell scripts

The user's environment has the `rtk` (Rust Token Killer) wrapper around CLI commands. When invoking `ssh host '<script>'` directly, the *local* rtk hook rewrites command names *inside the script string* (e.g. `grep` → `rtk grep`), which then fail on the remote host because rtk isn't installed there.

**Always wrap as `rtk proxy ssh host '<script>'`** when sending shell commands to a remote. Same for `rsync` (the local invocation gets wrapped) when output looks suspiciously truncated.

## Ownership cosmetics

Files synced from macOS (uid 501, gid `staff`) preserve those numeric ids in the chroot, then in the squashfs. They're cosmetic but show up in `ls -l` inside the booted system. To clean them up before squashing, `chown -R root:root $CHROOT/usr $CHROOT/etc` could be added, but watch for legitimate non-root ownership (e.g. `/var/lib/chrony` owned by `_chrony`).

## Boot-time debugging

`/usr/local/bin/veyage-diag` is shipped in the squashfs. Boot with `init=/usr/local/bin/veyage-diag` on the kernel cmdline to get a pre-systemd dump of:
- mount table
- `/proc/filesystems`
- listings of `/`, `/var`, `/var/lib`
- writability tests for `/`, `/etc`, `/var`, `/var/lib`, `/var/log`

Useful when "service X fails with EROFS" but you don't know which path is actually read-only or whether the overlay is mounted at all. Halts the system after 30 s.
