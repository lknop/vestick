# Build internals & gotchas

Non-obvious things the build pipeline relies on, with the reasons. Read this before changing anything that touches the chroot, the initramfs, or `/dev` handling.

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

`/usr/share/initramfs-tools/scripts/init-bottom/overlayroot` contains:

```sh
if [ "${cmdline_ro}" = "true" ]; then
    mount -o remount,ro "$ROOTMNT" || log_fail "..."
fi
```

Squashfs requires `ro` on the kernel cmdline. The unpatched hook propagates that to the overlay, locking the entire running system read-only — every unit using `StateDirectory=` or `LogsDirectory=` (chrony, systemd-logind, sshd-keygen, and most things under Proxmox) fails with EROFS. `build.sh::configure_readonly` sed-removes this line. **Do not revert without an alternative.**

If you're upgrading overlayroot and the patch's sed match changes, refresh the sed expression. Test by booting the image and confirming `mount` shows the overlay options *without* `ro`. The substring trick (`ro` at end of cmdline) does not work — overlayroot's check has additional logic that catches it.

## SSH host keys

Stock Debian's `openssh-server` postinst runs `ssh-keygen -A` at install time. In our build that lands in the chroot, so the keys would get baked into the squashfs — every dd'd device would ship identical keys.

The fix:

- **Build-time:** `configure_readonly` deletes `/etc/ssh/ssh_host_*` from the chroot. The squashfs ships with no keys.
- **Runtime:** `overlay/etc/systemd/system/vestick-sshkeys.service` runs at `sysinit.target`, before `ssh.service` and `ssh.socket`, and calls `ssh-keygen -A`. It's idempotent — only creates keys that don't exist — so it does the work once on first boot and is a no-op forever after. `/etc/ssh` is on the persistent f2fs overlay, so the keys persist across reboots.

It's a standalone service rather than an `ssh.service` drop-in for two reasons: socket-activated ssh wouldn't generate keys until the first incoming connection (too late), and stock `ssh.service` runs `sshd -t` as its own `ExecStartPre` which can fail when keys are missing, blocking any subsequent `ExecStartPre` from running.

## Boot-time debugging

`/usr/local/bin/vestick-diag` is shipped in the squashfs. Boot with `init=/usr/local/bin/vestick-diag` on the kernel cmdline to get a pre-systemd dump of:

- mount table
- `/proc/filesystems`
- listings of `/`, `/var`, `/var/lib`
- writability tests for `/`, `/etc`, `/var`, `/var/lib`, `/var/log`

Useful when "service X fails with EROFS" but you don't know which path is actually read-only or whether the overlay is mounted at all. Halts the system after 30 s.
