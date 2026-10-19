import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Import menu for RAW+JPEG pairs (RAW+JPEG Pairs tile): `both` = separate masters; the *Master modes import one master and keep the other file of the pair as a companion.
public enum RawJPEGMode: String, CaseIterable, Codable, Sendable { case both, rawOnly, jpegOnly, bothJPEGMaster, bothRAWMaster, matchingRAWOnly }

/// The factory file-naming policies.
public enum ImportNamePolicy: String, CaseIterable, Codable, Sendable {
    case versionName = "Version Name", versionNameDate = "Version Name and Date/Time", versionNameSequence = "Version Name with Sequence", versionNameIndex = "Version Name with Index"
    case customIndex = "Custom Name with Index", customIndexNoSpaces = "Custom Name with Index (no spaces)", imageDate = "Image Date/Time", customCounter = "Custom Name with Counter"
}
public enum FolderPolicy: String, CaseIterable, Codable, Sendable { case byImportDate = "Import date (yyyy/MM/dd)", byImageDate = "Image date (yyyy/MM/dd)", flat = "Flat", byProject = "Project name" }

public struct ImportOptions: Codable, Sendable {
    public var managed: Bool = true                 // copy into the library (false = reference in place)
    public var projectID: ID? = nil                 // existing target project
    public var newProjectName: String? = nil
    public var parentFolder: ID? = nil
    public var rawJPEG: RawJPEGMode = .both
    public var skipDuplicates: Bool = true          // identity = SHA-256 of the file bytes; same name with different bytes is imported and renamed on disk
    public var namePrefix: String? = nil
    public var kinds: Set<MediaKind> = [.image, .video, .audio]
    public var namePolicy: ImportNamePolicy = .versionName
    public var customName = "Image"
    public var counterStart = 1
    public var renameFiles = false                  // managed copies get the policy name on disk as well
    public var folderPolicy: FolderPolicy = .byImportDate
    public var backupFolder: URL? = nil             // optional second copy of every original; a failed backup fails that file
    public var splitGapHours: Double? = nil         // split into projects when the capture gap exceeds this
    public var minCameraRating: Int? = nil          // import only photos the camera rated at least this high
    public var mapCameraRating = true
    public var metadata: [String: String] = [:]     // metadata preset applied to every import (caption, iptc.*)
    public var keywords: [String] = []
    public var adjustments: AdjustmentSet? = nil    // adjustment preset applied to every import
    public var postScript: URL? = nil               // user-configured script, run with the imported file paths as arguments
    public init() {}
}

public struct ImportReport: Sendable {
    public var imported = 0
    public var duplicates: [String] = []
    public var failed: [(String, String)] = []
    public var skippedUnsupported: [String] = []
    public var filtered: [String] = []
    public var backupFailed: [String] = []
    public var projectID: ID? = nil
    public var projectIDs: [ID] = []
    public var versionIDs: [ID] = []
    public var notes: [String] = []
    public var summary: String { "\(imported) imported, \(duplicates.count) duplicates, \(failed.count) failed, \(skippedUnsupported.count) unsupported" + (filtered.isEmpty ? "" : ", \(filtered.count) filtered") }
}

public enum CameraMetadata {
    /// XMP/EXIF rating the camera (or a card reader workflow) wrote into the file; nil when absent.
    public static func rating(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
              let tag = CGImageMetadataCopyTagWithPath(md, nil, "xmp:Rating" as CFString), let v = CGImageMetadataTagCopyValue(tag) as? String else { return nil }
        return Int(v)
    }
}

public final class Importer {
    let store: LibraryStore
    public var cancelled = false
    public private(set) var importedVersions: [ID] = []
    public init(store: LibraryStore) { self.store = store }

    public static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url); defer { try? fh.close() }
        var h = SHA256()
        while let d = try fh.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func mediaKind(_ url: URL) -> (kind: MediaKind, raw: Bool)? {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if t.conforms(to: .rawImage) { return (.image, true) }
        if t.conforms(to: .image) { return (.image, false) }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return (.video, false) }
        if t.conforms(to: .audio) { return (.audio, false) }
        return nil
    }

    /// Expands folders recursively; hidden files and packages are skipped.
    public static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let f as URL in e where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(f) }
            } else { out.append(u) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func versionName(_ o: ImportOptions, base: String, date: Date, index: Int, counter: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; let d = f.string(from: date)
        switch o.namePolicy {
        case .versionName: return (o.namePrefix ?? "") + base
        case .versionNameDate: return "\(base) \(d)"
        case .versionNameSequence: return "\(base) \(counter)"
        case .versionNameIndex: return "\(base) \(index)"
        case .customIndex: return "\(o.customName) \(index)"
        case .customIndexNoSpaces: return "\(o.customName)_\(index)".replacingOccurrences(of: " ", with: "_")
        case .imageDate: return d
        case .customCounter: return "\(o.customName) \(counter)"
        }
    }

    struct Candidate { var url: URL; var kind: MediaKind; var raw: Bool; var date: Date; var probe: (size: CGSize, date: Date?, rating: Int?, lat: Double?, lon: Double?, orientation: Int)?; var media: MediaProbe.Info?; var cameraRating: Int? }

    @discardableResult
    public func importFiles(_ urls: [URL], options: ImportOptions, progress: ((Int, Int) -> Void)? = nil) throws -> ImportReport {
        var rep = ImportReport()
        var files = Importer.expand(urls)
        var companions: [String: URL] = [:]       // master file path → the other file of its RAW+JPEG pair
        if options.rawJPEG != .both {
            var groups: [String: [URL]] = [:]
            for f in files { groups[f.deletingPathExtension().path.lowercased(), default: []].append(f) }
            files = files.filter { f in
                guard let g = groups[f.deletingPathExtension().path.lowercased()], g.count > 1 else { return options.rawJPEG != .matchingRAWOnly || Importer.mediaKind(f)?.raw != true }
                let raws = g.filter { Importer.mediaKind($0)?.raw == true }, jpgs = g.filter { Importer.mediaKind($0)?.raw == false && Importer.mediaKind($0)?.kind == .image }
                guard let raw = raws.first, let jpg = jpgs.first else { return true }
                let isRaw = Importer.mediaKind(f)?.raw == true
                switch options.rawJPEG {
                case .rawOnly, .matchingRAWOnly: return isRaw
                case .jpegOnly: return !isRaw
                case .bothRAWMaster: if isRaw { companions[raw.path] = jpg; return true } else { return false }
                case .bothJPEGMaster: if !isRaw { companions[jpg.path] = raw; return true } else { return false }
                case .both: return true
                }
            }
        }
        // classify + read dates/ratings once
        var cands: [Candidate] = []
        let fileDate: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date() }
        for f in files {
            guard let mk = Importer.mediaKind(f) else { rep.skippedUnsupported.append(f.lastPathComponent); continue }
            guard options.kinds.contains(mk.kind) else { rep.filtered.append(f.lastPathComponent); continue }
            var c = Candidate(url: f, kind: mk.kind, raw: mk.raw, date: fileDate(f), probe: nil, media: nil, cameraRating: nil)
            if mk.kind == .image { c.probe = RenderEngine.probe(url: f); c.date = c.probe?.date ?? c.date; c.cameraRating = CameraMetadata.rating(f) }
            else { c.media = MediaProbe.probe(f); c.date = c.media?.date ?? c.date }
            if let min = options.minCameraRating, (c.cameraRating ?? 0) < min { rep.filtered.append(f.lastPathComponent); continue }
            cands.append(c)
        }
        cands.sort { $0.date < $1.date }
        // projects
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm"
        var projectFor: [Int: ID] = [:]
        func makeProject(_ name: String) throws -> ID { try store.addContainer(Container(kind: .project, name: name, parentID: options.parentFolder)).id }
        if let p = options.projectID, store.containers[p]?.kind == .project { for i in cands.indices { projectFor[i] = p } }
        else if let gap = options.splitGapHours, gap > 0, !cands.isEmpty {
            var cur: ID?; var lastDate: Date?
            for (i, c) in cands.enumerated() {
                if cur == nil || c.date.timeIntervalSince(lastDate!) > gap * 3600 { cur = try makeProject((options.newProjectName.map { $0 + " – " } ?? "") + df.string(from: c.date)) }
                projectFor[i] = cur!; lastDate = c.date
            }
        } else if !cands.isEmpty {
            let id = try makeProject(options.newProjectName ?? "Import \(df.string(from: Date()))"); for i in cands.indices { projectFor[i] = id }
        }
        rep.projectIDs = Array(Set(projectFor.values)); rep.projectID = projectFor[0] ?? rep.projectIDs.first
        let known = options.skipDuplicates ? Set(store.masters.values.map(\.checksum)) : []
        var seen = known
        var batch: [(Master, Version)] = []
        let dateDir = DateFormatter(); dateDir.dateFormat = "yyyy/MM/dd"
        var counter = options.counterStart
        var imported: [(Master, Version, URL)] = []
        for (i, c) in cands.enumerated() {
            if cancelled { rep.notes.append("cancelled – import again to resume (already imported files are skipped by checksum)"); break }
            progress?(i, cands.count)
            let f = c.url, projectID = projectFor[i]!
            do {
                let sum = try Importer.sha256(of: f)
                if options.skipDuplicates && seen.contains(sum) { rep.duplicates.append(f.lastPathComponent); continue }
                let name = Importer.versionName(options, base: f.deletingPathExtension().lastPathComponent, date: c.date, index: i + 1, counter: counter)
                // second copy first: a failed backup must not look like a successful import
                if let bk = options.backupFolder {
                    do {
                        try FileManager.default.createDirectory(at: bk, withIntermediateDirectories: true)
                        let dst = Exporter.unique(bk.appendingPathComponent(f.lastPathComponent)); try FileManager.default.copyItem(at: f, to: dst)
                        guard try Importer.sha256(of: dst) == sum else { try? FileManager.default.removeItem(at: dst); throw NSError(domain: "Import", code: 2, userInfo: [NSLocalizedDescriptionKey: "backup verification failed"]) }
                    } catch { rep.backupFailed.append(f.lastPathComponent); rep.failed.append((f.lastPathComponent, "backup copy failed: \(error.localizedDescription)")); continue }
                }
                var path = f.path
                var companionPath: String?
                if options.managed {
                    let sub: String
                    switch options.folderPolicy { case .byImportDate: sub = dateDir.string(from: Date()); case .byImageDate: sub = dateDir.string(from: c.date); case .flat: sub = ""
                    case .byProject: sub = (store.containers[projectID]?.name ?? "Project").replacingOccurrences(of: "/", with: "-") }
                    let base = options.renameFiles ? name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "." + f.pathExtension : f.lastPathComponent
                    var dst = store.mastersDir.appendingPathComponent(sub.isEmpty ? base : sub + "/" + base); var n = 1
                    try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    while FileManager.default.fileExists(atPath: dst.path) { n += 1; dst = dst.deletingLastPathComponent().appendingPathComponent("\(dst.deletingPathExtension().lastPathComponent)-\(n).\(dst.pathExtension)") }
                    try FileManager.default.copyItem(at: f, to: dst)
                    guard try Importer.sha256(of: dst) == sum else { try? FileManager.default.removeItem(at: dst); throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey: "copy verification failed"]) }
                    path = String(dst.path.dropFirst(store.mastersDir.path.count + 1))
                    if let comp = companions[f.path] {       // keep the other file of the pair next to the master
                        let cdst = Exporter.unique(dst.deletingPathExtension().appendingPathExtension(comp.pathExtension))
                        try FileManager.default.copyItem(at: comp, to: cdst)
                        companionPath = String(cdst.path.dropFirst(store.mastersDir.path.count + 1))
                    }
                } else if let comp = companions[f.path] { companionPath = comp.path }
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                var m = Master(projectID: projectID, path: path, isReference: !options.managed, isRaw: c.raw, kind: c.kind,
                               width: Int(c.probe?.size.width ?? c.media?.size.width ?? 0), height: Int(c.probe?.size.height ?? c.media?.size.height ?? 0), fileSize: size, checksum: sum, originalName: f.lastPathComponent)
                m.duration = c.media?.duration ?? 0
                var v = Version(masterID: m.id, projectID: projectID, name: name, imageDate: c.date)
                v.latitude = c.probe?.lat; v.longitude = c.probe?.lon
                if options.mapCameraRating, let r = c.cameraRating, r > 0 { v.rating = min(5, r) }
                for (k, val) in options.metadata where !val.isEmpty { if k == "caption" { v.caption = val } else if k == "name" { v.name = val } else { v.meta[k] = val } }
                v.keywords = options.keywords
                if let cp = companionPath { v.meta["pair.companion"] = cp; v.meta["pair.companion.managed"] = options.managed ? "1" : "0" }
                batch.append((m, v)); imported.append((m, v, f)); importedVersions.append(v.id); seen.insert(sum); rep.imported += 1; counter += 1
                if batch.count >= 50 { try store.insertBatch(batch); batch = [] }     // early usable images
            } catch { rep.failed.append((f.lastPathComponent, error.localizedDescription)) }
        }
        if !batch.isEmpty { try store.insertBatch(batch) }
        if let adj = options.adjustments, adj.hasAny || !adj.items.isEmpty { for (_, v, _) in imported { try? store.setAdjustments(v.id, adj) } }
        rep.versionIDs = imported.map { $0.1.id }
        progress?(cands.count, cands.count)
        if let script = options.postScript, !imported.isEmpty { rep.notes.append(Importer.runPostScript(script, files: imported.map { store.masterURL($0.0).path })) }
        return rep
    }

    /// Runs a user-configured script after the import: AppleScript via osascript, anything else executed directly. Output is returned for the log.
    public static func runPostScript(_ script: URL, files: [String]) -> String {
        let p = Process()
        if ["scpt", "applescript"].contains(script.pathExtension.lowercased()) { p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = [script.path] + files }
        else { p.executableURL = script; p.arguments = files }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "post-import script failed to start: \(error.localizedDescription)" }
        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return "post-import script timed out" }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return "post-import script exit \(p.terminationStatus)" + (out.isEmpty ? "" : ": " + out.prefix(400))
    }
}

// MARK: - Legacy library importer (read-only, from a copy or the original; never writes)

public struct MigrationReport: Sendable {
    public var projects = 0, folders = 0, masters = 0, versions = 0, adjustments = 0, keywords = 0, albums = 0
    public var missingMasters: [String] = []
    public var unsupported: [String: Int] = [:]
    public var notes: [String] = []
    public var text: String {
        var s = "Projects \(projects), folders \(folders), albums \(albums), masters \(masters), versions \(versions), adjustments \(adjustments), keyword links \(keywords)\n"
        s += "Missing masters: \(missingMasters.count)\n"
        for (k, v) in unsupported.sorted(by: { $0.key < $1.key }) { s += "Not transferable: \(k) ×\(v)\n" }
        for n in notes { s += n + "\n" }
        return s
    }
}

public enum LegacyLibraryImporter {
    /// Cocoa reference date (2001-01-01) → Date
    static func cocoa(_ v: SQLValue?) -> Date { Date(timeIntervalSinceReferenceDate: v?.dbl ?? 0) }

    public static func unarchive(_ data: Data) -> Any? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objs = plist["$objects"] as? [Any], let top = plist["$top"] as? [String: Any], let root = top["root"] else { return nil }
        func uidIndex(_ x: Any) -> Int? {
            // PropertyListSerialization yields CFKeyedArchiverUID; its description is "<CFKeyedArchiverUID …>{value = N}"
            guard !(x is [String: Any]), !(x is [Any]), !(x is String), String(describing: type(of: x)) == "__NSCFType" else { return nil }
            let d = "\(x)"; guard d.contains("CFKeyedArchiverUID"), let r = d.range(of: "value = ") else { return nil }
            return Int(d[r.upperBound...].prefix { $0.isNumber })
        }
        func resolve(_ x: Any, _ depth: Int) -> Any {
            if depth > 12 { return NSNull() }
            if let i = uidIndex(x), i < objs.count { return resolve(objs[i], depth + 1) }
            if let d = x as? [String: Any] {
                if let keys = d["NS.keys"] as? [Any], let vals = d["NS.objects"] as? [Any] {
                    var out: [String: Any] = [:]
                    for (k, v) in zip(keys, vals) { if let ks = resolve(k, depth + 1) as? String { out[ks] = resolve(v, depth + 1) } }
                    return out
                }
                if let vals = d["NS.objects"] as? [Any] { return vals.map { resolve($0, depth + 1) } }
                if let s = d["NS.string"] as? String { return s }
                var out: [String: Any] = [:]
                for (k, v) in d where k != "$class" { out[k] = resolve(v, depth + 1) }
                return out
            }
            return x
        }
        return resolve(root, 0)
    }

    public static func adjustment(from root: Any) -> (Adjustment?, String) {
        guard let d = root as? [String: Any] else { return (nil, "undecodable") }
        let ident = (d["DGOperationIdentifier"] as? String) ?? (d["DGOperationClassName"] as? String) ?? ""
        let id = Catalog.canonicalID(ident)
        guard let keys = d["inputKeys"] as? [String: Any] else { return (nil, ident) }
        var a = Adjustment(id: id, enabled: (d["enabled"] as? Bool) ?? ((d["enabled"] as? NSNumber)?.boolValue ?? true))
        for (k, v) in keys {
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { a.params[k] = n.doubleValue }
            else if let n = v as? NSNumber { a.params[k] = n.boolValue ? 1 : 0 }
        }
        if id == Catalog.wb { a.params["inputIsDefaults"] = a.params["inputIsDefaults"] ?? 0 }
        for k in ["RGBCurvePoints", "redCurvePoints", "greenCurvePoints", "blueCurvePoints"] {
            if let pts = keys[k] as? [[String: Any]] {
                a.curves[k] = pts.compactMap { p in
                    guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue else { return nil }
                    return CurvePoint(x: x, y: y, editable: (p["editable"] as? NSNumber)?.boolValue ?? true)
                }
            }
        }
        if let strokes = keys["inputStrokes"] as? [[String: Any]] {
            for s in strokes {
                guard let bs = s["brushStroke"] as? [String: Any], let data = bs["data"] as? [[String: Any]] else { continue }
                let pts = data.compactMap { p -> [Double]? in guard let x = (p["xLocation"] as? NSNumber)?.doubleValue, let y = (p["yLocation"] as? NSNumber)?.doubleValue else { return nil }; return [x, y] }
                var dx = 0.0, dy = 0.0
                if let o = s["sourceOffset"] as? String {
                    let nums = o.split(whereSeparator: { !"-0123456789.".contains($0) }).compactMap { Double($0) }
                    if nums.count == 2 { dx = nums[0]; dy = nums[1] }
                }
                a.strokes.append(Stroke(points: pts, radius: (bs["radius"] as? NSNumber)?.doubleValue ?? 20, softness: (bs["softness"] as? NSNumber)?.doubleValue ?? 0.5,
                                        opacity: (bs["opacity"] as? NSNumber)?.doubleValue ?? 1, sourceDX: dx, sourceDY: dy, mode: (s["mode"] as? NSNumber)?.intValue ?? 0))
            }
        }
        return (a, ident)
    }

    /// Imports projects, folders, masters (referenced in place unless `copyMasters`), versions, adjustments, keywords and manual albums.
    public static func importLibrary(at lib: URL, into store: LibraryStore, copyMasters: Bool = false, limitVersions: Int? = nil) throws -> MigrationReport {
        var rep = MigrationReport()
        let dbURL = lib.appendingPathComponent("Database/Library.apdb")
        let db = try SQLiteDB(path: dbURL.path, readOnly: true, immutable: true)   // never modifies the source
        let mastersDir = lib.appendingPathComponent("Masters")
        var folderMap: [String: ID] = [:], projectMap: [String: ID] = [:]
        // folders & projects
        let frows = try db.query("SELECT uuid,folderType,name,parentFolderUuid,folderPath FROM RKFolder ORDER BY length(folderPath)")
        var rootUUID: String?
        for r in frows {
            let uuid = r[0].str ?? "", type = r[1].int ?? 0, name = r[2].str ?? "", parent = r[3].str ?? ""
            if (r[4].str ?? "") == "1/" { rootUUID = uuid; continue }
            if ["Trash", "IPHPublishServiceMobileMe", "IPHPublishServiceFlickr", "IPHPublishServiceFacebook", "Content", "Library Albums"].contains(name) { continue }
            if type == 3 { continue }
            let kind: ContainerKind = type == 2 ? .project : .folder
            var parentID = folderMap[parent]
            if parent == rootUUID { parentID = nil }
            let c = try store.addContainer(Container(kind: kind, name: name == "Projects" && parent == rootUUID ? "Projects (imported)" : name, parentID: parentID))
            folderMap[uuid] = c.id; if kind == .project { projectMap[uuid] = c.id; rep.projects += 1 } else { rep.folders += 1 }
        }
        // masters & versions
        var masterMap: [String: ID] = [:]
        var masterExifCW: [ID: Int] = [:]
        func ourRotation(_ legacy: Int64, _ master: ID) -> Int { ((Int(legacy) % 360) - (masterExifCW[master] ?? 0) + 720) % 360 }   // Legacy rotation is clockwise from the sensor data; ours is clockwise from the EXIF-oriented image
        var versionByModel: [Int64: ID] = [:]
        var items: [(Master, Version)] = []
        let vrows = try db.query("""
            SELECT v.modelId,v.uuid,v.name,v.masterUuid,v.projectUuid,v.imageDate,v.mainRating,v.isFlagged,v.isHidden,v.colorLabelIndex,v.masterWidth,v.masterHeight,v.rotation,v.isInTrash,v.exifLatitude,v.exifLongitude,v.versionNumber,
                   m.uuid,m.imagePath,m.fileIsReference,m.isTrulyRaw,m.type,m.fileSize,m.fileName,m.projectUuid,m.imageDate
            FROM RKVersion v JOIN RKMaster m ON m.uuid=v.masterUuid ORDER BY v.modelId
            """ + (limitVersions.map { " LIMIT \($0)" } ?? ""))
        for r in vrows {
            let mUUID = r[17].str ?? "", pUUID = r[24].str ?? r[4].str ?? ""
            guard let pid = projectMap[pUUID] ?? projectMap[r[4].str ?? ""] else { continue }
            let rel = r[18].str ?? "", isRef = (r[19].int ?? 0) != 0
            let mid = masterMap[mUUID] ?? newID()
            if masterMap[mUUID] == nil {
                masterMap[mUUID] = mid
                let abs = isRef ? rel : mastersDir.appendingPathComponent(rel).path
                var kind: MediaKind = .image; switch r[21].str ?? "IMGT" { case "VIDT": kind = .video; case "AUDT": kind = .audio; default: break }
                var mw = Int(r[10].int ?? 0), mh = Int(r[11].int ?? 0), exifCW = 0
                if kind == .image, let pr = RenderEngine.probe(url: URL(fileURLWithPath: abs)) {
                    mw = Int(pr.size.width); mh = Int(pr.size.height)                     // oriented size, like our decoder output
                    exifCW = [1: 0, 6: 90, 3: 180, 8: 270][pr.orientation] ?? 0
                }
                masterExifCW[mid] = exifCW
                let m = Master(id: mid, projectID: pid, path: abs, isReference: true, isRaw: Importer.mediaKind(URL(fileURLWithPath: abs))?.raw ?? false, kind: kind, width: mw, height: mh, fileSize: r[22].int ?? 0, checksum: "", importDate: cocoa(r[25]), originalName: r[23].str ?? "")
                if !FileManager.default.fileExists(atPath: abs) { rep.missingMasters.append(r[23].str ?? rel) }
                rep.masters += 1
                _ = m
                var v = Version(masterID: mid, projectID: pid, name: r[2].str ?? "", imageDate: cocoa(r[5]))
                v.rating = Int(r[6].int ?? 0); v.flagged = (r[7].int ?? 0) != 0; v.hidden = (r[8].int ?? 0) != 0; v.colorLabel = Int(r[9].int ?? 0)
                v.rotation = ourRotation(r[12].int ?? 0, mid); v.trashed = (r[13].int ?? 0) != 0; v.latitude = r[14].dbl; v.longitude = r[15].dbl; v.versionNumber = Int(r[16].int ?? 1)
                v.id = r[1].str ?? newID()
                items.append((m, v)); versionByModel[r[0].int ?? 0] = v.id; rep.versions += 1
            } else {
                var v = Version(masterID: mid, projectID: pid, name: r[2].str ?? "", imageDate: cocoa(r[5]))
                v.rating = Int(r[6].int ?? 0); v.flagged = (r[7].int ?? 0) != 0; v.colorLabel = Int(r[9].int ?? 0); v.rotation = ourRotation(r[12].int ?? 0, mid); v.versionNumber = Int(r[16].int ?? 1)
                v.id = r[1].str ?? newID(); v.trashed = (r[13].int ?? 0) != 0
                if let mm = items.first(where: { $0.0.id == mid })?.0 { items.append((mm, v)) }
                versionByModel[r[0].int ?? 0] = v.id; rep.versions += 1
            }
        }
        // masters shared by several versions must not be inserted twice
        var seenMaster = Set<ID>(); var uniq: [(Master, Version)] = []
        for it in items { _ = seenMaster.insert(it.0.id); uniq.append(it) }
        try store.insertBatch(uniq)
        // keywords
        var kwName: [Int64: String] = [:], kwParent: [Int64: Int64] = [:]
        for r in try db.query("SELECT modelId,name,parentId FROM RKKeyword") { kwName[r[0].int ?? 0] = r[1].str ?? ""; if let p = r[2].int, p != 0 { kwParent[r[0].int ?? 0] = p } }
        func kwPath(_ id: Int64) -> String { var parts = [kwName[id] ?? ""]; var p = kwParent[id]; var n = 0; while let x = p, n < 12 { parts.insert(kwName[x] ?? "", at: 0); p = kwParent[x]; n += 1 }; return parts.filter { !$0.isEmpty }.joined(separator: "/") }
        var kws: [ID: [String]] = [:]
        for r in try db.query("SELECT versionId,keywordId FROM RKKeywordForVersion") {
            if let v = versionByModel[r[0].int ?? -1], let k = r[1].int, kwName[k] != nil { kws[v, default: []].append(kwPath(k)); rep.keywords += 1 }
        }
        try store.update(Array(kws.keys)) { $0.keywords = kws[$0.id] ?? [] }
        // adjustments
        var perVersion: [ID: AdjustmentSet] = [:]
        var maskedVersions = Set<ID>()
        for r in try db.query("SELECT versionUuid,name,isEnabled,data,maskUuid FROM RKImageAdjustment ORDER BY versionUuid, adjIndex") {
            guard let vid = r[0].str, store.versions[vid] != nil, let blob = r[3].data, let root = unarchive(blob) else { continue }
            let (adj, ident) = adjustment(from: root)
            let hasMask = !(r[4].str ?? "").isEmpty
            if let a = adj {
                if Catalog.brushSpec(a.id) != nil {
                    var b = BrushAdjustment(op: a.id, params: a.params); b.enabled = a.enabled
                    perVersion[vid, default: AdjustmentSet()].brushes.append(b); rep.adjustments += 1
                    if hasMask { rep.unsupported["brush mask data (\(a.id))", default: 0] += 1; maskedVersions.insert(vid) }
                } else if Catalog.spec(a.id) != nil {
                    var x = a; x.enabled = a.enabled && (r[2].int ?? 1) != 0
                    perVersion[vid, default: AdjustmentSet()].upsert(x); rep.adjustments += 1
                } else { rep.unsupported["operation \(ident)", default: 0] += 1 }
            } else { rep.unsupported["adjustment blob \(ident)", default: 0] += 1 }
        }
        for (vid, set) in perVersion { try store.setAdjustments(vid, set) }
        // versions whose look depends on data we cannot reproduce (brush masks): keep the stored rendering as a labelled fallback
        if !maskedVersions.isEmpty, let proxies = try? SQLiteDB(path: lib.appendingPathComponent("Database/ImageProxies.apdb").path, readOnly: true, immutable: true) {
            try? FileManager.default.createDirectory(at: store.root.appendingPathComponent("Fallbacks"), withIntermediateDirectories: true)
            var kept = 0
            for vid in maskedVersions {
                guard let rel = (try? proxies.query("SELECT fullSizePreviewPath FROM RKImageProxyState WHERE versionUuid=? AND fullSizePreviewUpToDate=1", [.text(vid)]))?.first?[0].str else { continue }
                let src = lib.appendingPathComponent("Previews").appendingPathComponent(rel); let relDst = "Fallbacks/\(vid).jpg"
                let dst = store.root.appendingPathComponent(relDst); try? FileManager.default.removeItem(at: dst)   // a repeated import must refresh the fallback, not lose it
                if FileManager.default.fileExists(atPath: src.path), (try? FileManager.default.copyItem(at: src, to: dst)) != nil { do { try store.update([vid]) { $0.meta["render.fallback"] = relDst }; kept += 1 } catch { rep.notes.append("fallback meta failed for \(vid): \(error)") } }
            }
            if kept > 0 { rep.notes.append("\(kept) versions with brush masks keep the stored preview as a labelled fallback (the masks themselves could not be imported).") }
        }
        // manual albums (smart albums and services are not migrated)
        var albumMap: [Int64: ID] = [:]
        for r in try db.query("SELECT modelId,name,albumType,albumSubclass,folderUuid,isMagic,queryData FROM RKAlbum WHERE albumSubclass IN (3) OR (albumType=1 AND albumSubclass=3)") {
            guard let modelID = r[0].int, let fid = r[4].str, let pid = folderMap[fid] else { continue }
            let c = try store.addContainer(Container(kind: .album, name: r[1].str ?? "Album", parentID: pid)); albumMap[modelID] = c.id; rep.albums += 1
        }
        var members: [ID: [ID]] = [:]
        for r in try db.query("SELECT versionId,albumId FROM RKAlbumVersion") { if let a = albumMap[r[1].int ?? -1], let v = versionByModel[r[0].int ?? -1] { members[a, default: []].append(v) } }
        for (a, vs) in members { try store.addToAlbum(a, vs) }
        rep.unsupported["smart albums, Faces, Places, vault/publish services, brush masks"] = 1
        rep.notes.append("Masters are referenced in place from: \(mastersDir.path)")
        return rep
    }
}
