# Releasing MonoPods

Release builds are signed with a Developer ID and the hardened runtime, and the disk image is notarized and stapled.
Updates reach existing installations through Sparkle. Sparkle installs an update only when the EdDSA signature of the disk image matches the public key in `Resources/UpdateChannel.json` and the new version's code signature is valid.

## Prerequisites

- The login keychain of the release machine holds exactly one Developer ID Application certificate with its private key. Create it in Xcode, Settings, Accounts, Manage Certificates. No team identifier or certificate name is stored in the repository: the script reads the certificate's SHA-1 from the keychain.
- A notary keychain profile named `notary`, created once with `xcrun notarytool store-credentials notary`.
- The private EdDSA key in the login keychain, under the account named by `MONOPODS_SPARKLE_ACCOUNT`. Keep an offline copy of that key. Installations of 1.0.x carry an ad hoc signature and accept an update only with this key, so every release they can reach keeps it. A future key rotation needs its own plan.

## Environment

- `MONOPODS_SPARKLE_ACCOUNT`: the keychain account of the EdDSA key, matching `^[A-Za-z0-9._-]{1,64}$`.
- `MONOPODS_RECEIPT`: an absolute path outside the repository for the release receipt. The file must not exist yet.

The script exports `MONOPODS_SIGNING_IDENTITY` for `scripts/bundle.sh` itself. `scripts/release.sh` and `scripts/bundle.sh` keep only `HOME`, `PATH`, `TMPDIR`, `LANG`, `LC_ALL`, `LC_CTYPE`, `USER`, `LOGNAME`, `DEVELOPER_DIR` and their own `MONOPODS_` parameters before they run any other command.

## Usage

```
scripts/release.sh [--first-release]
scripts/release.sh --candidate-version N --staging-dir DIR
```

- Without options the script builds a production release and requires the published feed at `https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml`. The new build must be newer than the published one.
- `--first-release` is only for the first public release, when no feed is published yet. With a reachable feed the script stops.
- `--candidate-version N --staging-dir DIR` builds a test candidate with `CFBundleVersion` N. `DIR` is an absolute, existing folder without links. The candidate image and its local feed are written there as `MonoPods-N.dmg` and `appcast-N.xml`; existing files are never replaced. The bundle still carries the production channel: a test feed is only ever set in the user defaults of the test machine.

The `dist` folder must be absent or empty when the script starts. Any unknown argument or invalid variable stops it with status 64. Every other refusal prints `STOP:` and a reason, and exits 1 without the final marker.

## Versions

`CFBundleVersion` is an integer that grows strictly with every build that may reach an installation, because Sparkle compares it and refuses downgrades. Test candidates use 2, 3 and 4; the first public release is `1.0.0` with `CFBundleVersion` 10, so no candidate can ever look newer than a release.

## Steps

1. **R0** `security find-identity -v -p codesigning` must list exactly one Developer ID Application certificate. The script prints only the first eight characters of its SHA-1, never its name, and exports the SHA-1 as `MONOPODS_SIGNING_IDENTITY`. Then `xcrun notarytool history --keychain-profile notary` must succeed, otherwise the run stops with `notary preflight failed`. This preflight shows that the certificate is listed and that the profile reaches the notary service; it does not prove that the private key is usable.
2. **R1** `scripts/sparkle-tools.sh` downloads the pinned Sparkle command line tools once, checks the archive digest, matches both executable files byte for byte against that archive on every invocation, checks the code signature of `generate_keys` and `sign_update`, and prints their folder.
3. **R2** `generate_keys -p` prints the public key of the account. It must be the `publicEDKey` of `Resources/UpdateChannel.json`, otherwise the release stops before any build.
4. **R3** `scripts/check.sh` runs the builds, the tests and the linters.
5. **R4** `scripts/bundle.sh --update-channel Resources/UpdateChannel.json` builds the bundle with the production channel (with `--candidate-version N` for a candidate). It signs Sparkle's helper tools, the framework and the app from the inside out, with the hardened runtime and a secure timestamp.
6. **R5** `scripts/developer-id-check.py` and `scripts/manifest.py verify` check the Developer ID signatures and the manifest of the bundle: one team for the app and the three Sparkle components, a timestamp, the hardened runtime and no entitlements.
7. **R6** `scripts/dmg.sh` creates and verifies the disk image.
8. **R6a** `codesign --timestamp` signs the disk image with the same certificate, and `codesign --verify --strict` checks it.
9. **R6b** `xcrun notarytool submit --keychain-profile notary --wait --timeout 30m --output-format json` submits the disk image. The run continues only with exit status 0 and one strict JSON object whose `id` is a UUID and whose `status` is exactly `Accepted`. Any other answer, a timeout or an interruption stops the run, keeps the disk image and prints its SHA-256. With a valid `id` it also prints `xcrun notarytool log <id> --keychain-profile notary`. The remote state of a submission that did not end with `Accepted` is unknown: reconcile it with the kept image before any new submission.
10. **R6c** `xcrun stapler staple` attaches the ticket to the disk image, and `xcrun stapler validate` checks it. A ticket that is not yet available stops the run.
11. **R6d** `spctl` must accept the disk image and the app: exit status 0, one line `<path>: accepted` and one line exactly `source=Notarized Developer ID`. The app is assessed up to five times, 15 seconds apart. The assessment output is never printed.
12. **R7** `sign_update -p` signs the stapled disk image with the EdDSA key, and `sign_update --verify` checks that signature. The signature comes after stapling because stapling changes the bytes of the image.
13. **R8** `scripts/appcast.py build` writes the feed and `scripts/appcast.py check` verifies it against the bundle, the disk image and, for a production release, the published feed. A candidate copies the disk image into the staging folder and points the feed at it with a `file://` URL.
14. **R9** `scripts/release-receipt.py` writes the receipt: source commit, manifest, disk image and feed digests, versions, the incorporated channel and the signing mode `developer-id`.
15. **R10** `scripts/artifact-scan.py` checks that the bundle carries no path of the build machine.
16. **R11** The script prints `___RELEASE_END ok version=<short> build=<build>___`, and only when every step succeeded.

A production release publishes `dist/MonoPods.dmg` and `dist/appcast.xml` as assets of the GitHub Release `v<short>`.

## Checking an update

MonoPods checks for updates when the user asks or, with Automatic Updates on, about once a day. To verify a release, install the previous release, choose Check for Updates… in its menu and install the offered update.
