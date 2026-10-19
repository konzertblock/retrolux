import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

// MARK: - web gallery / journal → local HTML
public enum WebExporter {
    struct Look { var bg: String, fg: String, accent: String, font: String, thumbBorder: String, cardBg: String }
    static let looks: [String: Look] = [
        "Art Collection": .init(bg: "#f3efe6", fg: "#2b2b2b", accent: "#8a6d3b", font: "Didot, Georgia, serif", thumbBorder: "8px solid #fff", cardBg: "#fff"),
        "Model": .init(bg: "#111", fg: "#eee", accent: "#c0a060", font: "Helvetica Neue, Arial, sans-serif", thumbBorder: "0", cardBg: "#1b1b1b"),
        "Picture": .init(bg: "#fff", fg: "#222", accent: "#3b6ea5", font: "Helvetica, Arial, sans-serif", thumbBorder: "1px solid #ccc", cardBg: "#fff"),
        "Proof": .init(bg: "#d8d8d8", fg: "#111", accent: "#555", font: "Courier, monospace", thumbBorder: "1px solid #888", cardBg: "#eee"),
        "Rules": .init(bg: "#fafafa", fg: "#333", accent: "#b33", font: "Georgia, serif", thumbBorder: "0", cardBg: "#fff"),
        "Special Occasion": .init(bg: "#f8f3e8", fg: "#5a3d12", accent: "#a67c00", font: "Zapfino, Georgia, serif", thumbBorder: "3px double #a67c00", cardBg: "#fffaf0"),
        "Stock": .init(bg: "#fff", fg: "#000", accent: "#0645ad", font: "Helvetica, Arial, sans-serif", thumbBorder: "0", cardBg: "#fff"),
        "Stock Black": .init(bg: "#000", fg: "#fff", accent: "#6ab0ff", font: "Helvetica, Arial, sans-serif", thumbBorder: "0", cardBg: "#000")]
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }

    public struct Result: Sendable { public var folder: URL; public var index: URL; public var images = 0; public var skipped: [String] = [] }

    /// Writes index.html (+ one page per photo for galleries), thumbnails and images; everything is local, no external requests.
    public static func export(_ doc: WebDoc, versions: [ID], store: LibraryStore, to folder: URL, progress: ((Int, Int) -> Void)? = nil) throws -> Result {
        let look = looks[doc.theme] ?? looks["Stock"]!
        let fm = FileManager.default; try fm.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true); try fm.createDirectory(at: folder.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
        let ip = WebDoc.presets.first { $0.0 == doc.imagePreset } ?? WebDoc.presets[4], tp = WebDoc.presets.first { $0.0 == doc.thumbPreset } ?? WebDoc.presets[1]
        var res = Result(folder: folder, index: folder.appendingPathComponent("index.html"))
        let ids: [ID] = doc.blocks.isEmpty ? versions : doc.blocks.compactMap(\.versionID)
        var files: [ID: (img: String, thumb: String, w: Int, h: Int)] = [:]
        func write(_ cg: CGImage, _ url: URL, q: Double, png: Bool) -> Bool {
            guard let d = CGImageDestinationCreateWithURL(url as CFURL, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(d, cg, png ? nil : [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary); return CGImageDestinationFinalize(d)
        }
        for (n, id) in ids.enumerated() {
            progress?(n, ids.count)
            guard store.versions[id] != nil, let big = store.renderedImage(id, maxPixel: Int(ip.1)) else { res.skipped.append(store.versions[id]?.name ?? id); continue }
            let ext = doc.imagePreset == "png" ? "png" : "jpg"; let base = String(format: "%04d", n + 1)
            let iname = "images/\(base).\(ext)", tname = "thumbs/\(base).jpg"
            guard write(big, folder.appendingPathComponent(iname), q: ip.2, png: ext == "png") else { res.skipped.append(id); continue }
            if let th = store.renderedImage(id, maxPixel: Int(tp.1)) { _ = write(th, folder.appendingPathComponent(tname), q: tp.2, png: false) }
            files[id] = (iname, tname, big.width, big.height); res.images += 1
        }
        progress?(ids.count, ids.count)
        let css = """
        body{margin:0;background:\(look.bg);color:\(look.fg);font-family:\(look.font)}a{color:\(look.accent);text-decoration:none}header{padding:24px 32px}h1{margin:0;font-weight:normal}
        .grid{display:grid;grid-template-columns:repeat(\(max(1, doc.columns)),1fr);gap:16px;padding:0 32px 32px}.card{background:\(look.cardBg);text-align:center;padding:8px}.card img{max-width:100%;border:\(look.thumbBorder)}
        .cap{font-size:12px;margin-top:6px}.page{max-width:1100px;margin:0 auto;padding:24px;text-align:center}.page img{max-width:100%}.nav{margin:12px 0}.journal{max-width:820px;margin:0 auto;padding:0 24px 40px}.journal img{max-width:100%;margin:16px 0}
        """
        try css.write(to: folder.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        func caption(_ id: ID) -> String { guard doc.showCaptions, let v = store.versions[id] else { return "" }; var s = "<div class=\"cap\">\(esc(v.name))" + (v.caption.isEmpty ? "" : " – \(esc(v.caption))") + "</div>"
            if doc.showMetadata, let m = store.masters[v.masterID] { let ex = ExifReader.values(for: store.masterURL(m), master: m, isMissing: false, version: v); s += "<div class=\"cap\">" + esc([ex["exif.camera"], ex["exif.aperture"], ex["exif.shutter"], ex["exif.iso"].map { "ISO " + $0 }].compactMap { $0 }.joined(separator: " · ")) + "</div>" }; return s }
        let copyright = (UserDefaults.standard.string(forKey: "webCopyright") ?? "").trimmingCharacters(in: .whitespaces)
        let foot = copyright.isEmpty ? "" : "<footer class=\"copyright\">\(esc(copyright))</footer>"
        var html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(esc(doc.title))</title><link rel=\"stylesheet\" href=\"style.css\"></head><body><header><h1>\(esc(doc.title))</h1></header>"
        if doc.blocks.isEmpty {
            html += "<div class=\"grid\">"
            for (n, id) in ids.enumerated() { guard let f = files[id] else { continue }; html += "<div class=\"card\"><a href=\"page\(n + 1).html\"><img src=\"\(f.thumb)\" alt=\"\(esc(store.versions[id]?.name ?? ""))\"></a>\(caption(id))</div>" }
            html += "</div>"
            let valid = ids.enumerated().filter { files[$0.element] != nil }.map(\.offset)
            for (k, n) in valid.enumerated() {
                let id = ids[n]; let f = files[id]!
                let prev = k > 0 ? "<a href=\"page\(valid[k - 1] + 1).html\">‹ prev</a>" : "", next = k < valid.count - 1 ? "<a href=\"page\(valid[k + 1] + 1).html\">next ›</a>" : ""
                let orig = doc.includeOriginalsLink ? "" : ""
                let page = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(esc(store.versions[id]?.name ?? ""))</title><link rel=\"stylesheet\" href=\"style.css\"></head><body><div class=\"page\"><div class=\"nav\">\(prev) <a href=\"index.html\">index</a> \(next)</div><img src=\"\(f.img)\" width=\"\(f.w)\" height=\"\(f.h)\">\(caption(id))\(orig)</div></body></html>"
                try page.replacingOccurrences(of: "</body></html>", with: foot + "</body></html>").write(to: folder.appendingPathComponent("page\(n + 1).html"), atomically: true, encoding: .utf8)
            }
        } else {
            html += "<div class=\"journal\">"; var imgCounter = 0
            for b in doc.blocks {
                switch b.kind {
                case .heading: html += "<h2>\(esc(b.text))</h2>"
                case .text: html += b.text.split(separator: "\n").map { "<p>\(esc(String($0)))</p>" }.joined()
                case .image: if let id = b.versionID, let f = files[id] { imgCounter += 1; html += "<img src=\"\(f.img)\" alt=\"\(esc(store.versions[id]?.name ?? ""))\">\(caption(id))" }
                }
            }
            html += "</div>"
        }
        html += foot + "</body></html>"
        try html.write(to: res.index, atomically: true, encoding: .utf8)
        return res
    }
}

// MARK: - slideshow → movie
public enum SlideshowExporter {
    public struct Preset: Sendable { public let name: String; public let width: Int, height: Int; public let fps: Int
        public static let all: [Preset] = [.init(name: "480p (SD)", width: 854, height: 480, fps: 24), .init(name: "720p (HD)", width: 1280, height: 720, fps: 30), .init(name: "1080p (Full HD)", width: 1920, height: 1080, fps: 30)] }

    /// Frame at time `t` of a slide pair: dissolve/fade between slides, optional Ken Burns on the shown slide.
    static func frame(slides: [(img: CIImage, dur: Double, kb: ([Double], [Double])?)], t: Double, fade: Double, kenBurns: Bool, bg: CGFloat, size: CGSize, fadeToBlack: Bool) -> CIImage {
        var start = 0.0; var idx = 0
        for (i, s) in slides.enumerated() { if t < start + s.dur || i == slides.count - 1 { idx = i; break }; start += s.dur }
        let s = slides[idx]; let local = t - start
        func place(_ s: (img: CIImage, dur: Double, kb: ([Double], [Double])?), _ lt: Double) -> CIImage {
            let e = s.img.extent; var rect = CGRect(x: 0, y: 0, width: e.width, height: e.height)
            if kenBurns || s.kb != nil {
                let f = max(0, min(1, lt / max(0.1, s.dur)))
                let a = s.kb?.0 ?? [0, 0, 1, 1], b = s.kb?.1 ?? [0.08, 0.08, 0.84, 0.84]
                let v = (0..<4).map { a[$0] + (b[$0] - a[$0]) * f }
                rect = CGRect(x: e.width * v[0], y: e.height * (1 - v[1] - v[3]), width: e.width * v[2], height: e.height * v[3])
            }
            let c = s.img.cropped(to: rect); let sc = min(size.width / rect.width, size.height / rect.height)
            let t = CGAffineTransform(translationX: -rect.minX, y: -rect.minY).concatenating(CGAffineTransform(scaleX: sc, y: sc)).concatenating(CGAffineTransform(translationX: (size.width - rect.width * sc) / 2, y: (size.height - rect.height * sc) / 2))
            return c.transformed(by: t)
        }
        let canvas = CIImage(color: CIColor(red: bg, green: bg, blue: bg)).cropped(to: CGRect(origin: .zero, size: size))
        var cur = place(s, local).composited(over: canvas).cropped(to: CGRect(origin: .zero, size: size))
        if fade > 0, local < fade, idx > 0 {              // cross-fade from the previous slide at the start of this one
            let prev = slides[idx - 1]; let p = place(prev, prev.dur + local).composited(over: canvas).cropped(to: CGRect(origin: .zero, size: size))
            let a = CGFloat(local / fade)
            let from: CIImage = fadeToBlack ? CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size)) : p
            if fadeToBlack { cur = a < 0.5 ? p.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -2 * a]) : cur.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -(2 - 2 * a)]); _ = from }
            else { let d = CIFilter(name: "CIDissolveTransition")!; d.setValue(p, forKey: kCIInputImageKey); d.setValue(cur, forKey: kCIInputTargetImageKey); d.setValue(a, forKey: kCIInputTimeKey); cur = d.outputImage ?? cur }
        }
        return cur
    }

    /// Renders the slideshow to an .mov (H.264) with the soundtrack mixed in. Styles other than Classic/Ken Burns are exported with
    /// the Classic dissolve – their live 3D transitions exist only in playback.
    public static func export(_ ids: [ID], settings: SlideshowSettings, store: LibraryStore, preset: Preset, to url: URL, progress: ((Double) -> Void)? = nil) throws -> (seconds: Double, note: String) {
        let size = CGSize(width: preset.width, height: preset.height)
        var order = ids; if settings.shuffle { order.shuffle() }
        var slides: [(CIImage, Double, ([Double], [Double])?)] = []
        for id in order {
            guard let cg = store.renderedImage(id, maxPixel: max(preset.width, preset.height) * 2) else { continue }
            let o = settings.overrides[id]; var kb: ([Double], [Double])? = nil
            if let a = o?.kenBurnsStart, let b = o?.kenBurnsEnd, a.count == 4, b.count == 4 { kb = (a, b) }
            slides.append((CIImage(cgImage: cg), settings.duration(for: id), kb))
        }
        guard !slides.isEmpty else { throw NSError(domain: "Slideshow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No slides"]) }
        let total = slides.reduce(0) { $0 + $1.1 }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".rl-\(UUID().uuidString).mov"); try? FileManager.default.removeItem(at: url)
        let w = try AVAssetWriter(outputURL: settings.songs.isEmpty ? url : tmp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: preset.width, AVVideoHeightKey: preset.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: preset.width, kCVPixelBufferHeightKey as String: preset.height])
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        let ctx = CIContext(); let frames = Int(total * Double(preset.fps)); let kbOn = settings.style == .kenBurns
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            let t = Double(f) / Double(preset.fps)
            let img = frame(slides: slides, t: t, fade: min(settings.fadeTime, slides.first!.1 * 0.8), kenBurns: kbOn, bg: CGFloat(settings.background), size: size, fadeToBlack: settings.transition == "Fade")
            var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            if let pb { ctx.render(img, to: pb); adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(preset.fps))) }
            if f % 15 == 0 { progress?(Double(f) / Double(max(1, frames))) }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); w.finishWriting { sem.signal() }; sem.wait()
        guard w.status == .completed else { throw w.error ?? NSError(domain: "Slideshow", code: 2) }
        var note = settings.style.fixedTransition ? "Style \(settings.style.title) is exported with the Classic dissolve." : ""
        if !settings.songs.isEmpty {
            // mix the soundtrack (looped / cut to length) into the movie
            let comp = AVMutableComposition()
            let vAsset = AVURLAsset(url: tmp)
            if let vt = vAsset.tracks(withMediaType: .video).first, let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) { try ct.insertTimeRange(CMTimeRange(start: .zero, duration: vAsset.duration), of: vt, at: .zero) }
            let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var cursor = CMTime.zero; let end = vAsset.duration; var guardN = 0
            while cursor < end, guardN < 200 { for s in settings.songs { guardN += 1
                let a = AVURLAsset(url: URL(fileURLWithPath: s)); guard let t = a.tracks(withMediaType: .audio).first else { continue }
                let d = min(a.duration, end - cursor); try? at?.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: t, at: cursor); cursor = cursor + d; if cursor >= end { break } }
                if !settings.loopSoundtrack { break } }
            let mix = AVMutableAudioMix(); if let at { let p = AVMutableAudioMixInputParameters(track: at); p.setVolume(Float(settings.musicVolume), at: .zero); p.setVolumeRamp(fromStartVolume: Float(settings.musicVolume), toEndVolume: 0, timeRange: CMTimeRange(start: max(.zero, end - CMTime(seconds: 2, preferredTimescale: 600)), duration: CMTime(seconds: 2, preferredTimescale: 600))); mix.inputParameters = [p] }
            guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw NSError(domain: "Slideshow", code: 3) }
            ex.outputURL = url; ex.outputFileType = .mov; ex.audioMix = mix
            let sem2 = DispatchSemaphore(value: 0); ex.exportAsynchronously { sem2.signal() }; sem2.wait()
            try? FileManager.default.removeItem(at: tmp)
            guard ex.status == .completed else { throw ex.error ?? NSError(domain: "Slideshow", code: 4) }
            note += (note.isEmpty ? "" : " ") + "Soundtrack mixed in."
        }
        progress?(1); return (total, note)
    }
}
