import Foundation

public struct UserPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: ID = newID()
    public var name: String
    public var folder: String = "User"
    public var set: AdjustmentSet
    public init(name: String, folder: String = "User", set: AdjustmentSet) { self.name = name; self.folder = folder; self.set = set }
}

/// Custom adjustment presets, stored as JSON next to the library; also exchangeable as single .rlpreset files.
public final class UserPresetStore {
    public let url: URL
    public private(set) var presets: [UserPreset] = []
    public init(libraryRoot: URL) {
        url = libraryRoot.appendingPathComponent("Presets.json")
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([UserPreset].self, from: d) { presets = p }
    }
    private func save() throws { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try e.encode(presets).write(to: url, options: .atomic) }
    @discardableResult public func add(_ p: UserPreset) throws -> UserPreset {
        var p = p
        if let i = presets.firstIndex(where: { $0.name == p.name && $0.folder == p.folder }) { p.id = presets[i].id; presets[i] = p } else { presets.append(p) }
        try save(); return p
    }
    public func remove(_ id: ID) throws { presets.removeAll { $0.id == id }; try save() }
    public func rename(_ id: ID, _ name: String) throws { if let i = presets.firstIndex(where: { $0.id == id }) { presets[i].name = name; try save() } }
    public func export(_ id: ID, to dest: URL) throws { guard let p = presets.first(where: { $0.id == id }) else { return }; try JSONEncoder().encode(p).write(to: dest, options: .atomic) }
    @discardableResult public func importFile(_ src: URL) throws -> UserPreset { try add(try JSONDecoder().decode(UserPreset.self, from: Data(contentsOf: src))) }
    public var folders: [String] { var s: [String] = []; for p in presets where !s.contains(p.folder) { s.append(p.folder) }; return s }
}
