import Foundation

public struct ImportPreset: Codable, Identifiable, Equatable, Sendable {
    public var id: ID = newID()
    public var name: String
    public var options: ImportOptions
    public static func == (a: ImportPreset, b: ImportPreset) -> Bool { a.id == b.id && a.name == b.name }
    public init(name: String, options: ImportOptions) { self.name = name; self.options = options }
}

/// Import presets (storage mode, naming, folders, metadata/adjustment presets, backup, filters, post-import script).
public final class ImportPresetStore {
    let url: URL
    public private(set) var presets: [ImportPreset] = []
    public init(libraryRoot: URL) {
        url = libraryRoot.appendingPathComponent("ImportPresets.json")
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([ImportPreset].self, from: d) { presets = p }
    }
    public func save(_ p: ImportPreset) { presets.removeAll { $0.name == p.name }; presets.append(p); flush() }
    public func remove(_ id: ID) { presets.removeAll { $0.id == id }; flush() }
    func flush() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(presets).write(to: url, options: .atomic) }
}

/// Importer for iPhoto libraries (AlbumData.xml): events → projects, albums → albums, ratings, captions, keywords, dates.
public enum IPhotoLibraryImporter {
    public struct Report: Sendable { public var projects = 0, albums = 0, versions = 0, missing: [String] = []; public var text: String { "\(projects) events, \(albums) albums, \(versions) photos, \(missing.count) missing" } }

    public static func albumDataURL(_ lib: URL) -> URL? {
        for c in ["AlbumData.xml", "iPhotoMain.db"] where c == "AlbumData.xml" { let u = lib.appendingPathComponent(c); if FileManager.default.fileExists(atPath: u.path) { return u } }
        return nil
    }
    public static func importLibrary(at lib: URL, into store: LibraryStore, copy: Bool = false) throws -> Report {
        guard let xml = albumDataURL(lib), let d = try? Data(contentsOf: xml),
              let root = try PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] else { throw NSError(domain: "iPhoto", code: 1, userInfo: [NSLocalizedDescriptionKey: "No AlbumData.xml found – is this an iPhoto library?"]) }
        var rep = Report()
        let images = root["Master Image List"] as? [String: [String: Any]] ?? [:]
        let kwNames = root["List of Keywords"] as? [String: String] ?? [:]
        var versionOf: [String: ID] = [:]
        var rolls = root["List of Rolls"] as? [[String: Any]] ?? []
        if rolls.isEmpty { rolls = [["RollName": "iPhoto", "KeyList": Array(images.keys)]] }
        for roll in rolls {
            let name = (roll["RollName"] as? String) ?? "Event"; let keys = (roll["KeyList"] as? [Any])?.map { "\($0)" } ?? []
            let proj = try store.addContainer(Container(kind: .project, name: name, parentID: nil)); rep.projects += 1
            var batch: [(Master, Version)] = []
            for k in keys {
                guard let img = images[k] else { continue }
                let path = (img["OriginalPath"] as? String).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? (img["ImagePath"] as? String) ?? ""
                guard FileManager.default.fileExists(atPath: path) else { rep.missing.append((img["Caption"] as? String) ?? k); continue }
                let url = URL(fileURLWithPath: path); guard let mk = Importer.mediaKind(url) else { continue }
                let probe = mk.kind == .image ? RenderEngine.probe(url: url) : nil
                var rel = path; var ref = true
                if copy { let dst = Exporter.unique(store.mastersDir.appendingPathComponent(url.lastPathComponent)); try FileManager.default.copyItem(at: url, to: dst); rel = dst.lastPathComponent; ref = false }
                let sum = (try? Importer.sha256(of: copy ? store.mastersDir.appendingPathComponent(rel) : url)) ?? ""
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                let m = Master(projectID: proj.id, path: rel, isReference: ref, isRaw: mk.raw, kind: mk.kind, width: Int(probe?.size.width ?? 0), height: Int(probe?.size.height ?? 0), fileSize: size, checksum: sum, originalName: url.lastPathComponent)
                let date = (img["DateAsTimerInterval"] as? Double).map { Date(timeIntervalSinceReferenceDate: $0) } ?? probe?.date ?? Date()
                var v = Version(masterID: m.id, projectID: proj.id, name: ((img["Caption"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? url.deletingPathExtension().lastPathComponent, imageDate: date)
                v.rating = (img["Rating"] as? Int) ?? 0; v.caption = (img["Comment"] as? String) ?? ""
                if let kws = img["Keywords"] as? [Any] { v.keywords = kws.compactMap { kwNames["\($0)"] } }
                if let lat = img["Latitude"] as? Double, let lon = img["Longitude"] as? Double { v.latitude = lat; v.longitude = lon }
                if (img["Flagged"] as? Bool) == true || (img["Flagged"] as? Int) == 1 { v.flagged = true }
                if let ori = img["Rotation"] as? Int { v.rotation = (ori % 360 + 360) % 360 }
                batch.append((m, v)); versionOf[k] = v.id; rep.versions += 1
            }
            try store.insertBatch(batch)
        }
        for al in root["List of Albums"] as? [[String: Any]] ?? [] {
            let type = (al["Album Type"] as? String) ?? ""
            guard type == "Regular" || type == "Book" || type == "Slideshow" || type.isEmpty, let n = al["AlbumName"] as? String, n != "Photos", n != "Library" else { continue }
            let ids = (al["KeyList"] as? [Any])?.compactMap { versionOf["\($0)"] } ?? []
            guard !ids.isEmpty else { continue }
            let c = try store.addContainer(Container(kind: .album, name: n, parentID: nil)); try store.addToAlbum(c.id, ids); rep.albums += 1
        }
        return rep
    }
}
