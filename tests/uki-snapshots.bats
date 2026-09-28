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
    echo 'SDBOOT_DEST=(EFI/systemd/systemd-bootx64.efi EFI/BOOT/BOOTX64.EFI)' >>"$T/conf"
    run uki plan
    [[ $output == *"sign    systemd-bootx64.efi -> EFI/BOOT/BOOTX64.EFI"* ]]
    [ ! -e "$T/esp/EFI/BOOT/BOOTX64.EFI" ]

    run uki sync
    echo "$output"
    [ "$status" -eq 0 ]
    for f in EFI/systemd/systemd-bootx64.efi EFI/BOOT/BOOTX64.EFI; do
        [ "$(cat "$T/esp/$f")" = "systemd-boot 261
signed by cert" ]
    done
    # signed once, installed twice
    [ "$(grep -c '^sbsign' "$T/calls")" -eq 1 ]

    : >"$T/calls"
    uki sync
    ! grep -q '^sbsign' "$T/calls"

    echo "systemd-boot 262" >"$T/stubs/systemd-bootx64.efi"
    uki sync
    grep -qx "systemd-boot 262" "$T/esp/EFI/BOOT/BOOTX64.EFI"
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
