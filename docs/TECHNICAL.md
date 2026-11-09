# Technical notes

[Product overview](../README.md)

## Audio and ear detection

MonoPods reads local system-log events for the current Bluetooth audio output.
The output must be paired and connected; its Core Audio UID must match its
Bluetooth address, and it must expose a valid product ID. Automatic Ear Detection
must be on. MonoPods observes that setting but cannot change it.

One earbud in selects mono; two or zero select stereo. The change affects the
whole Mac. [AudioModeAdapter](../Sources/MonoPodsRuntime/AudioModeAdapter.swift)
writes `kAudioHardwarePropertyMixStereoToMono` on the Core Audio system object,
then reads the property back. A serial worker performs these operations inside
the app. A successful readback confirms the property, not the sound at your ears.

The system Mono Audio switch takes priority. MonoPods reads `stereoAsMono` in
`com.apple.universalaccess` without changing it. When it is on, the app suspends
automatic writes, including stereo restoration. When switching is active, an
observed external change to the audio property schedules correction after 1 s,
with corrections at least 10 s apart. A changed target can trigger an immediate
write. Property listeners and refreshes on ear-count, wake, and reopen events
update the observation.

## Recovery and exit

The [engine](../Sources/MonoPodsCore/Engine.swift) records an intended write in
`restore.json` before applying it. The worker saves the running state, result,
and restoration debt. An owner lock serializes access. Invalid or unsaved
evidence blocks automation. On reopening after an unfinished run, the app
attempts stereo restoration when required and shows a crash notice. It does not
restore an earlier manually selected mono state.

Quit allows at most three stereo restoration attempts within a 2 s exit budget.
New attempts stop after 1.5 s. An independent watchdog ends the process at 2 s,
even if the audio worker stalls. If restoration is unconfirmed, the app launches
a detached copy of its executable to show a warning; an in-process panel is the
fallback if spawning fails. The journal retains the unfinished state for the
next opening. Mono may remain active after a crash or failed restoration.

## Video playback and limits

A silent Now Playing source observes Pause. A matching live transition from two
earbuds to one can authorize Play through MediaRemote. The engine checks recent
player state to avoid resuming a known manual pause. On insertion, it can send
Pause to counter a system resume while the player was stopped; brief audio is
still possible. Player compatibility and timing are not guaranteed. MediaRemote
is a private framework and may change between macOS releases.

Missing events, sleep, or an unreadable ear count can leave the last audio mode
in place until fresh evidence arrives. Historical events require a verified
connection boundary. The app does not infer an ear count from silence in the log.

Apart from Sparkle update checks, described in the README, the app makes no
network requests. Local diagnostics use `trace-v2.jsonl` and
one rotated file, each with a 16 MiB rotation threshold. Records contain sanitized
inputs, actions, and evidence hashes, not raw system-log messages, Bluetooth
addresses, or device names. Device names appear in the menu.

The tested setup reported for this project is AirPods Pro 2 on macOS 27.2.
Sleep/wake, restarting `coreaudiod`, restarting the Mac, a signed app launched at
login, and other macOS versions have not been measured. Other AirPods models,
players, acoustic latency, and power use also need measurement. Source inspection
and unit tests do not establish those results. Deferral of an update when stereo
restoration misses its deadline is covered only by automated tests; it has not
been measured on an installed app. An update from one installed release to the
next, including how long automatic switching stays suspended, has not been
measured.

## Updates and helper processes

Sparkle checks for updates only when the user chooses Check for Updates… in the
menu. At every launch, the app turns off Sparkle's automatic checks and
automatic downloads. If either is turned on later, the app turns both off
again. The app refuses every scheduled check.

MonoPods normally runs as a single process. Sparkle uses Autoupdate and Updater
while preparing and installing an update. Installation is allowed only after
MonoPods confirms stereo or confirms that there is nothing to restore.
Automation is suspended during this handoff, which starts before the download.
If confirmation misses the restore deadline, no update installs until the next
launch. A zero exit status alone does not authorize installation.

Mono switching is suspended only from the restore confirmation until the new
version is active, including the download. If the update cannot start in time,
the app keeps working, and the user can check again after the next launch.

After a crash, the next owner performs journal recovery before resuming
operation or updates. During replacement, an old version restarted by the launch
agent remains inactive. The new version validates its complete bundle and
acquires the runtime lock before recovery and activation; concurrent launches
cannot operate the audio engine. A failed or unconfirmed replacement blocks
operation until its outcome is established. Sparkle starts only in the instance
that owns the runtime lock, and only in builds with an update channel.

Release builds, including Sparkle's helper tools, are signed ad hoc and are not
notarized. Sparkle installs an update only when its disk image carries a valid
EdDSA signature from the key embedded in the installed app and the new version's
ad hoc code signature is valid.

## Build from source

Use macOS 14.2+ and Xcode with Swift 6. Checks also need Python 3, swift-format,
and SwiftLint. The only package dependency is Sparkle 2.10.1, pinned in
`Package.resolved`. MonoPods runs on Apple silicon only.

```sh
git clone https://github.com/bernalli/monoPods.git
cd monoPods
scripts/check.sh
scripts/bundle.sh
```

Use a clean checkout with HEAD reachable from a branch, tag, or remote reference.
Packaging rejects tracked changes and untracked files outside `build/`,
`.build/`, and `dist/`, including ignored files. It refuses an existing app
destination. The app keeps its state in
`~/Library/Application Support/io.github.bernalli.monopods` (mode 0700, files
0600) and creates the directory on first launch. An existing directory with
another mode, owner or a symbolic link blocks operation. Missing or unsafe
configuration blocks operation.

`scripts/bundle.sh` produces `dist/MonoPods.app`. It signs the bundle ad hoc and
verifies its signature and `Manifest.json`; it does not notarize or launch it.
`scripts/dmg.sh` produces `dist/MonoPods.dmg` and refuses an existing image.
Builds from source have no update channel, so they never check for updates.
Release builds are described in [RELEASING.md](RELEASING.md).

`scripts/check.sh` builds, runs Swift and Python tests, and checks formatting,
lint, and packaging syntax. It does not run installed-app acceptance. Keep real
audio, login-item, and restart measurements separate from these checks.
