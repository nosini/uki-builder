#!/usr/bin/env bats
# Run with: bats tests/

load helpers

# Live system 971 (default and booted), three older zypper pre snapshots
# that were made before any initrd was cached, a post snapshot, and leftover
# sdbootutil entries with tampered content.
setup() {
    setup_system
    echo 971 >"$T/default"; echo 971 >"$T/booted"
    snapshot 971 single "writable copy of #900"
    for n in 955 960 965; do
        snapshot "$n" pre "zypp(zypper)"
        echo "rpm-old-$n" >"$T/snapshots/$n/snapshot/usr/lib/sysimage/rpm/Packages.db"
        touch "$T/snapshots/$n/snapshot/.readonly"
    done
    snapshot 966 post
    for n in 971 955 960 965 966; do esp_entry "$n" "$KDEF"; esp_entry "$n" "$KLT"; done
}

@test "first sync: current UKIs from trusted inputs only" {
    run uki sync
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^dracut' "$T/calls")" -eq 2 ]
    [ "$(ukis)" = "uki-snap-971-$KLT.efi
uki-snap-971-$KDEF.efi" ]

    local img=$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi
    grep -qx -- "--linux=$T/snapshots/971/snapshot/usr/lib/modules/$KDEF/vmlinuz" "$img"
    grep -qx -- "--cmdline=root=/dev/disk/by-uuid/$UUID rootflags=subvol=@/.snapshots/971/snapshot splash=silent quiet" "$img"
    grep -q -- "--initrd=$T/state/initrd/" "$img"
    grep -qx "initrd-content initrd $KDEF rpm-1" "$img"
    grep -qx -- "--uname=$KDEF" "$img"
    # nothing from the ESP
    ! grep -q -e "$T/esp" -e evil "$img"

    [ "$(efi_default)" = "uki-snap-971-$KDEF.efi" ]
}

@test "previous snapshots without a cached initrd get no UKI; sdbootutil is never used" {
    run uki sync
    [ "$status" -eq 0 ]
    [[ $output == *"no initrd built for the state of snapshot 965"* ]]
    ! ls "$T/esp/EFI/Linux" | grep -q -e 965 -e 960
    ! grep -q sdbootutil "$T/calls"
    # leftover entries are not touched either
    [ "$(ls "$T/esp/loader/entries" | wc -l)" -eq 10 ]
}

@test "second sync changes nothing" {
    uki sync
    : >"$T/calls"
    run uki sync
    [ "$status" -eq 0 ]
    [ ! -s "$T/calls" ]
}

@test "a new pre snapshot gets the initrd of the state it was taken from" {
    uki sync
    local old
    old=$(grep -h -- "--initrd=" "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi")
    transaction 972
    : >"$T/calls"

    run uki sync
    echo "$output"
    [ "$status" -eq 0 ]
    # 972 boots with the initrd that was built before the transaction
    grep -qx -- "$old" "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi"
    grep -qx "initrd-content initrd $KDEF rpm-1" "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi"
    grep -q -- "rootflags=subvol=@/.snapshots/972/snapshot " "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi"
    # the current system got a new one
    grep -qx "initrd-content initrd $KDEF rpm after 972" "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi"
    # both initrds stay cached
    [ "$(ls "$T/state/initrd" | wc -l)" -eq 4 ]
}

@test "a change of the system while dracut runs discards its initrds" {
    touch "$T/dracut_mutate"
    run uki sync
    echo "$output"
    [[ $output == *"initrds discarded"* ]]
    # the next attempt in the same run builds them from the new state
    [ "$status" -eq 0 ]
    grep -q "changed during dracut" "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi"
}

@test "dracut failure: the existing current UKI stays, and stays the default" {
    uki sync
    echo "rpm-2" >"$T/snapshots/971/snapshot/usr/lib/sysimage/rpm/Packages.db"
    touch "$T/dracut_fail"
    run uki sync
    [ "$status" -eq 1 ]
    [[ $output == *"dracut failed"* ]]
    # the existing UKI stays the default
    [ -f "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]
    [ "$(efi_default)" = "uki-snap-971-$KDEF.efi" ]
}

@test "rollback to a copy of a previous snapshot: its initrd, no dracut" {
    uki sync
    transaction 972
    uki sync
    # snapper rollback 972: new writable copy 973 becomes the default
    snapshot 973 single "writable copy of #972"
    rm -rf "$T/snapshots/973/snapshot"
    cp -a "$T/snapshots/972/snapshot" "$T/snapshots/973/snapshot"
    rm "$T/snapshots/973/snapshot/.readonly"
    echo 973 >"$T/default"
    : >"$T/calls"

    run uki sync
    echo "$output"
    [ "$status" -eq 0 ]
    ! grep -q '^dracut' "$T/calls"
    grep -qx "initrd-content initrd $KDEF rpm-1" "$T/esp/EFI/Linux/uki-snap-973-$KDEF.efi"
    [ "$(efi_default)" = "uki-snap-973-$KDEF.efi" ]
    # the running system's UKI is gone once the default moved
    [ ! -e "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]
}

@test "rollback to a snapshot without the path unit: its UKI boots, with a warning" {
    uki sync
    transaction 972
    uki sync
    snapshot 973 single "writable copy of #972"
    rm -rf "$T/snapshots/973/snapshot"
    cp -a "$T/snapshots/972/snapshot" "$T/snapshots/973/snapshot"
    rm "$T/snapshots/973/snapshot/.readonly"
    rm "$T/snapshots/973/snapshot/etc/systemd/system/paths.target.wants/uki-snapshots.path"
    echo 973 >"$T/default"

    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"not enabled in snapshot 973"* ]]
    [ "$(efi_default)" = "uki-snap-973-$KDEF.efi" ]
}

@test "rollback to a snapshot without an initrd: the default stays on the running system" {
    uki sync
    snapshot 973 single "writable copy of #900"
    echo "rpm-old" >"$T/snapshots/973/snapshot/usr/lib/sysimage/rpm/Packages.db"
    echo 973 >"$T/default"

    run uki sync
    echo "$output"
    [ "$status" -eq 1 ]
    [[ $output == *"no default UKI for snapshot 973"* ]]
    [ "$(efi_default)" = "uki-snap-971-$KDEF.efi" ]
    [ -e "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi" ]
    ! ls "$T/esp/EFI/Linux" | grep -q 973
}

@test "booted from a read-only snapshot: nothing happens" {
    echo true >"$T/root_ro"
    run uki sync
    [ "$status" -eq 0 ]
    [[ $output == *"read-only snapshot"* ]]
    [ ! -s "$T/calls" ]
    [ -z "$(ukis)" ]
}

@test "plan changes nothing" {
    run uki plan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ $output == *"dracut  $KDEF"* ]]
    [[ $output == *"build   uki-snap-971-$KDEF.efi  (after dracut)"* ]]
    [ ! -s "$T/calls" ]
    [ -z "$(ukis)" ]
    [ -z "$(ls "$T/state/sysstate")" ]
}

@test "a deleted previous snapshot loses its UKI and cached initrd" {
    uki sync
    transaction 972
    uki sync
    [ -e "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi" ]
    rm -rf "$T/snapshots/972"

    run uki sync
    [ "$status" -eq 0 ]
    [ ! -e "$T/esp/EFI/Linux/uki-snap-972-$KDEF.efi" ]
    [ "$(ls "$T/state/initrd" | wc -l)" -eq 2 ]
    [ ! -e "$T/state/sysstate/972" ]
}

@test "cmdline: root= and subvol= replaced, other rootflags kept" {
    echo "root=/dev/mapper/main-root rootflags=subvol=@/old,compress=zstd quiet
security=selinux" >"$T/snapshots/971/snapshot/etc/kernel/cmdline"
    run uki sync
    [ "$status" -eq 0 ]
    grep -qx -- "--cmdline=root=/dev/disk/by-uuid/$UUID rootflags=subvol=@/.snapshots/971/snapshot,compress=zstd quiet security=selinux" \
        "$T/esp/EFI/Linux/uki-snap-971-$KDEF.efi"
}

@test "zypper running: nothing is done until it finishes" {
    sleep 60 &
    echo $! >"$T/run/zypp.pid"
    run uki sync
    kill %1
    [ "$status" -eq 1 ]
    [[ $output == *"still busy"* ]]
    [ ! -s "$T/calls" ]
}

@test "systemd-boot: signed with our key, installed, re-signed after an update" {
    echo "openSUSE signature" >>"$T/stubs/systemd-bootx64.efi"
    echo 'SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)' >>"$T/conf"
    echo 'SDBOOT_FALLBACK=(EFI/BOOT/BOOTX64.EFI)' >>"$T/conf"
    run uki plan
    [[ $output == *"sign    systemd-bootx64.efi -> EFI/systemd/systemd-bootx64.efi"* ]]
    # a missing fallback is installed right away
    [[ $output == *"sign    systemd-bootx64.efi -> EFI/BOOT/BOOTX64.EFI"* ]]
    [ ! -e "$T/esp/EFI/BOOT/BOOTX64.EFI" ]

    run uki sync
    echo "$output"
    [ "$status" -eq 0 ]
    for f in EFI/systemd/systemd-bootx64.efi EFI/BOOT/BOOTX64.EFI; do
        grep -qx "signed by cert" "$T/esp/$f"
        grep -q "systemd-boot 261 " "$T/esp/$f"
        ! grep -q "openSUSE signature" "$T/esp/$f"
    done
    # signed once, installed twice
    [ "$(grep -c '^sbsign' "$T/calls")" -eq 1 ]

    : >"$T/calls"
    uki sync
    ! grep -q '^sbsign' "$T/calls"
}

@test "systemd-boot fallback waits until the new version has booted" {
    echo 'SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi)' >>"$T/conf"
    echo 'SDBOOT_FALLBACK=(EFI/BOOT/BOOTX64.EFI)' >>"$T/conf"
    booted_sdboot 261
    uki sync
    grep -q "systemd-boot 261 " "$T/esp/EFI/BOOT/BOOTX64.EFI"

    # an update: the main copy right away, the fallback held back
    sdboot_release 262
    run uki plan
    [[ $output == *"hold    EFI/BOOT/BOOTX64.EFI  (until systemd-boot 262 has booted)"* ]]
    run uki sync
    [ "$status" -eq 0 ]
    grep -q "systemd-boot 262 " "$T/esp/EFI/systemd/systemd-bootx64.efi"
    grep -q "systemd-boot 261 " "$T/esp/EFI/BOOT/BOOTX64.EFI"

    # after a boot with 262 the fallback follows
    booted_sdboot 262
    run uki sync
    [ "$status" -eq 0 ]
    grep -q "systemd-boot 262 " "$T/esp/EFI/BOOT/BOOTX64.EFI"
}

@test "systemd-boot is left alone unless SDBOOT_DEST is set" {
    run uki sync
    [ "$status" -eq 0 ]
    ! grep -q -e '^sbsign' -e '^sbattach' "$T/calls"
    [ ! -e "$T/esp/EFI/systemd" ]
}

@test "db alarm: a forbidden certificate in db fails the service" {
    echo "DB_FORBIDDEN=('Microsoft Corporation UEFI CA 2011' 'Microsoft UEFI CA 2023')" >>"$T/conf"
    printf 'xxxxCN=Windows UEFI CA 2023\n' >"$T/efivars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f"
    run uki sync
    [ "$status" -eq 0 ]

    printf 'xxxxMicrosoft Corporation UEFI CA 2011\n' >>"$T/efivars/db-d719b2cb-3d3a-4596-a3bc-dad00e67656f"
    run uki sync
    [ "$status" -eq 1 ]
    [[ $output == *'db contains "Microsoft Corporation UEFI CA 2011" again'* ]]
}

@test "notify: a desktop notification for each user with a graphical session" {
    mock loginctl <<'EOF'
case "$*" in
"list-sessions --no-legend") printf ' 2 1000 alice seat0 tty2\n 5 1001 bob - pts/0\n 7 1000 alice seat0 tty3\n' ;;
"show-session 2 -p Type --value"|"show-session 7 -p Type --value") echo wayland ;;
"show-session 5 -p Type --value") echo tty ;;
*"-p Active --value") echo yes ;;
"show-session 2 -p Name --value"|"show-session 7 -p Name --value") echo alice ;;
"show-session 5 -p Name --value") echo bob ;;
esac
EOF
    mock journalctl "echo \"uki-snapshots: warning: dracut failed for $KDEF\""
    mock systemd-run 'echo "systemd-run $*" >>"$T/calls"'

    run uki notify
    echo "$output"
    [ "$status" -eq 0 ]
    # alice once (two sessions), bob not (no graphical session)
    [ "$(grep -c '^systemd-run' "$T/calls")" -eq 1 ]
    grep -q -- "--machine=alice@.host" "$T/calls"
    grep -q "'warning: dracut failed for $KDEF (journalctl -u uki-snapshots -b)'" "$T/calls"
}

@test "notify: NOTIFY=no stays quiet" {
    echo 'NOTIFY=no' >>"$T/conf"
    mock systemd-run 'echo "systemd-run $*" >>"$T/calls"'
    run uki notify
    [ "$status" -eq 0 ]
    [ ! -s "$T/calls" ]
}
