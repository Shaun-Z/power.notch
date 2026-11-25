import AppKit
import Combine
import Foundation

/// NetEase has no AppleScript dictionary. As in lyrimuse, live state/commands use
/// MediaRemote, while read-only client metadata supplies the exact song ID and cover.
@MainActor
final class NetEaseMusicController: MediaControllerProtocol {
    @Published private var playbackState = PlaybackState(
        bundleIdentifier: NetEaseMusicTrack.bundleIdentifier, title: "", artist: "", album: ""
    )
    private let source: NowPlayingController
    private var observationTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?
    private var enrichmentID = UUID()
    private var identity = ""

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    var supportsVolumeControl: Bool { false }
    var supportsFavorite: Bool { false }
    var supportsShuffleRepeat: Bool { false }

    init?() {
        guard let source = NowPlayingController() else { return nil }
        self.source = source
        observationTask = Task { [weak self, source] in
            for await state in source.playbackStatePublisher.values {
                guard !Task.isCancelled else { return }
                self?.receive(state)
            }
        }
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.updatePlaybackInfo()
            }
        }
    }

    deinit {
        observationTask?.cancel()
        livenessTask?.cancel()
        enrichmentTask?.cancel()
    }

    func isActive() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: NetEaseMusicTrack.bundleIdentifier).isEmpty
    }

    private var canControl: Bool {
        isActive() && source.playbackState.bundleIdentifier == NetEaseMusicTrack.bundleIdentifier
    }

    func play() async { if canControl { await source.play() } }
    func pause() async { if canControl { await source.pause() } }
    func togglePlay() async { if canControl { await source.togglePlay() } }
    func nextTrack() async { if canControl { await source.nextTrack() } }
    func previousTrack() async { if canControl { await source.previousTrack() } }
    func seek(to time: Double) async { if canControl, time.isFinite { await source.seek(to: max(0, time)) } }
    // These operations cannot be reliably read/set through NetEase's public interface.
    func setFavorite(_ favorite: Bool) async {}
    func setVolume(_ level: Double) async {}
    func toggleShuffle() async {}
    func toggleRepeat() async {}

    func updatePlaybackInfo() async {
        receive(source.playbackState)
    }

    private func receive(_ state: PlaybackState) {
        guard isActive(), state.bundleIdentifier == NetEaseMusicTrack.bundleIdentifier, !state.title.isEmpty else {
            enrichmentTask?.cancel()
            enrichmentTask = nil
            enrichmentID = UUID()
            identity = ""
            if playbackState.isPlaying || !playbackState.title.isEmpty {
                playbackState = PlaybackState(bundleIdentifier: NetEaseMusicTrack.bundleIdentifier, title: "", artist: "", album: "")
            }
            return
        }
        let key = "\(state.title)|\(state.artist)|\(state.album)|\(state.duration)"
        let changed = key != identity
        var updated = state
        if !changed, updated.artwork == nil { updated.artwork = playbackState.artwork }
        playbackState = updated
        guard changed || (updated.artwork == nil && enrichmentTask == nil) else { return }
        identity = key
        enrichmentTask?.cancel()
        let requestID = UUID()
        enrichmentID = requestID
        enrichmentTask = Task { [weak self] in
            let track = await NetEaseMusicLibrary.shared.track(title: state.title, artist: state.artist, album: state.album, duration: state.duration)
            guard !Task.isCancelled else { return }
            var artwork: Data?
            if state.artwork == nil, let url = track?.artworkURL {
                artwork = try? await ImageService.shared.fetchImageData(from: url)
            }
            guard !Task.isCancelled, let self, self.enrichmentID == requestID, self.identity == key else { return }
            self.enrichmentTask = nil
            if self.playbackState.artwork == nil, let artwork {
                self.playbackState.artwork = artwork
            }
        }
    }
}
