#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/package-identity.sh"
unset EDGEE_BUNDLE_ID EDGEE_PACKAGE_ID

assert_equal() {
    [[ "$1" == "$2" ]] || { echo "Identity test failed: $3" >&2; exit 1; }
}
expect_failure() {
    if "$@" >/dev/null 2>&1; then
        echo "Identity test unexpectedly accepted: $*" >&2
        exit 1
    fi
}

# Defaults do not assert ownership of the upstream service's namespace.
assert_equal 'org.example.edgee-pulse' "$(edgee_resolve_build_bundle_id -)" 'development bundle'
assert_equal 'org.example.edgee-pulse.pkg' "$(edgee_resolve_package_id org.example.edgee-pulse 1)" 'unsigned receipt'

# App and receipt IDs can be independently configured.
export EDGEE_BUNDLE_ID='dev.distributor.pulse'
export EDGEE_PACKAGE_ID='dev.distributor.installers.pulse'
assert_equal "$EDGEE_BUNDLE_ID" "$(edgee_resolve_build_bundle_id 'test signing identity')" 'custom signed bundle'
assert_equal "$EDGEE_PACKAGE_ID" "$(edgee_resolve_package_id "$EDGEE_BUNDLE_ID" 0)" 'custom signed receipt'
expect_failure edgee_resolve_package_id dev.other.pulse 1
expect_failure edgee_resolve_package_id dev.other.pulse 0

# Missing production configuration must fail before invoking signing tools.
unset EDGEE_PACKAGE_ID
expect_failure edgee_resolve_package_id "$EDGEE_BUNDLE_ID" 0
assert_equal 'dev.distributor.pulse.pkg' "$(edgee_resolve_package_id "$EDGEE_BUNDLE_ID" 1)" 'derived unsigned receipt'
unset EDGEE_BUNDLE_ID
expect_failure edgee_resolve_build_bundle_id 'test signing identity'
expect_failure edgee_resolve_package_id dev.distributor.pulse 0
expect_failure env SIGN_IDENTITY=test "$SCRIPT_DIR/build-app.sh" --release

for placeholder in org.example.edgee-pulse COM.EXAMPLE.Pulse net.example.pulse; do
    export EDGEE_BUNDLE_ID="$placeholder"
    export EDGEE_PACKAGE_ID='dev.distributor.installers.pulse'
    expect_failure edgee_resolve_build_bundle_id 'test signing identity'
    expect_failure edgee_resolve_package_id "$placeholder" 0
    export EDGEE_BUNDLE_ID='dev.distributor.pulse'
    export EDGEE_PACKAGE_ID="$placeholder"
    expect_failure edgee_resolve_package_id "$EDGEE_BUNDLE_ID" 0
done

# Reject empty labels, path traversal, whitespace, and plist/XML injection.
for invalid in '' 'single' '.dev.pulse' 'dev.pulse.' 'dev..pulse' 'dev.-pulse' 'dev.pulse-' 'dev/pulse' 'dev.pulse name' 'dev.pulse_thing' 'dev.pulse"/><evil' 'dev.pulse;id' 'dev.pulse$(id)'; do
    expect_failure edgee_validate_identifier "$invalid"
done
for valid in org.example.edgee-pulse dev.distributor.pulse com.Distributor.Pulse2; do
    edgee_validate_identifier "$valid"
done

echo 'Package identity checks passed: defaults, independent overrides, mismatch rejection, release requirements, and input validation.'
