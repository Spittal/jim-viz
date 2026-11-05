import Foundation

/// Locates the Content folder (scenes and shaders) and watches it for changes.
///
/// Resolution order:
/// 1. `JIMVIZ_CONTENT` environment variable (used by scripts/run.sh to edit the repo copy live).
/// 2. `~/Library/Application Support/jim-viz/Content`, seeded from the app bundle on first launch.
final class ContentStore {
    let root: URL
    var scenesDir: URL { root.appendingPathComponent("Scenes") }
    var shadersDir: URL { root.appendingPathComponent("Shaders") }
    var presetsDir: URL { root.appendingPathComponent("Presets") }

    private var mtimes: [URL: Date] = [:]
    private var timer: Timer?

    init() {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["JIMVIZ_CONTENT"], !env.isEmpty {
            root = URL(fileURLWithPath: env, isDirectory: true)
            return
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jim-viz/Content", isDirectory: true)
        if !fm.fileExists(atPath: support.path),
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("Content"),
           fm.fileExists(atPath: bundled.path) {
            try? fm.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: bundled, to: support)
        }
        root = support
    }

    func sceneURLs() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: scenesDir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func generatorShader(_ type: String) -> URL {
        shadersDir.appendingPathComponent("generators/\(type).metal")
    }

    func effectShader(_ name: String) -> URL {
        shadersDir.appendingPathComponent("effects/\(name).metal")
    }

    var commonShader: URL { shadersDir.appendingPathComponent("common.metal") }

    /// Processing for the Webcam input; its `// @param`s are the Webcam's knobs.
    var webcamShader: URL { shadersDir.appendingPathComponent("inputs/webcam.metal") }

    func availableEffects() -> [String] {
        let dir = shadersDir.appendingPathComponent("effects")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "metal" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Generator tools: one per shader in Shaders/generators.
    func generatorTypes() -> [String] {
        let dir = shadersDir.appendingPathComponent("generators")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "metal" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    func presetsDir(_ kind: DeviceKind, _ tool: String) -> URL {
        presetsDir.appendingPathComponent(kind.rawValue).appendingPathComponent(tool)
    }

    /// Preset ids (file names) for a tool, sorted.
    func presetIDs(_ kind: DeviceKind, _ tool: String) -> [String] { jsonNames(in: presetsDir(kind, tool)) }

    func preset(_ kind: DeviceKind, _ tool: String, _ id: String) -> Preset? {
        let url = presetsDir(kind, tool).appendingPathComponent("\(id).json")
        return try? JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
    }

    private func jsonNames(in dir: URL) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Polls file modification dates twice a second and reports changed files.
    func watch(_ onChange: @escaping ([URL]) -> Void) {
        mtimes = snapshot()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = self.snapshot()
            var changed: [URL] = []
            for (url, date) in now where self.mtimes[url] != date { changed.append(url) }
            for url in self.mtimes.keys where now[url] == nil { changed.append(url) }
            self.mtimes = now
            if !changed.isEmpty { onChange(changed) }
        }
    }

    /// Records the current state of a file, so a save we made ourselves is not reported.
    func markSeen(_ url: URL) {
        mtimes[url.standardizedFileURL] = modDate(url)
    }

    private func snapshot() -> [URL: Date] {
        var result: [URL: Date] = [:]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return result
        }
        for case let url as URL in e where ["json", "metal"].contains(url.pathExtension) {
            result[url.standardizedFileURL] = modDate(url)
        }
        return result
    }

    private func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
