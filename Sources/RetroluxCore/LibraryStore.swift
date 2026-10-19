import Foundation

public enum SortKey: String, CaseIterable, Sendable { case manual, name, imageDate, importDate, rating, fileName, label }

/// Persistent library: SQLite file + managed Masters folder. In-memory index for fast browsing (100k versions ≈ tens of MB).
/// All writes go through transactions; a crash cannot leave a half-written change.
public final class LibraryStore {
    public let root: URL
    let db: SQLiteDB
    var dbHandle: SQLiteDB { db }
    public internal(set) var masters: [ID: Master] = [:]
    public internal(set) var versions: [ID: Version] = [:]
    public internal(set) var containers: [ID: Container] = [:]
    var adjCache: [ID: AdjustmentSet] = [:]
    public var onChange: (() -> Void)?
    public let schemaVersion = 1

    public var mastersDir: URL { root.appendingPathComponent("Masters", isDirectory: true) }
    public var cacheDir: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }

    public init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Masters"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Thumbnails"), withIntermediateDirectories: true)
        db = try SQLiteDB(path: root.appendingPathComponent("Library.sqlite").path)
        try createSchema()
        try load()
    }

    private func createSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS container(id TEXT PRIMARY KEY, kind TEXT, name TEXT, parent TEXT, created REAL, sort INTEGER, query TEXT, keyphoto TEXT);
        CREATE TABLE IF NOT EXISTS album_member(album TEXT, version TEXT, pos INTEGER, PRIMARY KEY(album, version));
        CREATE TABLE IF NOT EXISTS master(id TEXT PRIMARY KEY, project TEXT, path TEXT, ref INTEGER, raw INTEGER, kind TEXT, width INTEGER, height INTEGER, size INTEGER, checksum TEXT, imported REAL, origname TEXT);
        CREATE TABLE IF NOT EXISTS version(id TEXT PRIMARY KEY, master TEXT, project TEXT, name TEXT, vnum INTEGER, rating INTEGER, flagged INTEGER, hidden INTEGER, label INTEGER, rotation INTEGER, imagedate REAL, created REAL, trashed INTEGER, lat REAL, lon REAL, caption TEXT, hasadj INTEGER, stack TEXT);
        CREATE TABLE IF NOT EXISTS adjustment(id TEXT PRIMARY KEY, version TEXT, idx INTEGER, op TEXT, enabled INTEGER, json TEXT);
        CREATE TABLE IF NOT EXISTS version_keyword(version TEXT, keyword TEXT, PRIMARY KEY(version, keyword));
        CREATE INDEX IF NOT EXISTS version_project ON version(project);
        CREATE INDEX IF NOT EXISTS version_master ON version(master);
        CREATE INDEX IF NOT EXISTS adjustment_version ON adjustment(version);
        CREATE TABLE IF NOT EXISTS version_meta(version TEXT, key TEXT, value TEXT, PRIMARY KEY(version, key));
        INSERT OR IGNORE INTO meta VALUES('schema','1');
        """)
        // schema 2: original capture date kept after date adjustments
        let cols = try db.query("PRAGMA table_info(version)").compactMap { $0[1].str }
        let ccols = try db.query("PRAGMA table_info(container)").compactMap { $0[1].str }
        if !ccols.contains("settings") { try db.exec("ALTER TABLE container ADD COLUMN settings TEXT") }
        let mcols = try db.query("PRAGMA table_info(master)").compactMap { $0[1].str }
        if !mcols.contains("duration") { try db.exec("ALTER TABLE master ADD COLUMN duration REAL DEFAULT 0") }
        if !cols.contains("stackpos") { try db.exec("ALTER TABLE version ADD COLUMN stackpos INTEGER DEFAULT 0") }
        try db.exec("""
        CREATE TABLE IF NOT EXISTS person(id TEXT PRIMARY KEY, name TEXT, created REAL, keyface TEXT);
        CREATE TABLE IF NOT EXISTS face(id TEXT PRIMARY KEY, version TEXT, x REAL, y REAL, w REAL, h REAL, person TEXT, confirmed INTEGER, suggest TEXT, sdist REAL, embedding BLOB, manual INTEGER, rejected INTEGER);
        CREATE TABLE IF NOT EXISTS face_state(master TEXT PRIMARY KEY, state INTEGER, analyzed REAL);
        CREATE INDEX IF NOT EXISTS face_version ON face(version); CREATE INDEX IF NOT EXISTS face_person ON face(person);
        """)
        try db.exec("CREATE TABLE IF NOT EXISTS stack_state(stack TEXT, album TEXT, pick TEXT, PRIMARY KEY(stack, album))")
        if !cols.contains("origdate") { try db.exec("ALTER TABLE version ADD COLUMN origdate REAL; UPDATE meta SET value='2' WHERE key='schema'") }
    }

    func reloadFromDisk() { adjCache = [:]; try? load() }
    private func load() throws {
        for r in try db.query("SELECT id,kind,name,parent,created,sort,query,keyphoto,settings FROM container") {
            var c = Container(id: r[0].str ?? "", kind: ContainerKind(rawValue: r[1].str ?? "") ?? .album, name: r[2].str ?? "", parentID: r[3].str)
            c.created = Date(timeIntervalSince1970: r[4].dbl ?? 0); c.sortIndex = Int(r[5].int ?? 0)
            if let q = r[6].str, let d = q.data(using: .utf8) { c.query = try? JSONDecoder().decode(SmartQuery.self, from: d) }
            c.keyPhotoID = r[7].str; c.settings = r[8].str
            containers[c.id] = c
        }
        for r in try db.query("SELECT album,version FROM album_member ORDER BY pos") { containers[r[0].str ?? ""]?.members.append(r[1].str ?? "") }
        for r in try db.query("SELECT id,project,path,ref,raw,kind,width,height,size,checksum,imported,origname,duration FROM master") {
            masters[r[0].str ?? ""] = Master(id: r[0].str ?? "", projectID: r[1].str ?? "", path: r[2].str ?? "", isReference: (r[3].int ?? 0) != 0,
                isRaw: (r[4].int ?? 0) != 0, kind: MediaKind(rawValue: r[5].str ?? "image") ?? .image, width: Int(r[6].int ?? 0), height: Int(r[7].int ?? 0),
                fileSize: r[8].int ?? 0, checksum: r[9].str ?? "", importDate: Date(timeIntervalSince1970: r[10].dbl ?? 0), originalName: r[11].str ?? "")
            masters[r[0].str ?? ""]?.duration = r[12].dbl ?? 0
        }
        var kw: [ID: [String]] = [:]
        for r in try db.query("SELECT version,keyword FROM version_keyword") { kw[r[0].str ?? "", default: []].append(r[1].str ?? "") }
        var metaRows: [ID: [String: String]] = [:]
        for r in try db.query("SELECT version,key,value FROM version_meta") { metaRows[r[0].str ?? "", default: [:]][r[1].str ?? ""] = r[2].str ?? "" }
        for r in try db.query("SELECT id,master,project,name,vnum,rating,flagged,hidden,label,rotation,imagedate,created,trashed,lat,lon,caption,hasadj,stack,origdate,stackpos FROM version") {
            var v = Version(id: r[0].str ?? "", masterID: r[1].str ?? "", projectID: r[2].str ?? "", name: r[3].str ?? "")
            v.versionNumber = Int(r[4].int ?? 1); v.rating = Int(r[5].int ?? 0); v.flagged = (r[6].int ?? 0) != 0; v.hidden = (r[7].int ?? 0) != 0
            v.colorLabel = Int(r[8].int ?? 0); v.rotation = Int(r[9].int ?? 0)
            v.imageDate = Date(timeIntervalSince1970: r[10].dbl ?? 0); v.createDate = Date(timeIntervalSince1970: r[11].dbl ?? 0)
            v.trashed = (r[12].int ?? 0) != 0; v.latitude = r[13].dbl; v.longitude = r[14].dbl; v.caption = r[15].str ?? ""
            v.hasAdjustments = (r[16].int ?? 0) != 0; v.stackID = r[17].str; v.keywords = kw[v.id] ?? []; v.meta = metaRows[v.id] ?? [:]
            v.originalImageDate = r[18].dbl.map { Date(timeIntervalSince1970: $0) }; v.stackPos = Int(r[19].int ?? 0)
            versions[v.id] = v
        }
    }

    private func changed() { onChange?() }

    // MARK: containers
    @discardableResult public func addContainer(_ c: Container) throws -> Container {
        var c = c
        c.sortIndex = (containers.values.filter { $0.parentID == c.parentID }.map(\.sortIndex).max() ?? -1) + 1
        let q = c.query.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        try db.run("INSERT INTO container(id,kind,name,parent,created,sort,query,keyphoto,settings) VALUES(?,?,?,?,?,?,?,?,?)", [.text(c.id), .text(c.kind.rawValue), .text(c.name), opt(c.parentID), .double(c.created.timeIntervalSince1970), .int(Int64(c.sortIndex)), opt(q), opt(c.keyPhotoID), opt(c.settings)])
        containers[c.id] = c; changed(); return c
    }
    public func renameContainer(_ id: ID, _ name: String) throws {
        try db.run("UPDATE container SET name=? WHERE id=?", [.text(name), .text(id)]); containers[id]?.name = name; changed()
    }
    public func moveContainer(_ id: ID, to parent: ID?) throws {
        guard id != parent else { return }
        var p = parent; while let x = p { if x == id { return }; p = containers[x]?.parentID }   // no cycles
        try db.run("UPDATE container SET parent=? WHERE id=?", [opt(parent), .text(id)]); containers[id]?.parentID = parent; changed()
    }
    public func setKeyPhoto(_ container: ID, _ version: ID?) throws {
        try db.run("UPDATE container SET keyphoto=? WHERE id=?", [opt(version), .text(container)]); containers[container]?.keyPhotoID = version; changed()
    }
    public func deleteContainer(_ id: ID) throws {
        let kids = containers.values.filter { $0.parentID == id }.map(\.id)
        for k in kids { try deleteContainer(k) }
        // images of a deleted project go to the trash; albums only lose membership
        if containers[id]?.kind == .project { try trash(versions.values.filter { $0.projectID == id }.map(\.id)) }
        try db.run("DELETE FROM album_member WHERE album=?", [.text(id)])
        try db.run("DELETE FROM container WHERE id=?", [.text(id)]); containers[id] = nil; changed()
    }
    public func children(of parent: ID?) -> [Container] {
        containers.values.filter { $0.parentID == parent }.sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }
    public func descendantProjects(of id: ID) -> [ID] {
        guard let c = containers[id] else { return [] }
        if c.kind == .project { return [id] }
        return children(of: id).flatMap { descendantProjects(of: $0.id) }
    }
    public func addToAlbum(_ album: ID, _ ids: [ID]) throws {
        guard var c = containers[album], c.kind != .smartAlbum else { return }
        try db.transaction {
            for v in ids where !c.members.contains(v) {
                try db.run("INSERT INTO album_member VALUES(?,?,?)", [.text(album), .text(v), .int(Int64(c.members.count))]); c.members.append(v)
            }
        }
        containers[album] = c; changed()
    }
    public func removeFromAlbum(_ album: ID, _ ids: [ID]) throws {
        try db.transaction { for v in ids { try db.run("DELETE FROM album_member WHERE album=? AND version=?", [.text(album), .text(v)]) } }
        containers[album]?.members.removeAll { ids.contains($0) }; changed()
    }

    // MARK: masters / versions
    public func masterURL(_ m: Master) -> URL { m.isReference ? URL(fileURLWithPath: m.path) : mastersDir.appendingPathComponent(m.path) }
    public func isMissing(_ m: Master) -> Bool { !FileManager.default.fileExists(atPath: masterURL(m).path) }

    public func insert(master m: Master, version v: Version) throws {
        try db.transaction {
            try db.run("INSERT OR REPLACE INTO master(id,project,path,ref,raw,kind,width,height,size,checksum,imported,origname,duration) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", [.text(m.id), .text(m.projectID), .text(m.path), .int(m.isReference ? 1 : 0), .int(m.isRaw ? 1 : 0), .text(m.kind.rawValue), .int(Int64(m.width)), .int(Int64(m.height)), .int(m.fileSize), .text(m.checksum), .double(m.importDate.timeIntervalSince1970), .text(m.originalName), .double(m.duration)])
            try writeVersion(v)
        }
        masters[m.id] = m; versions[v.id] = v; changed()
    }
    public func insertBatch(_ items: [(Master, Version)]) throws {
        try db.transaction {
            for (m, v) in items {
                try db.run("INSERT OR REPLACE INTO master(id,project,path,ref,raw,kind,width,height,size,checksum,imported,origname,duration) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", [.text(m.id), .text(m.projectID), .text(m.path), .int(m.isReference ? 1 : 0), .int(m.isRaw ? 1 : 0), .text(m.kind.rawValue), .int(Int64(m.width)), .int(Int64(m.height)), .int(m.fileSize), .text(m.checksum), .double(m.importDate.timeIntervalSince1970), .text(m.originalName), .double(m.duration)])
                try writeVersion(v)
            }
        }
        for (m, v) in items { masters[m.id] = m; versions[v.id] = v }; changed()
    }
    private func writeVersion(_ v: Version) throws {
        try db.run("INSERT OR REPLACE INTO version(id,master,project,name,vnum,rating,flagged,hidden,label,rotation,imagedate,created,trashed,lat,lon,caption,hasadj,stack,origdate,stackpos) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [.text(v.id), .text(v.masterID), .text(v.projectID), .text(v.name), .int(Int64(v.versionNumber)), .int(Int64(v.rating)), .int(v.flagged ? 1 : 0), .int(v.hidden ? 1 : 0), .int(Int64(v.colorLabel)), .int(Int64(v.rotation)), .double(v.imageDate.timeIntervalSince1970), .double(v.createDate.timeIntervalSince1970), .int(v.trashed ? 1 : 0), opt(v.latitude), opt(v.longitude), .text(v.caption), .int(v.hasAdjustments ? 1 : 0), opt(v.stackID), opt(v.originalImageDate?.timeIntervalSince1970), .int(Int64(v.stackPos))])
        try db.run("DELETE FROM version_meta WHERE version=?", [.text(v.id)])
        for (k, val) in v.meta where !val.isEmpty { try db.run("INSERT INTO version_meta VALUES(?,?,?)", [.text(v.id), .text(k), .text(val)]) }
        try db.run("DELETE FROM version_keyword WHERE version=?", [.text(v.id)])
        for k in Set(v.keywords) { try db.run("INSERT INTO version_keyword VALUES(?,?)", [.text(v.id), .text(k)]) }
    }
    public func update(_ ids: [ID], _ mutate: (inout Version) -> Void) throws {
        var out: [Version] = []
        for id in ids { if var v = versions[id] { mutate(&v); out.append(v) } }
        try db.transaction { for v in out { try writeVersion(v) } }
        for v in out { versions[v.id] = v }; changed()
    }
    public func trash(_ ids: [ID]) throws { try update(ids) { $0.trashed = true } }
    public func restore(_ ids: [ID]) throws { try update(ids) { $0.trashed = false } }
    /// Permanently removes trashed versions; masters without versions are removed, managed files deleted, referenced originals never touched.
    public func emptyTrash() throws {
        let gone = versions.values.filter(\.trashed).map(\.id)
        try db.transaction {
            for id in gone {
                try db.run("DELETE FROM version WHERE id=?", [.text(id)]); try db.run("DELETE FROM adjustment WHERE version=?", [.text(id)])
                try db.run("DELETE FROM version_keyword WHERE version=?", [.text(id)]); try db.run("DELETE FROM album_member WHERE version=?", [.text(id)])
            }
        }
        for id in gone { versions[id] = nil; adjCache[id] = nil }
        for c in containers.keys { containers[c]?.members.removeAll { versions[$0] == nil } }
        let used = Set(versions.values.map(\.masterID))
        for m in masters.values where !used.contains(m.id) {
            try db.run("DELETE FROM master WHERE id=?", [.text(m.id)])
            if !m.isReference { try? FileManager.default.removeItem(at: masterURL(m)) }
            masters[m.id] = nil
        }
        changed()
    }
    @discardableResult public func duplicateVersion(_ id: ID, fromMaster: Bool = false) throws -> Version? {
        guard var v = versions[id] else { return nil }
        let n = (versions.values.filter { $0.masterID == v.masterID }.map(\.versionNumber).max() ?? 1) + 1
        v.id = newID(); v.versionNumber = n; v.createDate = Date(); v.stackID = nil
        v.name = v.name.replacingOccurrences(of: #" \(Version \d+\)$"#, with: "", options: .regularExpression) + " (Version \(n))"
        let set = fromMaster ? AdjustmentSet() : adjustments(for: id)
        try db.transaction { try writeVersion(v) }
        versions[v.id] = v
        try setAdjustments(v.id, set)
        return v
    }

    // MARK: adjustments
    public func adjustments(for id: ID) -> AdjustmentSet {
        if let c = adjCache[id] { return c }
        var set = AdjustmentSet()
        if let rows = try? db.query("SELECT op,enabled,json FROM adjustment WHERE version=? ORDER BY idx", [.text(id)]) {
            for r in rows {
                guard let j = r[2].str?.data(using: .utf8) else { continue }
                if Catalog.brushSpec(r[0].str ?? "") != nil, var b = try? JSONDecoder().decode(BrushAdjustment.self, from: j) { b.enabled = (r[1].int ?? 1) != 0; set.brushes.append(b) }
                else if var a = try? JSONDecoder().decode(Adjustment.self, from: j) { a.enabled = (r[1].int ?? 1) != 0; set.items.append(a) }
            }
        }
        set.engineVersion = Int(versions[id]?.meta["engine"] ?? "") ?? 1
        adjCache[id] = set; return set
    }
    public func setAdjustments(_ id: ID, _ set: AdjustmentSet) throws {
        try db.transaction {
            try db.run("DELETE FROM adjustment WHERE version=?", [.text(id)])
            var i = 0
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            for a in set.items { try db.run("INSERT INTO adjustment VALUES(?,?,?,?,?,?)", [.text(newID()), .text(id), .int(Int64(i)), .text(a.id), .int(a.enabled ? 1 : 0), .text(String(data: try enc.encode(a), encoding: .utf8) ?? "{}")]); i += 1 }
            for b in set.brushes { try db.run("INSERT INTO adjustment VALUES(?,?,?,?,?,?)", [.text(newID()), .text(id), .int(Int64(i)), .text(b.op), .int(b.enabled ? 1 : 0), .text(String(data: try enc.encode(b), encoding: .utf8) ?? "{}")]); i += 1 }
            let has = set.hasAny ? 1 : 0
            try db.run("UPDATE version SET hasadj=? WHERE id=?", [.int(Int64(has)), .text(id)])
        }
        if set.engineVersion != 1 || versions[id]?.meta["engine"] != nil { try update([id]) { $0.meta["engine"] = set.engineVersion == 1 ? nil : String(set.engineVersion) } }
        adjCache[id] = set; versions[id]?.hasAdjustments = set.hasAny; changed()
    }

    // MARK: querying
    public func versions(in containerID: ID?, includeTrashed: Bool = false) -> [Version] {
        let all = versions.values.filter { includeTrashed ? $0.trashed : !$0.trashed }
        guard let cid = containerID, let c = containers[cid] else { return Array(all) }
        switch c.kind {
        case .project: return all.filter { $0.projectID == cid }
        case .folder: let ps = Set(descendantProjects(of: cid)); return all.filter { ps.contains($0.projectID) }
        case .album, .book, .lightTable, .slideshow, .webJournal:
            let order = Dictionary(uniqueKeysWithValues: c.members.enumerated().map { ($1, $0) })
            return all.filter { order[$0.id] != nil }.sorted { order[$0.id]! < order[$1.id]! }
        case .smartAlbum: guard let q = c.query else { return [] }; return all.filter { matches($0, q) }
        }
    }
    public func matches(_ v: Version, _ q: SmartQuery) -> Bool {
        func test(_ r: SmartRule) -> Bool {
            let m = masters[v.masterID]
            switch r.field {
            case .rating: let n = Int(r.value) ?? 0; return r.op == .atLeast ? v.rating >= n : r.op == .atMost ? v.rating <= n : v.rating == n
            case .flagged: return (r.op == .isTrue) == v.flagged
            case .colorLabel: return (v.colorLabel == (Int(r.value) ?? 0)) == (r.op != .notEquals)
            case .keyword: return v.keywords.contains { $0.localizedCaseInsensitiveContains(r.value) } == (r.op != .notEquals)
            case .name: return v.name.localizedCaseInsensitiveContains(r.value) == (r.op != .notEquals)
            case .caption: return v.caption.localizedCaseInsensitiveContains(r.value) == (r.op != .notEquals)
            case .hasAdjustments: return (r.op == .isTrue) == v.hasAdjustments
            case .isRaw: return (r.op == .isTrue) == (m?.isRaw ?? false)
            case .imageDate: let t = Double(r.value) ?? 0; return r.op == .after ? v.imageDate.timeIntervalSince1970 >= t : v.imageDate.timeIntervalSince1970 <= t
            }
        }
        if q.rules.isEmpty { return true }
        return q.matchAll ? q.rules.allSatisfy(test) : q.rules.contains(where: test)
    }
    public static func sorted(_ vs: [Version], by key: SortKey, ascending: Bool, masters: [ID: Master]) -> [Version] {
        let s: [Version]
        switch key {
        case .manual: s = vs
        case .name: s = vs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .fileName: s = vs.sorted { (masters[$0.masterID]?.originalName ?? "").localizedStandardCompare(masters[$1.masterID]?.originalName ?? "") == .orderedAscending }
        case .imageDate: s = vs.sorted { $0.imageDate < $1.imageDate }
        case .importDate: s = vs.sorted { (masters[$0.masterID]?.importDate ?? .distantPast) < (masters[$1.masterID]?.importDate ?? .distantPast) }
        case .rating: s = vs.sorted { $0.rating < $1.rating }
        case .label: s = vs.sorted { $0.colorLabel < $1.colorLabel }
        }
        return ascending ? s : s.reversed()
    }
    public var allKeywords: [String] { Array(Set(versions.values.flatMap(\.keywords))).sorted() }
}

public extension LibraryStore {
    func setQuery(_ id: ID, _ q: SmartQuery) {
        guard let d = try? JSONEncoder().encode(q), let s = String(data: d, encoding: .utf8) else { return }
        try? db.run("UPDATE container SET query=? WHERE id=?", [.text(s), .text(id)]); containers[id]?.query = q; onChange?()
    }
}

public extension LibraryStore {
    /// Updates a master row in place (checksum after an explicit IPTC write, relinked path, …).
    func updateMaster(_ m: Master) throws {
        try db.run("UPDATE master SET project=?,path=?,ref=?,raw=?,kind=?,width=?,height=?,size=?,checksum=?,origname=?,duration=? WHERE id=?", [.text(m.projectID), .text(m.path), .int(m.isReference ? 1 : 0), .int(m.isRaw ? 1 : 0), .text(m.kind.rawValue), .int(Int64(m.width)), .int(Int64(m.height)), .int(m.fileSize), .text(m.checksum), .text(m.originalName), .double(m.duration), .text(m.id)])
        masters[m.id] = m; onChange?()
    }
}

extension LibraryStore {
    /// File of the RAW+JPEG pair kept next to the master (RAW+JPEG Pairs import modes), if any.
    public func companionURL(for v: Version) -> URL? {
        guard let p = v.meta["pair.companion"] else { return nil }
        return v.meta["pair.companion.managed"] == "1" ? mastersDir.appendingPathComponent(p) : URL(fileURLWithPath: p)
    }
}

