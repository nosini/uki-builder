# Boot setup and Secure Boot

`uki-snapshots` manages signed snapshot images. Boot loader installation,
firmware trust and disk-unlock policy must be configured separately. The
`secureboot-keys` helper can replace firmware keys, but is optional and is
not run by `make install` or the snapshot service.

## Replacing sdbootutil

Before changing boot management, back up the ESP, firmware boot entries
and Secure Boot keys, and keep a recovery medium available. First establish
and test a boot path that trusts your signing certificate.

Remove sdbootutil and its snapshot hooks, then lock the packages to prevent
automatic reinstallation:

```sh
sudo zypper remove sdbootutil sdbootutil-snapper sdbootutil-dracut-measure-pcr
sudo zypper addlock 'sdbootutil*'
```

sdbootutil has several entry points: a snapper plugin, an rpm file trigger
and kernel update scripts in suse-module-tools. The kernel scripts check
its ESP marker, `EFI/systemd/installed_by_sdbootutil`; the rpm trigger also
uses `LOADER_TYPE`. Removing only one hook is insufficient.

After testing the replacement, remove obsolete sdbootutil entries, kernel
and initrd copies, and its ESP marker. Review the files before deleting
them; retain any boot path needed for recovery. Without sdbootutil, kernel
updates can still write kernels and initrds to `/boot`, but uki-snapshots
does not use those copies.

For a menu restricted to signed UKIs, disable automatic entries and command
line editing in the ESP's `loader/loader.conf`:

```text
auto-entries no
editor no
```

Review existing manual entries as well, including entries that load an
unsigned initrd or a UEFI shell. These settings do not remove those files.

Installation files inside snapshotted subvolumes can disappear after a
rollback. If the rollback target predates the installation, reinstall from
the source directory with `sudo make install` after booting it. Keeping
`/usr/local/sbin` in a separate btrfs subvolume can preserve the scripts
across rollbacks, but the service units still need to be present and enabled.

## Signing systemd-boot

To have the firmware boot systemd-boot directly, trust the signing
certificate in the firmware db and configure:

```bash
SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)
SDBOOT_FALLBACK=(EFI/BOOT/BOOTX64.EFI)
```

Both arrays are empty by default. Enabling this feature also requires
`sbattach` from sbsigntools. The script signs systemd-boot from the running
system with the UKI key. Destination copies update immediately; fallback
copies update only after that version has booted, preserving a working
fallback if an update fails. See [how it works](how-it-works.md).

Create a firmware entry for the destination and test it with
`sudo efibootmgr --bootnext XXXX`, replacing `XXXX` with its entry number.
Make the tested entry first in the boot order before replacing firmware
keys that might prevent shim from running.

## Replacing firmware keys

Trusting your own certificate alongside the Microsoft third-party UEFI
CAs still allows other boot chains signed by those CAs. The helper creates
a more restricted set:

| Variable | Contents |
| --- | --- |
| PK | Your platform key |
| KEK | Your key exchange key and the Microsoft KEKs named in `KEEP_KEK` |
| db | Your UKI signing certificate, the Windows CAs named in `KEEP_DB`, and hashes of loaded option ROMs from the TPM event log |
| dbx | The existing revocation list |

Other db certificates are dropped. This can prevent shim, live media and
option ROMs from starting. The Windows CAs remain trusted, and the retained
Microsoft KEKs allow signed updates to the signature databases.

The helper requires Python 3, OpenSSL, efitools and a readable TPM event
log. It also requires the Microsoft certificates listed in `KEEP_KEK` and
`KEEP_DB` to be present in the current firmware variables; otherwise it
refuses to build.

Before enrollment:

1. Set a firmware administrator password if protection against physical
   changes to Secure Boot is part of your threat model.
2. Trust your signing certificate in db and test direct boot of the signed
   systemd-boot as described above.
3. Put the tested entry first in the boot order.
4. Keep any BitLocker recovery key available; changing Secure Boot policy
   can require Windows recovery.

Build the enrollment files **before** resetting the firmware keys, while
the existing certificates and revocation list are still available:

```sh
sudo /usr/local/sbin/secureboot-keys build
```

This creates missing PK and KEK private keys in `/root/secureboot-owner`
and writes enrollment files under `/root/secureboot-owner/enroll`. The
signing certificate defaults to `/root/uki-signing/secureboot.pem`. Keep
an offline backup of the private keys and enrollment files. The helper's
paths can be overridden with environment variables; see
[`bin/secureboot-keys`](../bin/secureboot-keys).

Review the printed key set. In firmware setup, reset to Setup Mode and
decline any offer to install factory keys. Then boot Linux and enroll:

```sh
sudo /usr/local/sbin/secureboot-keys enroll
```

Enrollment writes db, dbx, KEK and PK, in that order, and checks each value
by reading it back. Enable Secure Boot again in firmware setup and check:

```sh
mokutil --sb-state
mokutil --pk
systemctl status uki-snapshots.service
```

To report if the third-party CAs reappear in db, add this to
`/etc/uki-snapshots.conf`:

```bash
DB_FORBIDDEN=('Microsoft Corporation UEFI CA 2011' 'Microsoft UEFI CA 2023')
```

This check reports a service failure; it does not remove certificates.

Option ROM hashes permit hardware firmware signed only by an excluded CA.
A new graphics card or firmware update can change the hash and prevent
preboot display output. If the graphics driver is included in the initrd,
display output may return when Linux loads it. Rebuild the key set from the
new TPM event log and enroll it to authorize the new ROM.

## Recovery

If one UKI fails, hold Space at startup and try another kernel or snapshot.
A read-only snapshot boot does not rebuild images. Use
`sudo snapper rollback` to create a writable rollback target.

If none boots, use live media. With restricted firmware keys, this may
require disabling Secure Boot or restoring factory keys first. Unlock and
mount the root file system and its required mounts, enter a chroot, and run
`sudo /usr/local/sbin/uki-snapshots sync`, or restore another boot manager.
Turn Secure Boot back on once the trusted boot path is restored.

Firmware updates can reset keys and remove boot entries. If the signed
boot loader is refused, disable Secure Boot temporarily to boot Linux.
Use the saved enrollment files to restore the keys in Setup Mode, then
re-enable Secure Boot. Rebuild first if an option ROM changed, while the
certificates required for the build are available.

The fallback path `EFI/BOOT/BOOTX64.EFI` can still start systemd-boot when
its firmware entry is gone. To recreate the entry, replace `/dev/DISK` and
`N` with the ESP's disk and partition number:

```sh
sudo efibootmgr --create --disk /dev/DISK --part N \
  --label 'systemd-boot' --loader '\EFI\systemd\systemd-bootx64.efi'
```

Check that firmware password protection also survived the update. Restoring
factory keys does not restore your signing certificate, so it alone does
not make your UKIs bootable with Secure Boot enabled.

## Returning to sdbootutil

Restore sdbootutil's boot path before deleting managed UKIs or cached
initrds. Ensure its boot chain is trusted by the current firmware policy;
restricted keys may require restoring certificates or factory keys first.

```sh
sudo make uninstall
sudo zypper removelock 'sdbootutil*'
sudo zypper install sdbootutil sdbootutil-snapper
sudo sdbootutil install
sudo sdbootutil add-all-kernels
sudo sdbootutil set-default-snapshot
```

After testing that boot path, remove the managed images and cache:

```sh
sudo rm /boot/efi/EFI/Linux/uki-snap-*.efi
sudo rm -r /var/lib/uki-snapshots
```

Adjust the paths if you changed `ESP`, `PREFIX` or `STATE`.

## Security assumptions and limits

The intended threat is offline modification of unencrypted storage by an
attacker with physical access. The encrypted root, snapshots, shared state
and signing key are trusted. The running system must have booted a trusted
signed UKI, since dracut runs there. Neither the ESP nor `/boot` supplies
image content.

The signing key is the trust anchor. Root access to the running system can
use it to sign arbitrary images. The configuration file is also an
administrator interface: it is sourced as root after ownership and
permission checks.

Protection depends on the boot configuration. Unsigned initrds, editable
command lines, alternative trusted boot chains and firmware settings can
weaken it. Restricted firmware keys reduce the accepted boot chains but
still trust the retained Windows CAs and option ROM hashes. A hardware
reset may clear firmware passwords or keys, depending on the firmware.

Disk-unlock policy is separate from this project. Requiring a passphrase
or a FIDO2 key avoids automatically unlocking a disk just because a signed
image booted. The scripts do not configure unlock methods or prove to you
that the expected image booted before you unlock it.

Old signed UKIs remain valid while their key is trusted. An attacker can
restore an older signed image to the ESP. Content fingerprints detect
replacement on the next sync, but do not prevent that image from booting
first or provide rollback protection.

ESP file presence and hashes affect rebuilding and pruning, even though
its content is never embedded in an image. The boot default is read from a
firmware variable once per run; concurrent changes by another tool are
not guarded against.
