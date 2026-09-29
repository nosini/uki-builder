#!/usr/bin/env bats
# Regression tests: each case failed before its fix. Mostly about failures
# and untrusted input: the ESP, races with zypper and snapper, symlinks,
# and plan agreeing with sync.

load helpers

setup() {
    setup_system
    echo 971 >"$T/default"; echo 971 >"$T/booted"
    snapshot 971 single "writable copy of #900"
}

live() { echo "$T/snapshots/971/snapshot"; }

@test "a reused snapshot number with new contents does not reuse the old state" {
    uki sync
    transaction 972
    uki sync
    [ -e "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi" ]

    # snapper deletes 972 and creates a new 972 with other contents (within
    # the same second, so the birth time is the same)
    rm -rf "$T/snapshots/972"
    snapshot 972 pre "zypp(zypper)"
    echo "rpm-unrelated" >"$T/snapshots/972/snapshot/usr/lib/sysimage/rpm/Packages.db"
    touch "$T/snapshots/972/snapshot/.readonly"

    run uki sync
    echo "$output"
    [[ $output == *"no initrd built for the state of snapshot 972"* ]]
    [ ! -e "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi" ]
}

@test "a rollback during a run does not lose the initrd the retry needs" {
    echo 'PREVIOUS=1' >>"$T/conf"
    uki sync
    transaction 972
    uki sync                  # 972 has the initrd of the first state
    transaction 973           # now 973 is the previous snapshot, 972 drops out
    # snapper rollback 972 while the next run builds its UKIs
    cat >"$T/hook" <<EOF
$(declare -f snapshot copy_snapshot); T=$T KDEF=$KDEF KLT=$KLT
copy_snapshot 972 974 single "writable copy of #972"
echo 974 >"$T/default"
EOF
    run uki sync
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "initrd-content initrd $KDEF rpm-1" "$T/esp/EFI/Linux/uki-snap-974-$KDEF.efi"
    [ "$(efi_default)" = "uki-snap-974-$KDEF.efi" ]
}

@test "a boot loader changing during a run is installed as it is now" {
    echo 'SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)' >>"$T/conf"
    # systemd-boot is updated (and the rpm database changes) while it is signed
    cat >"$T/sign-hook" <<EOF
printf 'sd-boot code\n#### LoaderInfo: systemd-boot 262 ####\n' >"$T/stubs/systemd-bootx64.efi"
echo "rpm after sd-boot 262" >"$(live)/usr/lib/sysimage/rpm/Packages.db"
EOF
    run uki sync
    echo "$output"
    grep -q "systemd-boot 262 " "$T/esp/EFI/systemd/systemd-bootx64.efi"
    : >"$T/calls"
    uki sync
    ! grep -q '^sbsign' "$T/calls"
}

@test "a failed initrd for a new kernel keeps that flavor's existing UKI" {
    uki sync
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
    # a newer longterm kernel is installed, and dracut fails
    mkdir -p "$(live)/usr/lib/modules/6.12.49-1-longterm"
    echo "vmlinuz new" >"$(live)/usr/lib/modules/6.12.49-1-longterm/vmlinuz"
    echo "rpm-new-kernel" >"$(live)/usr/lib/sysimage/rpm/Packages.db"
    touch "$T/dracut_fail"

    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]

    # once dracut works again, the new one replaces it
    rm "$T/dracut_fail"
    run uki sync
    [ "$status" -eq 0 ]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-6.12.49-1-longterm.efi" ]
    [ ! -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
}

@test "a failed build of an existing initrd keeps that flavor's UKI" {
    uki sync
    transaction 972            # a new state; the build of the new UKI fails
    mkdir -p "$(live)/usr/lib/modules/6.12.49-1-longterm"
    echo "vmlinuz new" >"$(live)/usr/lib/modules/6.12.49-1-longterm/vmlinuz"
    mock ukify 'exit 1'
    run uki sync
    [ "$status" -eq 1 ]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
}

@test "a changed symlink target is a new state" {
    mv "$(live)/etc/crypttab" "$(live)/etc/crypttab.real"
    ln -s /etc/crypttab.real "$(live)/etc/crypttab"
    uki sync
    : >"$T/calls"
    echo "luks UUID=y none fido2-device=auto" >"$(live)/etc/crypttab.real"
    uki sync
    grep -q '^dracut' "$T/calls"
}

@test "an absolute symlink in a snapshot is resolved inside that snapshot" {
    mv "$(live)/etc/crypttab" "$(live)/etc/crypttab.real"
    ln -s /etc/crypttab.real "$(live)/etc/crypttab"
    uki sync
    transaction 972
    # the snapshot's own target, not the running system's, decides
    echo "changed later" >"$(live)/etc/crypttab.real"
    run uki sync
    grep -qx "initrd-content initrd $KDEF rpm-1" "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi"
}

@test "a rewritten rpm index alone does not change the state" {
    echo "index 1" >"$(live)/usr/lib/sysimage/rpm/Index.db"
    uki sync
    echo "index 2" >"$(live)/usr/lib/sysimage/rpm/Index.db"
    transaction 972
    run uki sync
    echo "$output"
    [ -e "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi" ]
}

@test "a UKI replaced on the ESP is rebuilt" {
    uki sync
    echo "an older signed image" >"$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi"
    : >"$T/calls"
    uki sync
    grep -q "^ukify .*--uname=$KDEF" "$T/calls"
    grep -q -- "--uname=$KDEF" "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi"
}

@test "a config file writable by others is refused" {
    chmod 666 "$T/conf"
    run uki plan
    [ "$status" -eq 1 ]
    [[ $output == *"refusing"* ]]
}

@test "state and fingerprints from the previous format are taken over" {
    legacy=$BATS_TEST_DIRNAME/fixtures/uki-snapshots-v1
    old() { unshare -r env -u JOURNAL_STREAM UKI_SNAPSHOTS_CONF="$T/conf" "$legacy" "$@"; }
    echo "index 1" >"$(live)/usr/lib/sysimage/rpm/Index.db"
    old sync
    transaction 972
    old sync
    [ -e "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi" ]

    # plan already shows the takeover, and writes nothing
    local gens_before
    gens_before=$(ls "$T/state/gen")
    run uki plan
    echo "$output"
    [[ $output == *"take over the initrds of $T/snapshots/972/snapshot"* ]]
    [[ $output != *"dracut  "* && $output != *"remove  "* ]]
    [[ $output == *"build   uki-snap-972-$KDEF.efi"* ]]
    [ "$(ls "$T/state/gen")" = "$gens_before" ]

    : >"$T/calls"
    run uki sync
    echo "$output"
    [ "$status" -eq 0 ]
    # 972 keeps its initrd, and nothing needs dracut
    grep -qx "initrd-content initrd $KDEF rpm-1" "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi"
    ! grep -q '^dracut' "$T/calls"
}


@test "giving up on a busy zypper keeps the initrd cache" {
    uki sync
    transaction 972
    uki sync
    local before
    before=$(ls "$T/state/initrd" "$T/state/gen")
    sleep 60 &
    echo $! >"$T/run/zypp.pid"
    run uki sync
    kill %1
    [ "$status" -eq 1 ]
    [ "$(ls "$T/state/initrd" "$T/state/gen")" = "$before" ]
}

@test "a corrupt file at the new kernel's name never becomes the default" {
    uki sync
    local newk=7.2.8-1-default
    mkdir -p "$(live)/usr/lib/modules/$newk"
    echo "vmlinuz $newk" >"$(live)/usr/lib/modules/$newk/vmlinuz"
    echo "rpm-new-kernel" >"$(live)/usr/lib/sysimage/rpm/Packages.db"
    echo "corrupt" >"$T/esp/EFI/Linux/uki-snap-971-$newk.efi"
    mock ukify 'if [[ $1 == --version ]]; then echo "ukify 261"; exit 0; fi; exit 1'

    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [ "$(efi_default)" = "uki-snap-971-$KDEF.efi" ]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]
    [ ! -e "$T/esp/EFI/Linux/uki-snap-971-$newk.efi" ]
}

@test "output of a failed signing is never installed" {
    echo 'SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)' >>"$T/conf"
    # the first signing writes its output, then fails; the system changes too
    mock sbsign <<'EOF'
echo "sbsign $*" >>"$T/calls"
while [[ $1 == --* ]]; do
    case $1 in --cert) cert=$2 ;; --output) out=$2 ;; esac
    shift 2
done
if [[ ! -e $T/signed-once ]]; then
    touch "$T/signed-once"
    echo BROKEN >"$out"
    echo "rpm changed" >"$T/snapshots/971/snapshot/usr/lib/sysimage/rpm/Packages.db"
    exit 1
fi
{ cat "$1"; echo "signed by $(cat "$cert")"; } >"$out"
EOF
    run uki sync
    echo "$output"
    ! grep -q BROKEN "$T/esp/EFI/systemd/systemd-bootx64.efi"
    grep -qx "signed by cert" "$T/esp/EFI/systemd/systemd-bootx64.efi"
}

@test "symlinks in the middle of a path resolve inside the root" {
    mkdir -p "$(live)/etc/local-db"
    mv "$(live)/etc/crypttab" "$(live)/etc/local-db/crypttab"
    ln -s /etc/local-db "$(live)/etc/link-db"
    ln -s /etc/link-db/crypttab "$(live)/etc/crypttab"
    uki sync
    : >"$T/calls"
    echo "luks UUID=z none fido2-device=auto" >"$(live)/etc/local-db/crypttab"
    uki sync
    grep -q '^dracut' "$T/calls"
}

@test "no takeover of the old format when symlinks are involved" {
    legacy=$BATS_TEST_DIRNAME/fixtures/uki-snapshots-v1
    mv "$(live)/etc/crypttab" "$(live)/etc/crypttab.real"
    ln -s /etc/crypttab.real "$(live)/etc/crypttab"
    unshare -r env -u JOURNAL_STREAM UKI_SNAPSHOTS_CONF="$T/conf" "$legacy" sync
    echo "changed target" >"$(live)/etc/crypttab.real"
    : >"$T/calls"
    run uki sync
    echo "$output"
    [[ $output != *"took over"* ]]
    grep -q '^dracut' "$T/calls"
}

@test "plan does not announce a default sync cannot set" {
    uki sync
    snapshot 973 single "writable copy of #900"
    echo "rpm-old" >"$T/snapshots/973/snapshot/usr/lib/sysimage/rpm/Packages.db"
    echo 973 >"$T/default"
    run uki plan
    echo "$output"
    [[ $output != *"default uki-snap-973"* ]]
    [[ $output == *"no default UKI for snapshot 973"* ]]
}

@test "a held fallback that was changed on the ESP is restored to the version it held" {
    echo 'SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)' >>"$T/conf"
    echo 'SDBOOT_FALLBACK=(EFI/BOOT/BOOTX64.EFI)' >>"$T/conf"
    booted_sdboot 261
    uki sync
    sdboot_release 262
    uki sync                  # the fallback is held at 261
    echo "tampered" >"$T/esp/EFI/BOOT/BOOTX64.EFI"
    run uki plan
    [[ $output == *"restore EFI/BOOT/BOOTX64.EFI"* ]]
    run uki sync
    echo "$output"
    # restored from the copy in $STATE: still the version that has booted
    ! grep -q tampered "$T/esp/EFI/BOOT/BOOTX64.EFI"
    grep -q "systemd-boot 261 " "$T/esp/EFI/BOOT/BOOTX64.EFI"
    grep -qx "signed by cert" "$T/esp/EFI/BOOT/BOOTX64.EFI"
}

@test "a held fallback without a saved copy is replaced with the current version" {
    echo 'SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)' >>"$T/conf"
    echo 'SDBOOT_FALLBACK=(EFI/BOOT/BOOTX64.EFI)' >>"$T/conf"
    booted_sdboot 261
    uki sync
    sdboot_release 262
    uki sync
    rm -rf "$T/state/bootloader"
    echo "tampered" >"$T/esp/EFI/BOOT/BOOTX64.EFI"
    run uki sync
    echo "$output"
    grep -q "systemd-boot 262 " "$T/esp/EFI/BOOT/BOOTX64.EFI"
}

@test "a kernel flavor removed from the current snapshot loses its UKI" {
    uki sync
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
    rm -rf "$(live)/usr/lib/modules/$KLT"
    echo "rpm without longterm" >"$(live)/usr/lib/sysimage/rpm/Packages.db"
    run uki sync
    [ "$status" -eq 0 ]
    [ ! -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]
}


@test "a missing cmdline does not pass for removed kernels" {
    uki sync
    rm "$(live)/etc/kernel/cmdline"
    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [ -f "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
    [ -f "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]
}

@test "plan announces no default whose build must fail" {
    uki sync
    copy_snapshot 971 973 single
    rm "$T/snapshots/973/snapshot/usr/lib/os-release"
    echo 973 >"$T/default"
    run uki plan
    echo "$output"
    [[ $output != *'default uki-snap-973-'* ]]
    run uki sync
    [ "$(efi_default)" = "uki-snap-971-$KDEF.efi" ]
}

@test "plan shows the removal of a flavor whose kernel is gone" {
    uki sync
    rm -rf "$(live)/usr/lib/modules/$KLT"
    run uki plan
    echo "$output"
    [[ $output == *"remove  uki-snap-971-$KLT.efi"* ]]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
    uki sync
    [ ! -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
}

@test "a symlink chain past the limit does not reach outside the snapshot" {
    local i r
    r=$(live)
    uki sync
    echo outside >"$T/outside"
    rm "$r/etc/crypttab"
    for ((i = 0; i < 40; i++)); do ln -s "link$((i + 1))" "$r/etc/link$i"; done
    ln -s "$T/outside" "$r/etc/link40"
    ln -s link0 "$r/etc/crypttab"
    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"cannot determine the state"* ]]
    # no initrd from an unknowable state, and the working UKIs stay
    ! grep -q '^dracut' "$T/calls"
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KLT.efi" ]
    [ "$(ls "$T/state/initrd" | wc -l)" -eq 2 ]
}

@test "a FIFO as config file is refused without blocking" {
    rm "$T/conf"
    mkfifo -m 600 "$T/conf"
    run timeout 5 unshare -r env -u JOURNAL_STREAM UKI_SNAPSHOTS_CONF="$T/conf" "$SCRIPT" plan
    echo "$output"
    [ "$status" -ne 124 ]
    [ "$status" -ne 0 ]
    [[ $output == *"refusing"* ]]
}

@test "a symlink loop makes the state unknown, not missing" {
    uki sync
    rm "$(live)/etc/crypttab"
    ln -s loop-b "$(live)/etc/crypttab"
    ln -s crypttab "$(live)/etc/loop-b"
    : >"$T/calls"
    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"cannot determine the state"* ]]
    ! grep -q '^dracut' "$T/calls"
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]
}


@test "a state that turns unknown during dracut stops the cache GC" {
    uki sync
    local before
    before=$(find "$T/state/gen" "$T/state/initrd" -type f | sort)
    echo rpm2 >"$(live)/usr/lib/sysimage/rpm/Packages.db"
    cp "$T/bin/dracut" "$T/bin/dracut-original"
    mock dracut <<'EOF'
"$T/bin/dracut-original" "$@"
p=$T/snapshots/971/snapshot/etc/crypttab
if [[ ! -L $p ]]; then rm "$p"; ln -s crypttab "$p"; fi
EOF
    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"initrds discarded"* ]]
    [ "$(find "$T/state/gen" "$T/state/initrd" -type f | sort)" = "$before" ]
}

@test "a previous snapshot with an unknown state keeps its UKIs" {
    uki sync
    transaction 972
    uki sync
    rm "$T/state/sysstate/972"
    # reading the snapshot fails (without changing the read-only snapshot)
    mock sha256sum <<'EOF'
if [[ $(readlink /proc/$$/fd/0) == *"/snapshots/972/"* ]]; then
    echo "simulated read error" >&2
    exit 1
fi
exec /usr/bin/sha256sum "$@"
EOF
    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"cannot determine the state of snapshot 972"* ]]
    [ -f "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi" ]
    [ -f "$T/esp/EFI/Linux/uki-snap-972-$KLT.efi" ]
}

@test "a failed directory listing is not an empty directory" {
    mkdir -p "$(live)/etc/modprobe.d"
    echo "options x y=1" >"$(live)/etc/modprobe.d/x.conf"
    mock find <<'EOF'
if [[ $1 == */etc/modprobe.d ]]; then echo "simulated find error" >&2; exit 1; fi
exec /usr/bin/find "$@"
EOF
    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"cannot determine the state of the running system"* ]]
    ! grep -q '^dracut' "$T/calls"
}

@test "a failed readlink is not an empty link target" {
    mv "$(live)/etc/crypttab" "$(live)/etc/crypttab.real"
    ln -s /etc/crypttab.real "$(live)/etc/crypttab"
    mock readlink <<'EOF'
if [[ $1 == */etc/crypttab ]]; then echo "simulated readlink error" >&2; exit 1; fi
exec /usr/bin/readlink "$@"
EOF
    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"cannot determine the state of the running system"* ]]
    ! grep -q '^dracut' "$T/calls"
}

@test "plan knows the store copy sync saves before restoring from it" {
    echo 'SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)' >>"$T/conf"
    echo 'SDBOOT_FALLBACK=(EFI/BOOT/BOOTX64.EFI)' >>"$T/conf"
    booted_sdboot 261
    uki sync
    # as after an upgrade from a version without the store, before 261 booted
    rm -rf "$T/state/bootloader"
    booted_sdboot 260
    echo corrupt >"$T/esp/EFI/BOOT/BOOTX64.EFI"
    run uki plan
    echo "$output"
    local plan_output=$output
    [ ! -d "$T/state/bootloader" ]
    run uki sync
    echo "$output"
    [[ $output == *"EFI/BOOT/BOOTX64.EFI was not the file installed there; restored it"* ]]
    [[ $plan_output == *"restore EFI/BOOT/BOOTX64.EFI"* ]]
}

@test "plan knows the initrd a previous snapshot shares with the running system" {
    copy_snapshot 971 972 pre "zypp(zypper)"
    touch "$T/snapshots/972/snapshot/.readonly"
    run uki plan
    echo "$output"
    local plan_output=$output
    run uki sync
    [ "$status" -eq 0 ]
    [ -e "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi" ]
    [[ $plan_output == *"build   uki-snap-972-$KDEF.efi  (after dracut)"* ]]
}
