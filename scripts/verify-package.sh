#!/bin/bash
# Validate the installer payload without installing it or changing receipts.
set -euo pipefail
IFS=$'\n\t'

[[ $# == 1 && -f "$1" ]] || { echo 'Usage: scripts/verify-package.sh PATH.pkg' >&2; exit 1; }
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/edgee-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
pkgutil --expand-full "$1" "$VERIFY_DIR/expanded"
PRODUCT="$VERIFY_DIR/expanded"
COMPONENT="$PRODUCT/EdgeePulse-component.pkg"
PAYLOAD="$COMPONENT/Payload"
APP="$PAYLOAD/Applications/Edgee Pulse.app"
fail() { echo "Package verification failed: $*" >&2; exit 1; }
xml() { /usr/bin/xmllint --xpath "$2" "$1"; }
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1"; }

[[ -d "$APP" ]] || fail 'managed app path is missing'
[[ "$(plist "$APP/Contents/Info.plist" CFBundleIdentifier)" == ai.edgee.widget ]] || fail 'bundle identifier'
[[ "$(plist "$APP/Contents/Info.plist" LSMinimumSystemVersion)" == 14.0 ]] || fail 'minimum macOS'
VERSION="$(plist "$APP/Contents/Info.plist" CFBundleVersion)"
[[ "$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" ]] || fail 'app version mismatch'
[[ "$(xml "$COMPONENT/PackageInfo" 'string(/pkg-info/@identifier)')" == ai.edgee.widget.pkg ]] || fail 'receipt identifier'
[[ "$(xml "$COMPONENT/PackageInfo" 'string(/pkg-info/@version)')" == "$VERSION" ]] || fail 'receipt version'
[[ "$(xml "$COMPONENT/PackageInfo" 'count(/pkg-info/scripts/*)')" == 0 ]] || fail 'installer scripts present'
[[ ! -e "$COMPONENT/Scripts" ]] || fail 'installer scripts archive present'
[[ "$(xml "$PRODUCT/Distribution" 'string(/installer-gui-script/volume-check/allowed-os-versions/os-version/@min)')" == 14.0 ]] || fail 'Installer OS requirement'
[[ "$(xml "$PRODUCT/Distribution" 'string(/installer-gui-script/options/@hostArchitectures)')" == arm64,x86_64 ]] || fail 'Installer architectures'
[[ "$(xml "$PRODUCT/Distribution" 'string(/installer-gui-script/domains/@enable_currentUserHome)')" == false ]] || fail 'unexpected user-home installation'
[[ "$(xml "$PRODUCT/Distribution" 'string(/installer-gui-script/domains/@enable_localSystem)')" == true ]] || fail 'system installation disabled'
[[ "$(xml "$COMPONENT/PackageInfo" 'count(/pkg-info/relocate/*)')" == 0 ]] || fail 'bundle relocation is enabled'

for entry in "$PAYLOAD"/* "$PAYLOAD/Applications"/*; do
    [[ "$entry" == "$PAYLOAD/Applications" || "$entry" == "$APP" ]] || fail "unexpected payload entry: $entry"
done
[[ "$(xml "$COMPONENT/PackageInfo" 'string(/pkg-info/@relocatable)')" == false ]] || fail 'package is relocatable'
[[ -f "$APP/Contents/Resources/LICENSE" ]] || fail 'license missing'
[[ -f "$APP/Contents/Resources/EdgeeWidget_EdgeeWidget.bundle/EdgeeMark.pdf" ]] || fail 'branding missing'
[[ -f "$APP/Contents/Resources/EdgeeWidget_EdgeeWidget.bundle/EdgeeWordmark.pdf" ]] || fail 'wordmark missing'
lipo "$APP/Contents/MacOS/EdgeeWidget" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
echo "Verified Edgee Pulse $VERSION: universal app, fixed managed path, macOS 14+, no installer scripts."
