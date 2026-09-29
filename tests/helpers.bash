# Mock system for the uki-snapshots tests: snapshots, ESP, state and fake
# btrfs/findmnt/dracut/ukify/bootctl/sdbootutil. The script runs as root in
# a user namespace (unshare -r), with its paths redirected by a config file.

SCRIPT=$BATS_TEST_DIRNAME/../bin/uki-snapshots
MID=0123456789abcdef0123456789abcdef
UUID=12345678-0000-4000-8000-000000000000
KDEF=7.2.7-1-default
KLT=6.12.48-1-longterm

setup_system() {
    T=$BATS_TEST_TMPDIR
    mkdir -p "$T"/{bin,esp/loader/entries,esp/EFI/Linux,snapshots,state,efivars,stubs,run}
    echo "$MID" >"$T/machine-id"
    echo key >"$T/key"; echo cert >"$T/cert"
    echo stub >"$T/stubs/linuxx64.efi.stub"
    sdboot_release 261
    : >"$T/calls"
    echo false >"$T/root_ro"

    touch "$T/conf" && chmod 600 "$T/conf"
    cat >"$T/conf" <<EOF
PATH=$T/bin:/usr/bin:/bin
ESP=$T/esp
KEY=$T/key
CERT=$T/cert
STATE=$T/state
SNAPSHOTS=$T/snapshots
LOCK=$T/run/lock
ZYPP_PID=$T/run/zypp.pid
EFIVARS=$T/efivars
STUBS=$T/stubs
IDLE_WAIT_MIN=0
DRACUT_ARGS=(--force)
LIVE_ROOT=$T/snapshots/\$(cat $T/booted)/snapshot
EOF

    mock btrfs <<'EOF'
case "$1 $2" in
"subvolume get-default") echo "ID 300 gen 1 top level 266 path @/.snapshots/$(cat "$T/default")/snapshot" ;;
"subvolume show") echo "	UUID: 	$(cat "$3/.uuid" 2>/dev/null)" ;;
"property get")
    if [[ $4 == / ]]; then echo "ro=$(cat "$T/root_ro")"
    elif [[ -e $4/.readonly ]]; then echo ro=true
    else echo ro=false; fi ;;
esac
EOF
    mock findmnt <<'EOF'
case "$*" in
"-no FSROOT /") echo "/@/.snapshots/$(cat "$T/booted")/snapshot" ;;
"-no UUID /") echo "$UUID" ;;
esac
EOF
    # The initrd records its kernel and the rpm database it was built from.
    mock dracut <<'EOF'
echo "dracut $*" >>"$T/calls"
[[ ! -e $T/dracut_fail ]] || exit 1
out=${@: -2:1} kver=${@: -1}
root=$T/snapshots/$(cat "$T/booted")/snapshot
echo "initrd $kver $(cat "$root/usr/lib/sysimage/rpm/Packages.db")" >"$out"
if [[ -e $T/dracut_mutate ]]; then
    rm "$T/dracut_mutate"
    echo "changed during dracut" >>"$root/usr/lib/sysimage/rpm/Packages.db"
fi
EOF
    # The "UKI" is the list of what went into it.
    mock ukify <<'EOF'
if [[ $1 == --version ]]; then echo "ukify 261"; exit 0; fi
echo "ukify $*" >>"$T/calls"
if [[ -e $T/hook ]]; then mv "$T/hook" "$T/hook.ran"; bash "$T/hook.ran"; fi
for a; do case $a in --output=*) out=${a#--output=} ;; esac; done
printf '%s\n' "$@" >"$out"
for a; do
    case $a in --initrd=*) echo "initrd-content $(cat "${a#--initrd=}")" >>"$out" ;; esac
done
EOF
    mock sbverify 'exit 0'
    # "Signs" by appending the certificate to the image.
    mock sbsign <<'EOF'
echo "sbsign $*" >>"$T/calls"
if [[ -e $T/sign-hook ]]; then mv "$T/sign-hook" "$T/sign-hook.ran"; bash "$T/sign-hook.ran"; fi
while [[ $1 == --* ]]; do
    case $1 in --cert) cert=$2 ;; --output) out=$2 ;; esac
    shift 2
done
{ cat "$1"; echo "signed by $(cat "$cert")"; } >"$out"
EOF
    # Removes the "openSUSE signature" our fake systemd-boot may carry.
    mock sbattach <<'EOF'
echo "sbattach $*" >>"$T/calls"
[[ $1 == --remove ]] && grep -q '^openSUSE signature$' "$2" || exit 1
sed -i '/^openSUSE signature$/d' "$2"
EOF
    mock mountpoint 'exit 0'
    mock logger 'exit 0'
    mock bootctl <<'EOF'
echo "bootctl $*" >>"$T/calls"
{ printf '\x07\x00\x00\x00'; printf '%s\0' "$2" | iconv -t UTF-16LE; } >"$T/efivars/LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
EOF
    # Must never be called: sdbootutil is removed on the real system.
    mock sdbootutil <<'EOF'
echo "sdbootutil $*" >>"$T/calls"
exit 1
EOF
}

# mock NAME [BODY]  (BODY from stdin if not given)
mock() {
    local body
    if [[ $# -gt 1 ]]; then body=$2; else body=$(cat); fi
    printf '#!/bin/bash\nT=%q MID=%q UUID=%q\n%s\n' "$T" "$MID" "$UUID" "$body" >"$T/bin/$1"
    chmod +x "$T/bin/$1"
}

# snapshot NUM TYPE [DESCRIPTION]: a system with both kernels and the
# current rpm database of the live system (or "rpm-1" for the first one).
snapshot() {
    local n=$1 r=$T/snapshots/$1/snapshot
    mkdir -p "$r"/usr/lib/sysimage/rpm "$r"/etc/kernel \
        "$r"/etc/systemd/system/paths.target.wants \
        "$r/usr/lib/modules/$KDEF" "$r/usr/lib/modules/$KLT"
    printf '<?xml version="1.0"?>\n<snapshot>\n  <type>%s</type>\n  <num>%s</num>\n  <date>2026-09-2%s 10:00:00</date>\n  <description>%s</description>\n</snapshot>\n' \
        "$2" "$n" "${n: -1}" "${3:-}" >"$T/snapshots/$n/info.xml"
    printf 'NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nVERSION_ID="2026092%s"\nPRETTY_NAME="openSUSE Tumbleweed"\n' \
        "${n: -1}" >"$r/usr/lib/os-release"
    echo "root=/dev/mapper/main-root splash=silent quiet" >"$r/etc/kernel/cmdline"
    echo "rpm-1" >"$r/usr/lib/sysimage/rpm/Packages.db"
    echo "vmlinuz $KDEF" >"$r/usr/lib/modules/$KDEF/vmlinuz"
    echo "vmlinuz $KLT" >"$r/usr/lib/modules/$KLT/vmlinuz"
    echo "luks UUID=x none fido2-device=auto,x-initrd.attach" >"$r/etc/crypttab"
    ln -s /etc/systemd/system/uki-snapshots.path "$r/etc/systemd/system/paths.target.wants/uki-snapshots.path"
    cat /proc/sys/kernel/random/uuid >"$r/.uuid"
}

# copy_snapshot SRC DST TYPE [DESCRIPTION]: DST as a new subvolume with SRC's
# contents (a pre snapshot, or snapper rollback's writable copy).
copy_snapshot() {
    snapshot "$2" "$3" "${4:-}"
    rm -rf "$T/snapshots/$2/snapshot"
    cp -a "$T/snapshots/$1/snapshot" "$T/snapshots/$2/snapshot"
    rm -f "$T/snapshots/$2/snapshot/.readonly"
    cat /proc/sys/kernel/random/uuid >"$T/snapshots/$2/snapshot/.uuid"
}

# A zypper transaction on the live system: the pre snapshot is a read-only
# copy of it, then the rpm database changes.
transaction() {
    local pre=$1 live
    live=$T/snapshots/$(<"$T/booted")/snapshot
    copy_snapshot "$(<"$T/booted")" "$pre" pre "zypp(zypper)"
    touch "$T/snapshots/$pre/snapshot/.readonly"
    echo "rpm after $pre" >"$live/usr/lib/sysimage/rpm/Packages.db"
}

# A leftover sdbootutil entry for snapshot N, kernel K, with tampered
# content: nothing of it may end up in a UKI.
esp_entry() {
    mkdir -p "$T/esp/$MID/$2"
    echo evil >"$T/esp/$MID/$2/initrd-evil"
    printf 'title x\nversion %s@%s\nsort-key opensuse-tumbleweed\noptions root=UUID=%s rootflags=subvol=@/.snapshots/%s/snapshot init=/evil\nlinux /%s/%s/linux-evil\ninitrd /%s/%s/initrd-evil\n' \
        "$1" "$2" "$UUID" "$1" "$MID" "$2" "$MID" "$2" >"$T/esp/loader/entries/$MID-$2-$1.conf"
}

uki() { unshare -r env -u JOURNAL_STREAM UKI_SNAPSHOTS_CONF="$T/conf" "$SCRIPT" "$@"; }

efi_default() {
    tail -c +5 "$T/efivars/LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" | iconv -f UTF-16LE -t UTF-8 | tr -d '\0'
}

ukis() { ls "$T/esp/EFI/Linux"; }

# A fake systemd-boot of version V, with the marker it reports as LoaderInfo.
sdboot_release() {
    printf 'sd-boot code\n#### LoaderInfo: systemd-boot %s ####\n' "$1" >"$T/stubs/systemd-bootx64.efi"
}

# The systemd-boot version the firmware booted (LoaderInfo, UTF-16LE).
booted_sdboot() {
    { printf '\x06\x00\x00\x00'; printf 'systemd-boot %s\0' "$1" | iconv -t UTF-16LE; } \
        >"$T/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
}
