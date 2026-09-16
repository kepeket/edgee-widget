#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
CONFIGURATION="release"
UNIVERSAL=0

usage() {
    cat <<'EOF'
Usage: scripts/build-app.sh [--release|--debug] [--universal]

Builds the EdgeeWidget Swift package into build/Edgee.app.
--universal builds arm64 + x86_64 into build/universal/Edgee.app.
Set SIGN_IDENTITY to use a signing identity; the default is ad-hoc signing.
Set SWIFT_BUILD_FLAGS to append environment-specific SwiftPM flags.
Set EDGEE_SWIFT_DISABLE_SANDBOX=1 to use a local SwiftPM/module cache in restricted environments.
EOF
}

die() {
    printf 'build-app.sh: %s\n' "$1" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --release)
            CONFIGURATION="release"
            ;;
        --debug)
            CONFIGURATION="debug"
            ;;
        --universal)
            UNIVERSAL=1
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

BUILD_DIR="${ROOT_DIR}/build"
if [[ "$UNIVERSAL" == "1" ]]; then BUILD_DIR="${ROOT_DIR}/build/universal"; fi
APP_DIR="${BUILD_DIR}/Edgee.app"
ICONSET_DIR="${BUILD_DIR}/.Edgee.iconset"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
cd -- "$ROOT_DIR"

command -v swift >/dev/null 2>&1 || die "swift is required"
command -v iconutil >/dev/null 2>&1 || die "iconutil is required (macOS)"
command -v codesign >/dev/null 2>&1 || die "codesign is required (macOS)"

printf 'Building EdgeeWidget (%s)…\n' "$CONFIGURATION"
SWIFT_BUILD_FLAGS_ARRAY=()
if [[ -n "${SWIFT_BUILD_FLAGS:-}" ]]; then
    IFS=' ' read -r -a SWIFT_BUILD_FLAGS_ARRAY <<< "$SWIFT_BUILD_FLAGS"
fi
if [[ "${EDGEE_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]]; then
    SWIFT_BUILD_FLAGS_ARRAY+=(
        --disable-sandbox
        --cache-path "${ROOT_DIR}/.build/cache"
        -Xswiftc -module-cache-path
        -Xswiftc "${ROOT_DIR}/.build/module-cache"
    )
fi
build_product() {
    swift build --configuration "$CONFIGURATION" --product EdgeeWidget ${SWIFT_BUILD_FLAGS_ARRAY[@]+"${SWIFT_BUILD_FLAGS_ARRAY[@]}"} "$@"
}
bin_path() {
    swift build --configuration "$CONFIGURATION" --show-bin-path ${SWIFT_BUILD_FLAGS_ARRAY[@]+"${SWIFT_BUILD_FLAGS_ARRAY[@]}"} "$@"
}
if [[ "$UNIVERSAL" == "1" ]]; then
    build_product --triple arm64-apple-macosx14.0 --scratch-path "${ROOT_DIR}/.build/distribution-arm64"
    ARM_BIN_DIR="$(bin_path --triple arm64-apple-macosx14.0 --scratch-path "${ROOT_DIR}/.build/distribution-arm64")"
    build_product --triple x86_64-apple-macosx14.0 --scratch-path "${ROOT_DIR}/.build/distribution-x86_64"
    INTEL_BIN_DIR="$(bin_path --triple x86_64-apple-macosx14.0 --scratch-path "${ROOT_DIR}/.build/distribution-x86_64")"
    BINARY_PATH="${ARM_BIN_DIR}/EdgeeWidget"
    RESOURCE_BIN_DIR="$ARM_BIN_DIR"
else
    build_product
    RESOURCE_BIN_DIR="$(bin_path)"
    BINARY_PATH="${RESOURCE_BIN_DIR}/EdgeeWidget"
fi
[[ -f "$BINARY_PATH" ]] || die "SwiftPM did not produce ${BINARY_PATH}"

# These are exact, package-owned generated paths. Keep SwiftPM's .build directory intact.
case "$APP_DIR" in
    "${ROOT_DIR}/build/Edgee.app"|"${ROOT_DIR}/build/universal/Edgee.app") ;;
    *) die "refusing to remove an unexpected app path" ;;
esac
case "$ICONSET_DIR" in
    "${ROOT_DIR}/build/.Edgee.iconset"|"${ROOT_DIR}/build/universal/.Edgee.iconset") ;;
    *) die "refusing to remove an unexpected iconset path" ;;
esac

rm -rf -- "$APP_DIR" "$ICONSET_DIR"
mkdir -p -- "$MACOS_DIR" "$RESOURCES_DIR"

printf 'Generating Edgee.icns…\n'
ICON_SWIFT_CACHE_DIR="${ROOT_DIR}/.build/module-cache"
mkdir -p -- "$ICON_SWIFT_CACHE_DIR"
swift -module-cache-path "$ICON_SWIFT_CACHE_DIR" "${ROOT_DIR}/scripts/make-icon.swift" "$ICONSET_DIR"
iconutil -c icns -o "${RESOURCES_DIR}/Edgee.icns" "$ICONSET_DIR"
rm -rf -- "$ICONSET_DIR"

RESOURCE_BUNDLE="${RESOURCE_BIN_DIR}/EdgeeWidget_EdgeeWidget.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || die "SwiftPM did not produce the branding resource bundle"
cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
if [[ "$UNIVERSAL" == "1" ]]; then
    lipo -create "$BINARY_PATH" "${INTEL_BIN_DIR}/EdgeeWidget" -output "${MACOS_DIR}/EdgeeWidget"
    lipo "${MACOS_DIR}/EdgeeWidget" -verify_arch arm64 x86_64
else
    cp -- "$BINARY_PATH" "${MACOS_DIR}/EdgeeWidget"
fi
cp -- "${ROOT_DIR}/LICENSE" "$RESOURCES_DIR/LICENSE"
cp -- "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
chmod 755 "${MACOS_DIR}/EdgeeWidget"

SIGNING_IDENTITY="${SIGN_IDENTITY:--}"
printf 'Signing Edgee.app (%s)…\n' "$SIGNING_IDENTITY"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --sign - --options runtime --timestamp=none "$APP_DIR"
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

printf 'Built %s\n' "$APP_DIR"
