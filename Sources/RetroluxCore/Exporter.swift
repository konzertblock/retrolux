import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CoreText
import AppKit

/// The 17 factory export presets. PSD is written as 16-bit TIFF
/// (ImageIO cannot write PSD); the preset keeps its original name and reports the substitution.
public struct ExportPreset: Identifiable, Hashable, Sendable, Codable {
    public enum Format: String, Hashable, Sendable, Codable, CaseIterable { case jpeg, png, tiff, psd }
    public enum Unit: String, Hashable, Sendable, Codable { case pixels, inches, centimeters }
    public enum Size: Hashable, Sendable, Codable { case original, percent(Int), fit(Int), box(width: Double, height: Double, unit: Unit) }
    public var id: String { name }
    public var name: String
    public var format: Format
    public var size: Size
    public var deep: Bool
    public var quality: Double = 0.9
    public var includeMetadata = true
    public var dpi = 72
    public var isCustom = false
    public init(name: String, format: Format, size: Size, deep: Bool, quality: Double = 0.9, includeMetadata: Bool = true) { self.name = name; self.format = format; self.size = size; self.deep = deep; self.quality = quality; self.includeMetadata = includeMetadata }

    /// Longest edge in pixels for a master of the given size, nil = keep original size.
    public func maxPixel(for orig: CGSize) -> Int? {
        let long = max(orig.width, orig.height)
        switch size {
        case .original: return nil
        case .percent(let p): return max(1, Int(long * Double(p) / 100))
        case .fit(let f): return f
        case .box(let w, let h, let u):
            let k: Double = u == .pixels ? 1 : (u == .inches ? Double(dpi) : Double(dpi) / 2.54)
            guard w > 0, h > 0, orig.width > 0, orig.height > 0 else { return nil }
            return max(1, Int(long * min(w * k / orig.width, h * k / orig.height)))
        }
    }

    /// Custom presets live in UserDefaults next to the 17 factory ones (Retrolux ▸ Presets ▸ Image Export…).
    public static var custom: [ExportPreset] {
        get { (UserDefaults.standard.data(forKey: "customExportPresets")).flatMap { try? JSONDecoder().decode([ExportPreset].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "customExportPresets") }
    }
    public static var all: [ExportPreset] { factory + custom }

    public static let factory: [ExportPreset] = [
        .init(name: "Email Small - JPEG", format: .jpeg, size: .fit(320), deep: false, quality: 0.7),
        .init(name: "Email Medium - JPEG", format: .jpeg, size: .fit(640), deep: false, quality: 0.8),
        .init(name: "Email Original Size - JPEG", format: .jpeg, size: .original, deep: false, quality: 0.8),
        .init(name: "JPEG - 50% of Original Size", format: .jpeg, size: .percent(50), deep: false),
        .init(name: "JPEG - Fit within 1024 x 1024", format: .jpeg, size: .fit(1024), deep: false),
        .init(name: "JPEG - Fit within 640 x 640", format: .jpeg, size: .fit(640), deep: false),
        .init(name: "JPEG - Original Size", format: .jpeg, size: .original, deep: false, quality: 1.0),
        .init(name: "PNG - 50% of Original Size", format: .png, size: .percent(50), deep: false),
        .init(name: "PNG - Fit within 1024 x 1024", format: .png, size: .fit(1024), deep: false),
        .init(name: "PNG - Fit within 640 x 640", format: .png, size: .fit(640), deep: false),
        .init(name: "PNG - Original Size", format: .png, size: .original, deep: false),
        .init(name: "PSD - 50% of Original Size (16-bit)", format: .psd, size: .percent(50), deep: true),
        .init(name: "PSD - Original Size (16-bit)", format: .psd, size: .original, deep: true),
        .init(name: "TIFF - 50% of Original Size", format: .tiff, size: .percent(50), deep: false),
        .init(name: "TIFF - Fit within 1024 x 1024", format: .tiff, size: .fit(1024), deep: false),
        .init(name: "TIFF - Original Size (16-bit)", format: .tiff, size: .original, deep: true),
        .init(name: "TIFF - Original Size (8-bit)", format: .tiff, size: .original, deep: false),
    ]
    public var fileExtension: String { switch format { case .jpeg: return "jpg"; case .png: return "png"; case .tiff, .psd: return "tif" } }
    public var substitutes: Bool { format == .psd }
}

/// File name formats offered by the Name Format menu. Elements are joined by single spaces except where noted.
public enum NamingPolicy: String, CaseIterable, Sendable {
    case versionName = "Version Name", versionNameDate = "Version Name and Date/Time", versionNameIndex = "Version Name with Index"
    case versionNameSequence = "Version Name with Sequence", imageDate = "Image Date/Time"
    case customName = "Custom Name", customCounter = "Custom Name with Counter", customIndex = "Custom Name with Index", customIndexNoSpaces = "Custom Name with Index (no spaces)"
    public var needsCustomName: Bool { [.customName, .customCounter, .customIndex, .customIndexNoSpaces].contains(self) }

    /// `index` is 1-based within the export, `count` the number of exported items.
    public func fileName(version v: Version, index: Int, count: Int, custom: String) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"; let d = df.string(from: v.imageDate)
        df.dateFormat = "HH.mm.ss"; let t = df.string(from: v.imageDate)
        switch self {
        case .versionName: return v.name
        case .versionNameDate: return "\(v.name) - \(d) at \(t)"
        case .versionNameIndex: return "\(v.name) \(index)"
        case .versionNameSequence: return "\(v.name) \(index) of \(count)"
        case .imageDate: return "\(d) at \(t)"
        case .customName: return custom
        case .customCounter: return custom + " " + String(format: "%03d", index)
        case .customIndex: return "\(custom) \(index)"
        case .customIndexNoSpaces: return "\(custom)\(index)"
        }
    }
}

/// Subfolder Format menu: "None" plus the factory folder naming policies.
public enum SubfolderPolicy: String, CaseIterable, Sendable {
    case none = "None"
    case currentDate = "Current Date", currentMonthDay = "Current Month/Day", currentYearMonth = "Current Year/Month", currentYearMonthDay = "Current Year/Month/Day"
    case imageMonthDay = "Image Month/Day", imageYearMonth = "Image Year/Month", imageYearMonthDay = "Image Year/Month/Day"
    case customName = "Custom Name", customCounter = "Custom Name with Counter"
    public var needsCustomName: Bool { self == .customName || self == .customCounter }

    /// Relative folder path ("2010/03/24"), nil for `.none`.
    public func path(version v: Version, index: Int, custom: String, now: Date = Date()) -> String? {
        func f(_ fmt: String, _ date: Date) -> String { let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = fmt; return df.string(from: date) }
        switch self {
        case .none: return nil
        case .currentDate: return f("yyyy-MM-dd", now)
        case .currentMonthDay: return f("MM/dd", now)
        case .currentYearMonth: return f("yyyy/MM", now)
        case .currentYearMonthDay: return f("yyyy/MM/dd", now)
        case .imageMonthDay: return f("MM/dd", v.imageDate)
        case .imageYearMonth: return f("yyyy/MM", v.imageDate)
        case .imageYearMonthDay: return f("yyyy/MM/dd", v.imageDate)
        case .customName: return custom
        case .customCounter: return custom + " " + String(format: "%03d", index)
        }
    }
}

public struct ExportOptions: Sendable {
    public var includeKeywords = true, includeCaption = true, includeLocation = true
    public var includePeople = false            // names from Faces are never published unless the user asks for it
    public var includeCreditFields = true
    public var writeSidecar = false
    public var profile = "sRGB IEC61966-2.1"       // embedded output profile
    public var watermark: Watermark? = nil
    public init() {}
}
public struct Watermark: Sendable {
    public var text: String; public var opacity = 0.5; public var sizeFraction = 0.04; public var position = 8   // 0…8 as a 3×3 grid, 8 = bottom right
    public init(text: String) { self.text = text }
}

public struct ExportResult: Sendable { public var written: [URL] = []; public var failed: [(String, String)] = []; public var notes: [String] = [] }

public final class Exporter {
    let store: LibraryStore
    let engine: RenderEngine
    public init(store: LibraryStore, engine: RenderEngine = .shared) { self.store = store; self.engine = engine }

    /// Never overwrites silently: existing names get a numeric suffix.
    public static func unique(_ url: URL) -> URL {
        var u = url, n = 1
        while FileManager.default.fileExists(atPath: u.path) { n += 1; u = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(n).\(url.pathExtension)") }
        return u
    }

    public func export(_ ids: [ID], preset: ExportPreset, to folder: URL, naming: NamingPolicy = .versionName, custom: String = "Image", subfolder: SubfolderPolicy = .none, customSubfolder: String = "Folder", options: ExportOptions = ExportOptions(),
                       progress: ((Int, Int) -> Void)? = nil) throws -> ExportResult {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var res = ExportResult()
        if preset.substitutes { res.notes.append("PSD is written as 16-bit TIFF (ImageIO cannot write PSD).") }
        for (i, id) in ids.enumerated() {
            progress?(i, ids.count)
            guard let v = store.versions[id], let m = store.masters[v.masterID], m.kind == .image else { continue }
            let url = store.masterURL(m)
            let orig = CGSize(width: m.width, height: m.height)
            let mp = preset.maxPixel(for: orig)
            let req = RenderRequest(url: url, isRaw: m.isRaw, originalSize: orig, rotation: v.rotation, adjustments: store.adjustments(for: id), maxPixel: mp)
            let outSpace = ColorProfiles.space(named: options.profile)
            guard var cg = engine.renderCG(req, deep: preset.deep, colorSpace: outSpace) else { res.failed.append((v.name, "render failed")); continue }
            if let w = options.watermark, let marked = Exporter.applyWatermark(cg, w) { cg = marked }
            let base = naming.fileName(version: v, index: i + 1, count: ids.count, custom: custom)
            let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            var dir = folder
            if let sub = subfolder.path(version: v, index: i + 1, custom: customSubfolder) {
                for part in sub.split(separator: "/") { dir.appendPathComponent(String(part).replacingOccurrences(of: ":", with: "-")) }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let out = Exporter.unique(dir.appendingPathComponent(safe + "." + preset.fileExtension))
            let type: UTType = preset.format == .jpeg ? .jpeg : preset.format == .png ? .png : .tiff
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { res.failed.append((v.name, "cannot create destination")); continue }
            var props: [CFString: Any] = [:]
            if preset.dpi != 72 { props[kCGImagePropertyDPIWidth] = preset.dpi; props[kCGImagePropertyDPIHeight] = preset.dpi }
            if preset.format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = preset.quality }
            if preset.includeMetadata {
                var iptc: [CFString: Any] = [:]
                var kws = options.includeKeywords ? v.keywords : []
                if options.includePeople { kws += store.peopleNames(of: v.id).filter { !kws.contains($0) } }
                if !kws.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = kws }
                if options.includeCaption, !v.caption.isEmpty { iptc[kCGImagePropertyIPTCCaptionAbstract] = v.caption }
                if options.includeCreditFields {
                    if let x = v.meta["iptc.creator"] { iptc[kCGImagePropertyIPTCByline] = [x] }
                    if let x = v.meta["iptc.copyright"] { iptc[kCGImagePropertyIPTCCopyrightNotice] = x }
                    if let x = v.meta["iptc.credit"] { iptc[kCGImagePropertyIPTCCredit] = x }
                    if let x = v.meta["iptc.title"] { iptc[kCGImagePropertyIPTCObjectName] = x }
                }
                if !iptc.isEmpty { props[kCGImagePropertyIPTCDictionary] = iptc }
                if options.includeLocation, let la = v.latitude, let lo = v.longitude {
                    props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: abs(la), kCGImagePropertyGPSLatitudeRef: la < 0 ? "S" : "N", kCGImagePropertyGPSLongitude: abs(lo), kCGImagePropertyGPSLongitudeRef: lo < 0 ? "W" : "E"]
                }
            }
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
            if CGImageDestinationFinalize(dest) { res.written.append(out); if options.writeSidecar { _ = try? MetadataWriter.writeSidecar(for: v, nextTo: out, location: options.includeLocation, keywords: options.includeKeywords, caption: options.includeCaption) } } else { res.failed.append((v.name, "write failed")) }
        }
        progress?(ids.count, ids.count)
        return res
    }

    /// Draws a text watermark (3×3 grid position, relative size) onto the rendered image.
    static func applyWatermark(_ cg: CGImage, _ w: Watermark) -> CGImage? {
        let W = cg.width, H = cg.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: cg.bitsPerComponent >= 16 ? 16 : 8, bytesPerRow: 0, space: cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | (cg.bitsPerComponent >= 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        let size = CGFloat(min(W, H)) * CGFloat(w.sizeFraction)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor(gray: 1, alpha: CGFloat(w.opacity))]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: w.text, attributes: attrs))
        let b = CTLineGetBoundsWithOptions(line, [])
        let col = w.position % 3, row = w.position / 3          // row 0 = top
        let m = size
        let x = col == 0 ? m : (col == 1 ? (CGFloat(W) - b.width) / 2 : CGFloat(W) - b.width - m)
        let y = row == 0 ? CGFloat(H) - b.height - m : (row == 1 ? (CGFloat(H) - b.height) / 2 : m)
        ctx.setShadow(offset: CGSize(width: 1, height: -1), blur: size * 0.1, color: CGColor(gray: 0, alpha: CGFloat(w.opacity)))
        ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// Original export: copies the master bytes untouched.
    public func exportOriginals(_ ids: [ID], to folder: URL) throws -> ExportResult {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var res = ExportResult()
        for id in ids {
            guard let v = store.versions[id], let m = store.masters[v.masterID] else { continue }
            let src = store.masterURL(m)
            let dst = Exporter.unique(folder.appendingPathComponent(m.originalName.isEmpty ? src.lastPathComponent : m.originalName))
            do { try FileManager.default.copyItem(at: src, to: dst); res.written.append(dst) } catch { res.failed.append((v.name, error.localizedDescription)) }
            if let c = store.companionURL(for: v), FileManager.default.fileExists(atPath: c.path) {       // the other file of a RAW+JPEG pair travels with the master
                let cdst = Exporter.unique(folder.appendingPathComponent(c.lastPathComponent))
                do { try FileManager.default.copyItem(at: c, to: cdst); res.written.append(cdst) } catch { res.failed.append((v.name + " (companion)", error.localizedDescription)) }
            }
        }
        return res
    }
}
