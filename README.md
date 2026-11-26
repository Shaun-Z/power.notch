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
- **AI Usage & Desktop Widgets** — Optional monitoring for OpenAI Codex, Claude Code, Antigravity, GitHub Copilot, Cursor, OpenCode, Xiaomi MiMo, OpenRouter, DeepSeek, z.ai/GLM, and Kimi/Moonshot: session and weekly limits as concentric rings, a monthly credit allowance as its own ring, top-up balances as plain amounts, one reading pinnable beside the closed notch, and desktop widgets with a 24-hour / 7-day / 30-day trend for tokens, spend, or requests. Readings depend on the provider, credentials, and local history; the notch tab is disabled by default.
- **Developer Options** — Unlock animation speed controls and per-display Dynamic Island position and height adjustments by clicking the version number five times in About.

## Installation

**System Requirements:**

- macOS **15 Sequoia** or later
- Apple Silicon or Intel Mac
- macOS **26 or later** for native Liquid Glass

### Option 1: Homebrew (recommended)

```bash
brew install --cask Shaun-Z/tap/power-notch
```

The cask comes from [Shaun-Z/homebrew-tap](https://github.com/Shaun-Z/homebrew-tap). It installs **powerNotch.app** into `/Applications` and then removes the quarantine attribute from the installed copy (`xattr -dr com.apple.quarantine`).

> [!IMPORTANT]
> That postflight step clears the `com.apple.quarantine` flag, so macOS **skips its normal first-launch check** and the app starts without an "Open Anyway" step. This is a convenience, not a security guarantee: it does **not** mean powerNotch has been notarized, signed by a Developer ID, or vetted by Apple. The app is distributed ad-hoc signed, exactly as described below, and you remain the one deciding whether to trust it.
>
> If you would rather keep the standard first-launch check, use Option 2 instead — Homebrew only removes quarantine for copies it installs itself.

### Option 2: Download from Releases

Download the latest `.dmg` from the [Releases](https://github.com/Shaun-Z/power.notch/releases) page, open it, and drag **powerNotch.app** into `/Applications`.

> [!IMPORTANT]
> The app has not been notarized by Apple, and the DMG download keeps the quarantine attribute. The first launch therefore needs **System Settings → Privacy & Security → Open Anyway** (or, if you prefer the command line, `xattr -dr com.apple.quarantine /Applications/powerNotch.app`).
>
> Version **0.1.1** adds a read-only snapshot fallback for desktop widgets in ad-hoc builds. Version 0.1.0 does not support widget data sharing; AI usage monitoring inside that app remains available.

## Usage

- Launch **powerNotch** to activate the notch experience.
- Hover over or click the notch to expand controls, calendar, and shelf.
- Use the menu bar icon to open Settings and customize appearance, media controllers, lyrics, HUDs, and gestures.

### AI Usage

Open **Settings → AI Usage** and enable the providers you use. Credentials are read from the CLIs already signed in on your Mac (`~/.codex`, `~/.claude`, `~/.gemini`, `~/.local/share/opencode`, Cursor's session, or a GitHub Copilot device login), or from a key you paste in Settings. External Keychain reads (Claude Code) are off by default and only happen on a manual refresh.

- Session and weekly limits render as concentric rings. A credit allowance that states a monthly ceiling — an education or workspace Codex account, for example — renders as its own ring next to them, while an uncapped prepaid balance or a pay-as-you-go wallet stays a plain amount.
- Click a ring, or a balance badge, to pin that reading beside the closed notch. The AI Usage tab in the expanded notch is off by default; enable it in Settings.
- Desktop widgets offer small, medium, and large layouts with per-provider pages. The large layout adds a **24-hour / 7-day / 30-day** trend for tokens, spend, or requests.
- Spend follows the account's own currency. A history that mixes currencies is converted with cached daily USD rates, and real wallet movement is preferred to the log-based estimate for the same day.
- History is only as complete as what the Mac can see: provider APIs report current quotas, while daily spend comes from local CLI logs and from balance changes observed while the app runs. Days before first use, or while powerNotch was closed, stay empty rather than being estimated.

### Desktop widgets in ad-hoc builds

The app and widget prefer the team-prefixed App Group when configured. Builds signed by `.github/scripts/sign_adhoc.py` remove the provisioned group and share a snapshot at `~/Library/Application Support/powerNotch/widget/ai-usage-widget-state.json` instead. Only the app writes this file; the sandboxed widget has a read-only exception for that specific directory. It contains display data, never API keys or OAuth tokens. The directory is created with owner-only access.

Provider-page, chart-metric, and trend-range selections use the widget's own preferences when no App Group is configured. The last snapshot remains readable after the app quits; fetching new usage with the refresh button requires the app to be running. No local HTTP server is used.

Ad-hoc signing and file access do not guarantee WidgetKit registration, rendering, or AppIntent button delivery on every macOS release. Those behaviors need testing with the installed distribution build; upgrades may require re-adding the widget. Version 0.1.0 retains the data-sharing limitation noted above.

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

### Published build numbers

GitHub assigns each published build a number above both the project setting and previously distributed builds. After a successful stable release, the workflow saves the actual shipped version and build number back to `main` and `dev`. Beta releases update `dev` only; nightly releases save their actual number to `dev` with the nightly appcast. Pull the updated branch to use those numbers in local Xcode builds.

Synchronization changes only version settings, never increments the shipped number again, and preserves newer development versions/build numbers. Concurrent branch changes are retained; a rejected stable/beta push is retried on the latest head without force. If synchronization fails after publication, rerun the failed job rather than publishing the same release again.


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
