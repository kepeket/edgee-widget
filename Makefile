SHELL := /bin/bash

.PHONY: build debug run demo test package package-unsigned

build:
	./scripts/build-app.sh --release

debug:
	./scripts/build-app.sh --debug

run:
	./scripts/run.sh --release $(ARGS)

demo:
	./scripts/run.sh --release --demo --window

test:
	bash scripts/test-package-identity.sh
	swift test

package:
	@test -n "$$EDGEE_BUNDLE_ID" || (echo 'Set EDGEE_BUNDLE_ID to your app identifier.' >&2; exit 1)
	@test -n "$$EDGEE_PACKAGE_ID" || (echo 'Set EDGEE_PACKAGE_ID to your installer receipt identifier.' >&2; exit 1)
	@test -n "$$SIGN_IDENTITY" && test "$$SIGN_IDENTITY" != "-" || (echo 'Set SIGN_IDENTITY to your Developer ID Application identity.' >&2; exit 1)
	@test -n "$$INSTALLER_SIGN_IDENTITY" || (echo 'Set INSTALLER_SIGN_IDENTITY to your Developer ID Installer identity.' >&2; exit 1)
	@test -n "$$NOTARY_PROFILE" || (echo 'Set NOTARY_PROFILE to your saved notarytool Keychain profile.' >&2; exit 1)
	./scripts/build-app.sh --release --universal
	./scripts/package-app.sh --notarize

package-unsigned:
	SIGN_IDENTITY=- ./scripts/build-app.sh --release --universal
	./scripts/package-app.sh --unsigned
