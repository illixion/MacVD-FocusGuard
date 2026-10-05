#!/bin/bash
# Build FocusGuard.app (universal) and sign it with a stable local identity.
#
#   ./build.sh            build into ./build/FocusGuard.app
#   ./build.sh --install  also copy to ~/Applications and (re)launch
#
# Why a local certificate: macOS ties the Accessibility and Input Monitoring
# grants to the app's code signature. Ad-hoc signing changes that on every
# rebuild and the grants silently stop applying. A self-signed certificate kept
# in your login keychain gives a signature that survives rebuilds. It is
# created once, on the first build, and never leaves your machine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/FocusGuard.app"
SIGN_CN="FocusGuard Menu Bar (local signing)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

ensure_signing_identity() {
    security find-certificate -c "$SIGN_CN" "$KEYCHAIN" >/dev/null 2>&1 && return 0
    echo "==> Creating self-signed code-signing certificate '$SIGN_CN' (one time)"
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $SIGN_CN
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.conf" 2>/dev/null
    # macOS cannot import OpenSSL 3's default PKCS#12 encryption; force the legacy algorithms.
    openssl pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:tmp -name "$SIGN_CN" 2>/dev/null \
        || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:tmp -name "$SIGN_CN"
    security import "$tmp/id.p12" -k "$KEYCHAIN" -P tmp -A -T /usr/bin/codesign >/dev/null
    rm -rf "$tmp"
}

echo "==> Compiling"
rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$ROOT/build/obj"
for arch in arm64 x86_64; do
    xcrun swiftc -O -target "$arch-apple-macos13.0" \
        -framework AppKit -framework ApplicationServices -framework IOKit -framework ServiceManagement -framework Carbon -framework Security -framework CryptoKit \
        -o "$ROOT/build/obj/FocusGuard-$arch" "$ROOT"/Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/FocusGuard" "$ROOT"/build/obj/FocusGuard-*
rm -rf "$ROOT/build/obj"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

ensure_signing_identity
echo "==> Signing"
codesign --force --sign "$SIGN_CN" --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    pkill -x FocusGuard 2>/dev/null || true
    sleep 0.5
    rm -rf "$HOME/Applications/FocusGuard.app"
    cp -R "$APP" "$HOME/Applications/FocusGuard.app"
    open "$HOME/Applications/FocusGuard.app"
    echo "Installed to ~/Applications/FocusGuard.app"
fi
