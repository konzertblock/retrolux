import SwiftUI
import AppKit
import RetroluxCore

extension AppModel {
    var currentMetaView: MetadataView { metaConfig.views.first { $0.name == metaViewName } ?? MetadataView.factoryViews[6] }
    func configChanged() { configTick += 1; objectWillChange.send() }

    func setMetaField(_ id: String, _ value: String) {
        let ids = primaryOnly ? (primary.map { [$0] } ?? []) : selection
        guard !ids.isEmpty else { return }
        if id == "name" { if ids.count == 1 { rename(ids[0], value) } else { var ch = BatchChange(); ch.fields = ["name": value]; try? store.batchChange(ids, ch) }; return }
        if id == "caption" { setCaption(value); metaConfig.rememberAutofill(id, value); return }
        withUndo(L("Edit Metadata", "Metadaten ändern"), ids: ids) { $0.meta[id] = value }
        metaConfig.rememberAutofill(id, value)
    }
    func applyMetadataPreset(_ p: MetadataPreset) {
        var ch = BatchChange(); ch.fields = p.fields; ch.mode = .replace
        let ids = selection; guard !ids.isEmpty else { return }
        let before = ids.compactMap { store.versions[$0] }
        try? store.batchChange(ids, ch)
        pushUndo(L("Apply Metadata Preset", "Metadaten-Voreinstellung"), undo: { [weak self] in let m = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) }); try? self?.store.update(Array(m.keys)) { $0 = m[$0.id] ?? $0 } }, redo: { [weak self] in try? self?.store.batchChange(ids, ch) })
        status = L("Applied \"\(p.name)\" to \(ids.count) photos", "„\(p.name)“ auf \(ids.count) Fotos angewendet")
    }
    func runBatchChange(_ ch: BatchChange) {
        let ids = selection; guard !ids.isEmpty else { return }
        let before = ids.compactMap { store.versions[$0] }
        do { try store.batchChange(ids, ch) } catch { alert = ("Batch Change", error.localizedDescription); return }
        pushUndo(L("Batch Change", "Stapeländerung"), undo: { [weak self] in let m = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) }); try? self?.store.update(Array(m.keys)) { $0 = m[$0.id] ?? $0 } }, redo: { [weak self] in try? self?.store.batchChange(ids, ch) })
        status = L("Batch change applied to \(ids.count) photos", "Stapeländerung auf \(ids.count) Fotos angewendet"); log("Batch change on \(ids.count) versions")
    }
    func restoreOriginalDates() { try? store.restoreOriginalDate(selection); status = L("Original dates restored", "Originaldaten wiederhergestellt") }
    func updateFromMaster() {
        let n = (try? store.updateFromMaster(selection)) ?? 0; thumbRevision = thumbRevision; status = L("Updated \(n) versions from their masters", "\(n) Versionen vom Original aktualisiert")
    }
    func writeIPTCToMaster() {
        let vs = selectedVersions; guard !vs.isEmpty else { return }
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = L("Write IPTC metadata to the original files?", "IPTC-Metadaten in die Originaldateien schreiben?")
        a.informativeText = L("This changes the original files of \(vs.count) photo(s) (JPEG, TIFF, PNG). RAW originals are never modified; a .xmp sidecar is written next to them instead.", "Dadurch werden die Originaldateien von \(vs.count) Foto(s) verändert (JPEG, TIFF, PNG). RAW-Originale bleiben unverändert; stattdessen wird daneben eine .xmp-Datei angelegt.")
        a.addButton(withTitle: L("Write", "Schreiben")); a.addButton(withTitle: L("Cancel", "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var written = 0, side = 0, failed = 0
        for v in vs { guard let m = store.masters[v.masterID] else { continue }
            do { if try MetadataWriter.writeIPTC(v, to: store.masterURL(m)) { written += 1; var m2 = m; m2.checksum = (try? Importer.sha256(of: store.masterURL(m))) ?? m.checksum; try? store.updateMaster(m2) } else { side += 1 } } catch { failed += 1 } }
        status = L("IPTC written to \(written) originals, \(side) sidecars, \(failed) failed", "IPTC in \(written) Originale geschrieben, \(side) Sidecars, \(failed) fehlgeschlagen"); log(status)
    }
    func exportMetadataSidecars(to folder: URL) {
        var n = 0
        for v in selectedVersions {
            let base = folder.appendingPathComponent(v.name.replacingOccurrences(of: "/", with: "-") + ".jpg")
            if (try? MetadataWriter.writeSidecar(for: v, nextTo: base)) != nil { n += 1 }
        }
        status = L("Wrote \(n) XMP files", "\(n) XMP-Dateien geschrieben")
    }

    // keyword sets
    var activeKeywordSet: KeywordSet { metaConfig.keywordSets[min(metaConfig.activeKeywordSet, metaConfig.keywordSets.count - 1)] }
    func addKeywordSlot(_ i: Int) { let k = activeKeywordSet.keywords; if i < k.count, !k[i].isEmpty { addKeyword(k[i]) } }
    func removeAllKeywords() { withUndo(L("Remove All Keywords", "Alle Schlagwörter entfernen"), ids: selection) { $0.keywords = [] } }
    func newKeyword(_ name: String, parent: String?) { let path = parent.map { $0 + "/" + name } ?? name; addKeyword(path) }
}

extension AppModel {
    func attachAudioFile() {
        guard let id = primary else { return }
        let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.message = L("Choose an audio file to attach to the photo", "Audiodatei für dieses Foto wählen")
        guard p.runModal() == .OK, let u = p.url else { return }
        do { _ = try store.attachAudio(u, to: id); status = L("Audio attached", "Audio angehängt") } catch { alert = ("Audio", error.localizedDescription) }
    }

    /// Starts a tethered session: every picture the camera reports is downloaded and imported into `projectName`.
    func startTether(camera: CameraManager, projectName: String) {
        let name = projectName.isEmpty ? "Tether " + Date().formatted(date: .abbreviated, time: .shortened) : projectName
        guard let proj = try? store.addContainer(Container(kind: .project, name: name, parentID: nil)) else { return }
        tetherProject = proj.id; tether = camera; source = .container(proj.id)
        camera.onTetherFile = { [weak self] url in
            guard let self, let pid = self.tetherProject else { return }
            var o = ImportOptions(); o.projectID = pid; o.managed = true
            DispatchQueue.global(qos: .userInitiated).async {
                let imp = Importer(store: self.store)
                _ = try? imp.importFiles([url], options: o)
                DispatchQueue.main.async { if let v = imp.importedVersions.first { self.click(v, extend: false, toggle: false) }; self.status = self.L("Captured \(url.lastPathComponent)", "\(url.lastPathComponent) aufgenommen") }
            }
        }
        camera.startTether(into: FileManager.default.temporaryDirectory.appendingPathComponent("rl-tether-\(getpid())"))
        log("Tether session started in \(name)")
    }
}
