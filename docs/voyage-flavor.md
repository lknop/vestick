# Voyage-flavored redesign (branch: voyage-flavor)

The first cut of VEyage went the modern atomic-OS route: squashfs root + tmpfs
overlay + a separate state partition with per-path bind mounts. It works, but
the surface area is large — overlayroot patching, a state-init service that
bind-mounts the persisted paths back over the overlay, a custom firstboot
wizard with shadow-rewrite-in-place tricks to dodge bind-mount inode quirks.
Every new file you want to persist needs a code change.

This branch goes back to the **Voyage Linux** mental model — the system is
mounted read-only normally; the operator runs `remountrw`, makes the change,
then `remountro`. No overlay, no state partition for binds, no per-path
list. Just a normal Debian on a normal filesystem with a write switch.

The catch: Proxmox's `pve-cluster` (pmxcfs) writes to `/var/lib/pve-cluster/`
constantly — heartbeats, status, every config change. A pure Voyage model
where `/` is ro until the operator flips it doesn't survive pmxcfs starting.

So the adapted layout:

```
ESP                          (boot, FAT32, ~128 MB)
/                            ext4, mounted RO by default; remountrw on demand
/var/lib/pve-cluster         ext4, separate partition, always RW (~256 MB)
/var/lib/rrdcached           tmpfs (perf graphs reset on reboot — by design)
/tmp, /var/tmp, /var/log     tmpfs (logs forward via rsyslog)
/run                         tmpfs (systemd default)
```

## What this gives us

- **Operator UX is just Debian.** `apt upgrade` works (during a `remountrw`
  window). Editing any `/etc/foo.conf` persists. No "did I add this to
  PERSIST_PATHS?" surprise.
- **Single image, easy to dd.** No multi-partition state to keep separate.
  pmxcfs gets its own partition but it's part of the same disk image.
- **Squashfs's read-perf benefit is given up** — see "tradeoffs" below.
- **Most of this project's overlay code disappears.** No overlayroot patch,
  no veyage-state-init, no PERSIST_PATHS, no shadow rewrite-in-place.
  systemd-firstboot handles hostname/root-password natively because `/etc`
  is just normal writable storage now.
- **rrdcached on tmpfs eliminates the bulk of routine flash writes.** It's
  the chattiest writer on a Proxmox host and its data is genuinely
  disposable — losing perf graphs on reboot bothers nobody.

## Operator workflow

```sh
# Change anything
remountrw
vi /etc/network/interfaces
remountro

# Upgrade
remountrw
apt update && apt upgrade -y
remountro

# Reboot — change persists
```

A systemd timer auto-runs `remountro` after 10 min of unattended rw, in
case the operator forgets. This is what later Voyage builds did.

## Tradeoffs vs. the original design

| Property | Original (squashfs+overlay) | Voyage-flavored |
|---|---|---|
| Read perf on slow flash | excellent (compressed sequential reads) | normal ext4 (worse on cheap USB) |
| Boot speed on USB 2.0 | fast (less data to read) | slower (more data, random access) |
| `apt upgrade` works in place | no (writes vanish on reboot) | **yes**, during rw window |
| Power-loss exposure | none on /, only on state partition | rw window (operator-controlled) + pmxcfs partition |
| Atomic rollback after upgrade | possible with RAUC + A/B | not without adding A/B layout |
| Code surface in this project | ~500 lines overlay + scripts | ~100 lines |
| Operator surprise factor | high (custom mental model) | low (it's Debian) |

If the **read-perf / atomic-upgrade / immutability** properties matter for
your deployment, the original main-branch design is the right choice and
this branch is the wrong one. If you want a Proxmox-on-USB image with
normal Linux semantics and minimal write activity, this is.

## What stays from main

- `journald Storage=volatile` (logs in RAM)
- `rsyslog` forward profile (logs leave the box)
- `veyage-network-init` (interactive vmbr0 picker — there's no good
  systemd-shipped substitute; an interface picker is genuinely needed)
- The Phase 5 sshd drop-in (`PermitRootLogin yes`)
- The GitHub Actions workflow (just builds a different image)

## What goes away

- `overlay/etc/overlayroot.conf`
- `overlay/etc/systemd/system/mnt-state.mount`
- `overlay/etc/systemd/system/veyage-state.service`
- `overlay/usr/local/sbin/veyage-state-init`
- `overlay/etc/systemd/system/veyage-firstboot.service` (replaced by systemd-firstboot)
- `overlay/usr/local/sbin/veyage-firstboot`
- The overlayroot patch in `build.sh::configure_readonly`
- The squashfs pack step in `build.sh::pack_squashfs`
- The `MODE=direct` path in `test-vm.sh` (only useful for the squashfs design)
- `packages/base.list` no longer needs `overlayroot`, `busybox` (the latter
  was only there as initramfs glue for overlayroot)

## What's new

- `overlay/usr/local/sbin/remountrw` and `remountro`
- `overlay/etc/systemd/system/auto-remount-ro.service` + `.timer`
- `overlay/etc/fstab` with `/` ro, pmxcfs partition, tmpfs lines
- A systemd-firstboot service drop-in to limit prompts to hostname +
  root password (no locale/keymap/timezone)
- `build.sh` rewritten around `debootstrap → mounted ext4 image` instead of
  `debootstrap → chroot → squashfs → image`

## Open questions

- **Auto-remount-ro timer interval**: 10 min default. Configurable?
- **`/etc/fstab` `errors=` policy on /**: `errors=remount-ro` is appropriate
  for the ro design. Or `errors=panic` to force a reboot?
- **Image size default**: ext4 root needs more space than the squashfs did
  (no compression). Empirically 4 GB ran out of room mid-dpkg for the PVE
  build — bumped default to 8 GB. Operator grows on dd via growpart.
- **First-boot resize**: same growpart pattern still applies — grow the root
  partition to fill the device after dd to a larger USB.

## What we measured (trace experiment, 2026-05-06)

Built `INCLUDE_PROXMOX=1` with rw root + a baked-in trace script. Boot,
let PVE settle, mark a baseline, idle 60s, then `find -newer baseline`.
Headline: outside of `/var/lib/pve-cluster`, a steady-state PVE node
writes essentially nothing to /var. Detail:

| Path | Files modified in 60s | Real disk I/O? |
|---|---|---|
| `/var/lib/pve-cluster/config.db-{shm,wal}` | 2 | yes — already on its own partition |
| `/var/lib/pve-manager/pve-replication-state.json` | 1 | yes — tiny, infrequent |
| `/etc/pve/nodes/<n>/lrm_status` | 1 | no — `/etc/pve` is FUSE-backed by pmxcfs (so this is the same write as config.db) |
| `/var/lib/lxcfs/proc/*`, `/sys/*` | 207 | **no** — FUSE virtual files; mtime ticks but no disk I/O |
| `/var/log/*` | 16 | route to tmpfs (planned) |
| `/var/cache/*` | 108 | mostly stale apt cache from build, not runtime writes |
| `/var/lib/rrdcached/*` | 0 | tmpfs (planned) |
| `/var/tmp/*` | 0 | tmpfs (planned) |

This validates the layout above. The "all of /var on a separate
partition" rabbit hole I went down in the middle of the branch was
over-engineering — pmxcfs is genuinely the only chatty writer.

Caveats: idle PVE (no network → no cluster gossip; no VMs → no RRD
updates; no web-UI access → no pveproxy logs). Real-world load will
exercise more paths but the rate stays modest given log + rrdcached are
tmpfs.

## What's pending (next session)

Status as of last commit on this branch (`c548475`, "first-boot
wizards"): build runs to completion, image boots far enough to enter
firstboot. Two showstoppers blocking a clean boot, with the trace data
giving us the right way to fix them:

1. **`systemd-logind` crashloops** — `Failed at step STATE_DIRECTORY:
   Read-only file system`. logind wants to create
   `/var/lib/systemd/linger`. Solution informed by the trace: one tmpfs
   mount over `/var/lib/systemd` (small, ephemeral state — losing it on
   reboot is fine). Add to fstab.

2. **`veyage-firstboot.service` doesn't fire** — `WantedBy=
   multi-user.target` symlink doesn't activate it. Probable cause:
   logind's failure cascading through PAM ordering. Fixing #1 should
   unblock this. Verify by re-running the expect test after the logind
   fix.

After those, the per-path tmpfs picks for the small handful of `/var/lib/
<service>/` paths systemd insists on writing — nothing else. Drive
each pick with another trace run if needed.

### Caveat on what the trace did and didn't prove

The trace was run on a hand-patched **rw-root** image (so logind would
actually start and Proxmox could come up). It told us *which files*
get touched at runtime — that's a good map of the runtime write rate.

It did **not** prove that the ro-root design will boot. We already
know `systemd-logind` will crashloop at `STATE_DIRECTORY` on a ro root
because it tries to create `/var/lib/systemd/linger`. Other systemd
services may have similar `StateDirectory=` / `CacheDirectory=`
directives — we haven't enumerated them yet.

Concrete next-session checklist for the ro-root boot:

1. **`/var/lib/systemd` → tmpfs** is already encoded in `build.sh`'s
   `write_fstab` (commit baked in). Decided after weighing the contents
   of that dir: timer stamps, random-seed, optional linger, optional
   credential.secret. For Proxmox-on-USB the only visible effect of
   losing it on reboot is that anacron-style timers (apt-daily, fstrim,
   e2scrub_all) re-fire once per boot until next scheduled hour, all
   benign. Revisit if a real user trips over `systemd-creds`-encrypted
   secrets or timesyncd state.
2. Boot a ro-root build with the change in (1). If logind starts cleanly,
   the rest of the chain (firstboot wizard, network-init, getty) should
   come up — confirm via the existing expect test.
3. If something else fails with a `STATE_DIRECTORY` / `CACHE_DIRECTORY`
   error, audit the chroot:
   ```
   grep -lE '^(State|Cache|Logs)Directory=' /usr/lib/systemd/system/*.service
   ```
   For each hit, decide tmpfs vs persistent (default tmpfs unless the
   directory has data the operator would miss).
4. Re-run the trace experiment on a ro-root boot once it's clean —
   gives us a much more accurate picture of the actual write pattern
   than the rw-root trace did.

The whole effort is bounded — it's a small number of services and
each fix is one fstab line.
