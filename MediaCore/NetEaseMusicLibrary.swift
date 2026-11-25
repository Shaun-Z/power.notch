// NetEase client paths/schema and ID-first lookup approach reference lyrimuse (GPL-3.0):
// https://github.com/Yudaotor/lyrimuse — lyrimuse-engine/{clientdataroot,neteaselocal}.go
// Reimplemented for powerNotch. Playback identity always comes from Now Playing, not history order.
import Foundation
import SQLite3

struct NetEaseMusicTrack: Equatable, Sendable {
    static let bundleIdentifier = "com.netease.163music"
    let id: String
    let title: String
    let artists: [String]
    let album: String
    let duration: Double
    let artworkURL: URL?

    init?(json: [String: Any]) {
        let rawID = (json["id"] as? String) ?? (json["id"] as? NSNumber)?.stringValue ?? ""
        guard let numericID = Int64(rawID), numericID > 0,
              let title = json["name"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        id = String(numericID)
        self.title = title
        let artistRows = (json["artists"] ?? json["ar"]) as? [[String: Any]] ?? []
        artists = artistRows.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        let album = (json["album"] ?? json["al"]) as? [String: Any] ?? [:]
        self.album = album["name"] as? String ?? ""
        let milliseconds = (json["duration"] ?? json["dt"]) as? NSNumber
        duration = max(0, milliseconds?.doubleValue ?? 0) / 1000
        artworkURL = Self.coverURL(album["picUrl"] as? String)
    }

    static func coverURL(_ string: String?) -> URL? {
        guard let string, var parts = URLComponents(string: string),
              let scheme = parts.scheme, ["http", "https"].contains(scheme.lowercased()),
              let host = parts.host?.lowercased(), host.hasSuffix(".music.126.net"),
              parts.user == nil, parts.password == nil, parts.port == nil
        else { return nil }
        parts.scheme = "https"
        var query = parts.queryItems?.filter { $0.name != "param" } ?? []
        query.append(URLQueryItem(name: "param", value: "300y300"))
        parts.queryItems = query
        return parts.url
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static func artistNames(_ value: String) -> Set<String> {
        Set(value.components(separatedBy: CharacterSet(charactersIn: "/、,&，＆"))
            .map(normalized).filter { !$0.isEmpty })
    }

    func matches(title: String, artist: String, album: String, duration: Double) -> Bool {
        guard Self.normalized(self.title) == Self.normalized(title), !artist.isEmpty, !artists.isEmpty else { return false }
        let knownArtists = Set(artists.map(Self.normalized))
        guard knownArtists == Self.artistNames(artist)
                || Self.normalized(artists.joined(separator: "/")) == Self.normalized(artist)
        else { return false }
        if !album.isEmpty, !self.album.isEmpty, Self.normalized(album) != Self.normalized(self.album) { return false }
        if duration > 0, self.duration > 0, abs(duration - self.duration) > 2 { return false }
        return true
    }

    static func matching(in tracks: [Self], title: String, artist: String, album: String, duration: Double) -> Self? {
        let matches = tracks.filter { $0.matches(title: title, artist: artist, album: album, duration: duration) }
        // A client may contain several versions with identical names. Never guess a song ID.
        guard Set(matches.map(\.id)).count == 1 else { return nil }
        return matches.first
    }

    static func queueTracks(from data: Data) -> [Self] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["list"] as? [[String: Any]] else { return [] }
        return rows.prefix(20_000).compactMap { row in
            let kind = row["resourceType"] as? String ?? "track"
            guard kind == "track" || kind == "local" || kind == "download" else { return nil }
            return (row["track"] as? [String: Any]).flatMap(Self.init(json:))
        }
    }
}

actor NetEaseMusicLibrary {
    static let shared = NetEaseMusicLibrary()
    private let roots: [URL]
    private var cachedTracks: [NetEaseMusicTrack] = []
    private var lastSignature: [String: String] = [:]
    private var lastScan = Date.distantPast

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        roots = [
            home.appendingPathComponent("Library/Containers/com.netease.163music/Data/Documents"),
            home.appendingPathComponent("Library/Application Support/com.netease.163music/Documents")
        ]
    }

    func track(title: String, artist: String, album: String, duration: Double) -> NetEaseMusicTrack? {
        refreshIfNeeded()
        return NetEaseMusicTrack.matching(in: cachedTracks, title: title, artist: artist, album: album, duration: duration)
    }

    private func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastScan) >= 2 else { return }
        lastScan = Date()
        let files = roots.flatMap { root in
            ["storage/file_storage/webdata/file/playingList", "storage/sqlite_storage.sqlite3"].map { root.appendingPathComponent($0) }
        }
        var signature: [String: String] = [:]
        for url in files {
            for path in [url.path, url.path + "-wal"] {
                if let info = try? FileManager.default.attributesOfItem(atPath: path) {
                    let modified = (info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    signature[path] = "\(modified)|\(info[.size] ?? 0)"
                }
            }
        }
        guard signature != lastSignature else { return }
        lastSignature = signature
        var tracks: [NetEaseMusicTrack] = []
        for url in files {
            if url.lastPathComponent == "playingList" {
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      size <= 16 * 1024 * 1024,
                      let data = try? Data(contentsOf: url) else { continue }
                tracks += NetEaseMusicTrack.queueTracks(from: data)
            } else {
                tracks += Self.databaseTracks(at: url)
            }
        }
        cachedTracks = tracks
    }

    private static func databaseTracks(at url: URL) -> [NetEaseMusicTrack] {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return [] }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database = pointer else {
            if let pointer { sqlite3_close(pointer) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var tracks: [NetEaseMusicTrack] = []
        for table in ["dbTrack", "historyTracks"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT jsonStr FROM \(table) LIMIT 20000", -1, &statement, nil) == SQLITE_OK,
                  let statement else { continue }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard sqlite3_column_bytes(statement, 0) <= 1_048_576,
                      let value = sqlite3_column_text(statement, 0),
                      let data = String(cString: value).data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let track = NetEaseMusicTrack(json: json) else { continue }
                tracks.append(track)
            }
        }
        return tracks
    }
}

enum NetEaseMusicLyrics {
    static func url(for songID: String) -> URL? {
        guard let value = Int64(songID), value > 0 else { return nil }
        return URL(string: "https://music.163.com/api/song/lyric?id=\(value)&lv=-1&kv=-1&tv=-1")
    }

    static func lrc(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["code"] as? Int == 200,
              object["nolyric"] as? Bool != true,
              let lrc = (object["lrc"] as? [String: Any])?["lyric"] as? String,
              !lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return lrc
    }

    static func fetch(songID: String) async -> String? {
        guard let url = url(for: songID), !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled else { return nil }
        return lrc(from: data)
    }
}
