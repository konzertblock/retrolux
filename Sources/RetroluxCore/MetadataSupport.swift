import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Editable / displayable metadata fields. `iptc` keys are written to originals only by the explicit "Write IPTC to Master" action.
public struct MetadataField: Identifiable, Hashable, Sendable {
    public enum Group: String, Sendable { case general, iptc, exif, file, gps }
    public let id: String, en: String, de: String, group: Group, editable: Bool
    public init(_ id: String, _ en: String, _ de: String, _ g: Group, editable: Bool = false) { self.id = id; self.en = en; self.de = de; group = g; self.editable = editable }

    public static let all: [MetadataField] = [
        .init("name", "Name", "Name", .general, editable: true), .init("caption", "Caption", "Beschriftung", .general, editable: true),
        .init("rating", "Rating", "Bewertung", .general), .init("label", "Label", "Etikett", .general), .init("flag", "Flag", "Markierung", .general),
        .init("keywords", "Keywords", "Schlagwörter", .general), .init("people", "People", "Personen", .general), .init("date", "Image Date", "Aufnahmedatum", .general), .init("version", "Version", "Version", .general),
        .init("iptc.title", "Title", "Titel", .iptc, editable: true), .init("iptc.creator", "Creator", "Urheber", .iptc, editable: true),
        .init("iptc.creatorTitle", "Creator Job Title", "Berufsbezeichnung", .iptc, editable: true), .init("iptc.credit", "Credit", "Kredit", .iptc, editable: true),
        .init("iptc.source", "Source", "Quelle", .iptc, editable: true), .init("iptc.copyright", "Copyright Notice", "Copyright-Vermerk", .iptc, editable: true),
        .init("iptc.instructions", "Instructions", "Anweisungen", .iptc, editable: true), .init("iptc.city", "City", "Stadt", .iptc, editable: true),
        .init("iptc.state", "State/Province", "Bundesland", .iptc, editable: true), .init("iptc.country", "Country", "Land", .iptc, editable: true),
        .init("iptc.location", "Sublocation", "Ort", .iptc, editable: true), .init("iptc.contact", "Contact", "Kontakt", .iptc, editable: true),
        .init("exif.camera", "Camera", "Kamera", .exif), .init("exif.lens", "Lens", "Objektiv", .exif), .init("exif.focal", "Focal Length", "Brennweite", .exif),
        .init("exif.aperture", "Aperture", "Blende", .exif), .init("exif.shutter", "Shutter Speed", "Verschlusszeit", .exif), .init("exif.iso", "ISO", "ISO", .exif),
        .init("exif.bias", "Exposure Bias", "Belichtungskorrektur", .exif), .init("exif.flash", "Flash", "Blitz", .exif), .init("exif.wb", "White Balance", "Weißabgleich", .exif),
        .init("exif.metering", "Metering", "Messung", .exif), .init("exif.colorspace", "Color Space", "Farbraum", .exif),
        .init("file.name", "File Name", "Dateiname", .file), .init("file.size", "File Size", "Dateigröße", .file), .init("file.dims", "Dimensions", "Abmessungen", .file),
        .init("file.type", "File Type", "Dateityp", .file), .init("file.path", "Path", "Pfad", .file), .init("file.status", "Status", "Status", .file),
        .init("gps.coords", "Coordinates", "Koordinaten", .gps), .init("gps.altitude", "Altitude", "Höhe", .gps),
    ]
    public static func field(_ id: String) -> MetadataField? { all.first { $0.id == id } }
    public static var editableIPTC: [MetadataField] { all.filter { $0.group == .iptc } }
}

/// A saved list of metadata fields shown in the Metadata inspector.
public struct MetadataView: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var fields: [String]
    public var factory = false
    public init(name: String, fields: [String], factory: Bool = false) { self.name = name; self.fields = fields; self.factory = factory }
    public static let factoryViews: [MetadataView] = [
        .init(name: "Name Only", fields: ["name"], factory: true), .init(name: "Caption Only", fields: ["caption"], factory: true),
        .init(name: "Name & Rating", fields: ["name", "rating"], factory: true), .init(name: "Caption & Name", fields: ["caption", "name"], factory: true),
        .init(name: "Caption & Keywords", fields: ["caption", "keywords"], factory: true), .init(name: "Caption & Credits", fields: ["caption", "iptc.creator", "iptc.credit", "iptc.copyright"], factory: true),
        .init(name: "Photo Info", fields: ["name", "rating", "label", "flag", "date", "iptc.title", "iptc.creator", "iptc.copyright", "keywords"], factory: true),
        .init(name: "EXIF Info", fields: ["exif.camera", "exif.lens", "exif.focal", "exif.aperture", "exif.shutter", "exif.iso", "exif.bias", "exif.flash", "exif.wb", "exif.metering", "exif.colorspace"], factory: true),
        .init(name: "File Info", fields: ["file.name", "file.type", "file.dims", "file.size", "file.path", "file.status"], factory: true),
        .init(name: "GPS", fields: ["gps.coords", "gps.altitude", "iptc.city", "iptc.country"], factory: true),
    ]
}

public struct MetadataPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: ID = newID()
    public var name: String
    public var fields: [String: String]
    public init(name: String, fields: [String: String]) { self.name = name; self.fields = fields }
}

public struct KeywordSet: Codable, Identifiable, Equatable, Sendable {
    public var id: ID = newID()
    public var name: String
    public var keywords: [String]            // up to 9 quick-assign slots (⌥1…⌥9)
    public init(name: String, keywords: [String]) { self.name = name; self.keywords = keywords }
}

/// JSON-backed collections next to the library: metadata views, metadata presets, keyword sets, autofill lists.
public final class MetadataConfig {
    public struct Data_: Codable { var views: [MetadataView] = []; var presets: [MetadataPreset] = []; var keywordSets: [KeywordSet] = []; var activeKeywordSet = 0; var autofill: [String: [String]] = [:] }
    let url: URL
    public private(set) var data = Data_()
    public init(libraryRoot: URL) {
        url = libraryRoot.appendingPathComponent("MetadataConfig.json")
        if let d = try? Data(contentsOf: url), let x = try? JSONDecoder().decode(Data_.self, from: d) { data = x }
        if data.keywordSets.isEmpty { data.keywordSets = [KeywordSet(name: "Default", keywords: [])] }
    }
    public func save() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(data).write(to: url, options: .atomic) }
    public var views: [MetadataView] { MetadataView.factoryViews + data.views }
    public func addView(_ v: MetadataView) { data.views.removeAll { $0.name == v.name }; data.views.append(v); save() }
    public func removeView(_ name: String) { data.views.removeAll { $0.name == name }; save() }
    public var presets: [MetadataPreset] { data.presets }
    public func addPreset(_ p: MetadataPreset) { data.presets.removeAll { $0.name == p.name }; data.presets.append(p); save() }
    public func removePreset(_ id: ID) { data.presets.removeAll { $0.id == id }; save() }
    public var keywordSets: [KeywordSet] { get { data.keywordSets } set { data.keywordSets = newValue; save() } }
    public var activeKeywordSet: Int { get { min(data.activeKeywordSet, max(0, data.keywordSets.count - 1)) } set { data.activeKeywordSet = newValue; save() } }
    public func autofill(_ field: String) -> [String] { data.autofill[field] ?? [] }
    public func setAutofill(_ field: String, _ values: [String]) { data.autofill[field] = values; save() }
    public func rememberAutofill(_ field: String, _ value: String) {
        guard !value.isEmpty else { return }; var l = data.autofill[field] ?? []; l.removeAll { $0 == value }; l.insert(value, at: 0); data.autofill[field] = Array(l.prefix(30)); save()
    }
}

public enum BatchMode: String, CaseIterable, Sendable { case replace, append, setIfEmpty }
public struct BatchChange: Sendable {
    public var fields: [String: String] = [:]               // metadata field id → value (name/caption/iptc.*)
    public var mode: BatchMode = .replace
    public var nameTemplate: String? = nil                  // "Trip {n}" / "{name}-{date}"
    public var counterStart = 1
    public var dateShiftSeconds: TimeInterval = 0
    public var keywordsToAdd: [String] = []
    public init() {}
}

public extension LibraryStore {
    /// Applies a batch change in one transaction. Returns number of changed versions.
    @discardableResult func batchChange(_ ids: [ID], _ ch: BatchChange) throws -> Int {
        var n = ch.counterStart
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        try update(ids) { v in
            for (k, val) in ch.fields {
                func merge(_ old: String) -> String {
                    switch ch.mode { case .replace: return val; case .append: return old.isEmpty ? val : old + " " + val; case .setIfEmpty: return old.isEmpty ? val : old }
                }
                switch k { case "name": v.name = merge(v.name); case "caption": v.caption = merge(v.caption); default: v.meta[k] = merge(v.meta[k] ?? "") }
            }
            if let t = ch.nameTemplate, !t.isEmpty {
                v.name = t.replacingOccurrences(of: "{n}", with: String(n)).replacingOccurrences(of: "{nn}", with: String(format: "%02d", n)).replacingOccurrences(of: "{name}", with: v.name).replacingOccurrences(of: "{date}", with: df.string(from: v.imageDate))
                n += 1
            }
            if ch.dateShiftSeconds != 0 { if v.originalImageDate == nil { v.originalImageDate = v.imageDate }; v.imageDate = v.imageDate.addingTimeInterval(ch.dateShiftSeconds) }
            for k in ch.keywordsToAdd where !v.keywords.contains(k) { v.keywords.append(k) }
        }
        return ids.count
    }
    func restoreOriginalDate(_ ids: [ID]) throws { try update(ids) { if let o = $0.originalImageDate { $0.imageDate = o; $0.originalImageDate = nil } } }

    /// Renames a keyword path (and all descendants) everywhere.
    func renameKeyword(_ old: String, to new: String) throws {
        let ids = versions.values.filter { $0.keywords.contains { $0 == old || $0.hasPrefix(old + "/") } }.map(\.id)
        try update(ids) { v in v.keywords = v.keywords.map { $0 == old ? new : ($0.hasPrefix(old + "/") ? new + $0.dropFirst(old.count) : $0) } }
    }
    func deleteKeyword(_ path: String) throws {
        let ids = versions.values.filter { $0.keywords.contains { $0 == path || $0.hasPrefix(path + "/") } }.map(\.id)
        try update(ids) { v in v.keywords.removeAll { $0 == path || $0.hasPrefix(path + "/") } }
    }
    /// Re-reads date, GPS and pixel size from the original ("Update from Master").
    @discardableResult func updateFromMaster(_ ids: [ID]) throws -> Int {
        var n = 0
        try update(ids) { v in
            guard let m = masters[v.masterID], let p = RenderEngine.probe(url: masterURL(m)) else { return }
            if let d = p.date { v.imageDate = d; v.originalImageDate = nil }
            v.latitude = p.lat ?? v.latitude; v.longitude = p.lon ?? v.longitude; n += 1
        }
        return n
    }
}

public enum MetadataWriter {
    static func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }

    /// XMP packet for a version (rating, label, title/description, keywords, creator/copyright, GPS).
    public static func xmp(for v: Version, includeLocation: Bool = true, includeKeywords: Bool = true, includeCaption: Bool = true) -> String {
        var s = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        s += "<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\" xmlns:exif=\"http://ns.adobe.com/exif/1.0/\" xmlns:Iptc4xmpCore=\"http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/\""
        s += " xmp:Rating=\"\(v.rating < 0 ? -1 : v.rating)\" xmp:Label=\"\(xml(v.colorLabel > 0 ? Labels.names[v.colorLabel] : ""))\" xmp:CreatorTool=\"Retrolux\""
        if let c = v.meta["iptc.city"] { s += " photoshop:City=\"\(xml(c))\"" }
        if let c = v.meta["iptc.state"] { s += " photoshop:State=\"\(xml(c))\"" }
        if let c = v.meta["iptc.country"] { s += " photoshop:Country=\"\(xml(c))\"" }
        if let c = v.meta["iptc.credit"] { s += " photoshop:Credit=\"\(xml(c))\"" }
        if let c = v.meta["iptc.source"] { s += " photoshop:Source=\"\(xml(c))\"" }
        s += ">\n"
        if let t = v.meta["iptc.title"] ?? Optional(v.name) { s += "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(xml(t))</rdf:li></rdf:Alt></dc:title>\n" }
        if includeCaption, !v.caption.isEmpty { s += "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(xml(v.caption))</rdf:li></rdf:Alt></dc:description>\n" }
        if let c = v.meta["iptc.creator"] { s += "<dc:creator><rdf:Seq><rdf:li>\(xml(c))</rdf:li></rdf:Seq></dc:creator>\n" }
        if let c = v.meta["iptc.copyright"] { s += "<dc:rights><rdf:Alt><rdf:li xml:lang=\"x-default\">\(xml(c))</rdf:li></rdf:Alt></dc:rights>\n" }
        if includeKeywords, !v.keywords.isEmpty { s += "<dc:subject><rdf:Bag>" + v.keywords.map { "<rdf:li>\(xml($0))</rdf:li>" }.joined() + "</rdf:Bag></dc:subject>\n" }
        if includeLocation, let la = v.latitude, let lo = v.longitude {
            func dm(_ x: Double, _ pos: String, _ neg: String) -> String { let a = abs(x), d = Int(a), m = (a - Double(d)) * 60; return String(format: "%d,%.4f%@", d, m, x < 0 ? neg : pos) }
            s += "<exif:GPSLatitude>\(dm(la, "N", "S"))</exif:GPSLatitude><exif:GPSLongitude>\(dm(lo, "E", "W"))</exif:GPSLongitude>\n"
        }
        s += "</rdf:Description></rdf:RDF></x:xmpmeta>\n<?xpacket end=\"w\"?>\n"
        return s
    }
    public static func writeSidecar(for v: Version, nextTo url: URL, location: Bool = true, keywords: Bool = true, caption: Bool = true) throws -> URL {
        let out = url.deletingPathExtension().appendingPathExtension("xmp")
        try xmp(for: v, includeLocation: location, includeKeywords: keywords, includeCaption: caption).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// Writes IPTC (keywords, caption, creator, copyright …) into the original file. Only for formats ImageIO can rewrite losslessly
    /// (JPEG/TIFF/PNG); RAW originals get an XMP sidecar instead. This is the one deliberate, user-triggered change to original bytes.
    public static func writeIPTC(_ v: Version, to url: URL) throws -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()), !t.conforms(to: .rawImage),
              t.conforms(to: .jpeg) || t.conforms(to: .tiff) || t.conforms(to: .png),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else { _ = try writeSidecar(for: v, nextTo: url); return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".rl-\(UUID().uuidString)." + url.pathExtension)
        guard let dst = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { throw NSError(domain: "IPTC", code: 1) }
        let md = CGImageMetadataCreateMutable()
        func ns(_ prefix: String, _ uri: String) { CGImageMetadataRegisterNamespaceForPrefix(md, uri as CFString, prefix as CFString, nil) }
        ns("dc", "http://purl.org/dc/elements/1.1/"); ns("photoshop", "http://ns.adobe.com/photoshop/1.0/"); ns("xmp", "http://ns.adobe.com/xap/1.0/"); ns("Iptc4xmpCore", "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/")
        func setStr(_ path: String, _ val: String) { CGImageMetadataSetValueWithPath(md, nil, path as CFString, val as CFString) }
        func setArray(_ path: String, _ vals: [String], ordered: Bool) {
            let parts = path.split(separator: ":").map(String.init)
            let tag = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString, parts[0] as CFString, parts[1] as CFString, ordered ? .arrayOrdered : .arrayUnordered, vals as CFArray)
            if let tag { CGImageMetadataSetTagWithPath(md, nil, path as CFString, tag) }
        }
        if !v.keywords.isEmpty { setArray("dc:subject", v.keywords, ordered: false) }
        if !v.caption.isEmpty { setStr("dc:description", v.caption) }
        if let x = v.meta["iptc.creator"] { setArray("dc:creator", [x], ordered: true) }
        if let x = v.meta["iptc.copyright"] { setStr("dc:rights", x) }
        if let x = v.meta["iptc.title"] { setStr("dc:title", x) }
        for (k, path) in [("iptc.credit", "photoshop:Credit"), ("iptc.source", "photoshop:Source"), ("iptc.city", "photoshop:City"), ("iptc.state", "photoshop:State"), ("iptc.country", "photoshop:Country")] { if let x = v.meta[k] { setStr(path, x) } }
        setStr("xmp:Rating", String(max(0, v.rating)))
        let opts: [CFString: Any] = [kCGImageDestinationMetadata: md, kCGImageDestinationMergeMetadata: true]
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dst, src, opts as CFDictionary, &err) else { try? FileManager.default.removeItem(at: tmp); throw err?.takeRetainedValue() ?? NSError(domain: "IPTC", code: 2) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return true
    }
}

public enum ExifReader {
    /// Display values for the exif.* / gps.* / file.* fields of a master.
    public static func values(for url: URL, master: Master?, isMissing: Bool, version: Version?) -> [String: String] {
        var out: [String: String] = [:]
        if let m = master {
            out["file.name"] = m.originalName; out["file.size"] = ByteCountFormatter.string(fromByteCount: m.fileSize, countStyle: .file)
            out["file.dims"] = "\(m.width) × \(m.height) px"; out["file.type"] = m.isRaw ? "RAW" : m.kind.rawValue.capitalized; out["file.path"] = url.path
            out["file.status"] = isMissing ? "OFFLINE" : (m.isReference ? "Referenced" : "Managed")
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return out }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:], ex = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:], gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        if let mk = tiff[kCGImagePropertyTIFFMake] as? String, let md = tiff[kCGImagePropertyTIFFModel] as? String { out["exif.camera"] = md.hasPrefix(mk) ? md : "\(mk) \(md)" }
        if let l = ex[kCGImagePropertyExifLensModel] as? String { out["exif.lens"] = l }
        if let f = ex[kCGImagePropertyExifFocalLength] as? Double { out["exif.focal"] = String(format: "%.0f mm", f) }
        if let a = ex[kCGImagePropertyExifFNumber] as? Double { out["exif.aperture"] = String(format: "ƒ/%.1f", a) }
        if let t = ex[kCGImagePropertyExifExposureTime] as? Double { out["exif.shutter"] = t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t) }
        if let i = (ex[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { out["exif.iso"] = "\(i)" }
        if let b = ex[kCGImagePropertyExifExposureBiasValue] as? Double { out["exif.bias"] = String(format: "%+.1f EV", b) }
        if let f = ex[kCGImagePropertyExifFlash] as? Int { out["exif.flash"] = f & 1 == 1 ? "Fired" : "Did not fire" }
        if let w = ex[kCGImagePropertyExifWhiteBalance] as? Int { out["exif.wb"] = w == 0 ? "Auto" : "Manual" }
        if let m = ex[kCGImagePropertyExifMeteringMode] as? Int { out["exif.metering"] = ["Unknown", "Average", "Center-weighted", "Spot", "Multi-spot", "Pattern", "Partial"][min(max(m, 0), 6)] }
        if let c = p[kCGImagePropertyColorModel] as? String { out["exif.colorspace"] = (p[kCGImagePropertyProfileName] as? String) ?? c }
        if let la = version?.latitude, let lo = version?.longitude { out["gps.coords"] = String(format: "%.5f, %.5f", la, lo) }
        if let alt = gps[kCGImagePropertyGPSAltitude] as? Double { out["gps.altitude"] = String(format: "%.0f m", alt) }
        return out
    }
}
