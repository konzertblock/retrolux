import Foundation
import CoreGraphics

// MARK: - settings JSON helper on containers
public extension LibraryStore {
    func document<T: Decodable>(_ id: ID, as type: T.Type) -> T? {
        guard let s = containers[id]?.settings, let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
    func saveDocument<T: Encodable>(_ id: ID, _ doc: T) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        let s = String(data: try e.encode(doc), encoding: .utf8) ?? "{}"
        try dbHandle.run("UPDATE container SET settings=? WHERE id=?", [.text(s), .text(id)]); containers[id]?.settings = s; onChange?()
    }
}

// MARK: - light table
public struct LightTableItem: Codable, Equatable, Identifiable, Sendable {
    public var id: ID = newID()
    public var versionID: ID
    public var x: Double, y: Double              // center, in table coordinates (points)
    public var width: Double, height: Double     // current size
    public var rotation: Double = 0              // degrees
    public var z: Int = 0
    public init(versionID: ID, x: Double, y: Double, width: Double, height: Double, rotation: Double = 0, z: Int = 0) { self.versionID = versionID; self.x = x; self.y = y; self.width = width; self.height = height; self.rotation = rotation; self.z = z }
}
public struct LightTableDoc: Codable, Equatable, Sendable {
    public var items: [LightTableItem] = []
    public var background: Double = 0.25        // gray 0…1
    public var showLabels = true
    public var snapToGrid = false
    public var grid: Double = 20
    public init() {}
}

public enum LightTableLayout {
    public enum Align: String, CaseIterable, Sendable { case left, right, top, bottom, centerH, centerV }
    /// Aligns the given items to the extreme edge / center of the group.
    public static func align(_ items: inout [LightTableItem], ids: Set<ID>, _ a: Align) {
        let sel = items.filter { ids.contains($0.id) }; guard sel.count > 1 else { return }
        let minX = sel.map { $0.x - $0.width / 2 }.min()!, maxX = sel.map { $0.x + $0.width / 2 }.max()!
        let minY = sel.map { $0.y - $0.height / 2 }.min()!, maxY = sel.map { $0.y + $0.height / 2 }.max()!
        for i in items.indices where ids.contains(items[i].id) {
            switch a {
            case .left: items[i].x = minX + items[i].width / 2; case .right: items[i].x = maxX - items[i].width / 2
            case .top: items[i].y = minY + items[i].height / 2; case .bottom: items[i].y = maxY - items[i].height / 2
            case .centerH: items[i].x = (minX + maxX) / 2; case .centerV: items[i].y = (minY + maxY) / 2
            }
        }
    }
    public static func distribute(_ items: inout [LightTableItem], ids: Set<ID>, horizontal: Bool) {
        var sel = items.filter { ids.contains($0.id) }.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }; guard sel.count > 2 else { return }
        let first = horizontal ? sel.first!.x : sel.first!.y, last = horizontal ? sel.last!.x : sel.last!.y
        for (i, s) in sel.enumerated() { let v = first + (last - first) * Double(i) / Double(sel.count - 1); if let k = items.firstIndex(where: { $0.id == s.id }) { if horizontal { items[k].x = v } else { items[k].y = v } } }
        sel.removeAll()
    }
    /// Arranges items in a tidy grid inside `bounds`; aspect ratios are kept.
    public static func grid(_ items: inout [LightTableItem], aspect: (ID) -> Double, bounds: CGSize, margin: Double = 24, gap: Double = 14) {
        guard !items.isEmpty else { return }
        let n = items.count, cols = Int(ceil(Double(n).squareRoot() * Double(bounds.width / max(1, bounds.height)).squareRoot())), rows = Int(ceil(Double(n) / Double(max(1, cols))))
        let cw = (Double(bounds.width) - 2 * margin - gap * Double(cols - 1)) / Double(cols), ch = (Double(bounds.height) - 2 * margin - gap * Double(rows - 1)) / Double(rows)
        for (i, _) in items.enumerated() {
            let a = aspect(items[i].versionID); var w = cw, h = cw / a; if h > ch { h = ch; w = ch * a }
            items[i].width = w; items[i].height = h; items[i].rotation = 0
            items[i].x = margin + (Double(i % cols) + 0.5) * (cw + gap) + (cw - cw) / 2; items[i].y = margin + (Double(i / cols) + 0.5) * (ch + gap)
        }
    }
    /// Loose pile with small rotations (the "Stack"/"Pile" arrangement).
    public static func pile(_ items: inout [LightTableItem], center: CGPoint) {
        for i in items.indices { items[i].x = Double(center.x) + Double((i * 37) % 60 - 30); items[i].y = Double(center.y) + Double((i * 53) % 60 - 30); items[i].rotation = Double((i * 17) % 30 - 15); items[i].z = i }
    }
}

// MARK: - slideshow
public struct SlideOverride: Codable, Equatable, Sendable {
    public var duration: Double? = nil
    public var title: String? = nil
    public var kenBurnsStart: [Double]? = nil      // x, y, w, h in image fractions
    public var kenBurnsEnd: [Double]? = nil
    public init() {}
}

public enum SlideshowStyle: String, Codable, CaseIterable, Sendable { case classic = "Classic", kenBurns = "KenBurns", photoEdges = "PhotoEdges", scrapbook = "Scrapbook", shatter = "Shatter", slidingPanels = "SlidingPanels", snapshots = "Snapshots", watercolorPanels = "WatercolorPanels"
    public var title: String { switch self { case .classic: return "Classic"; case .kenBurns: return "Ken Burns"; case .photoEdges: return "Photo Edges"; case .scrapbook: return "Scrapbook"; case .shatter: return "Shatter"; case .slidingPanels: return "Sliding Panels"; case .snapshots: return "Snapshots"; case .watercolorPanels: return "Watercolor Panels" } }
    /// styles that bring their own transition and cannot customise it (mirrors "themes limit settings",)
    public var fixedTransition: Bool { self != .classic && self != .kenBurns }
}

public struct SlideshowSettings: Codable, Equatable, Sendable {
    public var preset = "classic"
    public var style: SlideshowStyle = .classic
    public var transition = "Dissolve"              // Dissolve, Fade, Cube, Wipe, Push
    public var displayTime = 3.0
    public var fadeTime = 1.0
    public var background = 0.0                     // gray 0…1
    public var loop = false
    public var shuffle = false
    public var showTitle = false
    public var songs: [String] = []
    public var loopSoundtrack = true
    public var musicVolume = 0.8
    public var videoVolume = 1.0
    public var duckMusicDuringVideo = true
    public var manualTiming = false
    public var overrides: [ID: SlideOverride] = [:]
    public var timings: [ID: Double] = [:]          // recorded manual timing
    public init() {}
    public func duration(for id: ID) -> Double { overrides[id]?.duration ?? timings[id] ?? displayTime }

    /// The 12 factory slideshow presets.
    public static let presets: [(String, SlideshowSettings)] = {
        func p(_ n: String, _ f: (inout SlideshowSettings) -> Void) -> (String, SlideshowSettings) { var s = SlideshowSettings(); s.preset = n; f(&s); return (n, s) }
        return [p("dissolve") { $0.transition = "Dissolve"; $0.displayTime = 3; $0.fadeTime = 2 }, p("fadeThruBlack") { $0.transition = "Fade"; $0.displayTime = 3; $0.fadeTime = 2 },
                p("manual") { $0.manualTiming = true; $0.displayTime = 3 }, p("slowDissolve") { $0.transition = "Dissolve"; $0.displayTime = 6; $0.fadeTime = 3 },
                p("classic") { $0.style = .classic }, p("kenBurns") { $0.style = .kenBurns; $0.displayTime = 5; $0.fadeTime = 1.5 }, p("photoEdges") { $0.style = .photoEdges; $0.displayTime = 4 },
                p("scrapbook") { $0.style = .scrapbook; $0.displayTime = 4 }, p("shatter") { $0.style = .shatter; $0.displayTime = 4 }, p("slidingPanels") { $0.style = .slidingPanels; $0.displayTime = 4 },
                p("snapshots") { $0.style = .snapshots; $0.displayTime = 4 }, p("watercolorPanels") { $0.style = .watercolorPanels; $0.displayTime = 4 }]
    }()
}

// MARK: - books
public struct BookType: Sendable { public let key: String, en: String, de: String, widthIn: Double, heightIn: Double, minPages: Int, maxPages: Int
    public static let all: [BookType] = [
        .init(key: "New Big Book", en: "Big Book", de: "Großes Buch", widthIn: 13, heightIn: 10.75, minPages: 20, maxPages: 100),
        .init(key: "New Duplex Book", en: "Duplex Book", de: "Duplex-Buch", widthIn: 10, heightIn: 8, minPages: 20, maxPages: 100),
        .init(key: "Large Softcover", en: "Large Softcover", de: "Großes Softcover", widthIn: 11, heightIn: 8.5, minPages: 20, maxPages: 100),
        .init(key: "Medium Softcover", en: "Medium Softcover", de: "Mittleres Softcover", widthIn: 8, heightIn: 6, minPages: 20, maxPages: 100),
        .init(key: "Small Softcover", en: "Small Softcover", de: "Kleines Softcover", widthIn: 6, heightIn: 4.5, minPages: 20, maxPages: 100)]   // page sizes are our own approximations
    public static func type(_ k: String) -> BookType { all.first { $0.key == k } ?? all[2] }
}
public struct BookTheme: Sendable { public let name: String; public let background: [Double]; public let text: [Double]; public let font: String; public let margin: Double; public let gutter: Double; public let frameWidth: Double; public let caption: Bool
    public static let all: [BookTheme] = [
        .init(name: "Art Collection", background: [0.95, 0.94, 0.9], text: [0.15, 0.15, 0.15], font: "Didot", margin: 0.09, gutter: 0.03, frameWidth: 6, caption: true),
        .init(name: "Formal", background: [1, 1, 1], text: [0.1, 0.1, 0.1], font: "Baskerville", margin: 0.08, gutter: 0.025, frameWidth: 0, caption: true),
        .init(name: "Mini Picture", background: [0.12, 0.12, 0.12], text: [0.9, 0.9, 0.9], font: "HelveticaNeue", margin: 0.1, gutter: 0.04, frameWidth: 0, caption: false),
        .init(name: "Modern Lines", background: [1, 1, 1], text: [0.2, 0.2, 0.2], font: "HelveticaNeue-Light", margin: 0.07, gutter: 0.02, frameWidth: 0, caption: true),
        .init(name: "Photo Essay", background: [0.08, 0.08, 0.08], text: [0.95, 0.95, 0.95], font: "Georgia", margin: 0.05, gutter: 0.015, frameWidth: 0, caption: true),
        .init(name: "Photo Journal", background: [0.96, 0.93, 0.86], text: [0.25, 0.2, 0.15], font: "Palatino-Roman", margin: 0.07, gutter: 0.03, frameWidth: 0, caption: true),
        .init(name: "Picture", background: [1, 1, 1], text: [0.1, 0.1, 0.1], font: "Helvetica", margin: 0.03, gutter: 0.01, frameWidth: 0, caption: false),
        .init(name: "Proof", background: [0.85, 0.85, 0.85], text: [0.1, 0.1, 0.1], font: "Courier", margin: 0.06, gutter: 0.01, frameWidth: 1, caption: true),
        .init(name: "Snapshot", background: [0.98, 0.97, 0.95], text: [0.2, 0.2, 0.2], font: "MarkerFelt-Thin", margin: 0.08, gutter: 0.04, frameWidth: 10, caption: true),
        .init(name: "Special Occasion", background: [0.97, 0.95, 0.9], text: [0.45, 0.3, 0.1], font: "Zapfino", margin: 0.1, gutter: 0.03, frameWidth: 3, caption: true),
        .init(name: "Stock", background: [1, 1, 1], text: [0, 0, 0], font: "Helvetica", margin: 0.05, gutter: 0.015, frameWidth: 0, caption: true),
        .init(name: "Stock Black", background: [0, 0, 0], text: [1, 1, 1], font: "Helvetica", margin: 0.05, gutter: 0.015, frameWidth: 0, caption: true)]
    public static func theme(_ n: String) -> BookTheme { all.first { $0.name == n } ?? all[0] }
}
/// A marker on a book map page (Map Options HUD: Places list).
public struct MapPlace: Codable, Equatable, Identifiable, Sendable { public var id: ID = newID(); public var name: String; public var latitude: Double; public var longitude: Double
    public init(name: String, latitude: Double, longitude: Double) { self.name = name; self.latitude = latitude; self.longitude = longitude } }
public struct BookItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, text, map }
    public var id: ID = newID()
    public var kind: Kind
    public var x: Double, y: Double, w: Double, h: Double      // fractions of the page (0…1, origin top-left)
    public var versionID: ID? = nil
    public var text: String = ""
    public var fontSize: Double = 14
    public var align = "center"
    public var cropX = 0.5, cropY = 0.5, zoom = 1.0           // image fill crop (center point, zoom ≥ 1); for maps: Map Options zoom (0.25…4)
    public var mapTitle: String? = nil, mapPlaces: [MapPlace]? = nil   // map items only
    public init(kind: Kind, x: Double, y: Double, w: Double, h: Double, versionID: ID? = nil, text: String = "") { self.kind = kind; self.x = x; self.y = y; self.w = w; self.h = h; self.versionID = versionID; self.text = text }
}
public struct BookPage: Codable, Equatable, Identifiable, Sendable { public var id: ID = newID(); public var layout: String; public var items: [BookItem]; public init(layout: String, items: [BookItem]) { self.layout = layout; self.items = items } }
public struct BookDoc: Codable, Equatable, Sendable {
    public var type = "Large Softcover"
    public var theme = "Photo Journal"
    public var title = ""
    public var pages: [BookPage] = []
    public var showPageNumbers = true
    public var bleed = true
    public var cover: String? = nil            // "hard" (default) or "soft"; descriptive only
    public init() {}
}

public enum BookLayouts {
    /// Layout templates: image slots (+ optional caption slot) as page fractions, per theme margins.
    public static let names = ["Full Page", "Image + Caption", "Two Up", "Two Stacked", "Three Up", "Grid 4", "Text Only", "Picture Left, Text Right"]
    public static func items(layout: String, theme t: BookTheme, versions: [ID?], caption: [String] = []) -> [BookItem] {
        let m = t.margin, g = t.gutter, W = 1 - 2 * m, H = 1 - 2 * m
        func img(_ i: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> BookItem { BookItem(kind: .image, x: x, y: y, w: w, h: h, versionID: i < versions.count ? versions[i] : nil) }
        func txt(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ s: String = "", size: Double = 14) -> BookItem { var b = BookItem(kind: .text, x: x, y: y, w: w, h: h, text: s); b.fontSize = size; return b }
        switch layout {
        case "Full Page": return [img(0, m, m, W, H)]
        case "Image + Caption": return [img(0, m, m, W, H * 0.84), txt(m, m + H * 0.87, W, H * 0.13, caption.first ?? "", size: 12)]
        case "Two Up": let w = (W - g) / 2; return [img(0, m, m, w, H), img(1, m + w + g, m, w, H)]
        case "Two Stacked": let h = (H - g) / 2; return [img(0, m, m, W, h), img(1, m, m + h + g, W, h)]
        case "Three Up": let w = (W - g) * 0.6, w2 = W - g - w, h2 = (H - g) / 2; return [img(0, m, m, w, H), img(1, m + w + g, m, w2, h2), img(2, m + w + g, m + h2 + g, w2, h2)]
        case "Grid 4": let w = (W - g) / 2, h = (H - g) / 2; return [img(0, m, m, w, h), img(1, m + w + g, m, w, h), img(2, m, m + h + g, w, h), img(3, m + w + g, m + h + g, w, h)]
        case "Text Only": return [txt(m, m, W, H, "", size: 18)]
        default: let w = (W - g) * 0.6; return [img(0, m, m, w, H), txt(m + w + g, m, W - w - g, H, caption.first ?? "", size: 13)]
        }
    }
    public static func slots(_ layout: String) -> Int { switch layout { case "Full Page", "Image + Caption", "Picture Left, Text Right": return 1; case "Two Up", "Two Stacked": return 2; case "Three Up": return 3; case "Grid 4": return 4; default: return 0 } }
    /// Autoflow: distributes versions over pages with a rhythm of layouts; every photo is used exactly once.
    public static func autoflow(_ ids: [ID], theme: String, captions: [ID: String] = [:]) -> [BookPage] {
        let t = BookTheme.theme(theme); var pages: [BookPage] = []; var i = 0; let rhythm = ["Image + Caption", "Two Up", "Three Up", "Full Page", "Grid 4", "Two Stacked"]; var r = 0
        while i < ids.count {
            let layout = rhythm[r % rhythm.count]; r += 1
            let take = min(slots(layout), ids.count - i), chosen = Array(ids[i..<(i + take)]); i += take
            let l2 = take < slots(layout) ? (take == 1 ? "Image + Caption" : (take == 2 ? "Two Up" : "Three Up")) : layout
            pages.append(BookPage(layout: l2, items: items(layout: l2, theme: t, versions: chosen.map { Optional($0) }, caption: chosen.map { captions[$0] ?? "" })))
        }
        return pages
    }
}

// MARK: - web journal / gallery
public struct WebBlock: Codable, Equatable, Identifiable, Sendable { public enum Kind: String, Codable, Sendable { case heading, text, image }; public var id: ID = newID(); public var kind: Kind; public var text: String = ""; public var versionID: ID? = nil
    public init(kind: Kind, text: String = "", versionID: ID? = nil) { self.kind = kind; self.text = text; self.versionID = versionID } }
public struct WebDoc: Codable, Equatable, Sendable {
    public var theme = "Stock"
    public var title = ""
    public var columns = 4
    public var imagePreset = "jpegHigh"       // jpegBest, jpegHigh, jpegMedium, png
    public var thumbPreset = "jpegThumbHigh"
    public var showCaptions = true
    public var showMetadata = false
    public var includeOriginalsLink = false
    public var blocks: [WebBlock] = []        // journal content; empty = gallery of the container members
    public init() {}
    public static let themes = ["Art Collection", "Model", "Picture", "Proof", "Rules", "Special Occasion", "Stock", "Stock Black"]
    public static let presets: [(String, Int, Double)] = [("jpegThumbBest", 200, 0.9), ("jpegThumbHigh", 200, 0.75), ("jpegThumbMedium", 200, 0.55), ("jpegBest", 1280, 0.9), ("jpegHigh", 1024, 0.75), ("jpegMedium", 800, 0.55), ("png", 1024, 1)]
}
