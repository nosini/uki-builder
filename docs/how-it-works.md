# How uki-snapshots works

## What goes into a UKI

The ESP and `/boot` are outside the disk encryption, so an attacker can
change them offline. Nothing from there goes into an image:

| Part | Source |
| --- | --- |
| kernel | `/.snapshots/N/snapshot/usr/lib/modules/<kver>/vmlinuz`, the newest per flavor in `FLAVORS` |
| command line | `/.snapshots/N/snapshot/etc/kernel/cmdline` without its `root=`, plus `root=/dev/disk/by-uuid/<uuid of />` and `rootflags=subvol=<prefix>.snapshots/N/snapshot` (other `rootflags` are kept) |
| initrd | dracut, run on the live system (see below) |
| os-release | the snapshot's `/usr/lib/os-release`, with the menu fields below |

**Initrds.** The script hashes the "system state": the rpm database plus the
`/etc` files dracut depends on (`SYSSTATE_PATHS`: crypttab, fstab,
dracut.conf(.d), modprobe.d, …). Symlinks, anywhere along a path, are
followed inside the root they belong to (an absolute link in a snapshot
points into that snapshot, and `..` never leaves it), and what counts is the
target's content. A path that does not resolve within 40 links (a loop), or
a file, link or directory that cannot be read, makes the state unknown: no
initrd is built or matched for it, that snapshot's existing UKIs stay,
cached initrds are not cleaned up, and the service reports it. rpm's
`Index.db` and lock files do not count (`SYSSTATE_EXCLUDE`): rpm rewrites
the index without any package change. A read-only snapshot's state is cached
under its btrfs subvolume UUID, since snapper can reuse the number of a
deleted snapshot.

Whenever the live system's state has no initrd yet, the script runs dracut
for each kernel of the current snapshot with
`--reproducible --force --tmpdir /var/tmp`. The result goes into
`/var/lib/uki-snapshots/initrd/<sha256>.img`, recorded under that state
(`gen/<state>/<kver>`). If the state changes while dracut runs, the result
is thrown away.

**Previous snapshots.** A zypper pre snapshot is the system as it was just
before a transaction. So its state hash finds the initrd built for exactly
that system, without relying on timing. A rollback copy of such a snapshot
finds it too. A snapshot without a matching initrd gets no UKI. That
applies to snapshots made before the cache existed, or while dracut had not
yet caught up. dracut never runs for a snapshot other than the running one.

This assumes that the live system booted a trusted signed UKI. dracut only
ever runs there, never against a snapshot or anything on the ESP.

## Synchronization

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
  - `PRETTY_NAME` is the title: `UKI: Tumbleweed <release> (<kver>)` or
    `UKI: #N before update MM-DD HH:MM (<kver>)`.
  - `IMAGE_ID` (`1-uki-current`, `2-uki-previous`) becomes the sort key,
    which puts the current snapshot first.
  - `IMAGE_VERSION` is `<snapshot>_<kver>`.
- **Incremental.** `/var/lib/uki-snapshots/<name>.fp` holds a content hash
  of every input (kernel, initrd, command line, uname, os-release, the
  cert, the systemd stubs and the ukify version) and the hash of the file
  that was installed. A UKI is rebuilt when an input changes, or when the
  file on the ESP is not the one installed (e.g. an older signed image put
  back from a copy of the ESP). The same applies to the signed systemd-boot.
  This reads every UKI once per run; timestamps do not establish integrity
  on an untrusted ESP.
- **Prune.** Managed `uki-snap-*.efi` files that are no longer wanted are
  removed, but never the one `LoaderEntryDefault` points at, and none of the
  current snapshot's before the builds. Afterwards only UKIs that this run
  built or verified stay, plus those whose rebuild failed but that are still
  the file installed: per kernel flavor, the current snapshot keeps the UKI
  of its newest kernel or, until that one is built, the newest one it
  already has that is intact. A file that merely exists on the ESP never
  counts, and never becomes the default. A flavor whose kernel is gone from
  the current snapshot loses its UKI; the kernels are looked up first, so a
  failure later (e.g. a missing `/etc/kernel/cmdline`) never passes for
  that. `plan` shows the removals of both passes, and knows what the same
  `sync` run adds first (initrds from dracut, boot loader copies). Cached
  initrds that no selected snapshot refers to are deleted only after a run
  that got as far as selecting snapshots and during which nothing changed (a
  rollback in the middle may need one the run did not select).
- **Default entry.** `bootctl set-default` points at the current snapshot's
  `DEFAULT_FLAVOR` UKI, and is written only when it changes.
  - If the current snapshot has no UKI (e.g. after a rollback to a snapshot
    without a cached initrd), the default stays where it is, with a
    warning. The machine then boots the running system rather than the
    rollback target.
  - If the current snapshot does not have `uki-snapshots.path` enabled (a
    rollback to before the install), its UKI still becomes the default,
    with a warning. Run `sudo make install` again from the source directory
    after booting it to keep its UKIs updated.
- **dracut or build failure.** The current snapshot's existing UKI of that
  flavor stays, and stays the default. The service reports the failure.
- **Triggers.**
  - `uki-snapshots.path` watches `/.snapshots` (snapshots created or
    deleted, rollbacks), the rpm database's `Packages.db`,
    `/etc/crypttab`, `/etc/dracut.conf.d`, `/etc/kernel/cmdline`,
    `/usr/lib/systemd/boot/efi` (systemd-boot and its stubs) and
    `EFI/Linux`.
  - The service also runs after every `snapper-cleanup.service` and once per
    boot.
  - `sync` repeats (up to 5 times) until the default subvolume, the snapshot
    list and the rpm database stay the same during a run. Only
    the last run's warnings decide the exit status.
- **Boot loader** (`SDBOOT_DEST`, `SDBOOT_FALLBACK`, off by default):
  systemd-boot from the running system, signed with the same key, is
  installed at every ESP path listed. The firmware can then boot it
  directly, without shim. It is signed again when systemd-boot or the
  certificate changes. The `SDBOOT_DEST` copies are updated right away.
  The `SDBOOT_FALLBACK` copies are only updated once the firmware has
  booted that version (the `LoaderInfo` variable systemd-boot sets at boot
  matches the version in the new binary). A systemd-boot update that does
  not start therefore still leaves a fallback that does. Every signed
  binary installed is also kept in `/var/lib/uki-snapshots/bootloader/`,
  so a held fallback that is no longer the file installed is restored to
  the version it held (or, without a saved copy, replaced with the current
  one). The signed binary gets its final name only after signing and
  verification succeeded.
- **Notifications** (`NOTIFY=yes`): when the service fails,
  `uki-snapshots-notify.service` (`OnFailure=`) sends a critical desktop
  notification with the last warning to every user with an active
  graphical session, through D-Bus (`gdbus`) in that user's session.
- **db alarm** (`DB_FORBIDDEN`, off by default): the service fails with a
  warning if the Secure Boot db contains one of the named certificates
  again, e.g. after a db update that Microsoft signed with its KEK.
- **Read-only snapshot boots** (recovery) do nothing: that snapshot's older
  ukify and stub would otherwise rebuild every UKI.

## State and installed files

The scripts are installed in `/usr/local/sbin` and the units in
`/etc/systemd/system`. Cached initrds, content fingerprints and saved signed
boot loaders live in `/var/lib/uki-snapshots`; this directory must be shared
across snapshots.

The script defaults to `/boot/efi` for the ESP and `/.snapshots` for snapper
snapshots. A UKI is installed as
`EFI/Linux/uki-snap-<snapshot>-<kernel>.efi`. The btrfs subvolume prefix for
the embedded `rootflags` is read from the default subvolume rather than
assumed to be `@/`.

## Configuration checks

`/etc/uki-snapshots.conf` is sourced as Bash and runs as root. It must be a
regular file owned by root, not writable by group or others, and not on a
FAT file system. The same checks apply to a file selected with
`UKI_SNAPSHOTS_CONF`. The script checks and reads the file through the same
open descriptor so it cannot be swapped between those operations.

See the [README](../README.md) for installation and everyday use, and the
[Secure Boot guide](secure-boot.md) for the trust model and key management.
