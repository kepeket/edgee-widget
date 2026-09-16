#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly DEFAULT_APP_SOURCE="build/universal/Edgee.app"
readonly DEPLOYED_APP_NAME="Edgee Pulse.app"
readonly BUNDLE_ID="ai.edgee.widget"
readonly PACKAGE_ID="ai.edgee.widget.pkg"
readonly MINIMUM_MACOS_VERSION="14.0"

usage() {
  cat <<'EOF'
Usage: scripts/package-app.sh [--unsigned] [--notarize] [--app PATH] [--output-dir PATH]

Packages an existing app for Jamf deployment. The default input is
build/universal/Edgee.app. The app is never built by this script. Production
packages require INSTALLER_SIGN_IDENTITY. Notarization also requires
NOTARY_PROFILE.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null ||
    die "missing or invalid $2 in $1"
}

assert_universal() {
  local architectures
  architectures="$(/usr/bin/lipo -archs "$1")" || die "cannot inspect executable architectures"
  for required_arch in arm64 x86_64; do
    case " $architectures " in
      *" $required_arch "*) ;;
      *) die "executable is missing $required_arch: $1" ;;
    esac
  done
}

assert_simple_output_dir() {
  local path="$1"
  [ -n "$path" ] || die "--output-dir requires a non-empty path"
  case "$path" in
    /|.|..|*[$'\n\r']*) die "unsafe output directory: $path" ;;
  esac
  if [ -e "$path" ] && [ ! -d "$path" ]; then
    die "output path exists and is not a directory: $path"
  fi
  if [ -L "$path" ]; then
    die "output directory must not be a symbolic link: $path"
  fi
}

notary_status() {
  local plist="$1"
  /usr/bin/plutil -extract status raw -o - "$plist" 2>/dev/null || true
}

unsigned=0
notarize=0
app_source="$DEFAULT_APP_SOURCE"
output_dir="dist"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --unsigned)
      unsigned=1
      ;;
    --notarize)
      notarize=1
      ;;
    --app)
      [ "$#" -ge 2 ] || die "--app requires a path"
      app_source="$2"
      shift
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || die "--output-dir requires a path"
      output_dir="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[ "$notarize" -eq 0 ] || [ "$unsigned" -eq 0 ] ||
  die "--notarize cannot be combined with --unsigned"
assert_simple_output_dir "$output_dir"

require_command codesign
require_command ditto
require_command lipo
require_command pkgbuild
require_command pkgutil
require_command plutil
require_command productbuild
require_command shasum
require_command xcrun

[ -n "$app_source" ] || die "--app requires a non-empty path"
case "$app_source" in
  *[$'\n\r']*) die "unsafe app path" ;;
esac
[ -d "$app_source" ] || die "$app_source does not exist; run the separate build process first"
[ ! -L "$app_source" ] || die "$app_source must not be a symbolic link"

info_plist="$app_source/Contents/Info.plist"
[ -f "$info_plist" ] || die "missing app Info.plist"

bundle_id="$(plist_value "$info_plist" CFBundleIdentifier)"
version="$(plist_value "$info_plist" CFBundleShortVersionString)"
bundle_version="$(plist_value "$info_plist" CFBundleVersion)"
minimum_macos="$(plist_value "$info_plist" LSMinimumSystemVersion)"
executable_name="$(plist_value "$info_plist" CFBundleExecutable)"
[ "$executable_name" = "EdgeeWidget" ] || die "unexpected app executable"

[ "$bundle_id" = "$BUNDLE_ID" ] || die "unexpected bundle identifier: $bundle_id"
[ "$minimum_macos" = "$MINIMUM_MACOS_VERSION" ] ||
  die "LSMinimumSystemVersion must be $MINIMUM_MACOS_VERSION (found $minimum_macos)"
[ "$version" = "$bundle_version" ] ||
  die "CFBundleShortVersionString and CFBundleVersion must match"
case "$version" in
  ''|*[!0-9A-Za-z._-]*) die "unsafe bundle version: $version" ;;
esac

app_executable="$app_source/Contents/MacOS/$executable_name"
[ -f "$app_executable" ] || die "missing app executable: $app_executable"
assert_universal "$app_executable"

/usr/bin/codesign --verify --deep --strict "$app_source" || die "input app signature is invalid"

if [ "$unsigned" -eq 0 ]; then
  [ -n "${INSTALLER_SIGN_IDENTITY:-}" ] ||
    die "INSTALLER_SIGN_IDENTITY is required for production packaging"
  case "$INSTALLER_SIGN_IDENTITY" in
    "Developer ID Installer:"*) ;;
    *) die "INSTALLER_SIGN_IDENTITY must be a Developer ID Installer identity" ;;
  esac

  signature_details="$(/usr/bin/codesign -dvvv "$app_source" 2>&1)" ||
    die "app signature inspection failed"
  printf '%s\n' "$signature_details" | /usr/bin/grep -q '^Authority=Developer ID Application:' ||
    die "app must have a Developer ID Application signing authority"
  printf '%s\n' "$signature_details" | /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' ||
    die "app signature must enable the hardened runtime"
  printf '%s\n' "$signature_details" | /usr/bin/grep -q '^Timestamp=' ||
    die "app signature must contain a secure timestamp"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_source" ||
    die "app signature verification failed"
fi

if [ "$notarize" -eq 1 ]; then
  [ -n "${NOTARY_PROFILE:-}" ] || die "NOTARY_PROFILE is required with --notarize"
fi

/bin/mkdir -p "$output_dir"

suffix="-signed-unnotarized"
[ "$notarize" -eq 0 ] || suffix=""
[ "$unsigned" -eq 0 ] || suffix="-unsigned"
artifact_base="Edgee-Pulse-$version-universal$suffix"
final_pkg="$output_dir/$artifact_base.pkg"
final_zip="$output_dir/$artifact_base.zip"
checksums="$output_dir/SHA256SUMS"

for artifact in "$final_pkg" "$final_zip" "$checksums"; do
  [ ! -e "$artifact" ] || die "refusing to overwrite existing output: $artifact"
done

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/edgee-package.XXXXXX")"
cleanup() {
  /bin/rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

payload_root="$work_dir/payload"
staged_app="$payload_root/Applications/$DEPLOYED_APP_NAME"
/bin/mkdir -p "$payload_root/Applications"
/usr/bin/ditto "$app_source" "$staged_app"

staged_zip="$work_dir/app-for-notarization.zip"
if [ "$notarize" -eq 1 ]; then
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$staged_zip"
  app_notary_plist="$work_dir/app-notary-result.plist"
  /usr/bin/xcrun notarytool submit "$staged_zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist >"$app_notary_plist"
  if [ "$(notary_status "$app_notary_plist")" != "Accepted" ]; then
    /bin/cat "$app_notary_plist" >&2
    die "app notarization was not accepted; use the submission ID above with notarytool log"
  fi
  /usr/bin/xcrun stapler staple "$staged_app"
  /usr/bin/xcrun stapler validate "$staged_app"
fi

component_plist="$work_dir/component.plist"
cat >"$component_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key><true/>
    <key>BundleIsRelocatable</key><false/>
    <key>BundleIsVersionChecked</key><true/>
    <key>BundleOverwriteAction</key><string>upgrade</string>
    <key>RootRelativeBundlePath</key><string>Applications/$DEPLOYED_APP_NAME</string>
  </dict>
</array>
</plist>
EOF
/usr/bin/plutil -lint "$component_plist" >/dev/null

component_pkg="$work_dir/EdgeePulse-component.pkg"
/usr/bin/pkgbuild --root "$payload_root" \
  --identifier "$PACKAGE_ID" \
  --version "$version" \
  --ownership recommended \
  --component-plist "$component_plist" \
  "$component_pkg"

distribution_xml="$work_dir/Distribution.xml"
cat >"$distribution_xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Edgee Pulse $version</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check>
    <allowed-os-versions>
      <os-version min="$MINIMUM_MACOS_VERSION"/>
    </allowed-os-versions>
  </volume-check>
  <choices-outline>
    <line choice="default"/>
  </choices-outline>
  <choice id="default" visible="false">
    <pkg-ref id="$PACKAGE_ID"/>
  </choice>
  <pkg-ref id="$PACKAGE_ID" version="$version" onConclusion="none">EdgeePulse-component.pkg</pkg-ref>
</installer-gui-script>
EOF

built_pkg="$work_dir/$artifact_base.pkg"
if [ "$unsigned" -eq 1 ]; then
  /usr/bin/productbuild --distribution "$distribution_xml" \
    --package-path "$work_dir" "$built_pkg"
else
  /usr/bin/productbuild --distribution "$distribution_xml" \
    --package-path "$work_dir" \
    --sign "$INSTALLER_SIGN_IDENTITY" --timestamp "$built_pkg"
  /usr/sbin/pkgutil --check-signature "$built_pkg" >/dev/null ||
    die "final package signature verification failed"
fi

if [ "$notarize" -eq 1 ]; then
  pkg_notary_plist="$work_dir/pkg-notary-result.plist"
  /usr/bin/xcrun notarytool submit "$built_pkg" \
    --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist >"$pkg_notary_plist"
  if [ "$(notary_status "$pkg_notary_plist")" != "Accepted" ]; then
    /bin/cat "$pkg_notary_plist" >&2
    die "package notarization was not accepted; use the submission ID above with notarytool log"
  fi
  /usr/bin/xcrun stapler staple "$built_pkg"
  /usr/bin/xcrun stapler validate "$built_pkg"
fi

expanded_pkg="$work_dir/expanded-pkg"
/usr/sbin/pkgutil --expand-full "$built_pkg" "$expanded_pkg"
payload_app="$expanded_pkg/EdgeePulse-component.pkg/Payload/Applications/$DEPLOYED_APP_NAME"
[ -d "$payload_app" ] || die "package payload does not contain Applications/$DEPLOYED_APP_NAME"
[ "$(plist_value "$payload_app/Contents/Info.plist" CFBundleIdentifier)" = "$BUNDLE_ID" ] ||
  die "package payload has the wrong bundle identifier"
[ "$(plist_value "$payload_app/Contents/Info.plist" CFBundleShortVersionString)" = "$version" ] ||
  die "package payload has the wrong version"
assert_universal "$payload_app/Contents/MacOS/$executable_name"

built_zip="$work_dir/$artifact_base.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$built_zip"

/bin/mv "$built_pkg" "$final_pkg"
/bin/mv "$built_zip" "$final_zip"
(
  cd "$output_dir"
  /usr/bin/shasum -a 256 "$artifact_base.pkg" "$artifact_base.zip" >SHA256SUMS
)

printf 'Created:\n  %s\n  %s\n  %s\n' "$final_pkg" "$final_zip" "$checksums"
