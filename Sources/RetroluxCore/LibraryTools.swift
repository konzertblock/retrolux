import Foundation

// MARK: - merge / export parts / project structure

public struct MergeOptions: Sendable {
    public var copyMasters = true            // managed masters are copied into the destination (referenced ones stay references)
    public var containerIDs: [ID]? = nil     // nil = everything
    public var intoParent: ID? = nil
    public init() {}
}
public struct MergeReport: Sendable {
    public var containers = 0, versions = 0, mastersCopied = 0, duplicatesReused = 0
    public var conflicts: [String] = []
    public var summary: String { "\(containers) containers, \(versions) versions, \(mastersCopied) masters copied, \(duplicatesReused) duplicates reused" }
}

public enum LibraryMerge {
    /// Copies containers (with versions, adjustments, keywords, albums, stacks) from `src` into `dst`. New ids are generated, so merging
    /// the same source twice never collides; masters with an identical checksum in `dst` are reused instead of copied again.
    public static func merge(from src: LibraryStore, into dst: LibraryStore, options: MergeOptions = MergeOptions()) throws -> MergeReport {
        var rep = MergeReport()
        func descendants(_ id: ID) -> [ID] { [id] + src.children(of: id).flatMap { descendants($0.id) } }
        let roots: [ID] = options.containerIDs ?? src.children(of: nil).map(\.id)
        let wanted = Set(roots.flatMap(descendants))
        var cmap: [ID: ID] = [:]
        func copyContainer(_ id: ID, parent: ID?) throws {
            guard let c = src.containers[id], wanted.contains(id) else { return }
            var n = Container(kind: c.kind, name: c.name, parentID: parent, query: c.query); n.created = c.created
            let added = try dst.addContainer(n); cmap[id] = added.id; rep.containers += 1
            for ch in src.children(of: id) { try copyContainer(ch.id, parent: added.id) }
        }
        for r in roots { try copyContainer(r, parent: options.intoParent ?? (src.containers[r]?.parentID.flatMap { wanted.contains($0) ? cmap[$0] : nil })) }
        // masters + versions of copied projects
        let projects = src.containers.values.filter { $0.kind == .project && cmap[$0.id] != nil }.map(\.id)
        var vmap: [ID: ID] = [:], mmap: [ID: ID] = [:], smap: [ID: ID] = [:]
        let known = Dictionary(dst.masters.values.filter { !$0.checksum.isEmpty }.map { ($0.checksum, $0.id) }, uniquingKeysWith: { a, _ in a })
        var items: [(Master, Version)] = []
        for pid in projects {
            for v in src.versions.values.filter({ $0.projectID == pid }).sorted(by: { $0.imageDate < $1.imageDate }) {
                guard let m = src.masters[v.masterID] else { continue }
                var master: Master
                if let existing = mmap[m.id] { master = dst.masters[existing] ?? items.first { $0.0.id == existing }!.0 }
                else if !m.checksum.isEmpty, let ex = known[m.checksum], var em = dst.masters[ex] { em.projectID = cmap[pid]!; master = em; mmap[m.id] = em.id; rep.duplicatesReused += 1 }
                else {
                    master = m; master.id = newID(); master.projectID = cmap[pid]!
                    if !m.isReference && options.copyMasters {
                        let from = src.masterURL(m); var to = dst.mastersDir.appendingPathComponent(m.path); var k = 1
                        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        while FileManager.default.fileExists(atPath: to.path) { k += 1; to = to.deletingLastPathComponent().appendingPathComponent("\(to.deletingPathExtension().lastPathComponent)-\(k).\(to.pathExtension)"); rep.conflicts.append(m.originalName) }
                        if FileManager.default.fileExists(atPath: from.path) {
                            try FileManager.default.copyItem(at: from, to: to)
                            if !m.checksum.isEmpty, try Importer.sha256(of: to) != m.checksum { try? FileManager.default.removeItem(at: to); throw NSError(domain: "Merge", code: 1, userInfo: [NSLocalizedDescriptionKey: "checksum mismatch for \(m.originalName)"]) }
                            master.path = String(to.path.dropFirst(dst.mastersDir.path.count + 1)); rep.mastersCopied += 1
                        } else { master.isReference = true; master.path = from.path; rep.conflicts.append("missing: \(m.originalName)") }
                    } else if !m.isReference { master.isReference = true; master.path = src.masterURL(m).path }
                    mmap[m.id] = master.id
                }
                var nv = v; nv.id = newID(); nv.masterID = master.id; nv.projectID = cmap[pid]!
                if let s = v.stackID { nv.stackID = smap[s] ?? { let n = newID(); smap[s] = n; return n }() }
                vmap[v.id] = nv.id; items.append((master, nv)); rep.versions += 1
            }
        }
        try dst.insertBatch(items)
        for (old, new) in vmap { let set = src.adjustments(for: old); if set.hasAny || !set.items.isEmpty { try dst.setAdjustments(new, set) } }
        for c in src.containers.values where cmap[c.id] != nil {
            guard let nid = cmap[c.id] else { continue }
            if c.kind != .project && c.kind != .folder && c.kind != .smartAlbum { try dst.addToAlbum(nid, c.members.compactMap { vmap[$0] }) }
            if let k = c.keyPhotoID, let nk = vmap[k] { try dst.setKeyPhoto(nid, nk) }
        }
        return rep
    }

    /// "Duplicate Project Structure": copies folders/projects/albums without any images.
    @discardableResult public static func duplicateStructure(of id: ID, in store: LibraryStore) throws -> ID? {
        func copy(_ cid: ID, parent: ID?) throws -> ID? {
            guard let c = store.containers[cid] else { return nil }
            var n = Container(kind: c.kind, name: c.name + " Copy", parentID: parent, query: c.query)
            if let p = parent, p != c.parentID { n.name = c.name }
            let added = try store.addContainer(n)
            for ch in store.children(of: cid) { _ = try copy(ch.id, parent: added.id) }
            return added.id
        }
        return try copy(id, parent: store.containers[id]?.parentID)
    }

    /// Moves everything from `sources` projects into `target` (Merge Projects…), then deletes the empty source projects.
    public static func mergeProjects(_ sources: [ID], into target: ID, store: LibraryStore) throws {
        for s in sources where s != target {
            let vs = store.versions.values.filter { $0.projectID == s }.map(\.id)
            try store.update(vs) { $0.projectID = target }
            for m in store.masters.values where m.projectID == s { var m2 = m; m2.projectID = target; try store.updateMaster(m2) }
            try store.deleteContainer(s)
        }
    }
}

// MARK: - master relocation

public extension LibraryStore {
    /// Copies referenced originals into the library (verified by checksum) – "Consolidate Master…".
    @discardableResult func consolidate(_ masterIDs: [ID]) throws -> (done: Int, failed: [String]) {
        var done = 0; var failed: [String] = []
        for id in masterIDs { guard var m = masters[id], m.isReference else { continue }
            let src = masterURL(m)
            guard FileManager.default.fileExists(atPath: src.path) else { failed.append(m.originalName); continue }
            let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
            var dst = mastersDir.appendingPathComponent(f.string(from: Date()) + "/" + m.originalName); var k = 1
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            while FileManager.default.fileExists(atPath: dst.path) { k += 1; dst = dst.deletingLastPathComponent().appendingPathComponent("\(dst.deletingPathExtension().lastPathComponent)-\(k).\(dst.pathExtension)") }
            try FileManager.default.copyItem(at: src, to: dst)
            let sum = try Importer.sha256(of: dst)
            if !m.checksum.isEmpty, sum != m.checksum { try? FileManager.default.removeItem(at: dst); failed.append(m.originalName + " (checksum)"); continue }
            m.checksum = sum; m.isReference = false; m.path = String(dst.path.dropFirst(mastersDir.path.count + 1)); try updateMaster(m); done += 1
        }
        return (done, failed)
    }
    /// Moves managed originals out of the library into `folder` and keeps them as references – "Relocate Master…".
    @discardableResult func relocate(_ masterIDs: [ID], to folder: URL) throws -> (done: Int, failed: [String]) {
        var done = 0; var failed: [String] = []
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in masterIDs { guard var m = masters[id] else { continue }
            let src = masterURL(m); guard FileManager.default.fileExists(atPath: src.path) else { failed.append(m.originalName); continue }
            let dst = Exporter.unique(folder.appendingPathComponent(m.originalName))
            try FileManager.default.copyItem(at: src, to: dst)
            if !m.checksum.isEmpty, try Importer.sha256(of: dst) != m.checksum { try? FileManager.default.removeItem(at: dst); failed.append(m.originalName + " (checksum)"); continue }
            if !m.isReference { try? FileManager.default.removeItem(at: src) }
            m.isReference = true; m.path = dst.path; try updateMaster(m); done += 1
        }
        return (done, failed)
    }
    /// Searches `folder` recursively for offline referenced masters (same file name; checksum or size must match) and relinks them.
    @discardableResult func locateReferenced(in folder: URL) throws -> (relinked: Int, missing: Int) {
        let missing = masters.values.filter { $0.isReference && isMissing($0) }
        guard !missing.isEmpty else { return (0, 0) }
        var index: [String: [URL]] = [:]
        if let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) { for case let u as URL in e { index[u.lastPathComponent, default: []].append(u) } }
        var n = 0
        for var m in missing {
            for cand in index[m.originalName] ?? [] {
                let size = (try? cand.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
                if (m.checksum.isEmpty ? size == m.fileSize || m.fileSize == 0 : ((try? Importer.sha256(of: cand)) == m.checksum)) { m.path = cand.path; try updateMaster(m); n += 1; break }
            }
        }
        return (n, missing.count - n)
    }
    /// "Delete Master Image and All Versions": permanently removes the masters of the given versions (managed files are deleted, referenced never).
    func deleteMastersAndVersions(of ids: [ID]) throws {
        let mids = Set(ids.compactMap { versions[$0]?.masterID })
        let all = versions.values.filter { mids.contains($0.masterID) }.map(\.id)
        try update(all) { $0.trashed = true }
        try emptyTrash()
    }
}

// MARK: - vaults (backups)

public struct Vault: Codable, Identifiable, Equatable, Sendable {
    public var id: ID = newID()
    public var name: String
    public var path: String                       // folder that holds "<library>.rlvault"
    public var lastUpdate: Date? = nil
    public var lastResult: String = ""
    public init(name: String, path: String) { self.name = name; self.path = path }
}
public struct VaultReport: Sendable { public var files = 0, bytes: Int64 = 0, referencedNotBackedUp = 0, removed = 0; public var summary: String { "\(files) files updated, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)); \(referencedNotBackedUp) referenced originals are not part of a vault" } }

public final class VaultManager {
    public private(set) var vaults: [Vault] = []
    let url: URL
    public init(libraryRoot: URL) { url = libraryRoot.appendingPathComponent("Vaults.json"); if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([Vault].self, from: d) { vaults = v } }
    func save() { try? JSONEncoder().encode(vaults).write(to: url, options: .atomic) }
    public func add(_ v: Vault) { vaults.append(v); save() }
    public func remove(_ id: ID) { vaults.removeAll { $0.id == id }; save() }
    public func setPath(_ id: ID, _ path: String) { if let i = vaults.firstIndex(where: { $0.id == id }) { vaults[i].path = path; save() } }
    public func isAvailable(_ v: Vault) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: v.path, isDirectory: &d) && d.boolValue }
    public func bundleURL(_ v: Vault, library: LibraryStore) -> URL { URL(fileURLWithPath: v.path).appendingPathComponent(library.root.deletingPathExtension().lastPathComponent + ".rlvault") }

    /// Incremental update: consistent database snapshot (VACUUM INTO), config files, and the managed Masters folder.
    @discardableResult public func update(_ id: ID, library: LibraryStore, progress: ((Int, Int) -> Void)? = nil) throws -> VaultReport {
        guard let i = vaults.firstIndex(where: { $0.id == id }) else { return VaultReport() }
        guard isAvailable(vaults[i]) else { vaults[i].lastResult = "Vault volume not available"; save(); throw NSError(domain: "Vault", code: 1, userInfo: [NSLocalizedDescriptionKey: "The vault location is not available (is the drive connected?)"]) }
        let dest = bundleURL(vaults[i], library: library)
        var rep = VaultReport()
        let fm = FileManager.default
        try fm.createDirectory(at: dest.appendingPathComponent("Masters"), withIntermediateDirectories: true)
        let tmp = dest.appendingPathComponent("Library.sqlite.new"); try? fm.removeItem(at: tmp)
        try library.dbHandle.exec("VACUUM INTO '\(tmp.path.replacingOccurrences(of: "'", with: "''"))'")
        _ = try? fm.replaceItemAt(dest.appendingPathComponent("Library.sqlite"), withItemAt: tmp)
        if !fm.fileExists(atPath: dest.appendingPathComponent("Library.sqlite").path) { try fm.moveItem(at: tmp, to: dest.appendingPathComponent("Library.sqlite")) }
        for f in ["Presets.json", "MetadataConfig.json", "Vaults.json", "Places.json", "Faces.json"] {
            let src = library.root.appendingPathComponent(f); if fm.fileExists(atPath: src.path) { try? fm.removeItem(at: dest.appendingPathComponent(f)); try fm.copyItem(at: src, to: dest.appendingPathComponent(f)) }
        }
        let managed = library.masters.values.filter { !$0.isReference }
        rep.referencedNotBackedUp = library.masters.values.filter(\.isReference).count
        let wanted = Set(managed.map(\.path))
        for (n, m) in managed.enumerated() {
            progress?(n, managed.count)
            let src = library.masterURL(m), dst = dest.appendingPathComponent("Masters").appendingPathComponent(m.path)
            guard fm.fileExists(atPath: src.path) else { continue }
            let ssize = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1, dsize = (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            if ssize != dsize { try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true); try? fm.removeItem(at: dst); try fm.copyItem(at: src, to: dst); rep.files += 1; rep.bytes += Int64(ssize) }
        }
        if let e = fm.enumerator(at: dest.appendingPathComponent("Masters"), includingPropertiesForKeys: [.isRegularFileKey]) {
            let base = dest.appendingPathComponent("Masters").resolvingSymlinksInPath().path.count + 1      // /var vs /private/var safe
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { if !wanted.contains(String(u.resolvingSymlinksInPath().path.dropFirst(base))) { try? fm.removeItem(at: u); rep.removed += 1 } }
        }
        progress?(managed.count, managed.count)
        vaults[i].lastUpdate = Date(); vaults[i].lastResult = rep.summary; save()
        return rep
    }

    /// Restores a vault into a NEW library folder (never overwrites an existing library).
    public static func restore(vaultBundle: URL, to dest: URL) throws -> (versions: Int, masters: Int) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) || ((try? fm.contentsOfDirectory(atPath: dest.path))?.isEmpty ?? true) else { throw NSError(domain: "Vault", code: 2, userInfo: [NSLocalizedDescriptionKey: "Destination already exists and is not empty"]) }
        guard fm.fileExists(atPath: vaultBundle.appendingPathComponent("Library.sqlite").path) else { throw NSError(domain: "Vault", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not a vault"]) }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: vaultBundle.path) where item != "Vaults.json" { try fm.copyItem(at: vaultBundle.appendingPathComponent(item), to: dest.appendingPathComponent(item)) }
        try fm.createDirectory(at: dest.appendingPathComponent("Thumbnails"), withIntermediateDirectories: true)
        let s = try LibraryStore(root: dest)
        let missing = s.masters.values.filter { !$0.isReference && s.isMissing($0) }.count
        if missing > 0 { throw NSError(domain: "Vault", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(missing) managed masters are missing in the vault"]) }
        return (s.versions.count, s.masters.count)
    }
}

// MARK: - integrity check & repair

public struct RepairReport: Sendable {
    public var issues: [String] = []
    public var fixed: [String] = []
    public var ok: Bool { issues.isEmpty }
    public var text: String { (issues.isEmpty ? "No problems found.\n" : "Problems:\n" + issues.map { "• " + $0 }.joined(separator: "\n") + "\n") + (fixed.isEmpty ? "" : "\nFixed:\n" + fixed.map { "• " + $0 }.joined(separator: "\n")) }
}

public extension LibraryStore {
    func checkIntegrity(verifyChecksums: Bool = false) -> RepairReport {
        var r = RepairReport()
        if let rows = try? dbHandle.query("PRAGMA integrity_check"), rows.first?[0].str != "ok" { r.issues.append("SQLite integrity check: \(rows.compactMap { $0[0].str }.joined(separator: "; "))") }
        let orphanVersions = versions.values.filter { masters[$0.masterID] == nil }; if !orphanVersions.isEmpty { r.issues.append("\(orphanVersions.count) versions without master") }
        let used = Set(versions.values.map(\.masterID)); let orphanMasters = masters.values.filter { !used.contains($0.id) }; if !orphanMasters.isEmpty { r.issues.append("\(orphanMasters.count) masters without version") }
        let noProject = versions.values.filter { containers[$0.projectID] == nil }; if !noProject.isEmpty { r.issues.append("\(noProject.count) versions in a missing project") }
        for c in containers.values { if let p = c.parentID, containers[p] == nil { r.issues.append("container \"\(c.name)\" has a missing parent") } }
        for c in containers.values { var seen = Set<ID>(); var p = c.parentID; while let x = p { if !seen.insert(x).inserted || x == c.id { r.issues.append("container \"\(c.name)\" is part of a cycle"); break }; p = containers[x]?.parentID } }
        let missingFiles = masters.values.filter { isMissing($0) }
        if !missingFiles.isEmpty { r.issues.append("\(missingFiles.count) original files are offline (\(missingFiles.prefix(3).map(\.originalName).joined(separator: ", "))\(missingFiles.count > 3 ? " …" : ""))") }
        let singles = Dictionary(grouping: versions.values.filter { $0.stackID != nil }, by: { $0.stackID! }).filter { $0.value.count < 2 }; if !singles.isEmpty { r.issues.append("\(singles.count) stacks with a single member") }
        if verifyChecksums { var bad = 0; for m in masters.values where !m.isReference && !m.checksum.isEmpty && !isMissing(m) { if (try? Importer.sha256(of: masterURL(m))) != m.checksum { bad += 1 } }; if bad > 0 { r.issues.append("\(bad) managed originals do not match their stored checksum") } }
        return r
    }

    /// Repairs structural problems. A copy of the database is kept as Library.sqlite.pre-repair-<timestamp> first.
    func repair() throws -> RepairReport {
        var r = checkIntegrity()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = root.appendingPathComponent("Library.sqlite.pre-repair-\(stamp)")
        try dbHandle.exec("VACUUM INTO '\(backup.path.replacingOccurrences(of: "'", with: "''"))'")
        r.fixed.append("backup saved as \(backup.lastPathComponent)")
        let orphanV = versions.values.filter { masters[$0.masterID] == nil }.map(\.id)
        if !orphanV.isEmpty { try dbHandle.transaction { for id in orphanV { try dbHandle.run("DELETE FROM version WHERE id=?", [.text(id)]); try dbHandle.run("DELETE FROM adjustment WHERE version=?", [.text(id)]); try dbHandle.run("DELETE FROM version_meta WHERE version=?", [.text(id)]); try dbHandle.run("DELETE FROM version_keyword WHERE version=?", [.text(id)]); try dbHandle.run("DELETE FROM album_member WHERE version=?", [.text(id)]) } }; r.fixed.append("removed \(orphanV.count) versions without master") }
        try dbHandle.exec("DELETE FROM adjustment WHERE version NOT IN (SELECT id FROM version); DELETE FROM album_member WHERE version NOT IN (SELECT id FROM version) OR album NOT IN (SELECT id FROM container); DELETE FROM version_keyword WHERE version NOT IN (SELECT id FROM version); DELETE FROM version_meta WHERE version NOT IN (SELECT id FROM version)")
        try dbHandle.exec("DELETE FROM master WHERE id NOT IN (SELECT master FROM version)")
        for c in containers.values { if let p = c.parentID, containers[p] == nil { try dbHandle.run("UPDATE container SET parent=NULL WHERE id=?", [.text(c.id)]); r.fixed.append("moved \"\(c.name)\" to the top level") } }
        try dbHandle.exec("VACUUM; REINDEX; ANALYZE")
        reloadAll()
        for s in stackIDs() where stackMembers(s).count < 2 { try? unstack(stackMembers(s).map(\.id)) }
        try? FileManager.default.removeItem(at: cacheDir); try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        r.fixed.append("thumbnail cache cleared (regenerated on demand)")
        return r
    }
    /// Re-reads everything from disk (used after repair).
    func reloadAll() { masters = [:]; versions = [:]; containers = [:]; reloadFromDisk(); onChange?() }
}
