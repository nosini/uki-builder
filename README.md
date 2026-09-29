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
| `systemd/uki-snapshots-notify.service` | `/etc/systemd/system/` (started by `OnFailure=`) |
| `bin/secureboot-keys` | `/usr/local/sbin/secureboot-keys` (one-time: replace the firmware's Secure Boot keys) |
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
for each kernel of the current snapshot, with sdbootutil's arguments
(`--reproducible --force --tmpdir /var/tmp`). The result goes into
`/var/lib/uki-snapshots/initrd/<sha256>.img`, recorded under that state
(`gen/<state>/<kver>`). If the state changes while dracut runs, the result
is thrown away.

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
  of every input (kernel, initrd, command line, uname, os-release, the
  cert, the systemd stubs and the ukify version) and the hash of the file
  that was installed. A UKI is rebuilt when an input changes, or when the
  file on the ESP is not the one installed (e.g. an older signed image put
  back from a copy of the ESP). The same applies to the signed systemd-boot.
  This reads every UKI once per run (about 700 MB for six, a few seconds);
  timestamps would be cheaper but prove nothing on an untrusted ESP.
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
    with a warning: run `make install` again after booting it, or its UKIs
    are no longer updated.
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

Usage (run as root, with the full path, because sudo's `secure_path` lacks
`/usr/local/sbin`):

    /usr/local/sbin/uki-snapshots plan   # dry run: dracut/keep/build/remove/default
    /usr/local/sbin/uki-snapshots sync   # do it (default)

## Settings

Defaults are at the top of `bin/uki-snapshots`. Override them in
`/etc/uki-snapshots.conf`. It is sourced as bash and runs as root, so the
script refuses it unless it is a regular file (anything else is not even
opened, since a FIFO would block) that belongs to root, is not writable by
group or others and is not on a FAT file system (the ESP),
where ownership means nothing. It is opened once and checked and read
through that same descriptor, so it cannot be swapped in between. The same
applies to a file named by `UKI_SNAPSHOTS_CONF`. E.g.:

    PREVIOUS=3
    FLAVORS=(default)
    KEY=/root/keys/db.key
    CERT=/root/keys/db.pem
    SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)
    SDBOOT_FALLBACK=(EFI/BOOT/BOOTX64.EFI)
    DB_FORBIDDEN=('Microsoft Corporation UEFI CA 2011' 'Microsoft UEFI CA 2023')

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
9. **State format change.** The system state used to be hashed without
   following symlinks and with `Index.db`; hashes in that format do not
   match any more. `take_over_legacy` adopts initrds cached under the old
   hash once, unless symlinks are among the tracked files (the old format
   recorded only their text, so it proves nothing about their targets; then
   dracut builds anew). Remove `legacy_sysstate`/`take_over_legacy` once no
   snapshot from before that version is a previous snapshot any more.

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
  - `EFI/tools/shellx64.efi` and the `windows.conf` entry that used it are
    gone. A UEFI shell runs before the OS and can write the firmware
    variables shim trusts (MOK). This one was unsigned, so with Secure Boot
    on the entry could not start anyway.
- **Windows** with its own ESP on another disk cannot be started by
  systemd-boot. Boot it through its firmware entry (Windows Boot
  Manager): the firmware boot menu at power-on, "Reboot Into Firmware
  Interface" in systemd-boot, or once from Linux with
  `sudo efibootmgr --bootnext XXXX && sudo systemctl reboot` (XXXX: its
  number in `efibootmgr`).
- `/boot/efi/loader/loader.conf` with `auto-entries no` and `editor no`.
- **The boot loader** is systemd-boot signed with your own key, booted
  directly by the firmware (no shim). `SDBOOT_DEST` keeps it up to date at
  `EFI/systemd/systemd-bootx64.efi` (firmware entry "systemd-boot (own
  key)"), and `SDBOOT_FALLBACK` at the fallback path `EFI/BOOT/BOOTX64.EFI`,
  one version behind until the new one has booted. shim, MokManager
  and the old `grub.efi`/`fallback.efi` are removed from the ESP, and so is
  shim's firmware boot entry. Firmware boot order: systemd-boot, the
  fallback path, Windows Boot Manager. The `shim` package stays installed
  (fwupd and gnome-software require it); with sdbootutil gone nothing
  copies it to the ESP, and the firmware would refuse it anyway.

## Own Secure Boot keys (Layer B)

With shim and the Microsoft 3rd-party UEFI CAs trusted, anyone can put
their own boot chain on the ESP (shim with any openSUSE kernel and initrd,
or a live system). Layer B makes the firmware trust only your keys, the
Windows CAs and your GPU's option ROM:

| Variable | Contents |
| --- | --- |
| PK | your own platform key |
| KEK | your own KEK, and Microsoft's KEKs (so Windows Update and fwupd can still update dbx) |
| db | your signing certificate, Microsoft Windows Production PCA 2011, Windows UEFI CA 2023, the hashes of the option ROMs the firmware loaded (TPM event log) |
| dbx | unchanged |

`secureboot-keys build` creates PK and KEK in `/root/secureboot-owner`
(root only; keep an offline backup) and writes the lists and signed
updates. `secureboot-keys enroll` writes them while the firmware is in
Setup Mode. Needs `efitools`.

Before that, and in this order:
1. set a firmware administrator password (otherwise anyone at the keyboard
   can simply turn Secure Boot off)
2. add your certificate to db (firmware setup, "Append"), set
   `SDBOOT_DEST`, add a firmware boot entry for the signed systemd-boot and
   test it with `efibootmgr --bootnext`
3. make that entry the first in `BootOrder`, since shim no longer starts
   once the keys are replaced
4. have the BitLocker recovery key at hand if Windows uses BitLocker (PCR 7
   changes)

**The GPU:** an option ROM signed only by the 3rd-party CA (e.g. a
graphics card's GOP driver) is allowed by its hash. After a GPU firmware
update or a new card the firmware shows nothing until Linux loads its
driver. If that driver is in the initrd (`lsinitrd | grep <driver>`), the
screen comes back in time for the disk unlock prompt. Then run
`secureboot-keys build` again (it picks up the new hash from the event
log) and enroll as in the first setup.

**Recovery:** the firmware setup can restore the factory keys ("Restore
Factory Keys" / "Install default Secure Boot keys"). That brings back the
Microsoft CAs but not your key, and shim is no longer on the ESP, so
nothing boots with Secure Boot on until your keys are back (see "BIOS
updates").

## BIOS updates

A firmware update can reset the Secure Boot keys to the factory
defaults and forget the firmware boot entries. Your systemd-boot is then
refused. Afterwards:

1. If the machine does not boot: firmware setup (administrator
   password), disable Secure Boot, boot Linux.
2. Firmware setup: Secure Boot → Key Management → "Reset To Setup Mode";
   decline any offer to install the factory keys.
3. Linux: `sudo /usr/local/sbin/secureboot-keys enroll` (the files from the
   last `build` in `/root/secureboot-owner/enroll`; run `build` first if the
   GPU or its firmware changed).
4. Firmware setup: enable Secure Boot again.
5. If "systemd-boot (own key)" is gone from the boot menu, the fallback
   path `EFI/BOOT/BOOTX64.EFI` still starts it. To recreate the entry:
   `sudo efibootmgr --create --disk /dev/DISK --part N --label
   "systemd-boot (own key)" --loader '\EFI\systemd\systemd-bootx64.efi'`,
   with DISK and N the ESP's disk and partition number (`findmnt /boot/efi`).
6. Check: `mokutil --sb-state`, `mokutil --pk` (your own PK) and
   `systemctl is-failed uki-snapshots.service` (`inactive`: the db alarm
   found nothing).

Also check that the administrator password, and the option that asks for
it only when entering the setup, survived the update.

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

If none of them boots, use a live USB stick. It only starts after you
disable Secure Boot in the firmware setup (administrator password) or
restore the factory keys there. Unlock and mount the root file system,
chroot into it, then run `/usr/local/sbin/uki-snapshots sync`, or go back
to sdbootutil (see Uninstall). Afterwards, turn Secure Boot back on, or
enroll your keys again (`secureboot-keys enroll` in Setup Mode).

Backups of everything removed from the ESP are in
`/root/esp-backup-layer-a` and `/root/esp-backup-layer-b`. The PK and KEK
private keys are in `/root/secureboot-owner`; keep an offline copy.

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
- **Closed by your own keys (Layer B):** the firmware runs only what your
  key, the Windows CAs or the GPU option ROM hash allow. shim, live systems
  and anything else signed by the Microsoft 3rd-party CAs are refused. The
  firmware setup is protected by an administrator password (asked only
  when entering the setup), so Secure Boot cannot simply be switched off or
  the keys reset. The db alarm (`DB_FORBIDDEN`) reports if a 3rd-party CA
  ever appears in db again, e.g. through a db update signed with
  Microsoft's KEK.
- **Still open:**
  - Windows' boot chain is trusted (Windows CAs). A Windows boot manager
    or a tool signed with them, placed on the ESP, would run. With
    BitLocker, Windows itself is protected, but the Linux unlock is not
    involved there.
  - Nothing proves to you that the boot chain is the expected one before
    you touch the FIDO2 key. tpm2-totp (a code sealed to the TPM's PCRs,
    shown at boot and compared with your phone) would add that without
    letting the TPM unlock the disk.
  - A CMOS reset (jumper/battery) may clear the administrator password.
    Whether it also resets the Secure Boot keys depends on the firmware.
- **Old UKIs stay valid.** Every UKI ever signed boots as long as the key is
  trusted, so an attacker can put back an old one from a copy of the ESP.
- **Data read from snapshots.** The script runs as root and reads
  `info.xml` (with sed), `os-release` (parsed, not sourced) and
  `/etc/kernel/cmdline` from snapshots. These are inside the encryption.
- **What the ESP still influences.** No file content from the ESP goes
  into an image. Which files exist there, and whether they match what was
  installed, does decide what is rebuilt, pruned or kept, and a file put
  back or removed by an attacker is replaced by the next run. The default
  entry is read from the firmware variable once per run, so a concurrent
  change by another tool is not guarded against.
- **The config file** is run as root: it is an administrator interface,
  accepted only when it belongs to root and nobody else can write it.

## License

GNU Affero General Public License v3.0, see [LICENSE](LICENSE).
