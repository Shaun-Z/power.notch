<h1 align="center">
  <br>
  <a href="https://github.com/Shaun-Z/power.notch">
    <img src="./powerNotch/Assets.xcassets/AppIcon.appiconset/powernotch-icon-256.png" alt="powerNotch" width="150">
  </a>
  <br>
  powerNotch
  <br>
</h1>

<p align="center">
  A macOS notch utility forked from and built upon <a href="https://github.com/TheBoredTeam/boring.notch"><strong>boringNotch</strong></a> by <a href="https://github.com/TheBoredTeam">TheBoredTeam</a>.
</p>

<p align="center">
  <a href="https://github.com/Shaun-Z/power.notch/actions/workflows/cicd.yml">
    <img src="https://github.com/Shaun-Z/power.notch/actions/workflows/cicd.yml/badge.svg" alt="powerNotch Build & Test" />
  </a>
  <a href="./LICENSE">
    <img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="License: GPL-3.0" />
  </a>
</p>

---

> [!NOTE]
> **powerNotch** is an independent fork of **[boringNotch](https://github.com/TheBoredTeam/boring.notch)** ([TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)). Full credit goes to TheBoredTeam and all boringNotch contributors for creating the original project and architecture. This repository tracks upstream boringNotch improvements while adding custom enhancements and rebranding.

Say hello to **powerNotch** — turning your MacBook's notch into a dynamic music control center with real-time lyrics, calendar and reminders integration, a handy file shelf with AirDrop support, a mirror/webcam view, and complete macOS HUD replacements.

## Features

- **Music Live Activity & Visualizer** — Dynamic playback controls and audio visualizer right in the notch (Apple Music, Spotify, YouTube Music, and system Now Playing).
- **Closed-Notch Real-Time Lyrics** — Displays synchronized lyrics below the closed notch with multi-source fallback (LRCLIB, NetEase, LewdHuTao, lyrics.ovh), adapted from [lycrics_notch](https://github.com/Dreammmmix/lycrics_notch).
- **Calendar & Reminders Integration** — Quick overview of upcoming events and reminders.
- **File Shelf with AirDrop Support** — Drag and drop files into the notch for temporary holding and quick sharing.
- **System HUD Replacements** — Sleek inline notch HUDs for volume, display brightness, and keyboard backlight.
- **Battery & Charging Indicator** — Live charging status and percentage indicator.
- **Mirror (Webcam)** — Quick camera preview directly from the notch.
- **Customizable Gestures & Sizing** — Fine-tune notch dimensions and interactions for different display sizes.

## Installation

**System Requirements:**
- macOS **14 Sonoma** or later
- Apple Silicon or Intel Mac

### Option 1: Download from Releases

Download the latest `.dmg` from the [Releases](https://github.com/Shaun-Z/power.notch/releases) page, open it, and drag **powerNotch.app** into `/Applications`.

> [!IMPORTANT]
> Because this app is not notarized with an Apple Developer account, macOS may warn that powerNotch is from an unidentified developer on first launch. You only need to clear the quarantine attribute once:
>
> ```bash
> xattr -dr com.apple.quarantine "/Applications/powerNotch.app"
> ```
>
> Alternatively, open **System Settings** > **Privacy & Security** and click **Open Anyway** next to the powerNotch warning.

### Option 2: Building from Source

#### Prerequisites
- **macOS 15.6 or later**
- **Xcode 26 or later**

#### Steps
1. **Clone the repository:**
   ```bash
   git clone https://github.com/Shaun-Z/power.notch.git
   cd power.notch
   ```

2. **Open the project in Xcode:**
   ```bash
   open powerNotch.xcodeproj
   ```

3. **Build and run:**
   - Select the `powerNotch` scheme and press `Cmd + R`.

## Usage

- Launch **powerNotch** to activate the notch experience.
- Hover over or click the notch to expand controls, calendar, and shelf.
- Use the menu bar icon to open Settings and customize appearance, media controllers, lyrics, HUDs, and gestures.

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](./CONTRIBUTING.md) before opening a pull request.

## Acknowledgments

**powerNotch** would not exist without the amazing open-source projects and communities behind it:

- **[boringNotch](https://github.com/TheBoredTeam/boring.notch)** by **[TheBoredTeam](https://github.com/TheBoredTeam)** — The original project that powerNotch is forked from. If you love this app, please consider starring and supporting the upstream boringNotch project!
- **[lycrics_notch](https://github.com/Dreammmmix/lycrics_notch)** — Inspiration and implementation reference for closed-notch real-time lyrics display.
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** — Enables Now Playing support on macOS 15.4+.
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** — Instrumental to the original Shelf feature in boringNotch.

For a full list of third-party licenses and attributions, see [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES).

## License

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](./LICENSE) for details.
