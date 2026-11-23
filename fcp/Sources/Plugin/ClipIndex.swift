// SPDX-License-Identifier: GPL-3.0-or-later
// The original file of the clip the effect is on. An FxPlug cannot see it, but knows the clip's source start time (its
// timecode), duration and frame duration: the index of the Final Cut libraries maps those to the file. It is the index
// of Log MetaRaw for Final Cut (slogmetaraw.fcp_catalog), shared: same file, same matching rule (fcp_catalog.match).
import Foundation
import os

private let idxLog = Logger(subsystem: "it.mecena.motion.fcp", category: "index")

struct ClipFile {
    let path: String
    let start: Double   // seconds of the file's first frame, as Final Cut counts source time
    let fps: Double
}

final class ClipIndex {
    static let shared = ClipIndex()

    private let support = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Log MetaRaw FCP")
    private var catalogPath: String { (support as NSString).appendingPathComponent("catalog.json") }
    private let lock = NSLock()
    private var files: [String: [String: Any]] = [:]
    private var loadedDate: Date?
    private var refreshing = false
    private var lastRefresh = Date.distantPast

    var available: Bool { FileManager.default.fileExists(atPath: (support as NSString).appendingPathComponent("lib/slogmetaraw")) }

    func lookup(start: Double, duration: Double, frame: Double, media: Double?) -> ClipFile? {
        reloadIfChanged()
        lock.lock(); defer { lock.unlock() }
        guard frame > 0 else { return nil }
        let fps = 1.0 / frame
        let same = files.filter { ($0.value["fps"] as? Double).map { abs($0 - fps) < 0.01 } ?? false }
        let exact = same.filter {
            guard let s = $0.value["start"] as? Double, let d = $0.value["duration"] as? Double else { return false }
            return abs(s - start) < frame / 2 && abs(d - duration) < frame * 1.5
        }
        var hit = exact.count == 1 ? exact.first : nil
        if hit == nil, let t = media {
            let inside = same.filter {
                guard let s = $0.value["start"] as? Double, let d = $0.value["duration"] as? Double else { return false }
                return s - frame / 2 <= t && t < s + d
            }
            if inside.count == 1 { hit = inside.first }
        }
        guard let e = hit, let s = e.value["start"] as? Double, let f = e.value["fps"] as? Double else { return nil }
        return ClipFile(path: e.key, start: s, fps: f)
    }

    /// The one file that starts and lasts as the clip, whatever frame rate the host gave (it may give the timeline's)
    func lookupAnyRate(start: Double, duration: Double) -> ClipFile? {
        reloadIfChanged()
        lock.lock(); defer { lock.unlock() }
        let hits = files.filter {
            guard let s = $0.value["start"] as? Double, let d = $0.value["duration"] as? Double else { return false }
            return abs(s - start) < 0.021 && abs(d - duration) < 0.1
        }
        guard hits.count == 1, let e = hits.first, let s = e.value["start"] as? Double, let f = e.value["fps"] as? Double else { return nil }
        return ClipFile(path: e.key, start: s, fps: f)
    }

    private func reloadIfChanged() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: catalogPath),
              let date = attrs[.modificationDate] as? Date else { return }
        lock.lock(); defer { lock.unlock() }
        if loadedDate == date { return }
        guard let data = FileManager.default.contents(atPath: catalogPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let f = json["files"] as? [String: [String: Any]] else { return }
        files = f
        loadedDate = date
        idxLog.info("indice caricato: \(f.count, privacy: .public) file")
    }

    func refreshInBackground(minInterval: TimeInterval = 60) {
        lock.lock()
        if refreshing || Date().timeIntervalSince(lastRefresh) < minInterval { lock.unlock(); return }
        refreshing = true
        lastRefresh = Date()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            runIndexer()
            lock.lock(); refreshing = false; lock.unlock()
        }
    }

    func refreshNow() {
        lock.lock(); refreshing = true; lastRefresh = Date(); lock.unlock()
        runIndexer()
        lock.lock(); refreshing = false; lock.unlock()
    }

    private func runIndexer() {
        guard available else { idxLog.error("indice di Log MetaRaw non installato"); return }
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { idxLog.error("python3 non trovato: indice non aggiornato"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "slogmetaraw.fcp_catalog", "--output", catalogPath]
        p.environment = ["PYTHONPATH": (support as NSString).appendingPathComponent("lib"),
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            idxLog.info("indice aggiornato, uscita \(p.terminationStatus, privacy: .public)")
        } catch {
            idxLog.error("indice non aggiornato: \(error.localizedDescription, privacy: .public)")
        }
    }
}
