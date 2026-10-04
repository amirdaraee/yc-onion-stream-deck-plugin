# Release guide

This project produces one installer for macOS and Windows. Public releases are
created from version tags after CI passes.

## One-time setup

1. Create the public GitHub repository as
   `amirdaraee/yc-onion-stream-deck-plugin`.
2. Enable private vulnerability reporting in repository Settings > Security.
3. Require pull requests and passing CI checks for the `main` branch.
4. Obtain an Apple Developer Program membership and a Developer ID Application
   certificate.
5. Create an app-specific password for Apple notarization.
6. Add these GitHub Actions secrets:

   - `MACOS_CERTIFICATE_BASE64` — base64-encoded Developer ID `.p12` file
   - `MACOS_CERTIFICATE_PASSWORD` — password used to export the `.p12`
   - `MACOS_KEYCHAIN_PASSWORD` — a random temporary keychain password
   - `MACOS_SIGNING_IDENTITY` — complete Developer ID Application identity
   - `APPLE_ID` — Apple developer account email
   - `APPLE_TEAM_ID` — Apple developer team identifier
   - `APPLE_APP_PASSWORD` — app-specific password

## Pre-release checklist

1. Confirm the working tree contains only intended changes.
2. Confirm every supported platform claim has been tested on physical hardware.
3. Update `CHANGELOG.md` and remove the target version's changes from
   `Unreleased`.
4. Keep these three versions synchronized:

   - `streamdeck/package.json`: `1.3.1`
   - `manifest.json`: `1.3.1.0`
   - `controllerVersion` in `streamdeck/src/plugin.ts`: `1.3.1`

5. Run:

   ```sh
   swift test
   swift run yc-onion self-test
   cd streamdeck
   npm ci
   npm audit
   npm run check
   npm run release
   ```

6. Install the resulting package on a clean macOS user account and a Windows
   test machine. Test installation, Bluetooth permission, discovery, every
   lighting action, Stream Deck restart, system sleep/wake, and uninstall.
7. Confirm the repository contains no credentials, private device identifiers,
   personal logs, or prohibited authorship metadata.

## Publish a GitHub release

After the release commit is reviewed and CI passes:

```sh
git tag -s v1.3.1 -m "Release 1.3.1"
git push origin main v1.3.1
```

The release workflow verifies the version, imports the signing certificate,
builds and notarizes the macOS helper, packages the plugin, creates a SHA-256
checksum, and attaches both files to a GitHub release.

## Submit to Elgato Marketplace

1. Create an organization and sign the Maker Agreement in Maker Console.
2. Upload the notarized `.streamDeckPlugin` file from the GitHub release.
3. Provide the English listing copy from `marketplace/listing.md`.
4. Upload one 288 × 288 PNG app icon, one 1920 × 960 PNG thumbnail, and at
   least three 1920 × 960 PNG gallery images or an eligible video.
5. Add the repository, support, setup, and privacy links.
6. Upload release notes and submit for review without automatic publication.
7. Download the processed package from Maker Console and test the protected
   build before approving publication.

Marketplace review commonly takes several business days. Keep the plugin UUID
unchanged after the first published version.
