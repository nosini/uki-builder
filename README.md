# uki-snapshots

Signed Unified Kernel Images (UKIs) for openSUSE Tumbleweed snapper snapshots,
built from the boot entries that sdbootutil already maintains.

For the current snapshot and the newest `PREVIOUS` zypper "pre" snapshots,
`uki-snapshots` takes sdbootutil's BLS type #1 entry with the newest kernel of
each flavor. It wraps that entry's kernel, initrd(s) and options into a UKI
with `ukify`, signs the UKI with your own Secure Boot key and installs it as
`EFI/Linux/uki-snap-<snapshot>-<kver>.efi` on the ESP. It does not run dracut.

Built for, and only tested on, one machine: Tumbleweed with systemd-boot
installed by sdbootutil, shim, Secure Boot in user mode with your own key
trusted, btrfs root in LUKS2/LVM, snapper.

## Layout

| Path | Installed to |
| --- | --- |
| `bin/uki-snapshots` | `/usr/local/sbin/uki-snapshots` (its own btrfs subvolume, so it survives rollbacks) |
| `systemd/uki-snapshots.path` | `/etc/systemd/system/` |
| `systemd/uki-snapshots.service` | `/etc/systemd/system/` |

## How it works

- **Selection.** The current snapshot is the btrfs default subvolume
  (`btrfs subvolume get-default /`). Previous snapshots are the newest
  `PREVIOUS` snapshots of type `pre` whose description starts with `zypp(`
  (zypper, myrlyn, YaST). They are read from `/.snapshots/N/info.xml`, not
  through the snapper CLI. A snapshot only qualifies if sdbootutil has
  entries for it. For each selected snapshot, the newest kernel of each flavor
  in `FLAVORS` is used.
- **Build.** `ukify build` gets `--linux`, `--initrd`, `--cmdline`, `--uname`,
  `--os-release` and signs with `sbsign`. The result is checked with
  `sbverify`, copied to a hidden `.tmp` file on the ESP and renamed into
  place. A free-space check leaves `MARGIN_MIB` free.
- **Menu.** The UKI's os-release comes from the snapshot itself:
  - `PRETTY_NAME` is the menu title: `UKI: Tumbleweed 20260924 (<kver>)` or
    `UKI: #N before update MM-DD HH:MM (<kver>)`.
  - `IMAGE_ID` (`1-uki-current`, `2-uki-previous`) becomes the systemd-boot
    sort key, so the UKIs sort above sdbootutil's entries.
  - `IMAGE_VERSION` is `<snapshot>_<kver>`.
- **Command line.** The entry's options are used, except that `root=UUID=` is
  rewritten to `root=/dev/disk/by-uuid/` (see Pitfalls).
- **Incremental.** `/var/lib/uki-snapshots/<name>.fp` holds a fingerprint of
  all build inputs: kernel/initrd stat, options, uname, os-release, the cert
  and the systemd stubs. A UKI is rebuilt only when the fingerprint changes.
- **Prune.** Managed `uki-snap-*.efi` files that are no longer wanted are
  removed, but never the file `LoaderEntryDefault` points at. Pruning runs
  again after the default has moved.
- **Default entry.** `bootctl set-default` is pointed at the current
  snapshot's `DEFAULT_FLAVOR` UKI. It is only written when it differs from
  the current value.
- **UNBOOT_OTHERS.** For every `pre`/`post` snapshot that has sdbootutil
  entries but is not in the keep set, the script runs
  `sdbootutil remove-all-kernels --disable-predictions N`. The snapshots
  themselves stay. `single` snapshots (rollback copies, manual ones) are never
  touched. Because sdbootutil has no locking, this first waits until zypper
  (`/run/zypp.pid`) and any other sdbootutil process are gone.
- **Trigger.** `uki-snapshots.path` watches `/boot/efi/loader/entries` and
  `/boot/efi/EFI/Linux` and starts `uki-snapshots.service` (oneshot). The
  service sleeps 5 s first so that sdbootutil can finish its batch. `sync`
  repeats (up to 5 times) until `loader/entries` is the same before and after
  a run.

Usage (run as root, with the full path, because sudo's `secure_path` lacks
`/usr/local/sbin`):

    /usr/local/sbin/uki-snapshots plan   # dry run: keep/build/remove/default/unboot
    /usr/local/sbin/uki-snapshots sync   # do it (default)

## Pitfalls (keep these fixes)

1. **Not a snapper plugin.** The first version ran as
   `/usr/lib/snapper/plugins/90-*.snapper`. That runs in `snapperd_t`, and
   SELinux denied creating the lock in `/run`. Giving that domain access to
   the signing key, the ESP and efivars is not acceptable. The systemd path
   unit runs unconfined.
2. **`root=/dev/disk/by-uuid/`, not `root=UUID=`.** `sdbootutil cleanup`
   treats every boot entry, UKIs included, as its own if its `root=` matches
   one of sdbootutil's spellings of the root fs (`get_all_rootfs`: findmnt
   SOURCE, `/dev/dm-N`, lsblk PATH, `UUID=`, `LABEL=`, `PARTUUID=`,
   `PARTLABEL=`). It deleted all UKIs twice. The by-uuid path is the same
   device to dracut, but sdbootutil does not recognise it. This depends on
   sdbootutil internals: after sdbootutil updates, check with
   `sdbootutil -vv cleanup` that no `uki-snap` file is mentioned.
3. **`set -euo pipefail`.** A `[[ … ]] && cmd` as the last command of a
   function or loop, inside a pipeline or `$(…)`, makes it return non-zero
   and aborts the script. Use `if` in those places.
4. **sudo** needs the full path (see above).
5. **Harmless noise:** sdbootutil's "WARNING: Can't determine the new
   default entry" during remove-all-kernels; `(reported/absent)` entries in
   `bootctl list` until the next reboot; ukify's "Using config file" and
   "+ sbsign" lines on stderr.

## Requirements outside this repo

- A signing key and certificate that the firmware (db) or shim (MOK) trusts,
  at `KEY`/`CERT` (default `/root/uki-signing/secureboot.{key,pem}`, root
  only). **Never commit keys.**
- `/boot/efi/loader/loader.conf` with `auto-entries no`.
- Packages: systemd-boot/ukify, sbsigntools, sdbootutil, snapper, btrfsprogs.

## Install

    sudo make install          # script + units, daemon-reload, enable --now the .path
    sudo /usr/local/sbin/uki-snapshots plan
    sudo systemctl start uki-snapshots.service

Settings are at the top of `bin/uki-snapshots`.

## Uninstall

    sudo make uninstall        # stops/disables the units, removes script and units

This leaves the UKIs, the default entry and `/var/lib/uki-snapshots` in
place. To remove those too, first move the default back to sdbootutil,
then delete the files:

    sudo sdbootutil set-default-snapshot "$(sudo btrfs subvolume get-default / | sed 's:.*/\.snapshots/\([0-9]*\)/.*:\1:')"
    sudo rm /boot/efi/EFI/Linux/uki-snap-*.efi
    sudo rm -r /var/lib/uki-snapshots

Entries that `UNBOOT_OTHERS` removed are not restored.
`sdbootutil add-all-kernels N` recreates them for snapshot N.

## Recovery

If a UKI does not boot, press Space (or hold it) at power-on to open the
systemd-boot menu and pick sdbootutil's entry for the current snapshot
("openSUSE Tumbleweed … (N@…)"). sdbootutil's entries stay in place for the
current snapshot and for the previous snapshots that the UKIs are built from.

## Threat model

- The signing key is stored **unencrypted** on the root fs (inside LUKS) and
  is the trust anchor: anyone with root on the running system can sign
  anything that this firmware will boot.
- As long as sdbootutil's type #1 entries stay bootable, the UKIs add little
  against an attacker with physical access. Those entries load an unsigned
  initrd from the unencrypted ESP, and their command line can be edited in
  the menu unless the editor is disabled in `loader.conf`.
- The script runs as root and reads data from snapshots: it sources
  `os-release` and parses `info.xml` with sed.

## License

GNU Affero General Public License v3.0, see [LICENSE](LICENSE).
