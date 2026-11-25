import Foundation
import SQLite3
import Testing
@testable import MediaCore

struct NetEaseMusicTests {
    private func json(id: Any = "123", album: String = "Album", duration: Int = 180_000) -> [String: Any] {
        ["id": id, "name": "Song", "artists": [["name": "Artist"]],
         "album": ["name": album, "picUrl": "http://p1.music.126.net/cover.jpg"], "duration": duration]
    }

    @Test func stringAndNumericIDsAndMilliseconds() throws {
        let stringID = try #require(NetEaseMusicTrack(json: json()))
        let numericID = try #require(NetEaseMusicTrack(json: json(id: 123)))
        #expect(stringID == numericID)
        #expect(stringID.duration == 180)
        #expect(stringID.artworkURL?.scheme == "https")
        #expect(stringID.artworkURL?.query == "param=300y300")
        #expect(NetEaseMusicTrack(json: json(id: "123&other=1")) == nil)
        #expect(NetEaseMusicTrack(json: json(id: 0)) == nil)
    }

    @Test func matchesVersionAndRejectsWrongArtistAlbumOrDuration() throws {
        let track = try #require(NetEaseMusicTrack(json: json()))
        #expect(track.matches(title: " song ", artist: "ARTIST", album: "Album", duration: 180.5))
        #expect(!track.matches(title: "Song", artist: "Someone Else", album: "Album", duration: 180))
        #expect(!track.matches(title: "Song", artist: "Artist", album: "Live", duration: 180))
        #expect(!track.matches(title: "Song", artist: "Artist", album: "Album", duration: 190))
        #expect(!track.matches(title: "Song", artist: "", album: "Album", duration: 180))
    }

    @Test func multipleArtistsMatchWithoutLosingNames() throws {
        var value = json()
        value["artists"] = [["name": "First"], ["name": "Second"]]
        let track = try #require(NetEaseMusicTrack(json: value))
        #expect(track.matches(title: "Song", artist: "First / Second", album: "", duration: 180))
        #expect(!track.matches(title: "Song", artist: "First", album: "", duration: 180))
    }

    @Test func ambiguousVersionsAreNotResolvedByHistoryOrder() throws {
        let first = try #require(NetEaseMusicTrack(json: json(id: 1)))
        let second = try #require(NetEaseMusicTrack(json: json(id: 2)))
        #expect(NetEaseMusicTrack.matching(in: [first, second], title: "Song", artist: "Artist", album: "Album", duration: 180) == nil)
        #expect(NetEaseMusicTrack.matching(in: [first, first], title: "Song", artist: "Artist", album: "Album", duration: 180)?.id == "1")
    }

    @Test func queueSkipsMalformedRowsAndPodcastEpisodes() throws {
        let queue: [String: Any] = ["list": [
            ["resourceType": "track", "track": json()],
            ["resourceType": "voice", "track": json(id: 222)],
            ["resourceType": "track", "track": ["id": "invalid"]]
        ]]
        let data = try JSONSerialization.data(withJSONObject: queue)
        #expect(NetEaseMusicTrack.queueTracks(from: data).map(\.id) == ["123"])
        #expect(NetEaseMusicTrack.queueTracks(from: Data("invalid".utf8)).isEmpty)
    }

    @Test func coverURLsOnlyAcceptNetEaseImageHosts() {
        for url in ["file:///private/image.jpg", "https://example.com/image.jpg", "https://p1.music.126.net.attacker.test/a", "https://user@p1.music.126.net/a"] {
            #expect(NetEaseMusicTrack.coverURL(url) == nil)
        }
        #expect(NetEaseMusicTrack.coverURL("https://p2.music.126.net/a.jpg?param=10y10")?.query == "param=300y300")
    }

    @Test func exactIDLyricEndpointAndResponseValidation() {
        #expect(NetEaseMusicLyrics.url(for: "123")?.host == "music.163.com")
        #expect(NetEaseMusicLyrics.url(for: "123&other=1") == nil)
        #expect(NetEaseMusicLyrics.url(for: "-1") == nil)
        let lrc = Data(#"{"code":200,"lrc":{"lyric":"[00:01.00]Hello"}}"#.utf8)
        #expect(NetEaseMusicLyrics.lrc(from: lrc) == "[00:01.00]Hello")
        #expect(NetEaseMusicLyrics.lrc(from: Data(#"{"code":429,"lrc":{"lyric":"bad"}}"#.utf8)) == nil)
        #expect(NetEaseMusicLyrics.lrc(from: Data(#"{"code":200,"nolyric":true}"#.utf8)) == nil)
    }

    @Test func readsStandaloneAndContainerQueuesWithoutAssumingCurrentTrack() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for root in ["Library/Containers/com.netease.163music/Data/Documents", "Library/Application Support/com.netease.163music/Documents"] {
            let file = home.appendingPathComponent(root + "/storage/file_storage/webdata/file/playingList")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["list": [["track": json()]]]).write(to: file)
        }
        let library = NetEaseMusicLibrary(home: home)
        let track = await library.track(title: "Song", artist: "Artist", album: "Album", duration: 180)
        #expect(track?.id == "123")
        let missing = await library.track(title: "Different Song", artist: "Artist", album: "Album", duration: 180)
        #expect(missing == nil)
    }

    @Test func readsHistoryWhenTrackTableIsMissingAndNeverWritesToDatabase() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("Library/Application Support/com.netease.163music/Documents/storage/sqlite_storage.sqlite3")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        #expect(sqlite3_open(file.path, &pointer) == SQLITE_OK)
        let database = try #require(pointer)
        #expect(sqlite3_exec(database, "CREATE TABLE historyTracks (jsonStr TEXT)", nil, nil, nil) == SQLITE_OK)
        let row = String(decoding: try JSONSerialization.data(withJSONObject: json()), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "''")
        #expect(sqlite3_exec(database, "INSERT INTO historyTracks VALUES ('\(row)')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let original = try Data(contentsOf: file)
        let library = NetEaseMusicLibrary(home: home)
        let track = await library.track(title: "Song", artist: "Artist", album: "Album", duration: 180)
        #expect(track?.id == "123")
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func absentLocalCacheReturnsNoMatch() async {
        let library = NetEaseMusicLibrary(home: URL(fileURLWithPath: "/nonexistent-powernotch-fixture"))
        #expect(await library.track(title: "Song", artist: "Artist", album: "Album", duration: 180) == nil)
    }
}
