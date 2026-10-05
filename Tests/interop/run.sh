#!/bin/bash
# Builds the firmware's real stream/crypto code natively and checks it against the Swift side.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FW="${FW_DIR:-$HOME/qmk/qmk/keyboards/ducky/one2sf/1967st/ansi/keymaps/illixion/fg}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Compile from a copy of the firmware sources, and refuse a tree that still holds an on-disk
# key file (fg_secret.h, from before keys moved to the Keychain): it must not linger anywhere.
[ ! -e "$FW/fg_secret.h" ] || { echo "FAIL: $FW/fg_secret.h exists — delete it, it is an on-disk device key" >&2; exit 1; }
mkdir -p "$TMP/inc" "$TMP/fw"
cp "$FW"/*.c "$FW"/*.h "$TMP/fw/"
# throw-away test key 00 01 02 ... 1f — never the real one (tools/fg-flash.sh supplies that)
printf '#define FG_SECRET_KEY_BYTES {' > "$TMP/inc/fg_device_key.h"
for i in $(seq 0 31); do printf '0x%02x,' "$i" >> "$TMP/inc/fg_device_key.h"; done
printf '}\n' >> "$TMP/inc/fg_device_key.h"
cc -O1 -Wall -Werror -I"$TMP/inc" -I"$HERE/stubs" -I"$TMP/fw" -o "$TMP/fgtest" \
    "$HERE/fgtest.c" "$TMP/fw/fg_stream.c" "$TMP/fw/fg_secure.c" "$TMP/fw/monocypher.c"
swiftc -O -o "$TMP/interop" "$HERE/main.swift" "$HERE/../../Sources/FirmwareCrypto.swift"
timeout 60 "$TMP/interop" "$TMP/fgtest"
