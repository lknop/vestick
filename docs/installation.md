# Installing VEstick

## Get the image

Download the latest release image from the [releases page](../../releases). Verify the checksum:
```sh
sha256sum -c vestick-pve.img.sha256
```

To build locally instead:
```sh
sudo INCLUDE_PROXMOX=1 ./build.sh   # output: out/vestick.img
```

## Flash

**macOS / Windows:** use [balenaEtcher](https://etcher.balena.io/).

**Linux:**
```sh
sudo dd if=vestick-pve.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## (Linux only) Pre-grow the overlay partition

The image ships with a 256 MB overlay partition. On first boot, `vestick-overlay-resize.service` extends it to fill the device. On some USB hardware this triggers a controller stall that drags out first boot by 30+ seconds or requires a reboot to complete.

If you flash from a Linux host, you can do the resize there and skip the first-boot step entirely:

```sh
sudo growpart /dev/sdX 3      # cloud-guest-utils
sudo resize.f2fs /dev/sdX3    # f2fs-tools
sync && sudo eject /dev/sdX
```

If the partition is already at the disk end, `growpart` exits with `NOCHANGE` — harmless.

## Boot

- UEFI only — BIOS firmware is not supported.
- Disable Secure Boot (GRUB is not signed).

## First boot

A console wizard (`vestick-firstboot`) runs once at the local console (HDMI or serial) and prompts for:

1. Hostname
2. Root password
3. Management NIC
4. Static IP/CIDR, gateway, DNS nameserver

It writes `/etc/hostname`, `/etc/shadow`, `/etc/network/interfaces`, and `/etc/hosts` together.

`vestick-sshkeys.service` generates per-host SSH keys automatically — no interaction needed.

When the wizard completes: networking comes up, sshd starts on port 22, Proxmox web UI is available at `https://<your-ip>:8006/`. Log in as `root` with the password you set.

Subsequent boots skip the wizard (gated by marker files in `/var/lib/vestick/`).

## Troubleshooting

**Boot stalls with `uas_eh_abort_handler` / `uas_eh_device_reset_handler` messages.**
USB controller compatibility issue triggered by the first-boot partition resize. Just reboot — the resize only runs once, so subsequent boots proceed normally. Pre-growing the partition on the flasher host (see above) avoids this entirely.

**Web UI: no response / connection drops.**
Check `journalctl -u pveproxy -n 50` for `unable to open log file '/var/log/pveproxy/access.log'`. Fix: `mkdir -p /var/log/pveproxy && chown www-data:www-data /var/log/pveproxy && systemctl restart pveproxy`.

**Web UI works locally (`curl https://localhost:8006/`) but not over the network.**
Check that `vestick-firstboot` completed the network step (`cat /etc/network/interfaces` should have `auto vmbr0`) and that `/etc/default/pveproxy` doesn't restrict `ALLOW_FROM`.

**Overlay partition didn't grow.**
Check `systemctl status vestick-overlay-resize` and `df -h /media/root-rw`. To force a retry: `rm /var/lib/vestick/.overlay-resized && reboot`.
