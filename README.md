![MonoPods](docs/images/banner.png)

MonoPods switches your Mac’s audio to mono when you wear one AirPod and back to stereo when you wear both.

| AirPods in your ears | Audio mode |
| --- | --- |
| One | Mono |
| Two | Stereo |
| Neither | Stereo |

## Install

1. Download `MonoPods.dmg` from the [latest release](https://github.com/bernalli/monoPods/releases/latest).
2. Open it and drag MonoPods into Applications.
3. Open MonoPods. macOS blocks the first launch because Apple has not notarized it.
4. In System Settings › Privacy & Security › Security, click Open, then Open Anyway. Do this within about an hour of the blocked launch. Enter your Mac login password if asked.
5. Allow Bluetooth access.

MonoPods uses an ad hoc signature, so macOS cannot verify its developer. Download only from this repository’s releases.

Click the MonoPods icon at the top right of your screen to open its menu. It starts at login when installed in Applications; turn off Options › Launch at Login to stop this. macOS may show a Background Items Added notification.

## Updates

Choose Check for Updates… to check for a new version. MonoPods never checks automatically and downloads an update only when you choose to install it.

- Before downloading, MonoPods must confirm stereo or that nothing needs restoring. Audio switching then pauses until the new version runs.
- If confirmation takes too long, the update stops and MonoPods keeps working. Quit and reopen MonoPods before checking again.
- After a crash, MonoPods handles audio recovery before allowing updates. During installation, extra copies wait for the complete, verified version.
- Each update has a new ad hoc signature. Allow Bluetooth access again if macOS asks.

Checks fetch the [update list](https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml) from GitHub; updates fetch the release’s disk image. GitHub receives your IP address and app version. [Sparkle](https://sparkle-project.org) verifies each update’s EdDSA signature against the key in the installed app before installing it.

## Requirements

- Apple silicon and macOS 14.2 or later.
- AirPods with ear detection sensors, excluding AirPods Max, connected and selected as your Mac’s sound output.
- Automatic Ear Detection turned on in Bluetooth settings.
- Bluetooth access allowed for MonoPods.

## Good to know

- Turning on Mono Audio in System Settings pauses automatic switching.
- MonoPods tries to resume video when removing one AirPod causes macOS to pause it. Your player must support macOS media controls; results vary.
- After a crash, mono may stay on until you reopen MonoPods.
- Tested only with AirPods Pro 2 on macOS 27.2.
- Report an Issue… opens a new GitHub issue in your browser. MonoPods does not submit it for you.
- Audio detection reads local system logs. Only the update process makes network requests.

See [technical notes and building from source](docs/TECHNICAL.md).

## License

MonoPods is released under the [MIT License](LICENSE). Copyright © 2026 Samuele Martinalli.

The app includes Sparkle, which has its own license; its notice is in `MonoPods.app/Contents/Resources/Sparkle-LICENSE.txt`.
