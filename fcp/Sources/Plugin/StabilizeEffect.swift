// SPDX-License-Identifier: GPL-3.0-or-later
// Mecena Stabilize as a Final Cut Pro effect (FxPlug 4, Metal). The stabilization is the Resolve effect's: the same
// plugin base (vendor/common) runs in vendor/fxplug, called through MecenaCore.h. Same modes, same reading of the
// clip's motion data from its original file, which the index of the libraries finds (ClipIndex).
import Foundation
import AppKit
import Metal
import os

private let stLog = Logger(subsystem: "it.mecena.motion.fcp", category: "stabilize")

// Parameter IDs are permanent: Final Cut stores them in projects (make_motion_template.py uses the same ones)
enum P: UInt32 {
    case status = 1, report = 2, read = 3
    case mode = 10, master = 11, zoom = 12
    case advanced = 100, smoothness = 101, horizon = 102, lens = 103, roll = 104, fov = 105
}

// The order of GyroflowPluginBase::MODES (vendor/common/src/lib.rs)
let modeNames = ["Treppiede", "Cinematografica", "Bilanciata", "A mano naturale", "Solo orizzonte dritto",
                 "Solo correzione ottica", "Personalizzata"]
let modeCustom: Int32 = 6
let modeDefault: Int32 = 2

/// What the render of one frame needs, made by pluginState on the host's side
struct StabState: Codable {
    var path = "", start = 0.0, fps = 0.0
    var mode: Int32 = modeDefault
    var master = 100.0, zoom = 130.0, smoothness = 50.0, horizon = 0.0, lens = 100.0, roll = 0.0, fov = 1.0
    var reload = 0
}

/// What the core said about each clip (Stato, Dati rilevati). Final Cut may render in another instance of the effect
/// than the one that shows the panel: the render writes here, pluginState shows it
final class StatusBoard {
    static let shared = StatusBoard()
    private let lock = NSLock()
    private var texts: [String: (String, String)] = [:]
    func set(_ path: String, _ status: String, _ report: String) { lock.lock(); texts[path] = (status, report); lock.unlock() }
    func get(_ path: String) -> (String, String)? { lock.lock(); defer { lock.unlock() }; return texts[path] }
}

@objc(MecenaStabilizePlugIn)
class MecenaStabilizePlugIn: NSObject, FxTileableEffect {
    let _apiManager: PROAPIAccessing!
    private var syncing = false
    private let coreLock = NSLock()
    private let core: OpaquePointer
    private var clipKey = "", clip: ClipFile?
    private var reloadCount = 0, coreReload = 0
    private var shown = ("", "")

    required init?(apiManager: PROAPIAccessing) {
        _apiManager = apiManager
        core = mm_stab_new()
    }
    deinit { mm_stab_free(core) }

    // MARK: Panel

    func addParameters() throws {
        let api = _apiManager!.api(for: FxParameterCreationAPI_v5.self) as! FxParameterCreationAPI_v5
        let none = FxParameterFlags(kFxParameterFlag_DEFAULT)
        let still = FxParameterFlags(kFxParameterFlag_NOT_ANIMATABLE)
        let text = FxParameterFlags(kFxParameterFlag_DISABLED | kFxParameterFlag_NOT_ANIMATABLE)
        func slider(_ name: String, _ id: P, _ def: Double, _ lo: Double, _ hi: Double, _ delta: Double,
                    sliderLo: Double? = nil, sliderHi: Double? = nil, flags: FxParameterFlags) {
            api.addFloatSlider(withName: name, parameterID: id.rawValue, defaultValue: def, parameterMin: lo, parameterMax: hi,
                               sliderMin: sliderLo ?? lo, sliderMax: sliderHi ?? hi, delta: delta, parameterFlags: flags)
        }

        api.addStringParameter(withName: "Stato", parameterID: P.status.rawValue, defaultValue: "In attesa della clip", parameterFlags: text)
        api.addStringParameter(withName: "Dati rilevati", parameterID: P.report.rawValue, defaultValue: "", parameterFlags: text)
        api.addPushButton(withName: "Leggi dati clip", parameterID: P.read.rawValue, selector: #selector(readClip), parameterFlags: none)

        api.addPopupMenu(withName: "Modalità", parameterID: P.mode.rawValue, defaultValue: UInt32(modeDefault), menuEntries: modeNames, parameterFlags: still)
        slider("Intensità (%)", .master, 100, 0, 100, 1, flags: none)
        slider("Zoom massimo (%)", .zoom, 130, 51, 300, 1, sliderLo: 100, sliderHi: 200, flags: still)

        api.startParameterSubGroup("Avanzate", parameterID: P.advanced.rawValue, parameterFlags: FxParameterFlags(kFxParameterFlag_COLLAPSED))
        slider("Fluidità (%)", .smoothness, 50, 1, 300, 1, sliderHi: 150, flags: still)
        slider("Orizzonte dritto (%)", .horizon, 0, 0, 100, 1, flags: still)
        slider("Correzione ottica (%)", .lens, 100, 0, 100, 1, flags: still)
        slider("Inclinazione orizzonte (°)", .roll, 0, -100, 100, 0.1, flags: still)
        slider("Campo visivo", .fov, 1, 0.1, 3, 0.01, sliderLo: 0.5, sliderHi: 2, flags: still)
        api.endParameterSubGroup()
    }

    /// A mode sets Fluidità and Orizzonte dritto; moving one of them makes the mode Personalizzata (as in Resolve)
    func parameterChanged(_ paramID: UInt32, at time: CMTime) throws {
        guard !syncing, let id = P(rawValue: paramID) else { return }
        let get = _apiManager!.api(for: FxParameterRetrievalAPI_v6.self) as! FxParameterRetrievalAPI_v6
        let set = _apiManager!.api(for: FxParameterSettingAPI_v5.self) as! FxParameterSettingAPI_v5
        syncing = true
        defer { syncing = false }
        switch id {
        case .mode:
            var mode: Int32 = 0
            get.getIntValue(&mode, fromParameter: P.mode.rawValue, at: time)
            var s = 0.0, h = 0.0
            if mm_mode_values(mode, &s, &h) != 0 {
                set.setFloatValue(s, toParameter: P.smoothness.rawValue, at: time)
                set.setFloatValue(h, toParameter: P.horizon.rawValue, at: time)
            }
        case .smoothness, .horizon:
            set.setIntValue(modeCustom, toParameter: P.mode.rawValue, at: time)
        default:
            break
        }
    }

    /// "Leggi dati clip": update the index of the libraries and read the clip again from its original
    @objc func readClip() {
        ClipIndex.shared.refreshNow()
        coreLock.lock()
        clipKey = ""
        reloadCount += 1
        coreLock.unlock()
        show(status: "Lettura della clip…", report: nil)
    }

    private func show(status: String, report: String?) {
        if shown.0 == status && (report == nil || shown.1 == report!) { return }
        shown = (status, report ?? shown.1)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let action = self._apiManager!.api(for: FxCustomParameterActionAPI_v4.self) as? FxCustomParameterActionAPI_v4 else {
                stLog.error("show: nessuna API delle azioni"); return
            }
            // Outside a parameter callback Final Cut hands out the setting API only inside an action
            action.startAction(self)
            guard let set = self._apiManager!.api(for: FxParameterSettingAPI_v5.self) as? FxParameterSettingAPI_v5 else {
                action.endAction(self)
                stLog.error("show: nessuna API per scrivere i parametri"); return
            }
            self.syncing = true
            set.setStringParameterValue(status, toParameter: P.status.rawValue)
            if let report { set.setStringParameterValue(report, toParameter: P.report.rawValue) }
            action.endAction(self)
            self.syncing = false
        }
    }

    func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
        properties?.pointee = NSDictionary(dictionary: [
            kFxPropertyKey_MayRemapTime: NSNumber(value: false),
            kFxPropertyKey_PixelTransformSupport: NSNumber(value: kFxPixelTransform_ScaleTranslate),
            kFxPropertyKey_VariesWhenParamsAreStatic: NSNumber(value: true),   // every frame moves differently
            kFxPropertyKey_NeedsFullBuffer: NSNumber(value: true),             // a geometric effect: the whole frame
            // the clip's own (gamma) code values, as Gyroflow Toolbox asks: no conversion to linear and back
            kFxPropertyKey_DesiredProcessingColorInfo: NSNumber(value: kFxImageColorInfo_RGB_GAMMA_VIDEO),
        ])
    }

    // MARK: Plug-in state

    /// The clip's original file, by its timing (once per clip: the index lookup isn't free)
    private func clipFile(at renderTime: CMTime) -> ClipFile? {
        guard let timing = _apiManager!.api(for: FxTimingAPI_v4.self) as? FxTimingAPI_v4 else { return nil }
        var start = CMTime.zero, dur = CMTime.zero, fd = CMTime.zero, input = CMTime.zero
        timing.startTimeOfInput(toFilter: &start)
        timing.durationTimeOfInput(toFilter: &dur)
        timing.frameDuration(&fd)
        timing.inputTime(&input, fromTimelineTime: renderTime)
        guard fd.seconds > 0 else { return nil }
        let key = String(format: "%.4f/%.4f/%.5f", start.seconds, dur.seconds, fd.seconds)
        coreLock.lock(); defer { coreLock.unlock() }
        if key == clipKey { return clip }
        var hit = ClipIndex.shared.lookup(start: start.seconds, duration: dur.seconds, frame: fd.seconds, media: input.seconds)
            ?? ClipIndex.shared.lookup(start: start.seconds, duration: dur.seconds, frame: fd.seconds, media: renderTime.seconds)
            ?? ClipIndex.shared.lookupAnyRate(start: start.seconds, duration: dur.seconds)
        if hit == nil {
            stLog.notice("clip non trovata: start=\(start.seconds, privacy: .public) dur=\(dur.seconds, privacy: .public) fd=\(fd.seconds, privacy: .public) input=\(input.seconds, privacy: .public) render=\(renderTime.seconds, privacy: .public)")
            ClipIndex.shared.refreshInBackground()   // new clips: a later frame finds them
        }
        if hit != nil { clipKey = key }
        clip = hit
        return hit
    }

    func pluginState(_ pluginState: AutoreleasingUnsafeMutablePointer<NSData>?, at renderTime: CMTime, quality qualityLevel: UInt) throws {
        let api = _apiManager!.api(for: FxParameterRetrievalAPI_v6.self) as! FxParameterRetrievalAPI_v6
        func f(_ id: P) -> Double { var v = 0.0; api.getFloatValue(&v, fromParameter: id.rawValue, at: renderTime); return v }
        var s = StabState()
        var mode: Int32 = modeDefault
        api.getIntValue(&mode, fromParameter: P.mode.rawValue, at: renderTime)
        s.mode = mode
        s.master = f(.master); s.zoom = f(.zoom); s.smoothness = f(.smoothness); s.horizon = f(.horizon)
        s.lens = f(.lens); s.roll = f(.roll); s.fov = f(.fov)
        if let c = clipFile(at: renderTime) { s.path = c.path; s.start = c.start; s.fps = c.fps }
        if s.path.isEmpty {
            show(status: ClipIndex.shared.available ? "Clip non trovata nell'indice: premi Leggi dati clip"
                                                    : "Indice delle librerie assente: installa Log MetaRaw per Final Cut", report: "")
        } else if let (status, report) = StatusBoard.shared.get(s.path) {
            show(status: status, report: report)
        } else {
            show(status: "Lettura dei dati della clip…", report: (s.path as NSString).lastPathComponent)
        }
        coreLock.lock(); s.reload = reloadCount; coreLock.unlock()
        pluginState?.pointee = try JSONEncoder().encode(s) as NSData
    }

    // MARK: Geometry: the whole frame in, the whole frame out

    func destinationImageRect(_ destinationImageRect: UnsafeMutablePointer<FxRect>, sourceImages: [FxImageTile], destinationImage: FxImageTile, pluginState: Data?, at renderTime: CMTime) throws {
        destinationImageRect.pointee = sourceImages[0].imagePixelBounds
    }

    func sourceTileRect(_ sourceTileRect: UnsafeMutablePointer<FxRect>, sourceImageIndex: UInt, sourceImages: [FxImageTile], destinationTileRect: FxRect, destinationImage: FxImageTile, pluginState: Data?, at renderTime: CMTime) throws {
        sourceTileRect.pointee = sourceImages[0].imagePixelBounds
    }

    // MARK: Render

    private func text(_ name: String) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        _ = mm_stab_text(core, name, &buf, buf.count)
        return String(cString: buf)
    }

    /// Hands the panel to the core (only what changed counts as an edit there). Called with coreLock held
    private func configure(_ s: StabState) {
        if s.reload != coreReload {   // "Leggi dati clip": the file again, from scratch
            coreReload = s.reload
            _ = mm_stab_set_file(core, "")
        }
        _ = mm_stab_set_file(core, s.path)
        _ = mm_stab_set(core, "Mode", Double(s.mode))
        _ = mm_stab_set(core, "ZoomLimit", s.zoom)
        _ = mm_stab_set(core, "Smoothness", s.smoothness)
        _ = mm_stab_set(core, "HorizonLockAmount", s.horizon)
        _ = mm_stab_set(core, "LensCorrectionStrength", s.lens)
        _ = mm_stab_set(core, "HorizonLockRoll", s.roll)
        _ = mm_stab_set(core, "Fov", s.fov)
    }

    func renderDestinationImage(_ destinationImage: FxImageTile, sourceImages: [FxImageTile], pluginState: Data?, at renderTime: CMTime) throws {
        let s = (pluginState.flatMap { try? JSONDecoder().decode(StabState.self, from: $0) }) ?? StabState()
        let src = sourceImages[0]
        let cache = MetalDeviceCache.shared
        guard let queue = cache.queue(src.deviceRegistryID),
              let input = src.metalTexture(for: queue.device),
              let output = destinationImage.metalTexture(for: queue.device) else {
            throw NSError(domain: "MecenaMotion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nessun dispositivo Metal"])
        }
        let w = min(input.width, output.width), h = min(input.height, output.height)
        let bpp: Int
        switch input.pixelFormat {
        case .rgba16Float: bpp = 8
        case .rgba32Float: bpp = 16
        default: bpp = 0
        }

        var rendered = false
        if bpp > 0, input.pixelFormat == output.pixelFormat, input.width == output.width, input.height == output.height,
           !s.path.isEmpty, s.fps > 0 {
            // The frame of the file: Final Cut's source time counts from the file's start timecode. A 25p clip on a 50p
            // timeline is asked for each source frame twice: floor, not round (a tick in the middle is the same frame)
            let frame = Int64(((src.mediaTime.seconds - s.start) * s.fps + 1e-3).rounded(.down))
            coreLock.lock()
            configure(s)
            // Final Cut's own textures, straight to the core (it copies them on the GPU): no wait here, one in the core
            let rc = mm_stab_render(core, frame, s.master / 100, Unmanaged.passUnretained(input).toOpaque(), input.width * bpp,
                                    Unmanaged.passUnretained(output).toOpaque(), output.width * bpp,
                                    Unmanaged.passUnretained(queue).toOpaque(), input.width, input.height, bpp == 8 ? 1 : 0, 1)
            let status = text("Status"), report = text("ClipReport")
            coreLock.unlock()
            StatusBoard.shared.set(s.path, rc == 0 ? "OK · stabilizzata" : status, report)
            rendered = rc == 0
            if rc != 0 { stLog.error("render \(rc, privacy: .public) frame \(frame, privacy: .public): \(status, privacy: .public)") }
        } else if bpp == 0, !s.path.isEmpty {
            StatusBoard.shared.set(s.path, "Formato pixel non gestito (\(input.pixelFormat.rawValue))", "")
        }
        if !rendered, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {   // the clip as it is
            if input.pixelFormat == output.pixelFormat {
                blit.copy(from: input, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: w, height: h, depth: 1), to: output, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
    }
}
