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
> **powerNotch** is an independent fork of **[boringNotch](https://github.com/TheBoredTeam/boring.notch)** ([TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)). Full credit goes to TheBoredTeam and all boringNotch contributors for creating the original project and architecture. This repository tracks the `main` branches of boringNotch and [lyrimuse](https://github.com/Yudaotor/lyrimuse) as upstream references while maintaining its own `main` and `dev` branches. NetEase integration references lyrimuse; this does not imply that all lyrimuse features are included.

Say hello to **powerNotch** — turning your Mac's notch or Dynamic Island into a music control center with real-time lyrics, calendar and reminders integration, a file shelf with AirDrop support, a mirror/webcam view, and replacements for volume and brightness HUDs.

## Features

- **Music Live Activity & Visualizer** — Dynamic playback controls and audio visualizer right in the notch (Apple Music, Spotify, YouTube Music, and system Now Playing).
- **NetEase Cloud Music** — Dedicated macOS client source with system playback state and controls, local song-ID/cover lookup, and ID-first synchronized lyrics, following [lyrimuse's approach](https://github.com/Yudaotor/lyrimuse).
- **Closed-Notch Real-Time Lyrics** — Displays synchronized lyrics below the closed notch on notched screens, or inside the collapsed Dynamic Island on other screens, with multi-source fallback (LRCLIB, NetEase, LewdHuTao, lyrics.ovh), adapted from [lycrics_notch](https://github.com/Dreammmmix/lycrics_notch).
- **Calendar & Reminders Integration** — Quick overview of upcoming events and reminders.
- **File Shelf with AirDrop Support** — Drag and drop files into the notch for temporary holding and quick sharing.
- **System HUD Replacements** — Sleek inline notch HUDs for volume, display brightness, and keyboard backlight.
- **Battery & Charging Indicator** — Live charging status and percentage indicator.
- **Mirror (Webcam)** — Quick camera preview directly from the notch.
- **Customizable Gestures & Sizing** — Fine-tune notch dimensions and interactions for different display sizes.
- **Liquid Glass & Dynamic Island** — Per-display Notch/Dynamic Island modes, Follow system/Light/Dark/Custom glass colors, and an app-specific opacity control. Native Liquid Glass requires macOS 26 or later; earlier versions use a blur material fallback.
- **Physical Notch Blending** — A solid black collapsed surface and a static, soft pill-shaped ink blend in the expanded glass card. Top-edge reflections are suppressed on notched displays; displays without a physical notch do not use the ink blend.
- **AI Usage & Desktop Widgets** — Optional provider quota, balance, and usage-history views, with desktop widgets. Available readings depend on the provider, credentials, and local history; the notch tab is disabled by default.
- **Developer Options** — Unlock animation speed controls and per-display Dynamic Island position and height adjustments by clicking the version number five times in About.

## Installation

**System Requirements:**

- macOS **15 Sequoia** or later
- Apple Silicon or Intel Mac
- macOS **26 or later** for native Liquid Glass

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

### Homebrew tap

Once the release and [Shaun-Z/homebrew-tap](https://github.com/Shaun-Z/homebrew-tap) are published, install with:

```bash
brew install --cask Shaun-Z/tap/power-notch
```

## Usage

- Launch **powerNotch** to activate the notch experience.
- Hover over or click the notch to expand controls, calendar, and shelf.
- Use the menu bar icon to open Settings and customize appearance, media controllers, lyrics, HUDs, and gestures.

### First-launch defaults

These defaults apply to a fresh configuration; existing saved preferences are preserved.

| Setting | Default |
| --- | --- |
| Displays | Enabled on all connected displays; Notch on screens with a physical notch, Dynamic Island on other screens |
| Remember last tab | Off |
| Use Liquid Glass | On |
| Color | Follow system |
| Opacity | 95% |
| Media color | Match album art |
| Boring Mirror | Off |
| Battery indicator, power status notifications, battery percentage, power status icons | All off |
| Lyrics | On |
| AI Usage notch tab | Off |
| Developer options | Hidden |

Change each display's **Notch / Dynamic Island / Off** mode in **Settings → General**.

### NetEase Cloud Music

In **Settings → Media → Music Source**, choose **NetEase Cloud Music**, then play music in the macOS NetEase client. Track metadata, playback position, play/pause, previous/next, and seeking use the existing bundled MediaRemote adapter. Commands are sent only while NetEase owns the system Now Playing session; another app taking over clears the dedicated source rather than controlling that app.

Read-only lookup of the client's queue, library, and history supports both App Store and standalone data locations. Matching requires the song title and artist, checks album/duration when available, and rejects ambiguous versions. An exact local ID enables direct NetEase LRC lookup; unreadable caches, changed schemas, or unavailable lyrics fall back to the existing lyrics providers. Local history is never treated as live playback state. Some macOS privacy configurations may prevent reading the App Store client's container; metadata from Now Playing still works without that lookup.

Favorite, app volume, shuffle, and repeat controls are unavailable for this source. This integration targets the native macOS client (`com.netease.163music`), not the iPad app or browser player.

The integration builds successfully and has automated coverage for metadata decoding, matching, lyric responses, and read-only database lookup. Live playback, seeking, artwork, and lyric timing still need verification with the NetEase macOS client.

### Glass appearance

Open **Settings → Appearance → Liquid Glass**:

1. **Use Liquid Glass** — Enable the glass background. Turning it off restores a solid black background.
2. **Color** — Choose **Follow system**, **Light**, **Dark**, or **Custom**. Follow system is the default and tracks the system appearance; Custom reveals a color picker.
3. **Opacity** — Adjust from **0% to 100%**, with **95%** as the default. The slider uses a continuous normalized range without fixed percentage steps. Its value is saved for powerNotch independently of the system glass transparency setting, and does not change other apps. It is disabled while Liquid Glass is off.

Native Liquid Glass requires macOS 26 or later; earlier versions adjust a fallback blur layer. Dark and Custom retain a tint as material intensity changes, so 0% does not mean a completely invisible card. On a display with a physical notch, the collapsed surface stays black. The expanded card uses a compact, static ink blend attached to the top edge; top-edge reflections are suppressed on notched displays.

### Developer options

Open **Settings → About** and click the **Version** row **five times in quick succession** to reveal **Developer options** in the sidebar. The unlock and control values persist between launches.

| Control | Behavior |
| --- | --- |
| **Animation speed** | **0.1×–2×**, in **0.05×** steps. **1×** is normal speed; lower values slow card expansion/collapse, album artwork, and lyric motion. **Reset animation speed** restores 1×. |
| **Vertical offset** | Adjust each enabled display's Dynamic Island position from **−12 to +24 pt**, in **0.5 pt** steps. Positive values move it downward. |
| **Total height** | Adjust each enabled display's collapsed Dynamic Island height from **14 to 48 pt**, in **0.5 pt** steps. **Auto** restores the automatic height; **Reset** restores both position and height for that display. |
| **Show developer options** | Turn off to hide the tab; click the Version row five times to reveal it again. |

Per-display position and height overrides take effect on displays set to **Dynamic Island** in General. Animation speed applies to the shared card, artwork, and lyric motion rather than every animation in the app.

### Expansion and collapse

The glass background, outline, and content clipping share the same animated surface geometry. The physical-notch ink blend stays static and is clipped by that surface. Use a slower animation speed in Developer options to inspect transitions on your display; the geometry synchronization has been checked in hosted-window tests, while visual behavior still needs confirmation on the target display.

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](./CONTRIBUTING.md) before opening a pull request.

Run `swift test` from the repository root for AI usage and NetEase metadata regression tests. The Swift Testing targets compile the same AI history models, Codex event parser, refresh coordinator, and NetEase metadata/lyrics helpers used by the app. NetEase tests use temporary queue and SQLite fixtures. These tests do not launch the app, access personal credentials or music caches, or call live provider APIs. The normal push/PR build and shared release build use Xcode 26.6.

AI usage history attributes Codex token increments to each event's local calendar day. Thread-level SQLite totals are excluded because they cannot establish daily usage. Cost history preserves currency and source: charts prefer balance-derived spend and otherwise show USD API-equivalent estimates with `≈`. A chart uses one currency and source across the entire period; missing observations are not filled with estimates from a different source. Legacy ledger costs without currency metadata are omitted rather than relabeled.

### Publishing a release

Prepare exactly one open, mergeable `dev` → `main` release PR in this repository, then run **Actions → Deploy powerNotch → Run workflow** from `main`, with version `0.1.0` for the first release. The workflow builds the PR's exact head commit and uses its title and body as release notes. Stable releases merge that PR before publication. Existing draft releases can be resumed from their original build source.

The release workflow uploads `powerNotch.dmg` to [Shaun-Z/power.notch](https://github.com/Shaun-Z/power.notch/releases), updates `updater/appcast.xml`, and writes the version and downloaded DMG's SHA-256 to `Casks/power-notch.rb` in `Shaun-Z/homebrew-tap`. Create that public tap repository with an initial commit (for example, a README) before publishing; the workflow creates the `Casks` directory.

Configure these GitHub Actions values in the app repository:

- Variables: `DEVELOPMENT_TEAM_ID`, `RELEASE_APP_CLIENT_ID`.
- Secrets: `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `RELEASE_APP_PRIVATE_KEY`, `PRIVATE_SPARKLE_KEY`.
- Install the release GitHub App on both `power.notch` and `homebrew-tap`, with Contents write access, and grant Pull requests write access for the release PR in `power.notch`.
- Ensure `PRIVATE_SPARKLE_KEY` matches `SUPublicEDKey` in `powerNotch/Info.plist`. The private key is never committed to this repository.

The app reads the update feed directly from `https://raw.githubusercontent.com/Shaun-Z/power.notch/main/updater/appcast.xml`, so application updates do not require GitHub Pages. The checked-in feed starts empty; the release workflow adds the signed enclosure for the actual build. The current build workflow uses Apple Development signing and does not notarize the app; publishing does not change that signing policy.

## Acknowledgments

**powerNotch** would not exist without the amazing open-source projects and communities behind it:

- **[boringNotch](https://github.com/TheBoredTeam/boring.notch)** by **[TheBoredTeam](https://github.com/TheBoredTeam)** — The original project that powerNotch is forked from. If you love this app, please consider starring and supporting the upstream boringNotch project!
- **[lyrimuse](https://github.com/Yudaotor/lyrimuse)** by **[Yudaotor](https://github.com/Yudaotor)** and contributors — Reference for NetEase system playback identification, client data locations, local song metadata matching, and ID-first lyrics lookup (GPL-3.0). powerNotch reimplements this approach in Swift and continues to use MediaRemoteAdapter for playback. The referenced revision and source files are recorded in [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES).
- **[lycrics_notch](https://github.com/Dreammmmix/lycrics_notch)** — Inspiration and implementation reference for closed-notch real-time lyrics display.
- **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** — Enables Now Playing support on macOS 15.4+.
- **[NotchDrop](https://github.com/Lakr233/NotchDrop)** — Instrumental to the original Shelf feature in boringNotch.
- **[OpenCode](https://github.com/anomalyco/opencode)** by Anomaly and contributors, **[CodexBar](https://github.com/steipete/CodexBar)** by Peter Steinberger and contributors, and **[paseo-usage-monitor](https://github.com/ABorakati/paseo-usage-monitor)** by ABorakati and contributors — References for AI usage models, provider discovery, quota fetching, and local usage-history strategies.

Thanks also to the maintainers of our Swift package dependencies: [Defaults](https://github.com/sindresorhus/Defaults), [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin-Modern), [AsyncXPCConnection](https://github.com/ChimeHQ/AsyncXPCConnection), [Lottie](https://github.com/airbnb/lottie-spm), [MacroVisionKit](https://github.com/TheBoredTeam/MacroVisionKit), [Pow](https://github.com/EmergeTools/Pow), [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow), [Sparkle](https://github.com/sparkle-project/Sparkle), [Swift Collections](https://github.com/apple/swift-collections), [SwiftSyntax](https://github.com/swiftlang/swift-syntax), and [SwiftUI Introspect](https://github.com/siteline/swiftui-introspect).

Existing third-party notices, including those for Calendr, DynamicNotchKit, and Parrot, are retained in [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES). Each dependency remains subject to its own license and copyright notices.

## License

This project is licensed under the **GNU General Public License v3.0** — see [LICENSE](./LICENSE) for details.
