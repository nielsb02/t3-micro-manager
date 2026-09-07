#!/usr/bin/env bash
# Assemble MicroManager.app, with the Inspector nested inside it.
#
# SwiftPM cannot emit an .app bundle, and an unbundled binary is a poor
# background app: no LSUIElement, no stable identity for TCC, and SMAppService
# refuses to register it as a login item.
#
#   ./scripts/bundle.sh              build into build/
#   ./scripts/bundle.sh --install    also copy to /Applications and launch
#
# Signing matters more than it looks. macOS keys the Input Monitoring grant to
# the code signature, so an ad-hoc signature - whose hash changes on every
# build - forces you to re-grant permission after every rebuild. A real
# identity gives a stable designated requirement and the grant sticks.
#
# Local builds reuse a private local certificate. Set WL_SIGN_IDENTITY to an
# Apple identity for distribution, or to "-" to opt into ad-hoc signing.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="T3MicroManager"
BUNDLE_ID="dev.t3micromanager.app"
INSPECTOR_NAME="Inspector"
INSPECTOR_BUNDLE_ID="dev.t3micromanager.inspector"
VERSION="${WL_VERSION:-0.3.0}"
OUT_DIR="${WL_OUT_DIR:-build}"
APP="$OUT_DIR/$APP_NAME.app"
INSPECTOR="$APP/Contents/Library/$INSPECTOR_NAME.app"

install=false
[[ "${1:-}" == "--install" ]] && install=true

echo "==> building (release)"
swift build -c release --product WLMicroManager
swift build -c release --product WLInspector
for product in WLMicroManager WLInspector; do
    [[ -f ".build/release/$product" ]] || {
        echo "build produced no binary at .build/release/$product" >&2; exit 1; }
done

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library"
cp ".build/release/WLMicroManager" "$APP/Contents/MacOS/$APP_NAME"

echo "==> drawing icon"
ICONSET="$OUT_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/genicon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>Micro Manager</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Menu-bar only: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Interoperability tool for the Work Louder Creator Micro 2.</string>
</dict>
</plist>
PLIST

# The Inspector rides along inside the host bundle. One download, one trust
# decision - and the panel's "Inspector" button has something to open.
echo "==> assembling $INSPECTOR"
mkdir -p "$INSPECTOR/Contents/MacOS" "$INSPECTOR/Contents/Resources"
cp ".build/release/WLInspector" "$INSPECTOR/Contents/MacOS/$INSPECTOR_NAME"
cp "$APP/Contents/Resources/AppIcon.icns" "$INSPECTOR/Contents/Resources/AppIcon.icns"

cat > "$INSPECTOR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$INSPECTOR_NAME</string>
    <key>CFBundleDisplayName</key>       <string>Micro Manager Inspector</string>
    <key>CFBundleIdentifier</key>        <string>$INSPECTOR_BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$INSPECTOR_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>  <string>Debug UI for the Work Louder Creator Micro 2.</string>
</dict>
</plist>
PLIST

echo "==> signing"
IDENTITY="${WL_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && "${CI:-}" != "true" ]]; then
    # No automatic fallback: a signing failure must not reset privacy grants.
    python3 scripts/sign-local.py "$INSPECTOR" "$APP"
elif [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
    echo "    identity: $IDENTITY"
    SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
    "${SIGN[@]}" "$INSPECTOR"
    "${SIGN[@]}" "$APP"
else
    echo "    WARNING: ad-hoc signing selected (explicitly or by unsigned CI)." >&2
    echo "    The Input Monitoring grant will not survive rebuilds." >&2
    SIGN=(codesign --force --sign -)
    "${SIGN[@]}" "$INSPECTOR"
    "${SIGN[@]}" "$APP"
fi

codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

if $install; then
    echo "==> installing to /Applications"
    STAGING="$(mktemp -d /Applications/.micromanager-install.XXXXXX)"
    trap 'rm -rf "$STAGING"' EXIT
    ditto "$APP" "$STAGING/$APP_NAME.app"
    codesign --verify --deep --strict "$STAGING/$APP_NAME.app"
    # Quit only this bundle, including an older copy launched from build/.
    swift scripts/quit-manager.swift
    if [[ -e "/Applications/$APP_NAME.app" ]]; then
        mv "/Applications/$APP_NAME.app" "$STAGING/previous.app"
    fi
    if ! mv "$STAGING/$APP_NAME.app" "/Applications/$APP_NAME.app"; then
        if [[ -e "$STAGING/previous.app" ]]; then
            if ! mv "$STAGING/previous.app" "/Applications/$APP_NAME.app"; then
                trap - EXIT
                echo "Previous app retained at $STAGING/previous.app" >&2
            fi
        fi
        exit 1
    fi
    echo "==> launching"
    open "/Applications/$APP_NAME.app" --args --refresh-login-item
    echo
    echo "If this is the first launch, macOS will ask for Input Monitoring."
    echo "Grant it, then quit and reopen /Applications/$APP_NAME.app."
else
    echo
    echo "built: $APP"
    echo "run:   open $APP        (or ./scripts/bundle.sh --install)"
fi
