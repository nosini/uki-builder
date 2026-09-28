# uki-snapshots

Signed Unified Kernel Images (UKIs) for openSUSE Tumbleweed snapper
snapshots, built only from content inside the encrypted root file system.

For the current snapshot and the newest `PREVIOUS` zypper "pre" snapshots,
`uki-snapshots` wraps the snapshot's own kernel, its `/etc/kernel/cmdline` and
an initrd built by dracut on the running system into a UKI. It signs the
UKI with your own Secure Boot key and installs it as
`EFI/Linux/uki-snap-<snapshot>-<kver>.efi` on the ESP.

Built for, and only tested on, one machine: Tumbleweed with systemd-boot
(originally installed by sdbootutil, which is then removed; see "System
setup"), shim, Secure Boot in user mode with your own key trusted, btrfs
root in LUKS2/LVM (unlocked with a FIDO2 key), snapper.

## Layout

| Path | Installed to |
| --- | --- |
| `bin/uki-snapshots` | `/usr/local/sbin/uki-snapshots` (its own btrfs subvolume, so it survives rollbacks) |
| `systemd/uki-snapshots.path` | `/etc/systemd/system/` |
| `systemd/uki-snapshots.service` | `/etc/systemd/system/` |
| `tests/` | bats tests against a mock system (`make check`) |

## What goes into a UKI

The ESP and `/boot` are outside the disk encryption, so an attacker can
change them offline. Nothing from there goes into an image:

| Part | Source |
| --- | --- |
| kernel | `/.snapshots/N/snapshot/usr/lib/modules/<kver>/vmlinuz`, the newest per flavor in `FLAVORS` |
| command line | `/.snapshots/N/snapshot/etc/kernel/cmdline` without its `root=`, plus `root=/dev/disk/by-uuid/<uuid of />` and `rootflags=subvol=@/.snapshots/N/snapshot` (other `rootflags` are kept) |
| initrd | dracut, run on the live system (see below) |
| os-release | the snapshot's `/usr/lib/os-release`, with the menu fields below |

**Initrds.** The script hashes the "system state": the rpm database plus
the `/etc` files dracut depends on (`SYSSTATE_PATHS`: crypttab, fstab,
dracut.conf(.d), modprobe.d, …). Whenever the live system's state has no
initrd yet, it runs dracut for each kernel of the current snapshot, with
sdbootutil's arguments (`--reproducible --force --tmpdir /var/tmp`). The
result goes into `/var/lib/uki-snapshots/initrd/<sha256>.img`, recorded
under that state (`gen/<state>/<kver>`). If the state changes while dracut
runs, the result is thrown away.

**Previous snapshots.** A zypper pre snapshot is the system as it was just
before a transaction. So its state hash finds the initrd built for exactly
that system, without relying on timing. A rollback copy of such a snapshot
finds it too. A snapshot without a matching initrd gets no UKI. That
applies to snapshots made before the cache existed, or while dracut had not
yet caught up. dracut never runs for a snapshot other than the running one.

The live system counts as trusted because it booted a signed UKI. dracut
only ever runs there, never against a snapshot or anything on the ESP.

## How it works

- **Selection.** The current snapshot is the btrfs default subvolume.
  Previous snapshots are the newest `PREVIOUS` snapshots of type `pre` whose
  description matches `PRE_DESCRIPTION` (`zypp(*`: zypper, myrlyn, YaST).
  They are read from `/.snapshots/N/info.xml`, not through the snapper CLI.
- **Waiting.** A run first waits (up to `IDLE_WAIT_MIN`) until zypper
  (`/run/zypp.pid`) is no longer running.
- **Build.** `ukify build` with `sbsign`, checked with `sbverify`, then
  copied to a hidden `.tmp` file on the ESP and renamed into place, with
  `MARGIN_MIB` left free.
- **Menu.**
  - `PRETTY_NAME` is the title: `UKI: Tumbleweed 20260924 (<kver>)` or
    `UKI: #N before update MM-DD HH:MM (<kver>)`.
  - `IMAGE_ID` (`1-uki-current`, `2-uki-previous`) becomes the sort key,
    which puts the current snapshot first.
  - `IMAGE_VERSION` is `<snapshot>_<kver>`.
- **Incremental.** `/var/lib/uki-snapshots/<name>.fp` holds a content hash
  of every input: kernel, initrd, command line, uname, os-release, the
  cert, the systemd stubs and the ukify version. A UKI is rebuilt only when
  it changes.
- **Prune.** Managed `uki-snap-*.efi` files that are no longer wanted are
  removed, but never the one `LoaderEntryDefault` points at. Pruning runs
  again after the default has moved. Cached initrds that no wanted snapshot
  refers to are deleted.
- **Default entry.** `bootctl set-default` points at the current snapshot's
  `DEFAULT_FLAVOR` UKI, and is written only when it changes.
  - If the current snapshot has no UKI (e.g. after a rollback to a snapshot
    without a cached initrd), the default stays where it is, with a
    warning. The machine then boots the running system rather than the
    rollback target.
  - If the current snapshot does not have `uki-snapshots.path` enabled (a
    rollback to before the install), its UKI still becomes the default,
    with a warning: run `make install` again after booting it, or its UKIs
    are no longer updated.
- **dracut failure.** The existing UKI of the current snapshot stays, and
  stays the default. The service reports the failure.
- **Triggers.**
  - `uki-snapshots.path` watches `/.snapshots` (snapshots created or
    deleted, rollbacks), the rpm database's `Packages.db`,
    `/etc/crypttab`, `/etc/dracut.conf.d`, `/etc/kernel/cmdline` and
    `EFI/Linux`.
  - The service also runs after every `snapper-cleanup.service` and once per
    boot.
  - `sync` repeats (up to 5 times) until the default subvolume, the snapshot
    list and the rpm database stay the same during a run. Only
    the last run's warnings decide the exit status.
- **Read-only snapshot boots** (recovery) do nothing: that snapshot's older
  ukify and stub would otherwise rebuild every UKI.

Usage (run as root, with the full path, because sudo's `secure_path` lacks
`/usr/local/sbin`):

    /usr/local/sbin/uki-snapshots plan   # dry run: dracut/keep/build/remove/default
    /usr/local/sbin/uki-snapshots sync   # do it (default)

## Settings

Defaults are at the top of `bin/uki-snapshots`. Override them in
`/etc/uki-snapshots.conf`, which is sourced as bash, e.g.:

    PREVIOUS=3
    FLAVORS=(default)
    KEY=/root/keys/db.key
    CERT=/root/keys/db.pem

## Pitfalls (keep these fixes)

1. **Not a snapper plugin.** The first version ran as
   `/usr/lib/snapper/plugins/90-*.snapper`. That runs in `snapperd_t`, and
   SELinux denied creating the lock in `/run`. Giving that domain access to
   the signing key, the ESP and efivars is not acceptable. The systemd units
   run unconfined.
2. **`root=/dev/disk/by-uuid/`, not `root=UUID=`.** While sdbootutil was
   installed, `sdbootutil cleanup` treated every boot entry, UKIs included,
   as its own if its `root=` matched one of its spellings of the root fs.
   Those spellings (`get_all_rootfs`) are the findmnt SOURCE, `/dev/dm-N`,
   the lsblk PATH, `UUID=`, `LABEL=`, `PARTUUID=` and `PARTLABEL=`. It
   deleted all UKIs twice. `/etc/kernel/cmdline` says
   `root=/dev/mapper/main-root`, one of those spellings, so the script drops
   it and sets its own. The by-uuid path is the same device to dracut. Keep
   it in case sdbootutil ever comes back.
3. **`set -euo pipefail`.** A `[[ … ]] && cmd` as the last command of a
   function or loop, inside a pipeline or `$(…)`, makes it return non-zero
   and aborts the script. Use `if` in those places.
4. **sudo** needs the full path (see above).
5. **Harmless noise:** `(reported/absent)` entries in `bootctl list` until
   the next reboot. ukify's and dracut's output is only shown when they
   fail.
6. **Start limit.** systemd refuses a service after 5 starts within 10 s
   (`StartLimitBurst`), and the path unit that triggers it then fails and
   stops watching. A fast service behind a busy path (the rpm database
   changes many times per transaction) hits that at once. The
   `ExecStartPre=sleep 5` keeps this service well below it; keep it, or set
   `StartLimitIntervalSec=0`.
7. **Watch `Packages.db`, not the rpm directory.** rpm's ndb backend
   rewrites `Index.db` (`CLOSE_WRITE`) on every root rpm query, so a
   watch on the directory fires without any package change. `Packages.db`
   only changes in a transaction.
8. **`reproducible=yes` comes from the ostree package**
   (`/etc/dracut.conf.d/ostree.conf`, which also adds dracut's `ostree`
   module), so the script passes `--reproducible` itself.

## System setup (outside this repo)

- A signing key and certificate that the firmware (db) or shim (MOK) trusts,
  at `KEY`/`CERT` (default `/root/uki-signing/secureboot.{key,pem}`, root
  only). **Never commit keys.**
- Packages: systemd-boot/ukify, sbsigntools, dracut, snapper, btrfsprogs.
- **sdbootutil removed and locked** (`sdbootutil`, `sdbootutil-snapper`,
  `sdbootutil-dracut-measure-pcr`; `zypper al 'sdbootutil*'`, since it is
  pulled in again as a "Supplements" of systemd-boot and shim). Its hooks
  and what disables them:
  - the snapper plugin (`sdbootutil-snapper`): writes entries for every
    new snapshot; only removing the package stops it
  - the rpm file trigger (`sdbootutil update` when systemd-boot or shim
    change; gated by `LOADER_TYPE`)
  - the kernel scripts, `regenerate-initrd-posttrans` and `weak-modules2` in
    suse-module-tools; gated by `sdbootutil is-installed`, i.e. the ESP
    marker `EFI/systemd/installed_by_sdbootutil`

  Without it, kernel updates take the classic path: kernel and initrd are
  also written to `/boot`, which nothing boots from.
- ESP cleaned up:
  - sdbootutil's entries (`loader/entries/<machine-id>-*.conf`), kernels and
    initrds (`/boot/efi/<machine-id>/`) and its marker are gone
  - `loader/entries/windows.conf` stays
  - `EFI/tools/shellx64.efi` is gone
- `/boot/efi/loader/loader.conf` with `auto-entries no` and `editor no`.
- **Not handled yet:** shim and systemd-boot on the ESP
  (`EFI/systemd/shim.efi`, which loads `grub.efi` = systemd-boot) are no
  longer updated. Layer B replaces them with systemd-boot signed with your
  own key.

## Install

    sudo make install          # script + units, daemon-reload, enable both, (re)start the .path
    sudo /usr/local/sbin/uki-snapshots plan
    sudo systemctl start uki-snapshots.service

The first run builds the initrds of the current system, which takes about a
minute per kernel. The pre snapshot of the next zypper transaction is the
first to get a previous-snapshot UKI.

## Uninstall

    sudo make uninstall        # disables and removes the units and the script

This leaves the UKIs, the default entry and `/var/lib/uki-snapshots` in
place, and nothing keeps them up to date any more. To go back to
sdbootutil, do that first:

    sudo zypper rl 'sdbootutil*'
    sudo zypper in sdbootutil sdbootutil-snapper
    sudo sdbootutil install                 # recreates the marker
    sudo sdbootutil add-all-kernels
    sudo sdbootutil set-default-snapshot
    sudo rm /boot/efi/EFI/Linux/uki-snap-*.efi
    sudo rm -r /var/lib/uki-snapshots

## Recovery

If a UKI does not boot, press Space (or hold it) at power-on to open the
systemd-boot menu and pick another one:
- the current snapshot's other flavor (longterm)
- a previous snapshot ("UKI: #N before update …"), which boots read-only;
  `snapper rollback` from there makes it the default

If none of them boots, use a live USB stick. Unlock and mount the root file
system, chroot into it, then either run
`/usr/local/sbin/uki-snapshots sync` or go back to sdbootutil (see
Uninstall). Once Layer B is in place, a live USB stick only boots if Secure
Boot is disabled in the firmware setup first, or its keys are reset.

## Threat model

Protects against an attacker with physical access and offline write access
to the unencrypted storage ("evil maid"). The disk unlocks with a FIDO2
key only; there is deliberately no TPM unlock, which would let anyone
boot the machine into an unlocked disk.

- **Trusted:** the encrypted btrfs root, including read-only snapshots and
  `/var`, and the signing key in `/root/uki-signing`.
- **Untrusted:** everything on the ESP and on `/boot`. Nothing from there
  is signed.
- **The key is the trust anchor.** It is stored unencrypted inside LUKS.
  Anyone with root on the running system can sign anything this firmware
  will boot.
- **Closed by the system setup:** no type #1 entries (unsigned initrd,
  editable command line) are left in the menu, the command line editor is
  off, and there is no UEFI shell. The UKIs' embedded command line cannot be
  overridden while Secure Boot is on.
- **Not closed yet (Layer B):**
  - The firmware trusts the Microsoft 3rd-party UEFI CA, so an attacker can
    put their own chain on the ESP: shim with any openSUSE-signed kernel and
    any initrd, or a live system.
  - `MokManager.efi` is on the ESP. A key enrolled in MOK, e.g. from such a
    live system, is trusted by shim.
  - Any code that runs before unlock can ask the FIDO2 key to unlock the disk
    (and capture its PIN, if the slot requires one).
- **Old UKIs stay valid.** Every UKI ever signed boots as long as the key is
  trusted, so an attacker can put back an old one from a copy of the ESP.
- **Data read from snapshots.** The script runs as root and reads
  `info.xml` (with sed), `os-release` (parsed, not sourced) and
  `/etc/kernel/cmdline` from snapshots. These are inside the encryption.

## License

GNU Affero General Public License v3.0, see [LICENSE](LICENSE).
