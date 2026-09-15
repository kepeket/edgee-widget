#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build-app.sh"
APP_PATH="${ROOT_DIR}/build/Edgee.app"
CONFIGURATION="--release"

usage() {
    cat <<'EOF'
Usage: scripts/run.sh [--release|--debug] [app launch arguments…]

Examples:
  scripts/run.sh --demo --window
  scripts/run.sh --debug -- --demo --window
EOF
}

while (($# > 0)); do
    case "$1" in
        --release|--debug)
            CONFIGURATION="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

cd -- "$ROOT_DIR"
"$BUILD_SCRIPT" "$CONFIGURATION"

if (($# > 0)); then
    open "$APP_PATH" --args "$@"
else
    open "$APP_PATH"
fi
