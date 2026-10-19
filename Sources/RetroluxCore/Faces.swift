import Foundation
import Vision
import CoreGraphics
import ImageIO

public struct Person: Identifiable, Equatable, Sendable { public var id: ID; public var name: String; public var created: Date; public var keyFace: ID? }

public struct Face: Identifiable, Equatable, Sendable {
    public var id: ID
    public var versionID: ID
    public var rect: CGRect                 // normalized, origin top-left, in the EXIF-oriented master image
    public var personID: ID?
    public var confirmed: Bool              // true = the user named/confirmed it; false + suggestion = machine guess
    public var suggestedID: ID?
    public var suggestedDistance: Double
    public var embedding: Data?
    public var manual: Bool
}

public struct DetectedFace: Sendable { public var rect: CGRect; public var embedding: Data; public init(rect: CGRect, embedding: Data) { self.rect = rect; self.embedding = embedding } }

public protocol FaceEngine {
    func analyze(_ image: CGImage) -> [DetectedFace]
    /// identity vector for a user-drawn face rectangle (normalized, top-left origin)
    func embedding(of image: CGImage, rect: CGRect) -> Data
}
public extension FaceEngine { func embedding(of image: CGImage, rect: CGRect) -> Data { Data() } }

/// Local face detection with Vision; the identity vector is the Vision image feature print of the face crop (nothing leaves the Mac).
public struct VisionFaceEngine: FaceEngine {
    public init() {}
    public func embedding(of image: CGImage, rect: CGRect) -> Data {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let r = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let crop = image.cropping(to: CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H).integral) else { return Data() }
        let fp = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([fp])) != nil, let o = fp.results?.first else { return Data() }
        return o.data
    }
    public func analyze(_ image: CGImage) -> [DetectedFace] {
        let req = VNDetectFaceRectanglesRequest()
        let h = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? h.perform([req])) != nil, let obs = req.results else { return [] }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        var out: [DetectedFace] = []
        for o in obs where o.confidence > 0.5 {
            let b = o.boundingBox
            let top = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            let pad = CGRect(x: top.minX - top.width * 0.2, y: top.minY - top.height * 0.25, width: top.width * 1.4, height: top.height * 1.5).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let crop = image.cropping(to: CGRect(x: pad.minX * W, y: pad.minY * H, width: pad.width * W, height: pad.height * H).integral) else { continue }
            let fp = VNGenerateImageFeaturePrintRequest()
            guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([fp])) != nil, let r = fp.results?.first else { continue }
            out.append(DetectedFace(rect: top, embedding: r.data))
        }
        return out
    }
}

public extension LibraryStore {
    // MARK: people
    func people() -> [Person] {
        ((try? dbHandle.query("SELECT id,name,created,keyface FROM person ORDER BY name COLLATE NOCASE")) ?? []).map { Person(id: $0[0].str ?? "", name: $0[1].str ?? "", created: Date(timeIntervalSince1970: $0[2].dbl ?? 0), keyFace: $0[3].str) }
    }
    @discardableResult func createPerson(_ name: String) throws -> Person {
        if let e = people().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return e }
        let p = Person(id: newID(), name: name, created: Date(), keyFace: nil)
        try dbHandle.run("INSERT INTO person VALUES(?,?,?,NULL)", [.text(p.id), .text(p.name), .double(p.created.timeIntervalSince1970)]); onChange?(); return p
    }
    func renamePerson(_ id: ID, _ name: String) throws { try dbHandle.run("UPDATE person SET name=? WHERE id=?", [.text(name), .text(id)]); onChange?() }
    /// Merges `source` into `target`: all faces (confirmed or suggested) move, the duplicate person disappears. Confirmed names are never lost.
    func mergePeople(_ source: ID, into target: ID) throws {
        guard source != target else { return }
        try dbHandle.transaction {
            try dbHandle.run("UPDATE face SET person=? WHERE person=?", [.text(target), .text(source)])
            try dbHandle.run("UPDATE face SET suggest=? WHERE suggest=?", [.text(target), .text(source)])
            try dbHandle.run("DELETE FROM person WHERE id=?", [.text(source)])
        }
        onChange?()
    }
    func deletePerson(_ id: ID) throws { try dbHandle.transaction { try dbHandle.run("UPDATE face SET person=NULL, confirmed=0 WHERE person=?", [.text(id)]); try dbHandle.run("UPDATE face SET suggest=NULL WHERE suggest=?", [.text(id)]); try dbHandle.run("DELETE FROM person WHERE id=?", [.text(id)]) }; onChange?() }

    // MARK: faces
    private func face(_ r: [SQLValue]) -> Face {
        Face(id: r[0].str ?? "", versionID: r[1].str ?? "", rect: CGRect(x: r[2].dbl ?? 0, y: r[3].dbl ?? 0, width: r[4].dbl ?? 0, height: r[5].dbl ?? 0), personID: r[6].str, confirmed: (r[7].int ?? 0) != 0,
             suggestedID: r[8].str, suggestedDistance: r[9].dbl ?? 0, embedding: r[10].data, manual: (r[11].int ?? 0) != 0)
    }
    private static let faceCols = "id,version,x,y,w,h,person,confirmed,suggest,sdist,embedding,manual"
    func faces(of version: ID) -> [Face] { ((try? dbHandle.query("SELECT \(Self.faceCols) FROM face WHERE version=? AND rejected=0", [.text(version)])) ?? []).map(face) }
    func faces(of person: ID, confirmedOnly: Bool = false) -> [Face] { ((try? dbHandle.query("SELECT \(Self.faceCols) FROM face WHERE person=? AND rejected=0" + (confirmedOnly ? " AND confirmed=1" : ""), [.text(person)])) ?? []).map(face) }
    func unnamedFaces() -> [Face] { ((try? dbHandle.query("SELECT \(Self.faceCols) FROM face WHERE person IS NULL AND rejected=0")) ?? []).map(face) }
    func allFaces() -> [Face] { ((try? dbHandle.query("SELECT \(Self.faceCols) FROM face WHERE rejected=0")) ?? []).map(face) }
    func versions(of person: ID, includeSuggested: Bool = true) -> [Version] {
        let ids = Set(((try? dbHandle.query("SELECT DISTINCT version FROM face WHERE rejected=0 AND (person=?" + (includeSuggested ? " OR suggest=?" : "") + ")", includeSuggested ? [.text(person), .text(person)] : [.text(person)])) ?? []).compactMap { $0[0].str })
        return ids.compactMap { versions[$0] }.filter { !$0.trashed }
    }
    func peopleNames(of version: ID) -> [String] { Array(Set(faces(of: version).filter { $0.confirmed }.compactMap { f in f.personID.flatMap { pid in people().first { $0.id == pid }?.name } })).sorted() }
    func insertFaces(_ detected: [DetectedFace], version: ID, manual: Bool = false) throws -> [Face] {
        var out: [Face] = []
        try dbHandle.transaction {
            for d in detected {
                let f = Face(id: newID(), versionID: version, rect: d.rect, personID: nil, confirmed: false, suggestedID: nil, suggestedDistance: 0, embedding: d.embedding, manual: manual)
                try dbHandle.run("INSERT INTO face VALUES(?,?,?,?,?,?,NULL,0,NULL,0,?,?,0)", [.text(f.id), .text(version), .double(d.rect.minX), .double(d.rect.minY), .double(d.rect.width), .double(d.rect.height), d.embedding.isEmpty ? .null : .blob(d.embedding), .int(manual ? 1 : 0)])
                out.append(f)
            }
        }
        onChange?(); return out
    }
    /// The user names a face: confirmed = true, never overwritten by later re-analysis.
    func nameFace(_ id: ID, person: ID) throws {
        try dbHandle.run("UPDATE face SET person=?, confirmed=1, suggest=NULL WHERE id=?", [.text(person), .text(id)])
        if let p = people().first(where: { $0.id == person }), p.keyFace == nil { try dbHandle.run("UPDATE person SET keyface=? WHERE id=?", [.text(id), .text(person)]) }
        onChange?()
    }
    func confirmSuggestion(_ id: ID) throws { try dbHandle.run("UPDATE face SET person=suggest, confirmed=1, suggest=NULL WHERE id=? AND suggest IS NOT NULL", [.text(id)]); onChange?() }
    func rejectSuggestion(_ id: ID) throws { try dbHandle.run("UPDATE face SET suggest=NULL, sdist=0 WHERE id=?", [.text(id)]); onChange?() }
    func unnameFace(_ id: ID) throws { try dbHandle.run("UPDATE face SET person=NULL, confirmed=0 WHERE id=?", [.text(id)]); onChange?() }
    func markNotAFace(_ id: ID) throws { try dbHandle.run("UPDATE face SET rejected=1 WHERE id=?", [.text(id)]); onChange?() }
    func faceState(master: ID) -> Int { ((try? dbHandle.query("SELECT state FROM face_state WHERE master=?", [.text(master)]))?.first?[0].int).map(Int.init) ?? 0 }
    func setFaceState(master: ID, _ s: Int) throws { try dbHandle.run("INSERT OR REPLACE INTO face_state VALUES(?,?,?)", [.text(master), .int(Int64(s)), .double(Date().timeIntervalSince1970)]) }
    ///: remove all face data (faces, people, analysis state).
    func deleteAllFaceData() throws { try dbHandle.exec("DELETE FROM face; DELETE FROM person; DELETE FROM face_state"); onChange?() }
    func mastersNeedingFaceAnalysis() -> [Master] { masters.values.filter { $0.kind == .image && faceState(master: $0.id) == 0 && !isMissing($0) } }
}

public final class FaceAnalyzer {
    let store: LibraryStore; let engine: FaceEngine
    public var threshold = 0.62                    // feature-print distance below which a face is suggested for a person
    public init(store: LibraryStore, engine: FaceEngine = VisionFaceEngine()) { self.store = store; self.engine = engine }

    public static func vector(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    public static func distance(_ a: Data, _ b: Data) -> Double {
        let x = vector(a), y = vector(b); guard x.count == y.count, !x.isEmpty else { return .infinity }
        var s: Double = 0; for i in 0..<x.count { let d = Double(x[i] - y[i]); s += d * d }; return s.squareRoot()
    }

    /// Detects faces of one version (on a ≤1600 px rendering of the oriented image) and stores them. Already named faces stay untouched.
    @discardableResult public func analyze(version vid: ID) throws -> Int {
        guard let v = store.versions[vid], let m = store.masters[v.masterID], m.kind == .image else { return 0 }
        let url = store.masterURL(m)
        let req = RenderRequest(url: url, isRaw: m.isRaw, originalSize: CGSize(width: m.width, height: m.height), rotation: v.rotation, adjustments: AdjustmentSet(), maxPixel: 1600)
        guard let cg = RenderEngine.shared.renderCG(req) else { return 0 }
        let found = engine.analyze(cg)
        let existing = store.faces(of: vid)
        let keep = existing.filter { $0.confirmed || $0.manual }
        // drop machine-found, unconfirmed faces from an earlier run; keep confirmed ones and avoid duplicates of them
        for f in existing where !f.confirmed && !f.manual { try store.markNotAFace(f.id) }
        let fresh = found.filter { d in !keep.contains { overlap($0.rect, d.rect) > 0.4 } }
        _ = try store.insertFaces(fresh, version: vid)
        try store.setFaceState(master: m.id, 1)
        return fresh.count
    }
    /// Adds a face the detector missed (user-drawn rectangle in fractions of the rotated, uncropped image).
    @discardableResult public func addManualFace(version vid: ID, rect: CGRect) throws -> Face? {
        guard let v = store.versions[vid], let m = store.masters[v.masterID] else { return nil }
        let req = RenderRequest(url: store.masterURL(m), isRaw: m.isRaw, originalSize: CGSize(width: m.width, height: m.height), rotation: v.rotation, adjustments: AdjustmentSet(), maxPixel: 1600)
        let emb = RenderEngine.shared.renderCG(req).map { engine.embedding(of: $0, rect: rect) } ?? Data()
        return try store.insertFaces([DetectedFace(rect: rect, embedding: emb)], version: vid, manual: true).first
    }
    func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat { let i = a.intersection(b); guard !i.isNull else { return 0 }; return (i.width * i.height) / min(a.width * a.height, b.width * b.height) }

    /// Suggests a person for every unnamed face (nearest confirmed faces; mean of the 3 closest). Confirmed assignments are never changed.
    @discardableResult public func suggestAll() throws -> Int {
        let people = store.people()
        var refs: [ID: [Data]] = [:]; for p in people { refs[p.id] = store.faces(of: p.id, confirmedOnly: true).compactMap(\.embedding) }
        var n = 0
        for f in store.unnamedFaces() {
            guard let e = f.embedding else { continue }
            var best: (ID, Double)?
            for (pid, list) in refs where !list.isEmpty {
                let ds = list.map { FaceAnalyzer.distance(e, $0) }.sorted(); let d = ds.prefix(3).reduce(0, +) / Double(min(3, ds.count))
                if d < threshold, best == nil || d < best!.1 { best = (pid, d) }
            }
            if let b = best { try store.dbHandle.run("UPDATE face SET suggest=?, sdist=? WHERE id=? AND confirmed=0", [.text(b.0), .double(b.1), .text(f.id)]); n += 1 }
            else if f.suggestedID != nil { try store.rejectSuggestion(f.id) }
        }
        store.onChange?(); return n
    }
    /// Groups unnamed faces that look alike so many can be named at once.
    public func clusterUnnamed(maxDistance: Double? = nil) -> [[Face]] {
        let faces = store.unnamedFaces().filter { $0.embedding != nil }; let th = maxDistance ?? threshold
        var groups: [[Face]] = []
        for f in faces {
            if let i = groups.firstIndex(where: { g in g.contains { FaceAnalyzer.distance($0.embedding!, f.embedding!) < th } }) { groups[i].append(f) } else { groups.append([f]) }
        }
        return groups.sorted { $0.count > $1.count }
    }
}
