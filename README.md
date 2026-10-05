# uki-snapshots

Build and sign Unified Kernel Images (UKIs) for openSUSE Tumbleweed snapper
snapshots, so you can boot the current system or a snapshot from before a
package update through systemd-boot.

Each image contains the snapshot's kernel and command line, plus an initrd
built on the running system and matched to the snapshot's package and
configuration state. Nothing from the unencrypted ESP or `/boot` is used
as image content. Images are signed with your Secure Boot key.

The service keeps images up to date after package updates, configuration
changes and snapper cleanup. By default it keeps the newest `default` and
`longterm` kernels, where installed, for the current snapshot and two
recent zypper pre snapshots.

## Requirements

This project is designed for openSUSE Tumbleweed with:

- An encrypted btrfs root managed by snapper, with a snapper snapshot as
  the btrfs default subvolume and snapshots accessible at `/.snapshots`.
- systemd-boot, an ESP mounted at `/boot/efi`, and a working signed UKI
  boot before using the service.
- A signing key and certificate trusted by the firmware's Secure Boot db
  or by shim's MOK, and a snapshot-local `/etc/kernel/cmdline`.
- `btrfs`, `findmnt`, `dracut`, `ukify`, `sbsign`, `sbverify` and `bootctl`.
  These are provided by btrfsprogs, util-linux, dracut, systemd-boot/ukify
  and sbsigntools. Installation also uses `make`.
- `/var/lib/uki-snapshots` shared across snapshots, with room for cached
  initrds, and enough ESP space for the selected images.

`uki-snapshots` replaces sdbootutil's snapshot boot management. Remove
sdbootutil and its hooks before enabling the service; its cleanup can
remove these UKIs. See [boot setup and migration](docs/secure-boot.md).

## Install

In the source directory, create `/etc/uki-snapshots.conf` with the paths to
your existing signing key and certificate. The defaults are:

```bash
KEY=/root/uki-signing/secureboot.key
CERT=/root/uki-signing/secureboot.pem
```

Keep the key private and outside the repository. The configuration must be
owned by root, not writable by anyone else, and stored outside the ESP.

```sh
sudoedit /etc/uki-snapshots.conf
sudo chown root:root /etc/uki-snapshots.conf
sudo chmod 600 /etc/uki-snapshots.conf
sudo make install
sudo /usr/local/sbin/uki-snapshots plan
sudo systemctl start uki-snapshots.service
```

Installation enables the service for subsequent boots and starts the path
watcher. The first run builds initrds for the current system. Older snapshots
without a matching cached initrd cannot get a UKI; pre snapshots from
subsequent package transactions can use the cache.

## Use

Updates run automatically. To preview or apply changes manually:

```sh
sudo /usr/local/sbin/uki-snapshots plan
sudo /usr/local/sbin/uki-snapshots sync
```

Use the full path because sudo's search path may omit `/usr/local/sbin`.
Check service status and warnings with:

```sh
systemctl status uki-snapshots.service
sudo journalctl -u uki-snapshots.service
```

Hold Space at startup to open the systemd-boot menu. Choose another kernel
or a previous snapshot if the default image fails to boot. Previous
snapshots boot read-only; run `sudo snapper rollback` to make a writable
rollback copy the default. If no cached initrd matches the rollback target,
the boot default stays on the existing image and the service reports a
warning.

For live-media recovery or firmware key resets, see the
[Secure Boot guide](docs/secure-boot.md#recovery).

## Configuration

Override defaults in `/etc/uki-snapshots.conf`, using Bash syntax. For
example, to keep three previous snapshots and only the default kernel:

```bash
PREVIOUS=3
FLAVORS=(default)
DEFAULT_FLAVOR=default
```

Other settings include `ESP`, `MARGIN_MIB` (64 MiB by default),
`SET_DEFAULT` and `NOTIFY`. Desktop failure notifications are enabled by
default. The complete defaults are at the top of
[`bin/uki-snapshots`](bin/uki-snapshots).

Boot loader signing and firmware key management are optional; see the
[Secure Boot guide](docs/secure-boot.md). Details of snapshot selection,
initrd matching and failure handling are in
[how it works](docs/how-it-works.md).

## Uninstall

From the source directory:

```sh
sudo make uninstall
```

This removes the scripts and units. It leaves the UKIs, boot default and
cache in place; they will no longer be updated. Set up and test a
replacement boot path before removing those files. Instructions for
returning to sdbootutil are in the [migration guide](docs/secure-boot.md#returning-to-sdbootutil).

## Development

See [development notes](docs/development.md) for checks and implementation
constraints.

## License

GNU Affero General Public License v3.0, see [LICENSE](LICENSE).
