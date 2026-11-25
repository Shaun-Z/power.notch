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
> **powerNotch** is an independent fork of **[boringNotch](https://github.com/TheBoredTeam/boring.notch)** ([TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)). Full credit goes to TheBoredTeam and all boringNotch contributors for creating the original project and architecture. NetEase Cloud Music support also draws on [lyrimuse](https://github.com/Yudaotor/lyrimuse); powerNotch does not include all lyrimuse features.

Say hello to **powerNotch** — turning your Mac's notch or Dynamic Island into a music control center with real-time lyrics, calendar and reminders integration, a file shelf with AirDrop support, a mirror/webcam view, and replacements for volume and brightness HUDs.

## Features

- **Music Live Activity & Visualizer** — Dynamic playback controls and audio visualizer right in the notch (Apple Music, Spotify, YouTube Music, and system Now Playing).
- **NetEase Cloud Music** — Playback controls, track information, artwork, and synchronized lyrics for the native macOS client (experimental).
- **Closed-Notch Real-Time Lyrics** — Displays synchronized lyrics below the closed notch on notched screens, or inside the collapsed Dynamic Island on other screens, with multi-source fallback (LRCLIB, NetEase, LewdHuTao, lyrics.ovh), adapted from [lycrics_notch](https://github.com/Dreammmmix/lycrics_notch).
- **Calendar & Reminders Integration** — Quick overview of upcoming events and reminders.
- **File Shelf with AirDrop Support** — Drag and drop files into the notch for temporary holding and quick sharing.
- **System HUD Replacements** — Sleek inline notch HUDs for volume, display brightness, and keyboard backlight.
- **Battery & Charging Indicator** — Live charging status and percentage indicator.
- **Mirror (Webcam)** — Quick camera preview directly from the notch.
- **Customizable Gestures & Sizing** — Fine-tune notch dimensions and interactions for different display sizes.
- **Liquid Glass & Dynamic Island** — Per-display Notch/Dynamic Island modes, Follow system/Light/Dark/Custom glass colors, and an app-specific opacity control. Native Liquid Glass requires macOS 26 or later; earlier versions use a blur material fallback.
- **Physical Notch Blending** — A black collapsed surface and soft shading blend the expanded glass card into your Mac's physical notch.
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
> The app has not been notarized by Apple. After moving the app to `/Applications` and attempting to open it, you may need to open **System Settings → Privacy & Security** and choose **Open Anyway**. Homebrew installs the same app and does not remove this first-launch requirement.
>
> Desktop widget data is unavailable in the current downloadable builds. AI usage monitoring inside the app remains available.

### Option 2: Homebrew

Install from [Shaun-Z/homebrew-tap](https://github.com/Shaun-Z/homebrew-tap):

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

In **Settings → Media → Music Source**, choose **NetEase Cloud Music**, then play a track in the native macOS NetEase client. You can view track information, artwork, and lyrics, and use play/pause, previous/next, and seeking controls. Enable lyrics in Settings if they are not visible.

Keep NetEase as the active system media player. When another app takes over playback, the dedicated NetEase source stops controlling playback. Local track lookup may be unavailable under some macOS privacy settings; track information can still appear, and lyrics may fall back to another provider.

Favorite, app volume, shuffle, and repeat controls are unavailable for this source. The integration is experimental and supports the native macOS client, not the iPad app or browser player.

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

Hover over or click the notch to expand it. Use **Developer options → Animation speed** to adjust how quickly it opens and closes.

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
