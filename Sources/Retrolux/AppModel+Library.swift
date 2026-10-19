import SwiftUI
import AppKit
import RetroluxCore

extension AppModel {
    // MARK: stacks
    var currentAlbumID: ID? { if case .container(let id) = source, let c = store.containers[id], c.kind != .project, c.kind != .folder, c.kind != .smartAlbum { return id }; return nil }
    func stackCount(_ v: Version) -> Int { v.stackID.map { store.stackMembers($0).count } ?? 0 }

    /// Collapsed stacks show only their pick (album pick wins inside an album).
    func collapseStacks(_ vs: [Version]) -> [Version] {
        let grouped = Dictionary(grouping: vs.filter { $0.stackID != nil }, by: { $0.stackID! })
        if grouped.isEmpty { return vs }
        var pick: [ID: ID] = [:]
        for (sid, members) in grouped {
            if let a = currentAlbumID, let ap = store.albumPick(stack: sid, album: a), members.contains(where: { $0.id == ap }) { pick[sid] = ap }
            else { pick[sid] = members.min { ($0.stackPos, $0.imageDate) < ($1.stackPos, $1.imageDate) }?.id }
        }
        return vs.filter { v in guard let s = v.stackID, !openStacks.contains(s) else { return true }; return pick[s] == v.id }
    }

    func stackOp(_ name: String, _ op: () throws -> Void) {
        var affected = Set(selection)
        for id in selection { if let s = store.versions[id]?.stackID { store.stackMembers(s).forEach { affected.insert($0.id) } } }
        let before = affected.compactMap { store.versions[$0] }.map { ($0.id, $0.stackID, $0.stackPos) }
        do { try op() } catch { alert = ("Stacks", error.localizedDescription); return }
        var after: [(ID, ID?, Int)] = []
        for id in affected { if let v = store.versions[id] { after.append((id, v.stackID, v.stackPos)) } }
        for id in selection { if let s = store.versions[id]?.stackID { store.stackMembers(s).forEach { m in if !after.contains(where: { $0.0 == m.id }) { after.append((m.id, m.stackID, m.stackPos)) } } } }
        func restore(_ st: [(ID, ID?, Int)]) { for (id, sid, pos) in st { try? store.update([id]) { $0.stackID = sid; $0.stackPos = pos } } }
        let beforeAll = before + after.filter { a in !before.contains { $0.0 == a.0 } }.map { ($0.0, nil, 0) }
        pushUndo(name, undo: { restore(beforeAll) }, redo: { restore(after) })
    }
    func stackSelection() {
        guard selection.count >= 2 else { status = L("Select at least two photos to stack", "Wähle mindestens zwei Fotos zum Stapeln"); return }
        let order = [primary].compactMap { $0 } + selection.filter { $0 != primary }
        stackOp(L("Stack", "Stapeln")) { if let sid = try store.makeStack(order) { openStacks.remove(sid) } }
        status = L("Stacked \(selection.count) photos", "\(selection.count) Fotos gestapelt")
    }
    func unstackSelection() { stackOp(L("Unstack", "Stapel auflösen")) { try store.unstack(selection) } }
    func extractFromStack() { stackOp(L("Extract from Stack", "Aus Stapel entfernen")) { try store.extractFromStack(selection) } }
    func splitStack() { guard let p = primary else { return }; stackOp(L("Split Stack", "Stapel teilen")) { try store.splitStack(at: p) } }
    func setPick() { guard let p = primary else { return }; stackOp(L("Pick", "Auswahlbild")) { try store.setPick(p) } }
    func setAlbumPick() { guard let p = primary, let a = currentAlbumID, let s = store.versions[p]?.stackID else { return }; try? store.setAlbumPick(stack: s, album: a, pick: p) }
    func promote() { guard let p = primary else { return }; stackOp(L("Promote", "Heraufstufen")) { try store.move(inStack: p, by: -1) } }
    func demote() { guard let p = primary else { return }; stackOp(L("Demote", "Herabstufen")) { try store.move(inStack: p, by: 1) } }
    func selectStackItems() { if let s = primaryVersion?.stackID { selection = store.stackMembers(s).map(\.id) } }
    func toggleStack() { if let s = primaryVersion?.stackID { if openStacks.contains(s) { openStacks.remove(s) } else { openStacks.insert(s) }; reloadVersions() } }
    func openAllStacks() { openStacks = store.stackIDs(); reloadVersions() }
    func closeAllStacks() { openStacks = []; reloadVersions() }
    func gotoStack(_ d: Int) {
        guard let p = primary, let i = shown.firstIndex(where: { $0.id == p }) else { return }
        var j = i + d
        while j >= 0 && j < shown.count { if shown[j].stackID != nil && shown[j].stackID != shown[i].stackID { click(shown[j].id, extend: false, toggle: false); return }; j += d }
    }
    func runAutoStack(gap: TimeInterval) {
        let ids = selection.count > 1 ? selection : shown.map(\.id)
        var n = 0
        stackOp(L("Auto-Stack", "Auto-Stapel")) { n = try store.autoStack(ids, gap: gap) }
        status = L("Created \(n) stacks", "\(n) Stapel erstellt"); reloadVersions()
    }
    func autoStackPreview(gap: TimeInterval) -> Int {
        let ids = selection.count > 1 ? selection : shown.map(\.id)
        let vs = ids.compactMap { store.versions[$0] }.filter { $0.stackID == nil }.sorted { $0.imageDate < $1.imageDate }
        var groups = 0, run = 1
        for i in 1..<max(vs.count, 1) { if vs[i].imageDate.timeIntervalSince(vs[i - 1].imageDate) <= gap { run += 1 } else { if run > 1 { groups += 1 }; run = 1 } }
        if run > 1 { groups += 1 }; return groups
    }

    // MARK: libraries (switching = relaunch with the other library)
    var recentLibraries: [URL] {
        let l = (UserDefaults.standard.array(forKey: "recentLibraries") as? [String]) ?? []
        return l.map { URL(fileURLWithPath: $0) }.filter { $0.path != store.root.path && FileManager.default.fileExists(atPath: $0.path) }
    }
    static func rememberLibrary(_ url: URL) {
        var l = (UserDefaults.standard.array(forKey: "recentLibraries") as? [String]) ?? []
        l.removeAll { $0 == url.path }; l.insert(url.path, at: 0); UserDefaults.standard.set(Array(l.prefix(10)), forKey: "recentLibraries"); UserDefaults.standard.set(url.path, forKey: "lastLibrary")
    }
    func clearRecentLibraries() { UserDefaults.standard.removeObject(forKey: "recentLibraries") }
    func switchLibrary(to url: URL) {
        AppModel.rememberLibrary(url)
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in DispatchQueue.main.async { exit(0) } }
        if Bundle.main.bundleURL.pathExtension != "app" { alert = ("Library", L("Restart the app with --library \(url.path)", "App neu starten mit --library \(url.path)")) }
    }
    func chooseLibrary() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.treatsFilePackagesAsDirectories = false; p.message = L("Choose a Retrolux library (.retrolux)", "Retrolux-Bibliothek (.retrolux) wählen")
        if p.runModal() == .OK, let u = p.url { if FileManager.default.fileExists(atPath: u.appendingPathComponent("Library.sqlite").path) { switchLibrary(to: u) } else { alert = ("Library", L("This folder is not a Retrolux library.", "Dieser Ordner ist keine Retrolux-Bibliothek.")) } }
    }
    func newLibrary() {
        let p = NSSavePanel(); p.nameFieldStringValue = "New Library.retrolux"; p.message = L("Create a new library", "Neue Bibliothek anlegen")
        guard p.runModal() == .OK, var u = p.url else { return }
        if u.pathExtension != "retrolux-library" { u.appendPathExtension("retrolux-library") }
        do { _ = try LibraryStore(root: u); switchLibrary(to: u) } catch { alert = ("Library", error.localizedDescription) }
    }
    func mergeLibrary(_ url: URL) {
        progress = 0.1; status = L("Merging library…", "Bibliothek wird zusammengeführt …")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let src = try LibraryStore(root: url)
                let rep = try LibraryMerge.merge(from: src, into: self.store)
                DispatchQueue.main.async { self.progress = nil; self.status = rep.summary; self.log("Merged library \(url.lastPathComponent): \(rep.summary)"); self.alert = (self.L("Merge finished", "Zusammenführen abgeschlossen"), rep.summary + (rep.conflicts.isEmpty ? "" : "\n\n" + rep.conflicts.prefix(8).joined(separator: "\n"))) }
            } catch { DispatchQueue.main.async { self.progress = nil; self.alert = ("Merge", error.localizedDescription) } }
        }
    }
    func exportSelectionAsLibrary() {
        var ids: [ID] = []
        if case .container(let id) = source { ids = [id] } else { ids = Array(Set(selectedVersions.map(\.projectID))) }
        guard !ids.isEmpty else { alert = ("Export", L("Select a project or folder first.", "Wähle zuerst ein Projekt oder einen Ordner.")); return }
        let p = NSSavePanel(); p.nameFieldStringValue = "Export.retrolux"
        guard p.runModal() == .OK, var u = p.url else { return }
        if u.pathExtension != "retrolux-library" { u.appendPathExtension("retrolux-library") }
        progress = 0.1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do { let dst = try LibraryStore(root: u); var o = MergeOptions(); o.containerIDs = ids; let rep = try LibraryMerge.merge(from: self.store, into: dst, options: o)
                DispatchQueue.main.async { self.progress = nil; self.status = rep.summary; NSWorkspace.shared.activateFileViewerSelecting([u]) } }
            catch { DispatchQueue.main.async { self.progress = nil; self.alert = ("Export", error.localizedDescription) } }
        }
    }

    // MARK: structure
    func duplicateContainer() {
        guard case .container(let id) = source, let c = store.containers[id] else { return }
        if c.kind == .album {
            if let n = try? store.addContainer(Container(kind: .album, name: c.name + " Copy", parentID: c.parentID)) { try? store.addToAlbum(n.id, c.members); source = .container(n.id) }
        } else if let n = try? LibraryMerge.duplicateStructure(of: id, in: store) { source = .container(n) }
    }
    func deleteMastersAndVersions() {
        let vs = selectedVersions; guard !vs.isEmpty else { return }
        let a = NSAlert(); a.alertStyle = .critical
        a.messageText = L("Delete master image(s) and all versions?", "Original(e) und alle Versionen löschen?")
        a.informativeText = L("This permanently deletes \(vs.count) selected photo(s) with all their versions. Managed originals are removed from the library; referenced originals stay where they are.", "Dadurch werden \(vs.count) gewählte Foto(s) mit allen Versionen endgültig gelöscht. Verwaltete Originale werden aus der Bibliothek entfernt; referenzierte Originale bleiben liegen.")
        a.addButton(withTitle: L("Delete", "Löschen")).hasDestructiveAction = true; a.addButton(withTitle: L("Cancel", "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? store.deleteMastersAndVersions(of: vs.map(\.id)); status = L("Deleted", "Gelöscht")
    }
    func relocateMasters() {
        let ids = Set(selectedVersions.map(\.masterID)); guard !ids.isEmpty else { return }
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.message = L("Move the originals to this folder (they become referenced files)", "Originale in diesen Ordner verschieben (werden zu referenzierten Dateien)")
        guard p.runModal() == .OK, let u = p.url else { return }
        let r = try? store.relocate(Array(ids), to: u); status = L("Relocated \(r?.done ?? 0) masters", "\(r?.done ?? 0) Originale verlagert"); if let f = r?.failed, !f.isEmpty { alert = ("Relocate", f.joined(separator: "\n")) }
    }
    func consolidateMasters() {
        let ids = Set(selectedVersions.map(\.masterID)); guard !ids.isEmpty else { return }
        let r = try? store.consolidate(Array(ids)); status = L("Consolidated \(r?.done ?? 0) masters into the library", "\(r?.done ?? 0) Originale in die Bibliothek übernommen"); if let f = r?.failed, !f.isEmpty { alert = ("Consolidate", f.joined(separator: "\n")) }
    }
    func locateReferenced() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.message = L("Choose the folder (or drive) that now holds the missing originals", "Ordner (oder Laufwerk) wählen, das die fehlenden Originale enthält")
        guard p.runModal() == .OK, let u = p.url else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let r = try? self.store.locateReferenced(in: u)
            DispatchQueue.main.async { self.status = self.L("Relinked \(r?.relinked ?? 0) originals, \(r?.missing ?? 0) still missing", "\(r?.relinked ?? 0) Originale neu verknüpft, \(r?.missing ?? 0) weiterhin fehlend"); self.reloadVersions(); self.thumbRevision = self.thumbRevision; self.scheduleRender() }
        }
    }

    // MARK: vaults
    func updateAllVaults() {
        let vs = vaultManager.vaults; guard !vs.isEmpty else { alert = (L("Vaults", "Vaults"), L("No vault set up yet. Choose File ▸ Vault ▸ Add Vault….", "Noch kein Vault eingerichtet. Datei ▸ Vault ▸ Vault hinzufügen … wählen.")); return }
        progress = 0
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var msgs: [String] = []
            for v in vs { do { let r = try self.vaultManager.update(v.id, library: self.store) { i, n in DispatchQueue.main.async { self.progress = n > 0 ? Double(i) / Double(n) : 1 } }; msgs.append("\(v.name): \(r.summary)") } catch { msgs.append("\(v.name): \(error.localizedDescription)") } }
            DispatchQueue.main.async { self.progress = nil; self.status = msgs.joined(separator: " | "); self.log(self.status); self.configChanged() }
        }
    }
    func addVault() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.message = L("Choose where the vault is stored (ideally another drive)", "Speicherort des Vaults wählen (am besten ein anderes Laufwerk)")
        guard p.runModal() == .OK, let u = p.url else { return }
        vaultManager.add(Vault(name: u.lastPathComponent, path: u.path)); configChanged(); showVaults = true
    }
    func restoreLibrary() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.treatsFilePackagesAsDirectories = true; p.message = L("Choose a vault (.rlvault) to restore", "Vault (.rlvault) zum Wiederherstellen wählen")
        guard p.runModal() == .OK, let bundle = p.url else { return }
        let sp = NSSavePanel(); sp.nameFieldStringValue = "Restored.retrolux"; sp.message = L("Restore into a new library", "In eine neue Bibliothek wiederherstellen")
        guard sp.runModal() == .OK, var dest = sp.url else { return }
        if dest.pathExtension != "retrolux-library" { dest.appendPathExtension("retrolux-library") }
        progress = 0.2
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do { let r = try VaultManager.restore(vaultBundle: bundle, to: dest)
                DispatchQueue.main.async { self.progress = nil; self.status = self.L("Restored \(r.versions) versions", "\(r.versions) Versionen wiederhergestellt")
                    let a = NSAlert(); a.messageText = self.L("Library restored", "Bibliothek wiederhergestellt"); a.informativeText = self.L("\(r.versions) versions and \(r.masters) masters restored. Open the restored library now?", "\(r.versions) Versionen und \(r.masters) Originale wiederhergestellt. Wiederhergestellte Bibliothek jetzt öffnen?")
                    a.addButton(withTitle: self.L("Open", "Öffnen")); a.addButton(withTitle: self.L("Later", "Später")); if a.runModal() == .alertFirstButtonReturn { self.switchLibrary(to: dest) } }
            } catch { DispatchQueue.main.async { self.progress = nil; self.alert = ("Restore", error.localizedDescription) } }
        }
    }

    // MARK: iPhoto
    func chooseIPhotoLibrary() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.treatsFilePackagesAsDirectories = false; p.message = L("Choose an iPhoto library", "iPhoto-Mediathek wählen")
        guard p.runModal() == .OK, let u = p.url else { return }
        let a = NSAlert(); a.messageText = L("Copy the originals into the library?", "Originale in die Bibliothek kopieren?"); a.informativeText = L("Otherwise the photos stay in the iPhoto library and are referenced.", "Sonst bleiben die Fotos in der iPhoto-Mediathek und werden referenziert.")
        a.addButton(withTitle: L("Copy", "Kopieren")); a.addButton(withTitle: L("Reference", "Referenzieren")); a.addButton(withTitle: L("Cancel", "Abbrechen"))
        let r = a.runModal(); if r == .alertThirdButtonReturn { return }
        progress = 0.2
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do { let rep = try IPhotoLibraryImporter.importLibrary(at: u, into: self.store, copy: r == .alertFirstButtonReturn)
                DispatchQueue.main.async { self.progress = nil; self.status = rep.text; self.showMigrationReport = "iPhoto: " + rep.text + (rep.missing.isEmpty ? "" : "\nMissing: " + rep.missing.prefix(20).joined(separator: ", ")) } }
            catch { DispatchQueue.main.async { self.progress = nil; self.alert = ("iPhoto", error.localizedDescription) } }
        }
    }
}
