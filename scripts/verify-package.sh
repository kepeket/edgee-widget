#!/bin/bash
# Validate the installer payload without installing it or changing receipts.
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/package-identity.sh"

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
BUNDLE_IDENTIFIER="$(plist "$APP/Contents/Info.plist" CFBundleIdentifier)"
PACKAGE_IDENTIFIER="$(xml "$COMPONENT/PackageInfo" 'string(/pkg-info/@identifier)')"
edgee_validate_identifier "$BUNDLE_IDENTIFIER" 'App bundle ID' || fail 'bundle identifier'
edgee_validate_identifier "$PACKAGE_IDENTIFIER" 'Installer receipt ID' || fail 'receipt identifier'
if [[ -n "${EDGEE_BUNDLE_ID:-}" ]]; then
    [[ "$BUNDLE_IDENTIFIER" == "$EDGEE_BUNDLE_ID" ]] || fail 'unexpected bundle identifier'
fi
if [[ -n "${EDGEE_PACKAGE_ID:-}" ]]; then
    [[ "$PACKAGE_IDENTIFIER" == "$EDGEE_PACKAGE_ID" ]] || fail 'unexpected receipt identifier'
fi
for reference in 'string(/installer-gui-script/choice/pkg-ref/@id)' 'string(/installer-gui-script/pkg-ref/@id)'; do
    [[ "$(xml "$PRODUCT/Distribution" "$reference")" == "$PACKAGE_IDENTIFIER" ]] || fail 'distribution receipt identifier mismatch'
done
[[ "$(plist "$APP/Contents/Info.plist" LSMinimumSystemVersion)" == 14.0 ]] || fail 'minimum macOS'
VERSION="$(plist "$APP/Contents/Info.plist" CFBundleVersion)"
[[ "$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" ]] || fail 'app version mismatch'
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
BRAND_RESOURCES="$APP/Contents/Resources/EdgeeWidget_EdgeeWidget.bundle"
if [[ -d "$BRAND_RESOURCES/Contents/Resources" ]]; then
  BRAND_RESOURCES="$BRAND_RESOURCES/Contents/Resources"
fi
[[ -f "$BRAND_RESOURCES/EdgeeMark.pdf" ]] || fail 'branding missing'
[[ -f "$BRAND_RESOURCES/EdgeeWordmark.pdf" ]] || fail 'wordmark missing'
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/EdgeeWidget")"
for required_arch in arm64 x86_64; do
  case " $ARCHITECTURES " in
    *" $required_arch "*) ;;
    *) echo "Package executable is missing $required_arch" >&2; exit 1 ;;
  esac
done
codesign --verify --deep --strict "$APP"
echo "Verified $BUNDLE_IDENTIFIER / $PACKAGE_IDENTIFIER, Edgee Pulse $VERSION: universal app, fixed managed path, macOS 14+, no installer scripts."
