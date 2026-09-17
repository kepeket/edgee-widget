# Company deployment

Edgee Pulse is a per-user menu-bar app for macOS 14 or later. The distribution build is universal: Apple Silicon (`arm64`) and Intel (`x86_64`).

## Package identity

| Item | Value |
| --- | --- |
| Installed app | `/Applications/Edgee Pulse.app` |
| App bundle ID | `ai.edgee.widget` |
| Installer receipt ID | `ai.edgee.widget.pkg` |
| Minimum macOS | 14.0 |
| Architectures | arm64 and x86_64 |
| Credentials | Each user's existing Edgee CLI profile |

The installer intentionally does not use `/Applications/Edgee.app`: that name may belong to another Edgee application. Bundle relocation is disabled so upgrades target the managed installation rather than a developer checkout. Quit running copies before updating and launch the installed copy afterwards.

No installer scripts run. Installation does not launch the app as root, install the CLI, distribute credentials, enable login items, or register a background daemon. The app appears only in the menu bar when launched normally.

## Prerequisites on employee Macs

- macOS 14+ and an installed Edgee CLI. The app discovers `edgee` at `/opt/homebrew/bin/edgee`, `/usr/local/bin/edgee`, `~/.local/bin/edgee`, or `~/.edgee/bin/edgee`.
- Each employee signs into Edgee with their own account. They can use **Connect with Edgee CLI** in the app or their existing CLI login. Provision the CLI separately using your established company process.
- Network access to the company's configured Edgee service; the app sends Console API credentials only to `https://api.edgee.app`.
- The active profile lives in the user's `~/.config/edgee/credentials.toml`. Do not include that file in a deployment package.

Routing is read-only while the “Soon available” feature is pending. Compression controls and usage refresh remain available. Launch at login and notifications are user preferences in the app; neither is forced by this installer.

## Build a signed and notarized production package

On a signing Mac, install **Developer ID Application** and **Developer ID Installer** identities, each with its private key, in an accessible keychain. A Jamf device-management identity or an Apple Development certificate does not substitute for these identities. Xcode's command-line tools must be configured and its license accepted by the operator.

Use Apple's `notarytool store-credentials` interactively to save notarization credentials to Keychain. Keep certificates, private keys, passwords, and notarization credentials out of this repository and out of chat. The scripts take a saved profile name, not a password.

```sh
export SIGN_IDENTITY='Developer ID Application: COMPANY (TEAMID)'
export INSTALLER_SIGN_IDENTITY='Developer ID Installer: COMPANY (TEAMID)'
export NOTARY_PROFILE='company-edgee-notary'
make package
```

This builds the app with hardened runtime and a secure signing timestamp, submits it to Apple for notarization, staples the app ticket, constructs the installer, then notarizes and staples the installer. The ZIP contains the stapled app. Inspect the completed artifacts and verify their signatures before uploading to Jamf:

```sh
codesign --verify --deep --strict build/universal/Edgee.app
pkgutil --check-signature dist/jamf-0.1.8/Edgee-Pulse-0.1.8-universal.pkg
spctl --assess --type install --verbose=2 dist/jamf-0.1.8/Edgee-Pulse-0.1.8-universal.pkg
(cd dist && shasum -a 256 -c SHA256SUMS)
```

For signing without submission to Apple, run the build and `scripts/package-app.sh` separately; those artifacts carry a `-signed-unnotarized` suffix. The script refuses to overwrite existing artifacts; use a fresh `--output-dir` when rerunning packaging.

Use the version from `Resources/Info.plist` in filenames for subsequent releases. `build/universal/Edgee.app` is the build input; the final ZIP and PKG contain the staged, stapled distribution app. Do not rename a signed bundle's contents or change its resources after signing.

Apple references: [Developer ID](https://developer.apple.com/developer-id/), [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [package signing](https://help.apple.com/xcode/mac/current/en.lproj/deve51ce7c3d.html).

## Unsigned review build

```sh
make package-unsigned
```

This creates clearly marked `*-unsigned.pkg` and `*-unsigned.zip` artifacts. The app has a local ad-hoc signature; the installer has no Developer ID Installer signature, and neither artifact is notarized. They are for packaging validation and IT review, not the signed production deliverable. Do not disable Gatekeeper or strip quarantine to make a test package appear production-ready.

CI builds these review artifacts, runs tests, and verifies the package payload without installing it. No signing identities or credentials are needed for CI review builds. A successful unsigned build does not validate the production certificate or notarization configuration.

## Jamf rollout

Reference: [Jamf — Deploying a package using a policy](https://learn.jamf.com/r/en-US/jamf-pro-documentation-current/Deploying_a_Package_Using_a_Policy).

1. Use the signed, notarized `.pkg` and verify its SHA-256 checksum against the release's `SHA256SUMS`.
2. Upload it to your Jamf distribution point through the Packages settings.
3. Create a policy to install the package. Start with a small pilot group containing an Apple Silicon Mac and an Intel Mac, both on supported macOS versions. Scope production policies to macOS 14+.
4. For the pilot, make the policy available in Self Service so employees can quit existing copies before updating. An automated rollout can use your normal check-in trigger after the pilot succeeds.
5. Have employees launch `/Applications/Edgee Pulse.app`, connect their own Edgee profile, and optionally enable **Launch at login**. Do not launch the app from a root installer script.
6. Confirm the menu-bar cost refreshes, agent settings load, the side routing preview is read-only, and no extra standalone window opens. Check both architectures on real devices; a universal build alone is not an Intel runtime test.

Inventory can use app bundle ID `ai.edgee.widget` / `CFBundleShortVersionString` and receipt ID `ai.edgee.widget.pkg`. Bump both app version fields before a new production release. Keep the install path and receipt ID stable for upgrades. Test upgrades with an existing CLI profile; personal settings should remain in the user's preferences.

For removal, quit the app, turn off its **Launch at login** setting, and remove only `/Applications/Edgee Pulse.app` using your approved MDM removal process. The app's preferences and Edgee CLI credentials are separate user data and are deliberately preserved. Forgetting the package receipt alone does not uninstall the app.

## Source and license

The app bundles this repository's `LICENSE` in `Contents/Resources`. Keep the matching source revision and build instructions accessible alongside your internal distribution: <https://github.com/kepeket/edgee-widget>. No company credentials, usage data, signing keys, or development caches are included in the package payload.
