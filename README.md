![MonoPods](docs/images/banner.png)

MonoPods is a menu bar app for Mac. It switches the sound to mono when you wear one AirPod and back to stereo when you wear two.

## Why

Put one AirPod back in its case and your Mac plays both channels through the other. Leave it on the desk or in your pocket and you would expect the same. It doesn't. Stereo sound is split between a left and a right channel, so with one AirPod you hear only half of it, and part of a song or a film goes missing. macOS can play stereo as mono, but only through an Accessibility setting you turn on and off by hand. MonoPods does it for you.

| AirPods in your ears | Sound |
| --- | --- |
| One | Mono |
| Two | Stereo |
| None | Stereo |

## Install

1. Download the disk image from the [latest release](https://github.com/bernalli/monoPods/releases/latest).
2. Open it and drag MonoPods into Applications.
3. Open MonoPods and allow Bluetooth access when macOS asks.

MonoPods is signed with a Developer ID and notarized by Apple. On first launch it asks whether to check for updates automatically, once a day. You can change this later in Options › Automatic Updates. An update is installed only when you choose Install and Relaunch. Update checks and update downloads contact GitHub, which receives your IP address and the app version; MonoPods makes no other network requests.

## Use

MonoPods has no Dock icon. Click its icon in the menu bar to see how many AirPods are in use and any warning.

- **Details** shows the audio output, the AirPods model and the state of ear detection.
- **Options › Launch at Login** is on by default when MonoPods is in Applications.
- **Options › Hide Menu Bar Icon** hides the icon. Open MonoPods again to bring it back.
- **Check for Updates…** looks for a new version at any time.
- **Report an Issue…** opens a new issue on GitHub in your browser.
- **Quit MonoPods** sets the sound back to stereo before it closes.

If the Accessibility setting for mono audio is already on, MonoPods leaves the sound as it is. The menu follows the system language: English, Italian, Spanish, French, German, Portuguese (Brazil), Japanese and Simplified Chinese.

## Requirements

- A Mac with Apple silicon and macOS 14.2 or later.
- AirPods with ear detection, connected and selected as the sound output. AirPods Max are not supported.
- Automatic Ear Detection turned on in Bluetooth settings.
- Bluetooth access allowed for MonoPods.

Technical notes and building from source: [docs/TECHNICAL.md](docs/TECHNICAL.md).

## License

MonoPods is released under the [MIT License](LICENSE). Copyright © 2026 Samuele Martinalli.

MonoPods includes Sparkle and the Plus Jakarta Sans font, each under its own license. Their notices are inside the app.
