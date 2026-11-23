# LidAwake ☕

A tiny macOS menu bar app that keeps your Mac awake — **even with the lid closed** — with a single click.

LidAwake is a one-click replacement for:

```sh
sudo pmset -a disablesleep 1
caffeinate -d
```

…and for remembering to undo it afterwards.

| Off | On | On with timer |
|:---:|:---:|:---:|
| empty mug | mug full of coffee + steam | mug + remaining time, e.g. `☕ 1:12` |

## Why

macOS normally puts a MacBook to sleep the moment you close the lid unless an external display, power and keyboard are connected (clamshell mode). Sometimes you need the machine to keep running with the lid closed — a long build, a download, an SSH session, a remote desktop connection, music over AirPlay, etc.

`sudo pmset -a disablesleep 1` does exactly that, but it's easy to forget it's on — and then the laptop never sleeps again. LidAwake puts the state right in the menu bar so you always see it, and can turn it off automatically on a timer.

## Features

- **Left click** the mug — toggle "never sleep" on/off (stays on until you turn it off).
- **Right click / two-finger click** — menu:
  - **Turn on for a set time**: pick a duration with the slider (15, 30, 45 min, 1, 1.5, 2, 3, 4, 6, 8, 12, 24 h) — the end time updates live — and press **Start**. Sleep is restored automatically when the timer ends. The last chosen duration is remembered.
  - Shows when it will turn off (`Turns off at 14:30 (in 1 h 12 min)`), or that it's on indefinitely.
  - **Turn off** and **Quit**.
- **Open at Login** switch in the menu (macOS 13+, via `SMAppService`).
- **Countdown in the menu bar** next to the mug while a timer is running (`H:MM`).
- **Safety mode** (on by default, toggle in the menu) — protects the Mac while the lid is closed:
  - **Lid closed → screen brightness set to 0** (the screen is *not* locked); lid opened → previous brightness restored.
  - **Overheating with the lid closed → trackpad siren**: the Force Touch motor plays a smooth rising 20 → 600 Hz sweep (lingers in the lows, accelerates at the end) once per second, 10 times, each pulse longer than the last (0.2 → 0.5 s), at 80% strength to spare the motor. It is both felt and heard — even with speakers muted. Opening the lid stops it.
  - **Still hot after 1 min → Low Power Mode** is turned on (and turned back off when the Mac cools down, only if LidAwake was the one that enabled it).
  - **Still hot after 3 min → sleep is re-enabled** and the Mac is put to sleep to prevent damage. The menu shows a note about it afterwards.
- **Colored icon** when active — brown coffee and steam; adapts to light and dark menu bars. Monochrome empty mug when inactive.
- **Safe by default** — quitting the app restores normal sleep. On launch it reads the real `pmset` state, so it never lies about whether sleep is disabled (e.g. after a crash).
- **One-time setup** — on first use it asks for your password once (standard macOS dialog) and installs a narrowly-scoped sudo rule. No password prompts after that.
- **Tiny and idle** — ~330 KB universal binary, no dependencies, no background polling, 0% CPU when idle. The countdown redraws only at the exact moment the minute changes.
- **Universal** — runs natively on Apple Silicon and Intel, macOS 11 Big Sur and later.

> **Language:** the app follows the system language — Russian if it's your first preferred language, English otherwise. The installer and the bundled install guide (`How to install.txt` / `Как установить.txt`) are bilingual too.

## Installation

### Option A — one command (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/Timenty/lid-awake/main/get.sh | zsh
```

[`get.sh`](get.sh) downloads the latest release with `curl`, installs it to `/Applications` (or `~/Applications` if you're not an admin), quits the old version if it's running, and launches the app. Files fetched by `curl` don't get the `com.apple.quarantine` flag, so macOS doesn't block the ad-hoc signed app. Run the same command again to update.

Then click the mug — macOS will ask for your password **once** to allow LidAwake to toggle sleep. You must be an administrator on the Mac (needed to install the sudo rule).

### Option B — Homebrew

```sh
brew install --cask timenty/tap/lidawake
```

Upgrade with `brew upgrade --cask lidawake`. The cask lives in [Timenty/homebrew-tap](https://github.com/Timenty/homebrew-tap); it clears the quarantine flag after install so the ad-hoc signed app opens normally.

- `brew uninstall --cask lidawake` — quits the app (restoring sleep) and removes it.
- `brew uninstall --cask --zap lidawake` — also removes the sudo rule and settings.

### Option C — prebuilt app, manual

1. Download `LidAwake.zip` from [Releases](https://github.com/Timenty/lid-awake/releases/latest) and unzip it.
2. Drag **LidAwake.app** to **Applications** and open it. The app is ad-hoc signed (not notarized by Apple), so macOS will block it the first time:
   - *"Apple could not verify…"* → click **Done**, then **System Settings → Privacy & Security** → *"LidAwake was blocked…"* → **Open Anyway**.
   - *"LidAwake can't be opened"* (only an **OK** button) → remove the quarantine flag:
     ```sh
     xattr -cr /Applications/LidAwake.app && open /Applications/LidAwake.app
     ```
3. Click the mug — macOS will ask for your password once.

### Option D — build from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/Timenty/lid-awake.git
cd lid-awake
./install.sh     # build, install sudo rule (GUI password prompt), copy to /Applications, launch
```

**Launch at login:** right-click the mug → **Open at Login** (macOS 13+; uses `SMAppService`). On macOS 11–12: System Settings → Users & Groups → Login Items → `+` → LidAwake.

## How it works

When you turn LidAwake **on**, it:

1. Runs `sudo -n /usr/bin/pmset -a disablesleep 1` — prevents system sleep entirely, including on lid close.
2. Creates an IOKit power assertion `PreventUserIdleDisplaySleep` — the in-process equivalent of `caffeinate -d`, so the display doesn't idle-sleep while the lid is open. No extra `caffeinate` process is spawned.

When you turn it **off** (manually, by timer, or by quitting), it runs `pmset -a disablesleep 0` and releases the assertion. If the lid is closed at that moment (timer ran out, overheat protection), it also runs `pmset sleepnow`, so the Mac sleeps just like it normally would with the lid closed.

### Safety mode internals

Everything is event-driven — nothing is polled, so safety mode costs 0% CPU while idle.

| What | How |
|---|---|
| Lid state | `AppleClamshellState` on `IOPMrootDomain` + IOKit interest notification `kIOPMMessageClamshellStateChange` |
| Overheating | `ProcessInfo.thermalState` ≥ `.serious` + `thermalStateDidChangeNotification` — macOS's own thermal-pressure verdict (exact sensor temperatures need private SMC access) |
| Brightness | `DisplayServicesGet/SetBrightness` from the private `DisplayServices` framework (loaded lazily via `dlopen`). The previous value is persisted, so it is restored even after a crash |
| Trackpad siren | Force Touch actuator via the private `MultitouchSupport` framework (`MTActuatorOpen`, `MTActuationCreateFromDictionary`, `MTActuationActuate`), driving it with sine waveforms — technique from [os6/nospeaker](https://github.com/os6/nospeaker) (MIT). Loaded lazily, only when an alarm actually fires |
| Low Power Mode | `sudo -n pmset -a lowpowermode 1/0` (macOS 12+) |

Private frameworks are resolved with `dlopen`/`dlsym`; if a future macOS removes them, the corresponding step is silently skipped and everything else keeps working.

You can verify the state at any time:

```sh
pmset -g | grep SleepDisabled       # 1 = sleep disabled
pmset -g assertions | grep LidAwake # display assertion
```

### Privileges

`pmset disablesleep` needs root. Instead of running a privileged helper, LidAwake installs a single sudoers drop-in on first use:

```
/etc/sudoers.d/lidawake
<your-user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1, /usr/bin/pmset sleepnow
```

- It allows **only** these exact commands, for **only** your user — nothing else can be run as root through it.
- The file is validated with `visudo -c` before being installed (mode `0440`, owner `root:wheel`), so a malformed rule can never break `sudo`.
- Installation goes through the standard macOS administrator password dialog (`do shell script … with administrator privileges`).
- If an older rule (from a previous version) is found, LidAwake asks once to extend it when you turn it on — while you're at the Mac, never in the middle of an overheat.

## ⚠️ Warning

While the mug is full, **your Mac will not sleep — even closed in a bag.** A MacBook running in a closed bag can overheat and drain its battery. Safety mode is a last line of defense, not a license: turn LidAwake off (empty mug) before packing your laptop, or use the timer mode.

## Uninstall

```sh
osascript -e 'quit app "LidAwake"'           # also restores sleep
sudo pmset -a disablesleep 0                 # just in case
sudo rm /etc/sudoers.d/lidawake
rm -rf /Applications/LidAwake.app
defaults delete local.lidawake 2>/dev/null   # remembered settings
```

## Development

No Xcode project — plain `swiftc`.

| File | Purpose |
|---|---|
| `main.swift` | App: status item, toggle, timer menu, safety state machine, `pmset`/IOKit logic, sudo setup |
| `Safety.swift` | Lid notifications, built-in display brightness, trackpad siren |
| `Mug.swift` | Hand-drawn mug icon (empty template / filled with coffee + steam) |
| `demo/siren.sh` | Standalone siren demo (builds `demo/main.swift` + `Safety.swift` on first run) |
| `build.sh` | Builds a universal (`arm64` + `x86_64`, macOS 11+) `LidAwake.app`, ad-hoc signed |
| `install.sh` | Builds, installs the sudo rule, copies the app to `/Applications` and launches it |
| `L10n.swift` | `t("English", "Русский")` — picks the string by system language |
| `VERSION` | App version, read by `build.sh` |
| `dist.sh` | Builds and packages `dist/LidAwake.zip` (app + install guides) for sharing |
| `release.sh` | Cuts a release: bumps `VERSION`, builds, tags, publishes the GitHub release, updates the Homebrew cask |
| `get.sh` | One-command installer/updater: downloads the latest release zip and installs it |
| `How to install.txt` / `Как установить.txt` | Step-by-step install guides for non-technical users |

```sh
./build.sh   # → LidAwake.app
./dist.sh    # → dist/LidAwake.zip
```

Editors using SourceKit may show `Cannot find 'mugImage' / 'Lid' in scope` — that's because the Swift files are compiled together by `build.sh` without a package manifest; the build itself is fine.

### Siren demo

Hear (and film) the overheat siren without actually overheating your Mac:

```sh
./demo/siren.sh         # turn LidAwake on, then close the lid — plays while the lid is closed
./demo/siren.sh --now   # play immediately, lid open
```

It plays exactly what safety mode plays: 10 pulses, one per second, each a 20 → 600 Hz sweep growing from 0.2 to 0.5 s.

### Releasing

```sh
./release.sh 1.3.0
```

Requires a clean working tree and an authenticated `gh`. It writes `VERSION`, builds `dist/LidAwake.zip`, commits and tags `v1.3.0`, publishes the GitHub release with the zip, and bumps `version`/`sha256` in the [Homebrew cask](https://github.com/Timenty/homebrew-tap/blob/main/Casks/lidawake.rb). `get.sh` always fetches the latest release, so nothing else needs updating.

### Distribution without Gatekeeper warnings

To let users open the app without the "Open Anyway" step, sign it with a Developer ID certificate and notarize it (requires a paid Apple Developer account):

```sh
codesign -s "Developer ID Application: …" --options runtime --force LidAwake.app
ditto -c -k --keepParent LidAwake.app LidAwake.zip
xcrun notarytool submit LidAwake.zip --apple-id … --team-id … --wait
xcrun stapler staple LidAwake.app
```

## Requirements

- macOS 11 Big Sur or later
- Apple Silicon or Intel Mac
- Administrator account (for the one-time sudo rule)
