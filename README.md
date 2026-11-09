![MonoPods](docs/images/banner.png)

MonoPods is a macOS menu bar app that switches the Mac's audio to mono when you wear one AirPod and back to stereo when you wear both.

| AirPods in your ears | Audio mode |
| --- | --- |
| One | Mono |
| Two | Stereo |
| Neither | Stereo |

When macOS pauses your video as you remove one AirPod, MonoPods sends Play to resume it; your player must support macOS media controls.

## Install

1. Download `MonoPods.dmg` from the [latest release](https://github.com/bernalli/monoPods/releases/latest).
2. Open the disk image and drag MonoPods into Applications.
3. Open MonoPods from Applications. macOS blocks this first launch because MonoPods is not notarized by Apple.
4. Open System Settings › Privacy & Security and scroll down to Security. Click Open, then click Open Anyway. Open Anyway is available for about an hour after the blocked launch. If macOS asks for your login password, enter it and click OK.
5. Allow Bluetooth access when macOS asks.

MonoPods is signed ad hoc, not with a Developer ID, so macOS cannot verify its developer. Download it only from this repository's releases. From Applications it starts at login; turn off Launch at Login in its Options menu to stop this. macOS may show a Background Items Added notification for this login item.

## Updates

MonoPods checks for updates only when you choose Check for Updates… in its menu. It never checks by itself.

- If a new version is available, MonoPods downloads it only after you choose to install it.
- MonoPods installs an update only after it has returned the sound to stereo, or confirmed that there is nothing to restore. From that confirmation until the new version is running, download included, automatic switching is suspended.
- If this cannot be confirmed in time, MonoPods does not install the update and keeps working. After the next launch of MonoPods, you can choose Check for Updates… again.
- After a crash, MonoPods recovers its saved restore state before resuming updates. During installation, concurrent launches wait for one complete, validated version.
- macOS may ask again for Bluetooth access after an update, because each version has a new ad hoc signature. If it asks, allow it to keep automatic switching working.

Each check downloads `https://github.com/bernalli/monoPods/releases/latest/download/appcast.xml` from GitHub, and each update downloads the disk image from the same release. GitHub receives your IP address and the app version. Updates use [Sparkle](https://sparkle-project.org) and install only with a valid EdDSA signature from the key in the installed app.

## Requirements

- A Mac with Apple silicon and macOS 14.2 or later.
- AirPods with ear detection sensors, excluding AirPods Max, connected and selected as the Mac's sound output.
- Automatic Ear Detection turned on in Bluetooth settings.
- Bluetooth access allowed for MonoPods when macOS asks.

## Good to know

- Turning on Mono Audio in System Settings pauses automatic switching.
- After a crash, mono may stay on until you reopen MonoPods.
- Tested only with AirPods Pro 2 on macOS 27.2.
- Apart from update checks, MonoPods makes no network requests. It reads the local system log.

See [technical notes and building from source](docs/TECHNICAL.md).

## License

MonoPods is released under the [MIT License](LICENSE). Copyright © 2026 Samuele Martinalli.

The app includes Sparkle, which has its own license; its notice is in `MonoPods.app/Contents/Resources/Sparkle-LICENSE.txt`.
