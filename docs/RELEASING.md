# Releasing MonoPods

Release builds are signed ad hoc and are not notarized.
Updates reach existing installations through Sparkle. The only guarantee of their integrity is the EdDSA signature of the disk image, checked against the public key in `Resources/UpdateChannel.json`.

## Prerequisite

The private EdDSA key lives in the login keychain of the release machine, under the account named by `MONOPODS_SPARKLE_ACCOUNT`.
Keep an offline copy of that key. An application without a Developer ID signature has no key rotation path: if the key is lost, no existing installation accepts another update, and every user must reinstall from a new disk image.

## Environment

- `MONOPODS_SPARKLE_ACCOUNT`: the keychain account of the EdDSA key, matching `^[A-Za-z0-9._-]{1,64}$`.
- `MONOPODS_RECEIPT`: an absolute path outside the repository for the release receipt. The file must not exist yet.

## Usage

```
scripts/release.sh [--first-release]
scripts/release.sh --candidate-version N --staging-dir DIR
```

- Without options the script builds a production release and requires the published feed at `https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml`. The new build must be newer than the published one.
- `--first-release` is only for the first public release, when no feed is published yet. With a reachable feed the script stops.
- `--candidate-version N --staging-dir DIR` builds a test candidate with `CFBundleVersion` N. `DIR` is an absolute, existing folder without links. The candidate image and its local feed are written there as `MonoPods-N.dmg` and `appcast-N.xml`; existing files are never replaced. The bundle still carries the production channel: a test feed is only ever set in the user defaults of the test machine.

The `dist` folder must be absent or empty when the script starts. Any unknown argument or invalid variable stops it with status 64.

## Versions

`CFBundleVersion` is an integer that grows strictly with every build that may reach an installation, because Sparkle compares it and refuses downgrades. Test candidates use 2, 3 and 4; the first public release is `1.0.0` with `CFBundleVersion` 10, so no candidate can ever look newer than a release.

## Steps

1. **R1** `scripts/sparkle-tools.sh` downloads the pinned Sparkle command line tools once, checks the archive digest, matches both executable files byte for byte against that archive on every invocation, checks the code signature of `generate_keys` and `sign_update`, and prints their folder.
2. **R2** `generate_keys -p` prints the public key of the account. It must be the `publicEDKey` of `Resources/UpdateChannel.json`, otherwise the release stops before any build.
3. **R3** `scripts/check.sh` runs the builds, the tests and the linters.
4. **R4** `scripts/bundle.sh --update-channel Resources/UpdateChannel.json` builds the bundle with the production channel (with `--candidate-version N` for a candidate).
5. **R5** `scripts/adhoc-check.py` and `scripts/manifest.py verify` check the ad hoc signatures and the manifest of the bundle.
6. **R6** `scripts/dmg.sh` creates and verifies the disk image.
7. **R7** `sign_update -p` signs the disk image with the EdDSA key, and `sign_update --verify` checks that signature.
8. **R8** `scripts/appcast.py build` writes the feed and `scripts/appcast.py check` verifies it against the bundle, the disk image and, for a production release, the published feed. A candidate copies the disk image into the staging folder and points the feed at it with a `file://` URL.
9. **R9** `scripts/release-receipt.py` writes the receipt: source commit, manifest, disk image and feed digests, versions, the incorporated channel and the signing mode `ad-hoc`.
10. **R10** `scripts/artifact-scan.py` checks that the bundle carries no path of the build machine.
11. **R11** The script prints `___RELEASE_END ok version=<short> build=<build>___`, and only when every step succeeded.

A production release publishes `dist/MonoPods.dmg` and `dist/appcast.xml` as assets of the GitHub Release `v<short>`.

## Checking an update

MonoPods checks for updates only when the user asks. To verify a release, install the previous release, choose Check for Updates… in its menu and install the offered update.
