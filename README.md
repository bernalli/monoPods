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
3. Open MonoPods. macOS blocks the first launch because MonoPods is not notarized by Apple.
4. In System Settings, open Privacy & Security and scroll down to Security. Click Open, then Open Anyway. Do this within about an hour of the blocked launch. Enter your Mac login password if asked.
5. Allow Bluetooth access.

MonoPods is signed ad hoc, not with a Developer ID, so macOS cannot verify its developer. Download it only from this repository’s releases.

Click the MonoPods icon at the top right of your screen to open its menu. It starts at login when installed in Applications; turn off Options › Launch at Login to stop this. macOS may show a Background Items Added notification.

## Updates

Choose Check for Updates… to check for a new version. MonoPods never checks automatically and downloads an update only when you choose to install it.

- Before downloading, MonoPods must return the sound to stereo or confirm that there is nothing to restore. From that confirmation until the new version runs, automatic switching is paused.
- If MonoPods cannot confirm this, it does not install the update and keeps working. Quit and reopen MonoPods before you check again.
- After a crash, MonoPods recovers its saved audio state before it allows updates. During installation, other launches of MonoPods stay inactive until the new version is complete and verified.
- macOS may ask again for Bluetooth access after an update, because each version has a new ad hoc signature. If it asks, allow it to keep automatic switching working.

Checks fetch the [update list](https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml) from GitHub; updates fetch the disk image from the same release. GitHub receives your IP address and the app version. [Sparkle](https://sparkle-project.org) installs an update only when its EdDSA signature is valid for the key in the installed app.

## Requirements

- A Mac with Apple silicon and macOS 14.2 or later.
- AirPods with ear detection sensors, excluding AirPods Max, connected and selected as your Mac’s sound output.
- Automatic Ear Detection turned on in Bluetooth settings.
- Bluetooth access allowed for MonoPods.

## Good to know

- Turning on Mono Audio in System Settings pauses automatic switching.
- MonoPods tries to resume video when removing one AirPod causes macOS to pause it. Your player must support macOS media controls; results vary.
- After a crash, mono may stay on until you reopen MonoPods.
- Tested only with AirPods Pro 2 on macOS 27.2.
- Report an Issue… opens GitHub’s new-issue page in your browser. MonoPods sends nothing by itself.
- Apart from update checks and downloads, MonoPods makes no network requests. It reads the local system log.

See [technical notes and building from source](docs/TECHNICAL.md).

## License

MonoPods is released under the [MIT License](LICENSE). Copyright © 2026 Samuele Martinalli.

The app includes Sparkle, which has its own license; its notice is in `MonoPods.app/Contents/Resources/Sparkle-LICENSE.txt`.

The app includes Plus Jakarta Sans SemiBold, licensed under SIL OFL 1.1; its notice is in `MonoPods.app/Contents/Resources/PlusJakartaSans-OFL.txt`.
