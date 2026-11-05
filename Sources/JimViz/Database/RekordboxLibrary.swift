import Foundation
import SQLite3

struct RekordboxCue: Identifiable, Hashable {
    let id: String
    let kind: Int // 0 = memory cue, 1..=3 = hot cue A..C, 4 = active loop, 5..=9 = hot cue D..H
    let inMsec: Int
    let outMsec: Int
    let comment: String
    let color: Int

    var label: String {
        switch kind {
        case 1: return "Hot Cue A"
        case 2: return "Hot Cue B"
        case 3: return "Hot Cue C"
        case 4: return "Loop"
        case 5: return "Hot Cue D"
        case 6: return "Hot Cue E"
        case 7: return "Hot Cue F"
        case 8: return "Hot Cue G"
        case 9: return "Hot Cue H"
        default: return "Cue"
        }
    }

    var timeSeconds: Double { Double(inMsec) / 1000.0 }
}

struct RekordboxTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let key: String
    let camelot: String
    let bpm: Double
    let duration: Double // in seconds
    let rating: Int
    let artworkURL: URL?
    let playedAt: Date?
    var cues: [RekordboxCue] = []

    var displayTitle: String {
        artist.isEmpty ? title : "\(artist) – \(title)"
    }
}

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Reads collection metadata, recent history, and cue points from the decrypted SQLite database.
final class RekordboxLibrary {
    private let dbPath: URL
    private let shareDir: URL

    init(dbPath: URL, shareDir: URL) {
        self.dbPath = dbPath
        self.shareDir = shareDir
    }

    /// Queries the most recently played track from `djmdSongHistory`.
    func queryLatestPlayedTrack() throws -> RekordboxTrack? {
        let history = try queryRecentHistory(limit: 1)
        return history.first
    }

    /// Queries the N most recently played tracks.
    func queryRecentHistory(limit: Int = 20) throws -> [RekordboxTrack] {
        var db: OpaquePointer?
        let uri = "file:\(dbPath.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let msg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            throw DatabaseError(message: "sqlite3_open_v2: \(msg)")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT c.ID, c.Title, IFNULL(a.Name, ''), IFNULL(al.Name, ''),
               IFNULL(k.ScaleName, ''), c.BPM, c.Length, c.Rating, c.ImagePath, s.created_at
        FROM djmdSongHistory s
        JOIN djmdContent c ON c.ID = s.ContentID
        LEFT JOIN djmdArtist a ON a.ID = c.ArtistID
        LEFT JOIN djmdAlbum al ON al.ID = c.AlbumID
        LEFT JOIN djmdKey k ON k.ID = c.KeyID
        WHERE s.rb_local_deleted = 0
        ORDER BY s.created_at DESC
        LIMIT ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw DatabaseError(message: "sqlite3_prepare_v2: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var tracks: [RekordboxTrack] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let artist = String(cString: sqlite3_column_text(stmt, 2))
            let album = String(cString: sqlite3_column_text(stmt, 3))
            let key = String(cString: sqlite3_column_text(stmt, 4))
            let rawBPM = sqlite3_column_int(stmt, 5)
            let length = sqlite3_column_double(stmt, 6)
            let rating = Int(sqlite3_column_int(stmt, 7))
            let imagePath = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let dateStr = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

            let bpm = rawBPM > 0 ? Double(rawBPM) / 100.0 : 0
            let camelot = CamelotKey.parse(key)?.camelot ?? key

            var artworkURL: URL?
            if let imagePath, !imagePath.isEmpty {
                // Rekordbox stores paths starting with /PIONEER/Artwork/...
                var rel = imagePath
                if rel.hasPrefix("/") { rel.removeFirst() }
                artworkURL = shareDir.appendingPathComponent(rel)
            }

            var playedAt: Date?
            if let dateStr {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                playedAt = fmt.date(from: dateStr) ?? ISO8601DateFormatter().date(from: dateStr)
            }

            let cues = try? queryCues(for: id, in: db)
            let track = RekordboxTrack(
                id: id,
                title: title,
                artist: artist,
                album: album,
                key: key,
                camelot: camelot,
                bpm: bpm,
                duration: length,
                rating: rating,
                artworkURL: artworkURL,
                playedAt: playedAt,
                cues: cues ?? []
            )
            tracks.append(track)
        }

        return tracks
    }

    /// Queries cues (hot cues and memory cues) for a given track content ID.
    private func queryCues(for contentID: String, in db: OpaquePointer?) throws -> [RekordboxCue] {
        let sql = """
        SELECT ID, Kind, InMsec, OutMsec, IFNULL(Comment, ''), Color
        FROM djmdCue
        WHERE ContentID = ? AND rb_local_deleted = 0
        ORDER BY InMsec ASC;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        _ = contentID.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }

        var cues: [RekordboxCue] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let kind = Int(sqlite3_column_int(stmt, 1))
            let inMsec = Int(sqlite3_column_int(stmt, 2))
            let outMsec = Int(sqlite3_column_int(stmt, 3))
            let comment = String(cString: sqlite3_column_text(stmt, 4))
            let color = Int(sqlite3_column_int(stmt, 5))

            cues.append(RekordboxCue(
                id: id,
                kind: kind,
                inMsec: inMsec,
                outMsec: outMsec,
                comment: comment,
                color: color
            ))
        }

        return cues
    }
}
