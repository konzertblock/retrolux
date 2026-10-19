import Foundation
import CoreGraphics

public typealias ID = String
public func newID() -> ID { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

public struct CurvePoint: Codable, Equatable, Sendable { public var x: Double; public var y: Double; public var editable: Bool = true
    public init(x: Double, y: Double, editable: Bool = true) { self.x = x; self.y = y; self.editable = editable } }

/// One brush stroke in image-pixel coordinates (origin: top-left).
public struct Stroke: Codable, Equatable, Sendable {
    public var points: [[Double]]          // [[x, y]] in master pixel coordinates
    public var radius: Double
    public var softness: Double
    public var opacity: Double
    public var erase: Bool = false
    public var sourceDX: Double = 0         // retouch / spot&patch source offset
    public var sourceDY: Double = 0
    public var mode: Int = 0                // retouch: 0 repair, 1 clone
    public var pressure: [Double] = []      // optional per-point tablet pressure 0…1 (radius scales with it)
    public init(points: [[Double]], radius: Double, softness: Double = 0.5, opacity: Double = 1, erase: Bool = false,
                sourceDX: Double = 0, sourceDY: Double = 0, mode: Int = 0) {
        self.points = points; self.radius = radius; self.softness = softness; self.opacity = opacity; self.erase = erase
        self.sourceDX = sourceDX; self.sourceDY = sourceDY; self.mode = mode
    }
}

/// A non-destructive edit step. `id` is the operation identifier (see Catalog).
public struct Adjustment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var enabled: Bool = true
    public var params: [String: Double] = [:]
    public var curves: [String: [CurvePoint]] = [:]
    public var strokes: [Stroke] = []
    public init(id: String, enabled: Bool = true, params: [String: Double] = [:], curves: [String: [CurvePoint]] = [:], strokes: [Stroke] = []) {
        self.id = id; self.enabled = enabled; self.params = params; self.curves = curves; self.strokes = strokes
    }
    public func value(_ key: String) -> Double { params[key] ?? Catalog.spec(id)?.param(key)?.def ?? 0 }
    public var isDefault: Bool {
        guard let spec = Catalog.spec(id) else { return false }
        if spec.kind != .global { return strokes.isEmpty }
        if spec.alwaysApplies { return false }
        if !curves.isEmpty, curves.values.contains(where: { !isIdentity($0) }) { return false }
        return spec.params.allSatisfy { abs(value($0.key) - $0.def) < 1e-9 }
    }
    private func isIdentity(_ pts: [CurvePoint]) -> Bool { pts.filter { $0.editable }.isEmpty }
}

/// Quick-brush adjustment: an operation applied only where strokes paint a mask.
public struct BrushAdjustment: Codable, Equatable, Identifiable, Sendable {
    public var uid: ID = newID()
    public var op: String
    public var enabled: Bool = true
    public var params: [String: Double] = [:]
    public var strokes: [Stroke] = []
    public var tonalRange: Int = 0          // 0 all tones, 1 shadows, 2 midtones, 3 highlights
    public var edgeDetect: Bool = false     // limit each stroke to colors similar to its starting point
    public var id: ID { uid }
    public init(op: String, params: [String: Double] = [:], strokes: [Stroke] = []) { self.op = op; self.params = params; self.strokes = strokes }
    public func value(_ key: String) -> Double { params[key] ?? Catalog.brushSpec(op)?.param(key)?.def ?? 0 }
}

public struct AdjustmentSet: Codable, Equatable, Sendable {
    public var items: [Adjustment] = []
    public var brushes: [BrushAdjustment] = []
    /// Recipe/engine version these adjustments were authored with. Updates never change it silently.
    public var engineVersion: Int = 1
    public static let currentEngineVersion = 1
    public var needsEngineUpdate: Bool { engineVersion < AdjustmentSet.currentEngineVersion }
    public init(items: [Adjustment] = [], brushes: [BrushAdjustment] = []) { self.items = items; self.brushes = brushes }
    public init(from d: Decoder) throws { let c = try d.container(keyedBy: CodingKeys.self); items = try c.decodeIfPresent([Adjustment].self, forKey: .items) ?? []; brushes = try c.decodeIfPresent([BrushAdjustment].self, forKey: .brushes) ?? []; engineVersion = try c.decodeIfPresent(Int.self, forKey: .engineVersion) ?? 1 }
    public var isEmpty: Bool { items.allSatisfy { !$0.enabled || $0.isDefault } && brushes.allSatisfy { !$0.enabled || $0.strokes.isEmpty } }
    /// RAW Fine Tuning alone does not count as an edit (it is a decode setting, not an adjustment)
    public var hasAny: Bool { items.contains { $0.id != Catalog.raw } || !brushes.isEmpty }
    public func item(_ id: String) -> Adjustment? { items.first { $0.id == id } }
    /// Brick order follows the Catalog, so output is deterministic regardless of insertion order.
    public mutating func upsert(_ a: Adjustment) {
        if let i = items.firstIndex(where: { $0.id == a.id }) { items[i] = a } else { items.append(a) }
        let order = Catalog.ops.map(\.id)
        items.sort { (order.firstIndex(of: $0.id) ?? 999) < (order.firstIndex(of: $1.id) ?? 999) }
    }
    public mutating func remove(_ id: String) { items.removeAll { $0.id == id } }
}

public enum MediaKind: String, Codable, Hashable, Sendable { case image, video, audio }

public struct Master: Codable, Equatable, Identifiable, Sendable {
    public var id: ID
    public var projectID: ID
    public var path: String                // absolute path (referenced) or path relative to library "Masters/" (managed)
    public var isReference: Bool
    public var isRaw: Bool
    public var kind: MediaKind
    public var width: Int
    public var height: Int
    public var fileSize: Int64
    public var checksum: String            // SHA-256 of the original bytes at import time
    public var importDate: Date
    public var originalName: String
    public var duration: Double = 0                 // seconds, video/audio
    public init(id: ID = newID(), projectID: ID, path: String, isReference: Bool, isRaw: Bool, kind: MediaKind = .image,
                width: Int = 0, height: Int = 0, fileSize: Int64 = 0, checksum: String = "", importDate: Date = Date(), originalName: String) {
        self.id = id; self.projectID = projectID; self.path = path; self.isReference = isReference; self.isRaw = isRaw; self.kind = kind
        self.width = width; self.height = height; self.fileSize = fileSize; self.checksum = checksum; self.importDate = importDate; self.originalName = originalName
    }
}

public struct Version: Codable, Equatable, Identifiable, Sendable {
    public var id: ID
    public var masterID: ID
    public var projectID: ID
    public var name: String
    public var versionNumber: Int = 1
    public var rating: Int = 0              // -1 = rejected, 0 = unrated, 1...5
    public var flagged: Bool = false
    public var hidden: Bool = false
    public var colorLabel: Int = 0          // 0 none, 1 red, 2 orange, 3 yellow, 4 green, 5 blue, 6 purple, 7 gray
    public var rotation: Int = 0            // degrees, multiples of 90
    public var imageDate: Date
    public var createDate: Date = Date()
    public var trashed: Bool = false
    public var latitude: Double? = nil
    public var longitude: Double? = nil
    public var caption: String = ""
    public var keywords: [String] = []
    public var hasAdjustments: Bool = false
    public var stackID: ID? = nil
    public var stackPos: Int = 0                   // 0 = pick of the stack
    public var meta: [String: String] = [:]        // IPTC / custom fields, keys from MetadataField
    public var originalImageDate: Date? = nil      // kept when the date was adjusted
    public init(id: ID = newID(), masterID: ID, projectID: ID, name: String, imageDate: Date = Date()) {
        self.id = id; self.masterID = masterID; self.projectID = projectID; self.name = name; self.imageDate = imageDate
    }
}

public enum ContainerKind: String, Codable, Sendable { case folder, project, album, smartAlbum, book, lightTable, slideshow, webJournal }

/// Library tree node: folders, projects and the album-like objects in them.
public struct Container: Codable, Equatable, Identifiable, Sendable {
    public var id: ID
    public var kind: ContainerKind
    public var name: String
    public var parentID: ID?
    public var created: Date = Date()
    public var sortIndex: Int = 0
    public var query: SmartQuery? = nil
    public var keyPhotoID: ID? = nil
    public var settings: String? = nil      // JSON document of books, light tables, slideshows, web journals
    public var members: [ID] = []           // version ids for manual albums, in order
    public init(id: ID = newID(), kind: ContainerKind, name: String, parentID: ID?, query: SmartQuery? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.parentID = parentID; self.query = query
    }
}

public struct SmartRule: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable, CaseIterable { case rating, flagged, colorLabel, keyword, name, hasAdjustments, isRaw, imageDate, caption }
    public enum Op: String, Codable, Sendable { case equals, notEquals, atLeast, atMost, contains, isTrue, isFalse, after, before }
    public var field: Field; public var op: Op; public var value: String
    public init(_ f: Field, _ o: Op, _ v: String = "") { field = f; op = o; value = v }
}
public struct SmartQuery: Codable, Equatable, Sendable {
    public var matchAll: Bool = true
    public var rules: [SmartRule] = []
    public init(matchAll: Bool = true, rules: [SmartRule]) { self.matchAll = matchAll; self.rules = rules }
}

public enum Labels {
    public static let names = ["", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"]
    public static let namesDE = ["", "Rot", "Orange", "Gelb", "Grün", "Blau", "Violett", "Grau"]
}
