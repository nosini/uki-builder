# Development

`bin/uki-snapshots` is a Bash script; `bin/secureboot-keys` is a Python 3
helper. The systemd units are in `systemd/`.

## Checks

Install ShellCheck and bats, then run:

```sh
make check
```

This checks the shell scripts, compiles the Python source for syntax
checking and runs the bats suite against a mock system. The tests do not
require enrolling firmware keys or modifying a real ESP.

`make install` supports `DESTDIR`, `SBINDIR` and `UNITDIR` for staging.
With `DESTDIR` set, it copies files without enabling or starting units.
The runtime paths in the script and units still need to match the target
system.

## Implementation constraints

The [architecture guide](how-it-works.md) describes selection, state
hashing and pruning. Preserve these constraints when changing the scripts:

- Run builds through the systemd service rather than a snapper plugin.
  SELinux's `snapperd_t` domain is unsuitable for access to the signing
  key, ESP and efivars. The supplied service runs unconfined.
- Use `root=/dev/disk/by-uuid/…` in embedded command lines. sdbootutil
  cleanup recognizes other common spellings of the root device and can
  treat the UKIs as its own entries.
- With `set -euo pipefail`, a trailing `[[ … ]] && cmd` can make a function
  or loop return nonzero and abort the script. Use `if` when a false
  condition should succeed.
- Keep the service's five-second `ExecStartPre` delay or adjust systemd's
  start limit. Frequent rpm changes can otherwise exhaust the limit and
  stop the path watcher.
- Watch rpm's `Packages.db`, not its parent directory. The ndb backend
  rewrites `Index.db` during root queries even without package changes.
- Pass `--reproducible` to dracut explicitly; do not depend on another
  package's dracut configuration to supply it.
- Legacy state hashes did not follow symlink targets and included
  `Index.db`. `legacy_sysstate` and `take_over_legacy` support that cache
  format. Adoption is refused when tracked symlinks make the old hash
  insufficient to establish matching content.

Transient `(reported/absent)` entries in `bootctl list` can remain until a
reboot. ukify and dracut output is shown only when they fail.
