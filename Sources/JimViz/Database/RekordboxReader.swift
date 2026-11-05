import Foundation
import Observation

/// Observes Rekordbox's local `master.db` and `master.db-wal` files, automatically decrypting
/// and querying recent playback history and track metadata.
@Observable
final class RekordboxReader {
    private(set) var isAvailable: Bool = false
    private(set) var currentTrack: RekordboxTrack?
    private(set) var history: [RekordboxTrack] = []
    private(set) var statusText: String = "Searching for Rekordbox library..."
    private(set) var lastUpdated: Date?
    /// Increments whenever a new track enters history.
    private(set) var trackSerial: Int = 0
    private(set) var isRefreshing: Bool = false

    @ObservationIgnored private let dbURL: URL
    @ObservationIgnored private let walURL: URL
    @ObservationIgnored private let shareDir: URL
    @ObservationIgnored private let decryptedURL: URL
    @ObservationIgnored private let queue = DispatchQueue(label: "jim-viz.rekordbox-reader", qos: .utility)
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastDbMtime: Date?
    @ObservationIgnored private var lastWalMtime: Date?
    @ObservationIgnored private var lastWalSize: Int64 = -1
    @ObservationIgnored private var isDecrypting = false

    init(pioneerDir: URL? = nil) {
        let dir = pioneerDir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Pioneer/rekordbox", isDirectory: true)
        self.dbURL = dir.appendingPathComponent("master.db")
        self.walURL = dir.appendingPathComponent("master.db-wal")
        self.shareDir = dir.appendingPathComponent("share", isDirectory: true)

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.decryptedURL = tempDir.appendingPathComponent("jim-viz-rekordbox.db")
    }

    func start() {
        checkAndRefresh()
        // Schedule on .common modes so timer fires during window drag or UI interaction
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Key-harmonized 5-color palette for the current track, if musical key is detected.
    var keyPalette: [SIMD3<Float>]? {
        guard let track = currentTrack, !track.key.isEmpty,
              let info = CamelotKey.parse(track.key) else { return nil }
        return CamelotKey.palette(for: info)
    }

    // MARK: - Direct File Attributes (bypassing URL resourceValues cache)

    private func fileStats(at path: String) -> (mtime: Date?, size: Int64) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return (nil, -1)
        }
        let mtime = attrs[.modificationDate] as? Date
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return (mtime, size)
    }

    // MARK: - Polling

    private func poll() {
        guard !isDecrypting else { return }
        queue.async { [weak self] in
            guard let self, !self.isDecrypting else { return }
            let fm = FileManager.default
            guard fm.fileExists(atPath: self.dbURL.path) else {
                DispatchQueue.main.async {
                    if self.isAvailable {
                        self.isAvailable = false
                        self.statusText = "master.db not found"
                    }
                }
                return
            }

            let (dbMtime, _) = self.fileStats(at: self.dbURL.path)
            let (walMtime, walSize) = self.fileStats(at: self.walURL.path)

            let changed = dbMtime != self.lastDbMtime || walMtime != self.lastWalMtime || walSize != self.lastWalSize
            if changed || !self.isAvailable {
                self.decryptAndLoad(dbMtime: dbMtime, walMtime: walMtime, walSize: walSize)
            }
        }
    }

    func checkAndRefresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let (dbMtime, _) = self.fileStats(at: self.dbURL.path)
            let (walMtime, walSize) = self.fileStats(at: self.walURL.path)
            self.decryptAndLoad(dbMtime: dbMtime, walMtime: walMtime, walSize: walSize)
        }
    }

    private func decryptAndLoad(dbMtime: Date?, walMtime: Date?, walSize: Int64) {
        isDecrypting = true
        DispatchQueue.main.async { self.isRefreshing = true }

        do {
            try RekordboxSQLCipher.decrypt(dbURL: dbURL, walURL: walURL, destinationURL: decryptedURL)
            let library = RekordboxLibrary(dbPath: decryptedURL, shareDir: shareDir)
            let recent = try library.queryRecentHistory(limit: 20)
            let latest = recent.first

            DispatchQueue.main.async {
                self.lastDbMtime = dbMtime
                self.lastWalMtime = walMtime
                self.lastWalSize = walSize
                self.isAvailable = true
                self.isRefreshing = false
                self.isDecrypting = false
                self.history = recent

                if self.currentTrack?.id != latest?.id {
                    self.currentTrack = latest
                    self.trackSerial += 1
                } else if latest != nil {
                    self.currentTrack = latest
                }

                self.lastUpdated = Date()
                if let track = latest {
                    self.statusText = "Track: \(track.displayTitle) [\(track.camelot), \(String(format: "%.1f", track.bpm)) BPM]"
                } else {
                    self.statusText = "Library connected (no history rows)"
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.isDecrypting = false
                self.statusText = "DB decrypt error: \(error.localizedDescription)"
            }
        }
    }
}
