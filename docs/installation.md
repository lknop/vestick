# Installing VEstick

End-to-end recipe to get a VEstick image onto a USB stick or SD card and through first boot.

## Get the image

Either build from this repo (`sudo INCLUDE_PROXMOX=1 ./build.sh` → `out/vestick.img`) or download a CI artifact:

```sh
gh run download <run-id> -n vestick-pve     # latest CI run
# or, from a tagged release:
gh release download vX.Y.Z --pattern 'vestick-pve.img*'
sha256sum -c vestick-pve.img.sha256
```

## Flash to the device

Identify the target device with `lsblk` first — get this wrong and you overwrite the wrong disk. Look for the right size, `RM=1` for removable.

```sh
sudo dd if=vestick-pve.img of=/dev/sdX bs=4M status=progress conv=fsync
```

`conv=fsync` makes `dd` block until the kernel has actually flushed pages to the device. Without it, `dd` reports completion as soon as bytes hit the page cache and the real write finishes later — yanking the stick early gives you a half-written image. If `dd` reports an absurd speed (e.g. multiple GB/s on a USB stick), either you have very fast hardware or the device cache is lying. Verify with a read-back:

```sh
sudo cmp -n 4194304 vestick-pve.img /dev/sdX && echo "first 4 MiB match"
```

## (Optional, recommended on Linux flasher) Pre-grow the partition

The image ships with a 256 MB overlay partition. On first boot, `vestick-overlay-resize.service` extends partition 3 to fill the device, then grows the f2fs filesystem. On some USB-to-SATA bridges this triggers a UAS abort/reset that stalls boot for ~30+ seconds.

If you flash from a Linux host, you can do the resize there instead — the appliance's first boot then has nothing to do and skips the rescan entirely:

```sh
# Right after the dd above, before unplugging the device:
sudo growpart /dev/sdX 3                # extend p3 to disk end
sudo resize.f2fs /dev/sdX3              # grow the f2fs to match
sync && sudo eject /dev/sdX
```

`growpart` is in `cloud-guest-utils`; `resize.f2fs` is in `f2fs-tools`. If the partition is already at the disk end (e.g. you flashed to a stick the same size as the image), `growpart` exits non-zero with `NOCHANGE` — harmless.

This is purely an optimization. Skipping it just means first boot does the resize itself; on enclosures with well-behaved UAS firmware, no one notices.

## Boot

Insert the device into the target machine, set UEFI boot order to it. BIOS-only firmware won't work — VEstick is UEFI-only. Disable UEFI Secure Boot (we don't sign GRUB).

## First boot

One interactive console wizard (`vestick-firstboot`) runs at the local console (HDMI or serial, whichever is `/dev/console`) and prompts for:

1. System hostname.
2. Root password (twice).
3. Management NIC.
4. Static IP/CIDR, gateway, DNS nameserver.

It writes `/etc/hostname`, root's `/etc/shadow` entry, `/etc/network/interfaces` (vmbr0 over the chosen NIC) and `/etc/hosts` together.

Separately, `vestick-sshkeys.service` runs at `sysinit.target` and generates per-host SSH keys before networking and sshd come up — no operator interaction required.

When the wizard completes, networking comes up, ssh starts on port 22, the Proxmox web UI is reachable at `https://<your-ip>:8006/`. Default user is `root` with the password you set.

## Subsequent boots

All wizards are gated by marker files in `/var/lib/vestick/`, so they don't re-run. Boot proceeds straight to multi-user.

## Troubleshooting

**Boot stalls on `pvebanner.service` / `ldconfig.service` for 30+ seconds with `uas_eh_abort_handler` / `uas_eh_device_reset_handler` messages.** Your USB-to-SATA bridge has buggy UAS firmware. At the GRUB menu, press `e`, append `usb-storage.quirks=*:*:u` to the `linux` line, F10 to boot. That disables UAS for all USB-storage devices for this boot. If it works, consider baking it into the image's GRUB cmdline.

**SSH: "Permission denied (publickey,password)" with the password you just set.** Check `journalctl -b -u ssh.service` for `bad ownership or modes for directory /etc` (`StrictModes` rejecting key auth — usually means `/etc` ownership is wrong). On a fresh build this should not happen; if it does, file an issue with the journal output.

**Web UI returns nothing / connection drops.** Check `journalctl -u pveproxy -n 50` for `unable to open log file '/var/log/pveproxy/access.log'` (the directory is recreated on every boot via `tmpfiles.d`; if missing, `mkdir -p /var/log/pveproxy && chown www-data:www-data /var/log/pveproxy && systemctl restart pveproxy`).

**Web UI works locally (`curl https://localhost:8006/`) but not over the network.** Check that `vestick-firstboot` actually completed the network step (`cat /etc/network/interfaces` should have `auto vmbr0`); check that `pveproxy` isn't restricted via `/etc/default/pveproxy`'s `ALLOW_FROM`.

**Partition didn't grow.** Check `systemctl status vestick-overlay-resize` and `df -h /media/root-rw`. If the marker is set and the overlay is small, you may have hit the "skip when at disk end" short-circuit (see the script). If genuinely undersized, delete `/var/lib/vestick/.overlay-resized` and reboot — the service will retry.
