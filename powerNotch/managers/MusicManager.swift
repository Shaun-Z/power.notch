//
//  MusicManager.swift
//  powerNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    private var lyricsFetchTask: Task<Void, Never>?
    private var appleMusicCacheRetryTask: Task<Void, Never>?
    private var lastLyricsTrackKey: String = ""
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // Fetch or clear lyrics immediately when the lyrics setting is toggled mid-track
        Defaults.publisher(.enableLyrics, options: [])
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isEnabled {
                        let hasLoadedTrack = !self.songTitle.isEmpty
                            && (self.bundleIdentifier != nil || self.isPlaying || self.songDuration > 0)
                        guard hasLoadedTrack else { return }
                        if self.syncedLyrics.isEmpty && self.currentLyrics.isEmpty && !self.isFetchingLyrics {
                            self.fetchLyricsIfAvailable(
                                bundleIdentifier: self.bundleIdentifier,
                                title: self.songTitle,
                                artist: self.artistName,
                                album: self.album,
                                duration: self.songDuration
                            )
                        }
                    } else {
                        self.lyricsFetchTask?.cancel()
                        self.lyricsFetchTask = nil
                        self.appleMusicCacheRetryTask?.cancel()
                        self.appleMusicCacheRetryTask = nil
                        self.isFetchingLyrics = false
                        self.currentLyrics = ""
                        self.syncedLyrics = []
                        self.lastLyricsTrackKey = ""
                    }
                }
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        lyricsFetchTask?.cancel()
        appleMusicCacheRetryTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
                if self.syncedLyrics.isEmpty && self.currentLyrics.isEmpty {
                    self.fetchLyricsIfAvailable(
                        bundleIdentifier: state.bundleIdentifier,
                        title: state.title,
                        artist: state.artist,
                        album: state.album,
                        duration: state.duration
                    )
                }
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let trackMetadataChanged = titleChanged || artistChanged || albumChanged || bundleChanged
        let hasContentChange = trackMetadataChanged || artworkChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            if artworkChanged || state.artwork == nil {
                // Update last artwork change values
                self.lastArtworkTitle = state.title
                self.lastArtworkArtist = state.artist
                self.lastArtworkAlbum = state.album
                self.lastArtworkBundleIdentifier = state.bundleIdentifier
            }

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

            // Fetch lyrics on track metadata change (avoid restarting fetch on artwork-only updates)
            if trackMetadataChanged || (self.syncedLyrics.isEmpty && self.currentLyrics.isEmpty && !self.isFetchingLyrics) {
                self.fetchLyricsIfAvailable(
                    bundleIdentifier: state.bundleIdentifier,
                    title: state.title,
                    artist: state.artist,
                    album: state.album,
                    duration: state.duration
                )
            }
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics

    private struct LyricFetchResult {
        let plainText: String
        let synced: [(time: Double, text: String)]
    }

    @MainActor
    private func fetchLyricsIfAvailable(
        bundleIdentifier: String?,
        title: String,
        artist: String,
        album: String = "",
        duration: TimeInterval = 0
    ) {
        // Cancel any in-flight lyrics fetch or delayed cache upgrade to prevent race conditions
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        appleMusicCacheRetryTask?.cancel()
        appleMusicCacheRetryTask = nil

        guard Defaults[.enableLyrics], !title.isEmpty else {
            self.isFetchingLyrics = false
            self.currentLyrics = ""
            self.syncedLyrics = []
            self.lastLyricsTrackKey = ""
            return
        }

        let trackKey = "\(bundleIdentifier ?? "")|\(title)|\(artist)|\(album)|\(Int(duration.rounded()))"
        let isAppleMusic = bundleIdentifier?.contains("com.apple.Music") == true

        self.lastLyricsTrackKey = trackKey
        self.isFetchingLyrics = true
        self.currentLyrics = ""
        self.syncedLyrics = []

        lyricsFetchTask = Task { @MainActor in

            // Layer 1: Apple Music local TTML cache (zero-config, exact official timing)
            if isAppleMusic {
                if let ttml = await XPCHelperClient.shared.fetchAppleMusicCachedTTML(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                ), !Task.isCancelled, self.lastLyricsTrackKey == trackKey {
                    let parsed = self.parseAppleMusicTTML(ttml)
                    if !parsed.isEmpty {
                        self.syncedLyrics = parsed
                        self.currentLyrics = parsed.map(\.text).joined(separator: "\n")
                        self.isFetchingLyrics = false
                        return
                    }
                }
            }

            if Task.isCancelled || self.lastLyricsTrackKey != trackKey { return }

            // Layer 2: Multi-source scored web lookup + offline AppleScript fallback
            await self.fetchLyricsFromWeb(
                isAppleMusic: isAppleMusic,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                trackKey: trackKey
            )

            // If Apple Music didn't have the track in Cache.db yet (brand new play),
            // check Cache.db shortly after playback starts to upgrade seamlessly to official TTML.
            if isAppleMusic, !Task.isCancelled, self.lastLyricsTrackKey == trackKey {
                self.scheduleAppleMusicCacheUpgrade(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    trackKey: trackKey
                )
            }
        }
    }

    @MainActor
    private func scheduleAppleMusicCacheUpgrade(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        trackKey: String
    ) {
        appleMusicCacheRetryTask?.cancel()
        appleMusicCacheRetryTask = Task { @MainActor in
            let delays: [Duration] = [.milliseconds(2500), .milliseconds(3500)]
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, self.lastLyricsTrackKey == trackKey else { return }

                if let ttml = await XPCHelperClient.shared.fetchAppleMusicCachedTTML(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                ) {
                    guard !Task.isCancelled, self.lastLyricsTrackKey == trackKey else { return }
                    let parsed = self.parseAppleMusicTTML(ttml)
                    if !parsed.isEmpty {
                        self.syncedLyrics = parsed
                        self.currentLyrics = parsed.map(\.text).joined(separator: "\n")
                        self.isFetchingLyrics = false
                        return
                    }
                }

                // If we already have synced web lyrics, one retry is enough
                if !self.syncedLyrics.isEmpty {
                    return
                }
            }
        }
    }

    private func fetchAppleScriptEmbeddedLyrics() async -> String? {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return nil }

        let script = """
        tell application "Music"
            if it is running then
                if player state is playing or player state is paused then
                    try
                        set l to lyrics of current track
                        if l is missing value then
                            return ""
                        else
                            return l
                        end if
                    on error
                        return ""
                    end try
                else
                    return ""
                end if
            else
                return ""
            end if
        end tell
        """
        guard let result = try? await AppleScriptHelper.execute(script),
              let lyricsString = result.stringValue else { return nil }
        let trimmed = lyricsString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toSimplifiedChinese(_ string: String) -> String {
        string.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? string
    }

    /// Canonical key for fuzzy comparison across Traditional/Simplified Chinese and punctuation
    private func matchKey(_ string: String) -> String {
        let simplified = toSimplifiedChinese(string)
        let folded = simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private func containsCJK(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    /// Strip half-width & full-width parenthetical suffixes, feat., etc. for better search matching
    private func cleanTrackTitle(_ title: String) -> String {
        var cleaned = title
        // Remove (...), [...], {...}, （...）, 【...】, 「...」
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*[\(\[\{（【「][^\)\]\}）】」]*[\)\]\}）】」]"#,
            with: "",
            options: .regularExpression
        )
        // Remove "feat."/"ft." and everything after
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*[-–—]\s*(feat\.?|ft\.?)\s+.*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove trailing " - xxx" suffixes like " - Remix", " - Live", " - Acoustic"
        cleaned = cleaned.replacingOccurrences(
            of: #"\s*[-–—]\s*(Remix|Live|Acoustic|Radio Edit|Remaster(ed)?|Deluxe|Single Version|Album Version|Instrumental).*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func primaryArtistName(_ artist: String) -> String {
        let separators = [" & ", ", ", " feat. ", " ft. ", " feat ", " x ", " / ", "、"]
        var result = artist
        for sep in separators {
            if let range = result.range(of: sep, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func applyLyricsResult(_ result: LyricFetchResult, trackKey: String) {
        guard !Task.isCancelled, self.lastLyricsTrackKey == trackKey else { return }
        self.syncedLyrics = result.synced
        self.currentLyrics = result.plainText
        self.isFetchingLyrics = false
    }

    @MainActor
    private func fetchLyricsFromWeb(
        isAppleMusic: Bool,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        trackKey: String
    ) async {
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)
        let cleanAlbum = normalizedQuery(album)
        let strippedTitle = cleanTrackTitle(cleanTitle)
        let effectiveTitle = strippedTitle.isEmpty ? cleanTitle : strippedTitle
        var bestPlainFallback: String?

        // 1) LRCLIB exact match (/api/get with duration + album)
        if Task.isCancelled { return }
        if let exact = await fetchLRCLIBExact(
            title: cleanTitle,
            artist: cleanArtist,
            album: cleanAlbum,
            duration: duration
        ) {
            if !exact.synced.isEmpty {
                applyLyricsResult(exact, trackKey: trackKey)
                return
            }
            if bestPlainFallback == nil, !exact.plainText.isEmpty {
                bestPlainFallback = exact.plainText
            }
        }

        // 2) LRCLIB scored search (original title, then stripped title)
        if Task.isCancelled { return }
        if let scored = await fetchLRCLIBScoredSearch(
            title: cleanTitle,
            artist: cleanArtist,
            album: cleanAlbum,
            duration: duration
        ) {
            if !scored.synced.isEmpty {
                applyLyricsResult(scored, trackKey: trackKey)
                return
            }
            if bestPlainFallback == nil, !scored.plainText.isEmpty {
                bestPlainFallback = scored.plainText
            }
        }

        if effectiveTitle != cleanTitle {
            if Task.isCancelled { return }
            if let scoredStripped = await fetchLRCLIBScoredSearch(
                title: effectiveTitle,
                artist: cleanArtist,
                album: cleanAlbum,
                duration: duration
            ) {
                if !scoredStripped.synced.isEmpty {
                    applyLyricsResult(scoredStripped, trackKey: trackKey)
                    return
                }
                if bestPlainFallback == nil, !scoredStripped.plainText.isEmpty {
                    bestPlainFallback = scoredStripped.plainText
                }
            }
        }

        // 3) NetEase Cloud Music scored search (Simplified Chinese + duration-gated title-only bridge
        //    for Apple Music US storefront pairs like "心牆 | JJ Lin" or "遇見 | Yanzi Sun")
        if Task.isCancelled { return }
        if let netEase = await fetchNetEaseScored(
            title: effectiveTitle,
            rawTitle: cleanTitle,
            artist: cleanArtist,
            duration: duration
        ) {
            if !netEase.synced.isEmpty {
                applyLyricsResult(netEase, trackKey: trackKey)
                return
            }
            if bestPlainFallback == nil, !netEase.plainText.isEmpty {
                bestPlainFallback = netEase.plainText
            }
        }

        // 4) Plain-text fallbacks (only if NO synced source succeeded)
        if isAppleMusic {
            if Task.isCancelled { return }
            if let embedded = await fetchAppleScriptEmbeddedLyrics() {
                let parsed = parseLRC(embedded)
                applyLyricsResult(
                    LyricFetchResult(
                        plainText: parsed.isEmpty ? embedded : parsed.map(\.text).joined(separator: "\n"),
                        synced: parsed
                    ),
                    trackKey: trackKey
                )
                return
            }
        }

        if let plain = bestPlainFallback, !plain.isEmpty {
            applyLyricsResult(LyricFetchResult(plainText: plain, synced: []), trackKey: trackKey)
            return
        }

        // 5) LewdHuTao lyrics-api (Musixmatch, then YouTube Music — plain text)
        if Task.isCancelled { return }
        if let mm = await fetchLewdHuTaoAPI(title: effectiveTitle, artist: cleanArtist, source: "musixmatch") {
            applyLyricsResult(LyricFetchResult(plainText: mm, synced: []), trackKey: trackKey)
            return
        }

        if Task.isCancelled { return }
        if let yt = await fetchLewdHuTaoAPI(title: effectiveTitle, artist: cleanArtist, source: "youtube") {
            applyLyricsResult(LyricFetchResult(plainText: yt, synced: []), trackKey: trackKey)
            return
        }

        // 6) lyrics.ovh (plain text)
        if Task.isCancelled { return }
        if let ovh = await fetchLyricsOvh(title: effectiveTitle, artist: cleanArtist) {
            applyLyricsResult(LyricFetchResult(plainText: ovh, synced: []), trackKey: trackKey)
            return
        }

        // All sources exhausted
        guard !Task.isCancelled, self.lastLyricsTrackKey == trackKey else { return }
        self.currentLyrics = ""
        self.isFetchingLyrics = false
        self.syncedLyrics = []
    }

    // MARK: - LRCLIB source

    private func fetchLRCLIBExact(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async -> LyricFetchResult? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/get")
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return extractLRCLIBResult(from: json)
        } catch {
            return nil
        }
    }

    private func fetchLRCLIBScoredSearch(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) async -> LyricFetchResult? {
        guard !title.isEmpty else { return nil }
        var components = URLComponents(string: "https://lrclib.net/api/search")
        var queryItems = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty {
            queryItems.append(URLQueryItem(name: "artist_name", value: artist))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !jsonArray.isEmpty else { return nil }

            let targetTitleKey = matchKey(cleanTrackTitle(title))
            let targetRawTitleKey = matchKey(title)
            let targetArtistKey = matchKey(primaryArtistName(artist))
            let targetAlbumKey = matchKey(album)

            var bestScore = -1000
            var bestCandidate: LyricFetchResult?

            for item in jsonArray {
                guard let parsed = extractLRCLIBResult(from: item) else { continue }
                let candName = item["trackName"] as? String ?? ""
                let candArtist = item["artistName"] as? String ?? ""
                let candAlbum = item["albumName"] as? String ?? ""
                let candDuration = item["duration"] as? Double ?? 0

                let candTitleKey = matchKey(cleanTrackTitle(candName))
                let candRawTitleKey = matchKey(candName)
                let candArtistKey = matchKey(primaryArtistName(candArtist))
                let candAlbumKey = matchKey(candAlbum)

                var score = 0
                if !parsed.synced.isEmpty { score += 35 }

                // Title match
                if !targetRawTitleKey.isEmpty && (candRawTitleKey == targetRawTitleKey || candTitleKey == targetTitleKey) {
                    score += 45
                } else if !targetTitleKey.isEmpty && (candTitleKey.contains(targetTitleKey) || targetTitleKey.contains(candTitleKey)) {
                    score += 20
                } else {
                    score -= 35
                }

                // Artist match
                if !targetArtistKey.isEmpty {
                    if candArtistKey == targetArtistKey {
                        score += 35
                    } else if candArtistKey.contains(targetArtistKey) || targetArtistKey.contains(candArtistKey) {
                        score += 20
                    } else {
                        score -= 15
                    }
                }

                // Album bonus
                if !targetAlbumKey.isEmpty && !candAlbumKey.isEmpty &&
                    (candAlbumKey == targetAlbumKey || candAlbumKey.contains(targetAlbumKey) || targetAlbumKey.contains(candAlbumKey)) {
                    score += 10
                }

                // Duration proximity
                if duration > 0 && candDuration > 0 {
                    let diff = abs(candDuration - duration)
                    if diff <= 2.0 {
                        score += 35
                    } else if diff <= 5.0 {
                        score += 20
                    } else if diff <= 10.0 {
                        score += 5
                    } else if diff > 20.0 {
                        score -= 40
                    }
                }

                if score > bestScore {
                    bestScore = score
                    bestCandidate = parsed
                }
            }

            guard bestScore >= 45 else { return nil }
            return bestCandidate
        } catch {
            return nil
        }
    }

    private func extractLRCLIBResult(from json: [String: Any]) -> LyricFetchResult? {
        if let instrumental = json["instrumental"] as? Bool, instrumental {
            return nil
        }
        let plain = (json["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let syncedRaw = (json["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !plain.isEmpty || !syncedRaw.isEmpty else { return nil }
        let synced = syncedRaw.isEmpty ? [] : parseLRC(syncedRaw)
        let resolvedPlain = !plain.isEmpty ? plain : synced.map(\.text).joined(separator: "\n")
        return LyricFetchResult(plainText: resolvedPlain, synced: synced)
    }

    // MARK: - NetEase Cloud Music (scored search + CJK/US-storefront duration bridge)

    private func fetchNetEaseScored(
        title: String,
        rawTitle: String,
        artist: String,
        duration: TimeInterval
    ) async -> LyricFetchResult? {
        let simpTitle = toSimplifiedChinese(title)
        let simpArtist = toSimplifiedChinese(primaryArtistName(artist))

        // Pass 1: Title + Artist query
        var candidateIDs: [Int] = []
        if !simpArtist.isEmpty {
            let query = "\(simpTitle) \(simpArtist)"
            candidateIDs = await searchNetEaseSongIDs(
                query: query,
                targetTitle: simpTitle,
                rawTitle: toSimplifiedChinese(rawTitle),
                targetArtist: simpArtist,
                duration: duration,
                requireTightDurationOnly: false
            )
        }

        for songID in candidateIDs.prefix(2) {
            if Task.isCancelled { return nil }
            if let result = await fetchNetEaseLyricByID(songID), !result.synced.isEmpty {
                return result
            }
        }

        // Pass 2: Title-only Simplified Chinese query strictly gated on exact title + tight duration (<= 3.5s)
        // Bridges Apple Music US storefront metadata like "心牆 | JJ Lin" -> "心墙 | 林俊杰".
        let needsTitleOnlyBridge = containsCJK(simpTitle) || simpArtist.isEmpty
        if needsTitleOnlyBridge {
            let bridgeIDs = await searchNetEaseSongIDs(
                query: simpTitle,
                targetTitle: simpTitle,
                rawTitle: toSimplifiedChinese(rawTitle),
                targetArtist: simpArtist,
                duration: duration,
                requireTightDurationOnly: true
            )
            for songID in bridgeIDs.prefix(2) where !candidateIDs.contains(songID) {
                if Task.isCancelled { return nil }
                if let result = await fetchNetEaseLyricByID(songID), !result.synced.isEmpty {
                    return result
                }
            }
        }

        // Fallback: if Pass 1 had a plain-text-only match, return it
        if let firstID = candidateIDs.first {
            return await fetchNetEaseLyricByID(firstID)
        }
        return nil
    }

    private func searchNetEaseSongIDs(
        query: String,
        targetTitle: String,
        rawTitle: String,
        targetArtist: String,
        duration: TimeInterval,
        requireTightDurationOnly: Bool
    ) async -> [Int] {
        var components = URLComponents(string: "https://music.163.com/api/search/get")
        components?.queryItems = [
            URLQueryItem(name: "s", value: query),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components?.url else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  !songs.isEmpty else { return [] }

            let targetTitleKey = matchKey(targetTitle)
            let targetRawKey = matchKey(rawTitle)
            let targetArtistKey = matchKey(targetArtist)

            var scored: [(id: Int, score: Int)] = []

            for song in songs {
                guard let songID = song["id"] as? Int, songID > 0 else { continue }
                let candName = song["name"] as? String ?? ""
                let candCleanKey = matchKey(cleanTrackTitle(candName))
                let candRawKey = matchKey(candName)

                let artists = song["artists"] as? [[String: Any]] ?? []
                let candArtistKeys = artists.compactMap { ($0["name"] as? String).map(matchKey) }

                let candDurationSec: Double
                if let durMs = song["duration"] as? Double {
                    candDurationSec = durMs / 1000.0
                } else if let durMs = song["duration"] as? Int {
                    candDurationSec = Double(durMs) / 1000.0
                } else {
                    candDurationSec = 0
                }

                let titleExact = (!targetTitleKey.isEmpty && (candCleanKey == targetTitleKey || candRawKey == targetTitleKey || candRawKey == targetRawKey))
                let titleContains = !titleExact && !targetTitleKey.isEmpty && (candCleanKey.contains(targetTitleKey) || targetTitleKey.contains(candCleanKey))
                let artistMatches = !targetArtistKey.isEmpty && candArtistKeys.contains {
                    $0 == targetArtistKey || $0.contains(targetArtistKey) || targetArtistKey.contains($0)
                }

                if requireTightDurationOnly {
                    // Must match title accurately AND match duration tightly (within 3.5s)
                    guard titleExact else { continue }
                    if duration > 0 {
                        guard candDurationSec > 0, abs(candDurationSec - duration) <= 3.5 else { continue }
                    } else {
                        guard artistMatches else { continue }
                    }
                }

                var score = 0
                if titleExact {
                    score += 50
                } else if titleContains {
                    score += 20
                } else {
                    score -= 40
                }

                if artistMatches {
                    score += 40
                } else if !requireTightDurationOnly && !targetArtistKey.isEmpty {
                    score -= 10
                }

                if duration > 0 && candDurationSec > 0 {
                    let diff = abs(candDurationSec - duration)
                    if diff <= 1.5 {
                        score += 45
                    } else if diff <= 3.5 {
                        score += 30
                    } else if diff <= 7.0 {
                        score += 10
                    } else if diff > 15.0 {
                        score -= 45
                    }
                }

                if score >= 50 {
                    scored.append((songID, score))
                }
            }

            return scored.sorted { $0.score > $1.score }.map(\.id)
        } catch {
            return []
        }
    }

    private func fetchNetEaseLyricByID(_ songID: Int) async -> LyricFetchResult? {
        var components = URLComponents(string: "https://music.163.com/api/song/lyric")
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "lv", value: "1"),
        ]
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lrcObj = json["lrc"] as? [String: Any],
                  let lrcString = lrcObj["lyric"] as? String else { return nil }

            let trimmed = lrcString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.contains("纯音乐，请欣赏") || trimmed.contains("純音樂，請欣賞") {
                return nil
            }

            let parsed = parseLRC(trimmed)
            if !parsed.isEmpty {
                return LyricFetchResult(
                    plainText: parsed.map(\.text).joined(separator: "\n"),
                    synced: parsed
                )
            }

            let plainLines = trimmed.components(separatedBy: .newlines).filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty
                    && !t.hasPrefix("作词") && !t.hasPrefix("作曲")
                    && !t.hasPrefix("编曲") && !t.hasPrefix("制作")
            }
            guard !plainLines.isEmpty else { return nil }
            return LyricFetchResult(plainText: plainLines.joined(separator: "\n"), synced: [])
        } catch {
            return nil
        }
    }

    // MARK: - LewdHuTao lyrics-api (Musixmatch + YouTube Music aggregator, plain text)

    private func fetchLewdHuTaoAPI(title: String, artist: String, source: String) async -> String? {
        var components = URLComponents(string: "https://lyrics.lewdhutao.my.eu.org/v2/\(source)/lyrics")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist),
        ]
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let lyrics = dataObj["lyrics"] as? String else { return nil }

            let trimmed = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    // MARK: - lyrics.ovh fallback (plain lyrics only)

    private func fetchLyricsOvh(title: String, artist: String) async -> String? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)")
        else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lyrics = json["lyrics"] as? String else { return nil }

            let trimmed = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    // MARK: - Synced lyrics parsers (Apple Music TTML & Enhanced/Multi-tag LRC)

    private func parseAppleMusicTTML(_ ttml: String) -> [(time: Double, text: String)] {
        guard let data = ttml.data(using: .utf8) else { return [] }
        let delegate = AppleMusicTTMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.lines.sorted { $0.time < $1.time }
    }

    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        guard let tagRegex = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#),
              let offsetRegex = try? NSRegularExpression(pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#, options: .caseInsensitive),
              let inlineTagRegex = try? NSRegularExpression(pattern: #"<\d{1,3}:\d{2}(?:[\.:]\d{1,3})?>"#)
        else { return [] }

        var offsetSeconds: Double = 0
        var entries: [(time: Double, text: String)] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            if let offsetMatch = offsetRegex.firstMatch(in: line, range: fullRange),
               let ms = Double(nsLine.substring(with: offsetMatch.range(at: 1))) {
                // Standard LRC spec: positive offset shifts lyrics earlier
                offsetSeconds = ms / 1000.0
                continue
            }

            let matches = tagRegex.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }

            // Remove all [mm:ss.xx] tags and inline <mm:ss.xx> enhanced tags to obtain clean lyric text
            let withoutTags = tagRegex.stringByReplacingMatches(in: line, range: fullRange, withTemplate: "")
            let withoutInline = inlineTagRegex.stringByReplacingMatches(
                in: withoutTags,
                range: NSRange(location: 0, length: (withoutTags as NSString).length),
                withTemplate: ""
            )
            let text = withoutInline.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                let fracRange = match.range(at: 3)
                let fracStr = fracRange.location != NSNotFound ? nsLine.substring(with: fracRange) : ""

                let minutes = Double(minStr) ?? 0
                let seconds = Double(secStr) ?? 0
                let fraction: Double
                if !fracStr.isEmpty, let fracVal = Double(fracStr) {
                    fraction = fracVal / pow(10.0, Double(fracStr.count))
                } else {
                    fraction = 0
                }
                let rawTime = minutes * 60.0 + seconds + fraction
                entries.append((time: rawTime, text: text))
            }
        }

        if offsetSeconds != 0 {
            entries = entries.map { (time: max(0, $0.time - offsetSeconds), text: $0.text) }
        }
        return entries.sorted { $0.time < $1.time }
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        // Don't show the first lyric prematurely during an instrumental intro
        if elapsed < syncedLyrics[0].time {
            return ""
        }
        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return syncedLyrics[idx].text
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram]
                || Defaults[.liquidGlassNotch]
                || Defaults[.playerColorTinting]
                || Defaults[.enableAIUsageNotchTab]
            {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
// MARK: - Apple Music TTML Parser

private final class AppleMusicTTMLParserDelegate: NSObject, XMLParserDelegate {
    private(set) var lines: [(time: Double, text: String)] = []

    private var inBody = false
    private var inParagraph = false
    private var ignoredDepth = 0
    private var currentBeginTime: Double?
    private var currentBuffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()

        if localName == "body" {
            inBody = true
            return
        }
        guard inBody else { return }

        if localName == "p" {
            inParagraph = true
            ignoredDepth = 0
            currentBuffer = ""
            currentBeginTime = Self.parseTimestamp(attributeDict["begin"])
            return
        }

        guard inParagraph else { return }

        if ignoredDepth > 0 {
            ignoredDepth += 1
            return
        }

        let role = (attributeDict["ttm:role"] ?? attributeDict["role"] ?? "").lowercased()
        if role == "x-bg" || role == "x-roman" || role == "x-translation" {
            ignoredDepth = 1
            return
        }

        if localName == "br" {
            currentBuffer.append(" ")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inBody, inParagraph, ignoredDepth == 0 else { return }
        currentBuffer.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let localName = elementName.components(separatedBy: ":").last?.lowercased() ?? elementName.lowercased()

        if localName == "body" {
            inBody = false
            return
        }
        guard inBody else { return }

        if localName == "p" {
            if let begin = currentBeginTime {
                let collapsed = currentBuffer
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !collapsed.isEmpty {
                    lines.append((time: begin, text: collapsed))
                }
            }
            inParagraph = false
            ignoredDepth = 0
            currentBeginTime = nil
            currentBuffer = ""
            return
        }

        if inParagraph, ignoredDepth > 0 {
            ignoredDepth -= 1
        }
    }

    private static func parseTimestamp(_ raw: String?) -> Double? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if value.hasSuffix("ms") {
            value.removeLast(2)
            return Double(value).map { $0 / 1000.0 }
        }
        if value.hasSuffix("s") {
            value.removeLast(1)
            return Double(value)
        }

        let parts = value.split(separator: ":")
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60.0 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600.0 + m * 60.0 + s
        default:
            return nil
        }
    }
}


