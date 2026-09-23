#!/bin/bash
# Shared build/package identity validation. Signing material stays in Keychain.

edgee_validate_identifier() {
    local value="$1"
    local label="${2:-Identifier}"
    local identifier_pattern='^[A-Za-z0-9]+([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]+([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
    if [[ ! "$value" =~ $identifier_pattern ]]; then
        printf '%s must be a reverse-DNS identifier containing letters, digits, hyphens, and periods.\n' "$label" >&2
        return 1
    fi
}

edgee_require_release_identifier() {
    local value="$1"
    local label="$2"
    edgee_validate_identifier "$value" "$label" || return 1
    # The reserved example namespace is only for local development and CI.
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
        org.example|org.example.*|com.example|com.example.*|net.example|net.example.*)
            printf '%s uses a development placeholder; choose your own distribution identifier.\n' "$label" >&2
            return 1
            ;;
    esac
}

edgee_resolve_build_bundle_id() {
    local signing_identity="${1:--}"
    local bundle_id="${EDGEE_BUNDLE_ID:-org.example.edgee-pulse}"
    edgee_validate_identifier "$bundle_id" EDGEE_BUNDLE_ID || return 1
    if [[ "$signing_identity" != '-' ]]; then
        [[ -n "${EDGEE_BUNDLE_ID:-}" ]] || {
            echo 'Set EDGEE_BUNDLE_ID explicitly before building a signed release.' >&2
            return 1
        }
        edgee_require_release_identifier "$bundle_id" EDGEE_BUNDLE_ID || return 1
    fi
    printf '%s\n' "$bundle_id"
}

edgee_resolve_package_id() {
    local bundle_id="$1"
    local unsigned="$2"
    edgee_validate_identifier "$bundle_id" 'App bundle ID' || return 1
    if [[ -n "${EDGEE_BUNDLE_ID:-}" ]]; then
        edgee_validate_identifier "$EDGEE_BUNDLE_ID" EDGEE_BUNDLE_ID || return 1
        [[ "$bundle_id" == "$EDGEE_BUNDLE_ID" ]] || {
            echo 'The app bundle ID does not match EDGEE_BUNDLE_ID; rebuild with the intended identifier.' >&2
            return 1
        }
    fi
    local package_id="${EDGEE_PACKAGE_ID:-${bundle_id}.pkg}"
    edgee_validate_identifier "$package_id" EDGEE_PACKAGE_ID || return 1
    if [[ "$unsigned" != 1 ]]; then
        [[ -n "${EDGEE_BUNDLE_ID:-}" && -n "${EDGEE_PACKAGE_ID:-}" ]] || {
            echo 'Set EDGEE_BUNDLE_ID and EDGEE_PACKAGE_ID explicitly before packaging a signed release.' >&2
            return 1
        }
        edgee_require_release_identifier "$bundle_id" EDGEE_BUNDLE_ID || return 1
        edgee_require_release_identifier "$package_id" EDGEE_PACKAGE_ID || return 1
    fi
    printf '%s\n' "$package_id"
}
