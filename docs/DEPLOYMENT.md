# Deployment

Edgee Pulse is a per-user menu-bar app for macOS 14 or later. The distribution build is universal: Apple Silicon (`arm64`) and Intel (`x86_64`).

## Package identity

| Item | Value |
| --- | --- |
| Installed app | `/Applications/Edgee Pulse.app` |
| App bundle ID | Build-time `EDGEE_BUNDLE_ID` |
| Installer receipt ID | Packaging-time `EDGEE_PACKAGE_ID` |
| Minimum macOS | 14.0 |
| Architectures | arm64 and x86_64 |
| Credentials | Each user's existing Edgee CLI profile |

The source does not select a production namespace. Local ad-hoc builds use the reserved development placeholder `org.example.edgee-pulse`; unsigned installers default to that app's identifier plus `.pkg`. Set `EDGEE_BUNDLE_ID` to override the app ID and `EDGEE_PACKAGE_ID` to override the installer receipt independently. Use reverse-DNS identifiers in a namespace you control. Identifiers are validated before they are written to the bundle or installer XML.

Signed builds require an explicit, non-placeholder `EDGEE_BUNDLE_ID`. Signed packages require both identifiers explicitly, and the app's embedded ID must match `EDGEE_BUNDLE_ID`. The scripts reject reserved example namespaces for production signing. Changing the environment after an app has been signed does not change its identity: rebuild it with the intended ID first.

The installer intentionally does not use `/Applications/Edgee.app`: that name may belong to another Edgee application. Bundle relocation is disabled so upgrades target the managed installation rather than a developer checkout. Quit running copies before updating and launch the installed copy afterwards.

No installer scripts run. Installation does not launch the app as root, install the CLI, distribute credentials, enable login items, or register a background daemon. The app appears only in the menu bar when launched normally.

## Prerequisites on employee Macs

- macOS 14+ and an installed Edgee CLI. The app discovers `edgee` at `/opt/homebrew/bin/edgee`, `/usr/local/bin/edgee`, `~/.local/bin/edgee`, or `~/.edgee/bin/edgee`.
- Each employee signs into Edgee with their own account. They can use **Connect with Edgee CLI** in the app or their existing CLI login. Provision the CLI separately using your established company process.
- Network access to the company's configured Edgee service; the app sends Console API credentials only to `https://api.edgee.app`.
- The active profile lives in the user's `~/.config/edgee/credentials.toml`. Do not include that file in a deployment package.

Routing is read-only while the “Soon available” feature is pending. Compression controls and usage refresh remain available. Launch at login and notifications are user preferences in the app; neither is forced by this installer.

## Build a signed and notarized production package

On a signing Mac, install **Developer ID Application** and **Developer ID Installer** identities, each with its private key, in an accessible keychain. A device-management identity or an Apple Development certificate does not substitute for these identities. Xcode's command-line tools must be configured and its license accepted by the operator.

Use Apple's `notarytool store-credentials` interactively to save notarization credentials to Keychain. Keep certificates, private keys, passwords, and notarization credentials out of this repository and out of chat. The scripts take a saved profile name, not a password. Signing identities and their private keys stay in macOS Keychain; none are bundled with the source. A signed app or installer carries the public certificate chain needed to verify its signature, never the private key. Signing exports and provisioning files are ignored by Git. CI uses ad-hoc signing and requires no personal certificates or notarization credentials.

```sh
# Replace both placeholders with identifiers chosen for your distribution.
export EDGEE_BUNDLE_ID='<your-app-bundle-id>'
export EDGEE_PACKAGE_ID='<your-installer-receipt-id>'
export SIGN_IDENTITY='Developer ID Application: COMPANY (TEAMID)'
export INSTALLER_SIGN_IDENTITY='Developer ID Installer: COMPANY (TEAMID)'
export NOTARY_PROFILE='company-edgee-notary'
make package
```

This builds the app with hardened runtime and a secure signing timestamp, submits it to Apple for notarization, staples the app ticket, constructs the installer, then notarizes and staples the installer. The ZIP contains the stapled app. Inspect the completed artifacts and verify their signatures before distribution:

```sh
codesign --verify --deep --strict build/universal/Edgee.app
./scripts/verify-package.sh dist/Edgee-Pulse-0.1.10-universal.pkg
pkgutil --check-signature dist/Edgee-Pulse-0.1.10-universal.pkg
spctl --assess --type install --verbose=2 dist/Edgee-Pulse-0.1.10-universal.pkg
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

CI builds these review artifacts, runs tests, and verifies the package payload without installing it. No signing identities or credentials are needed for CI review builds. CI uses explicit reserved example IDs to exercise both overrides; the identity checks also cover the default development ID. A successful unsigned build does not validate the production certificate or notarization configuration.

## Managed rollout

1. Use the signed, notarized `.pkg` and verify its SHA-256 checksum against the release's `SHA256SUMS`.
2. Upload the installer to your device-management system or software distribution service. For upgrades, preserve the existing package record and deployment references where supported. Verify the uploaded filename, size, checksum, and availability.
3. Start with a small pilot group containing an Apple Silicon Mac and an Intel Mac, both on supported macOS versions. Target macOS 14+ and configure the deployment to run for devices that need the new version; replacing an uploaded file alone may not trigger an upgrade.
4. For the pilot, make the installer available through your managed software catalog so users can quit existing copies before updating. Schedule an automated rollout after the pilot succeeds.
5. Have users launch `/Applications/Edgee Pulse.app`, connect their own Edgee profile, and optionally enable **Launch at login**. Do not launch the app from a root installer script.
6. Confirm the menu-bar cost refreshes, agent settings load, the side routing preview is read-only, and no extra standalone window opens. Check both architectures on real devices; a universal build alone is not an Intel runtime test.

Inventory can use your chosen app bundle ID with `CFBundleShortVersionString`, and your chosen installer receipt ID. Bump both app version fields before a new production release. Keep the install path and receipt ID stable for upgrades. Test upgrades with an existing CLI profile; personal settings should remain in the user's preferences when the bundle ID stays the same. Changing a deployed bundle ID changes the preferences domain and can affect notification permissions and login-item registration. Changing the receipt ID creates a separate installer identity. Treat an identifier change as a migration, not a routine version update; this configuration change does not modify already-distributed packages or migrate existing users automatically.

For removal, quit the app, turn off its **Launch at login** setting, and remove only `/Applications/Edgee Pulse.app` using your approved MDM removal process. The app's preferences and Edgee CLI credentials are separate user data and are deliberately preserved. Forgetting the package receipt alone does not uninstall the app.

## Source and license

The app bundles this repository's `LICENSE` in `Contents/Resources`. Keep the matching source revision and build instructions accessible alongside your internal distribution: <https://github.com/kepeket/edgee-widget>. No company credentials, usage data, signing keys, or development caches are included in the package payload.

## Watchdog notifications and Focus

Standard local builds use normal native notifications. Users can allow Edgee through DND by adding it in **System Settings → Focus → Do Not Disturb → Allowed Apps**. Notification permission is requested only after the user enables notifications in Watchdog.

To distribute a build supporting Time Sensitive notifications:

1. Enable **Time Sensitive Notifications** for the app's explicit identifier in your Apple developer account and generate a matching macOS provisioning profile for the signing/distribution method.
2. Set `EDGEE_BUNDLE_ID` and `SIGN_IDENTITY` as usual. Set `EDGEE_TIME_SENSITIVE_PROFILE` to the profile's local path before running `scripts/build-app.sh` (or packaging, which invokes it).
3. The build checks the profile's capability and app identifier, embeds it, applies `Resources/Watchdog.entitlements`, and marks support in the app's Info.plist. The profile and signing credentials must remain outside Git. Ad-hoc builds reject this option instead of producing an app with restricted entitlements that may not launch.
4. In Watchdog, enable notifications, then **Allow alerts during Focus / DND**. Allow Time Sensitive notifications for Edgee in macOS Notifications settings and in the desired Focus. macOS retains final control of delivery; there is no unconditional DND bypass.

The implementation uses `UNNotificationInterruptionLevel.timeSensitive`; it does not request the separately approved Critical Alerts entitlement. Verify the distributed signed build's launch and delivery on a Mac with DND enabled. Normal unit tests can check notification content and policy but cannot prove system presentation through Focus.

Manual acceptance checks: grant/deny notification permission; send a test; toggle DND with Edgee allowed/disallowed; click **Review model routing**; restart without repeated day/month alerts; wake from sleep; cross UTC day/month boundaries; disconnect the network and switch Edgee accounts. Routing previews must never mutate agent settings.

Apple references: [Time Sensitive notifications](https://developer.apple.com/videos/play/wwdc2021/10091/) and [Focus settings](https://support.apple.com/guide/mac-help/change-focus-settings-mchlff5da36d/mac).
