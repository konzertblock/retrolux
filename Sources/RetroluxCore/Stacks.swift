import Foundation

/// Stacks: groups of similar photos shown as one (pick = position 0). Album picks override the pick inside one album.
public extension LibraryStore {
    func stackMembers(_ stackID: ID) -> [Version] { versions.values.filter { $0.stackID == stackID && !$0.trashed }.sorted { ($0.stackPos, $0.imageDate) < ($1.stackPos, $1.imageDate) } }
    func stackIDs() -> Set<ID> { Set(versions.values.compactMap(\.stackID)) }

    private func renumber(_ stack: ID) throws {
        let m = stackMembers(stack)
        if m.count < 2 { try update(m.map(\.id)) { $0.stackID = nil; $0.stackPos = 0 }; return }
        for (i, v) in m.enumerated() where v.stackPos != i { try update([v.id]) { $0.stackPos = i } }
    }

    /// Puts the given versions into one stack (first id becomes the pick). Existing stacks of the members are merged.
    @discardableResult func makeStack(_ ids: [ID]) throws -> ID? {
        let vs = ids.compactMap { versions[$0] }; guard vs.count >= 2 else { return nil }
        let sid = vs.first(where: { $0.stackID != nil })?.stackID ?? newID()
        let old = Set(vs.compactMap(\.stackID))
        // everything that was in any of the old stacks joins the new one
        let all = versions.values.filter { v in ids.contains(v.id) || (v.stackID != nil && old.contains(v.stackID!)) }
        let order = ids + all.map(\.id).filter { !ids.contains($0) }
        try update(order) { $0.stackID = sid }
        for (i, id) in order.enumerated() { try update([id]) { $0.stackPos = i } }
        return sid
    }
    func unstack(_ ids: [ID]) throws {
        let stacks = Set(ids.compactMap { versions[$0]?.stackID })
        for s in stacks { let members = stackMembers(s).map(\.id); try update(members) { $0.stackID = nil; $0.stackPos = 0 } }
    }
    func extractFromStack(_ ids: [ID]) throws {
        let stacks = Set(ids.compactMap { versions[$0]?.stackID })
        try update(ids) { $0.stackID = nil; $0.stackPos = 0 }
        for s in stacks { try renumber(s) }
    }
    /// Splits the stack in two: the selected version and everything after it form a new stack.
    func splitStack(at id: ID) throws {
        guard let v = versions[id], let sid = v.stackID else { return }
        let m = stackMembers(sid); guard let i = m.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let tail = m[i...].map(\.id); let new = newID()
        try update(Array(tail)) { $0.stackID = new }
        try renumber(sid); try renumber(new)
    }
    func setPick(_ id: ID) throws {
        guard let sid = versions[id]?.stackID else { return }
        var m = stackMembers(sid).map(\.id); m.removeAll { $0 == id }; m.insert(id, at: 0)
        for (i, x) in m.enumerated() { try update([x]) { $0.stackPos = i } }
    }
    func move(inStack id: ID, by d: Int) throws {
        guard let sid = versions[id]?.stackID else { return }
        var m = stackMembers(sid).map(\.id); guard let i = m.firstIndex(of: id) else { return }
        let j = max(0, min(m.count - 1, i + d)); m.swapAt(i, j)
        for (k, x) in m.enumerated() { try update([x]) { $0.stackPos = k } }
    }
    /// Groups consecutive photos (by capture time) whose gap is at most `gap` seconds. Returns number of stacks created.
    @discardableResult func autoStack(_ ids: [ID], gap: TimeInterval) throws -> Int {
        let vs = ids.compactMap { versions[$0] }.filter { $0.stackID == nil }.sorted { $0.imageDate < $1.imageDate }
        var groups: [[ID]] = []; var cur: [Version] = []
        for v in vs { if let l = cur.last, v.imageDate.timeIntervalSince(l.imageDate) > gap { if cur.count > 1 { groups.append(cur.map(\.id)) }; cur = [] }; cur.append(v) }
        if cur.count > 1 { groups.append(cur.map(\.id)) }
        for g in groups { _ = try makeStack(g) }
        return groups.count
    }
    func albumPick(stack: ID, album: ID) -> ID? { (try? dbHandle.query("SELECT pick FROM stack_state WHERE stack=? AND album=?", [.text(stack), .text(album)]))?.first?[0].str }
    func setAlbumPick(stack: ID, album: ID, pick: ID) throws { try dbHandle.run("INSERT OR REPLACE INTO stack_state VALUES(?,?,?)", [.text(stack), .text(album), .text(pick)]); onChange?() }
}
