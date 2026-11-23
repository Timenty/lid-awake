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
  - **Turn on for a set time**: pick a duration with `−` / `+` (15, 30, 45 min, 1, 1.5, 2, 3, 4, 6, 8, 12, 24 h) and press **Start**. Sleep is restored automatically when the timer ends. The last chosen duration is remembered.
  - Shows when it will turn off (`Turns off at 14:30 (in 1 h 12 min)`), or that it's on indefinitely.
  - **Turn off** and **Quit**.
- **Countdown in the menu bar** next to the mug while a timer is running (`H:MM`).
- **Colored icon** when active — brown coffee and steam; adapts to light and dark menu bars. Monochrome empty mug when inactive.
- **Safe by default** — quitting the app restores normal sleep. On launch it reads the real `pmset` state, so it never lies about whether sleep is disabled (e.g. after a crash).
- **One-time setup** — on first use it asks for your password once (standard macOS dialog) and installs a narrowly-scoped sudo rule. No password prompts after that.
- **Tiny and idle** — ~270 KB universal binary, no dependencies, no background polling, 0% CPU when idle. The countdown redraws only at the exact moment the minute changes.
- **Universal** — runs natively on Apple Silicon and Intel, macOS 11 Big Sur and later.

> **UI language:** the in-app menu and the install guide (`Как установить.txt`) are currently in Russian.

## Installation

### Option A — prebuilt app

1. Download `LidAwake.zip` (from Releases, or build it yourself with `./dist.sh`) and unzip it.
2. Drag **LidAwake.app** to **Applications**.
3. Open it. The app is ad-hoc signed (not notarized by Apple), so the first time macOS will block it:
   - Click **Done** in the warning dialog.
   - Open **System Settings → Privacy & Security**, scroll down to *"LidAwake was blocked…"* and click **Open Anyway**, then confirm with your password.
   - On older macOS versions you can instead right-click the app → **Open** → **Open**.
4. The empty mug appears in the menu bar. Click it — macOS will ask for your password **once** to allow LidAwake to toggle sleep.

You must be an administrator on the Mac (needed to install the sudo rule).

**Launch at login:** System Settings → General → Login Items → `+` → LidAwake.

### Option B — build from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/Timenty/lid-awake.git
cd lid-awake
./install.sh     # build, install sudo rule (GUI password prompt), copy to /Applications, launch
```

## How it works

When you turn LidAwake **on**, it:

1. Runs `sudo -n /usr/bin/pmset -a disablesleep 1` — prevents system sleep entirely, including on lid close.
2. Creates an IOKit power assertion `PreventUserIdleDisplaySleep` — the in-process equivalent of `caffeinate -d`, so the display doesn't idle-sleep while the lid is open. No extra `caffeinate` process is spawned.

When you turn it **off** (manually, by timer, or by quitting), it runs `pmset -a disablesleep 0` and releases the assertion.

You can verify the state at any time:

```sh
pmset -g | grep SleepDisabled       # 1 = sleep disabled
pmset -g assertions | grep LidAwake # display assertion
```

### Privileges

`pmset disablesleep` needs root. Instead of running a privileged helper, LidAwake installs a single sudoers drop-in on first use:

```
/etc/sudoers.d/lidawake
<your-user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

- It allows **only** these two exact commands, for **only** your user — nothing else can be run as root through it.
- The file is validated with `visudo -c` before being installed (mode `0440`, owner `root:wheel`), so a malformed rule can never break `sudo`.
- Installation goes through the standard macOS administrator password dialog (`do shell script … with administrator privileges`).

## ⚠️ Warning

While the mug is full, **your Mac will not sleep — even closed in a bag.** A MacBook running in a closed bag can overheat and drain its battery. Turn LidAwake off (empty mug) before packing your laptop, or use the timer mode.

## Uninstall

```sh
osascript -e 'quit app "LidAwake"'           # also restores sleep
sudo pmset -a disablesleep 0                 # just in case
sudo rm /etc/sudoers.d/lidawake
rm -rf /Applications/LidAwake.app
defaults delete local.lidawake 2>/dev/null   # remembered timer duration
```

## Development

No Xcode project — plain `swiftc`.

| File | Purpose |
|---|---|
| `main.swift` | App: status item, toggle, timer menu, `pmset`/IOKit logic, first-run sudo setup |
| `Mug.swift` | Hand-drawn mug icon (empty template / filled with coffee + steam) |
| `build.sh` | Builds a universal (`arm64` + `x86_64`, macOS 11+) `LidAwake.app`, ad-hoc signed |
| `install.sh` | Builds, installs the sudo rule, copies the app to `/Applications` and launches it |
| `dist.sh` | Builds and packages `dist/LidAwake.zip` (app + install guide) for sharing |
| `Как установить.txt` | Step-by-step install guide for non-technical users (Russian) |

```sh
./build.sh   # → LidAwake.app
./dist.sh    # → dist/LidAwake.zip
```

Editors using SourceKit may show `Cannot find 'mugImage' in scope` — that's because `main.swift` and `Mug.swift` are compiled together by `build.sh` without a package manifest; the build itself is fine.

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
