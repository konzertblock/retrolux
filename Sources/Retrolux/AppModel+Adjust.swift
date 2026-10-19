import SwiftUI
import AppKit
import RetroluxCore

extension AppModel {
    // MARK: adjustment editing
    func adj(_ id: String) -> Adjustment { adjustments.item(id) ?? Adjustment(id: id, enabled: false, params: Catalog.spec(id)?.defaults ?? [:]) }
    func isOn(_ id: String) -> Bool { adjustments.item(id)?.enabled ?? false }
    func value(_ id: String, _ key: String) -> Double { adj(id).value(key) }

    /// Preferences ▸ Advanced ▸ Create new versions when making adjustments: the first edit of an unadjusted version works on a new version.
    func beginEdit() {
        if UserDefaults.standard.bool(forKey: "newVersionOnAdjust"), let id = primary, let v = store.versions[id], v.versionNumber == 1,
           adjustments.items.allSatisfy({ $0.id == Catalog.raw || $0.isDefault }), let n = try? store.duplicateVersion(id, fromMaster: false) {
            selection = [n.id]; primary = n.id
            status = L("Created a new version for your adjustments", "Neue Version für deine Anpassungen angelegt")
        }
        editSnapshot0 = adjustments
    }
    func endEdit(_ name: String) { commitAdjustments(name) }

    func setParam(_ id: String, _ key: String, _ v: Double, live: Bool = true) {
        guard primary != nil, let spec = Catalog.spec(id) else { return }
        var a = adjustments.item(id) ?? Adjustment(id: id, enabled: true, params: spec.defaults)
        a.enabled = true
        a.params[key] = spec.param(key)?.clamp(v) ?? v
        if id == Catalog.wb { a.params["inputIsDefaults"] = 0 }
        adjustments.upsert(a); scheduleRender()
    }
    func setEnabled(_ id: String, _ on: Bool) {
        var a = adjustments.item(id) ?? Adjustment(id: id, enabled: on, params: Catalog.spec(id)?.defaults ?? [:])
        a.enabled = on; beginEdit(); adjustments.upsert(a); commitAdjustments(L("Toggle Adjustment", "Anpassung ein-/ausschalten")); scheduleRender()
    }
    func resetOp(_ id: String) { beginEdit(); adjustments.remove(id); commitAdjustments(L("Reset Adjustment", "Anpassung zurücksetzen")); scheduleRender() }
    func setCurve(_ id: String, _ key: String, _ pts: [CurvePoint]) {
        var a = adjustments.item(id) ?? Adjustment(id: id, enabled: true, params: Catalog.spec(id)?.defaults ?? [:])
        a.enabled = true; a.curves[key] = pts; adjustments.upsert(a); scheduleRender()
    }
    func applyPreset(_ p: AdjPreset, replace: Bool = false) {
        guard let id = primary else { return }
        beginEdit()
        var cur = replace ? AdjustmentSet(brushes: adjustments.brushes) : adjustments
        for a in p.make().items { cur.upsert(a) }
        adjustments = cur; commitAdjustments(L("Apply Preset", "Voreinstellung anwenden")); _ = id; scheduleRender()
    }
    func commitAdjustments(_ name: String) {
        guard let id = primary else { return }
        let before = editSnapshot0 ?? adjustments, after = adjustments
        editSnapshot0 = nil
        guard before != after else { return }
        try? store.setAdjustments(id, after)
        thumbRevision[id, default: 0] += 1
        pushUndo(name, undo: { [weak self] in self?.applyAdjustmentsUndo(id, before) }, redo: { [weak self] in self?.applyAdjustmentsUndo(id, after) })
    }
    private func applyAdjustmentsUndo(_ id: ID, _ s: AdjustmentSet) {
        try? store.setAdjustments(id, s); thumbRevision[id, default: 0] += 1
        if primary == id { adjustments = s; scheduleRender() }
    }

    // MARK: brush / stroke tools
    func masterPoint(fromDisplay p: CGPoint) -> [Double]? {      // p normalized 0…1, top-left origin, in displayed image
        guard let m = primaryMaster, let v = primaryVersion else { return nil }
        var W = Double(m.width), H = Double(m.height)
        var cropX = 0.0, cropY = 0.0
        if let c = adjustments.item(Catalog.crop), c.enabled { cropX = c.value("inputXOrigin"); cropY = c.value("inputYOrigin"); W = c.value("inputWidth"); H = c.value("inputHeight") }
        var x = Double(p.x), y = Double(p.y)           // fractions of the displayed (rotated) image
        switch ((v.rotation % 360) + 360) % 360 {
        case 90: (x, y) = (y, 1 - x)
        case 180: (x, y) = (1 - x, 1 - y)
        case 270: (x, y) = (1 - y, x)
        default: break
        }
        return [cropX + x * W, cropY + y * H]
    }
    func addStroke(_ pts: [[Double]], source: (Double, Double)? = nil, pressure: [Double] = []) {
        guard primary != nil, !pts.isEmpty else { return }
        beginEdit()
        switch tool {
        case .brush(let op):
            var b = adjustments.brushes.last(where: { $0.op == op && $0.enabled && $0.tonalRange == brushTonal && $0.edgeDetect == brushEdge }) ?? BrushAdjustment(op: op, params: [:])
            b.tonalRange = brushTonal; b.edgeDetect = brushEdge
            var s = Stroke(points: pts, radius: brushRadius, softness: brushSoftness, opacity: 1)
            if pressure.count == pts.count, (pressure.max() ?? 1) - (pressure.min() ?? 1) > 0.02 { s.pressure = pressure }
            if NSEvent.modifierFlags.contains(.option) { s.erase = true }
            if let i = adjustments.brushes.firstIndex(where: { $0.uid == b.uid }) { adjustments.brushes[i].strokes.append(s) } else { b.strokes = [s]; adjustments.brushes.append(b) }
        case .redEye, .spotPatch, .retouch:
            let id = tool == .redEye ? Catalog.redEye : (tool == .spotPatch ? Catalog.spotPatch : Catalog.retouch)
            var a = adjustments.item(id) ?? Adjustment(id: id)
            let s = Stroke(points: pts, radius: brushRadius, softness: tool == .redEye ? 0.3 : brushSoftness, opacity: 1, sourceDX: source?.0 ?? 0, sourceDY: source?.1 ?? 0, mode: 0)
            a.strokes.append(s); a.enabled = true; adjustments.items.removeAll { $0.id == id }; adjustments.items.append(a)
        default: return
        }
        commitAdjustments(L("Brush Stroke", "Pinselstrich")); scheduleRender()
    }
    func clearStrokes() { beginEdit(); adjustments.brushes.removeAll(); for id in [Catalog.redEye, Catalog.spotPatch, Catalog.retouch] { adjustments.remove(id) }; commitAdjustments(L("Clear Strokes", "Pinselstriche löschen")); scheduleRender() }

    // MARK: crop
    func setCrop(x: Double, y: Double, w: Double, h: Double) {
        guard let m = primaryMaster else { return }
        let W = Double(m.width), H = Double(m.height)
        let cw = min(W, max(8, w)), ch = min(H, max(8, h)), cx = min(W - cw, max(0, x)), cy = min(H - ch, max(0, y))
        var a = adjustments.item(Catalog.crop) ?? Adjustment(id: Catalog.crop)
        a.enabled = true; a.params = ["inputXOrigin": cx.rounded(), "inputYOrigin": cy.rounded(), "inputWidth": cw.rounded(), "inputHeight": ch.rounded()]
        adjustments.upsert(a); scheduleRender()
    }
    func applyAspect(_ ratio: Double?) {
        guard let m = primaryMaster else { return }
        let W = Double(m.width), H = Double(m.height)
        guard let r = ratio else { beginEdit(); adjustments.remove(Catalog.crop); commitAdjustments(L("Reset Crop", "Zuschnitt zurücksetzen")); scheduleRender(); return }
        beginEdit()
        var w = W, h = W / r
        if h > H { h = H; w = H * r }
        setCrop(x: (W - w) / 2, y: (H - h) / 2, w: w, h: h); commitAdjustments(L("Crop", "Zuschneiden"))
    }

    // MARK: rendering
    func scheduleRender() {
        guard let v = primaryVersion, let m = primaryMaster, m.kind == .image else { viewerImage = nil; histogram = []; return }
        let url = store.masterURL(m)
        guard FileManager.default.fileExists(atPath: url.path) else { viewerImage = nil; histogram = []; status = L("Original file is offline", "Originaldatei ist offline"); return }
        renderGen += 1; let gen = renderGen
        var set = showMaster ? AdjustmentSet() : adjustments
        if tool == .crop { set.remove(Catalog.crop); set.remove(Catalog.straighten) }
        let px = zoomActual ? min(max(m.width, m.height), 8192) : viewerTargetPixel
        var req = RenderRequest(url: url, isRaw: m.isRaw, originalSize: CGSize(width: m.width, height: m.height), rotation: v.rotation, adjustments: set, maxPixel: px)
        req.maskPreview = showMask
        let hot = hotCold, proof = proofOn ? ColorProfiles.space(named: proofProfile) : nil, gamut = gamutWarning
        let display: CGColorSpace? = useDisplayProfile ? (NSScreen.main?.colorSpace?.cgColorSpace) : nil
        let fallback = (showMaster || tool != .select) ? nil : store.fallbackImage(v, maxPixel: px)
        rendering = true
        if quickPreview {          // embedded/decoded preview without the current edit state (Quick Preview is its own state,)
            let vv = v
            Task { @MainActor in
                let img = await ThumbnailProvider.shared.image(for: vv, store: store, px: min(2400, viewerTargetPixel))
                guard gen == self.renderGen else { return }
                self.rendering = false; self.viewerImage = img; if let img { self.viewerSize = img.size }
            }
            return
        }
        renderQ.async { [weak self] in
            guard let self, gen == self.renderGen else { return }
            var cg = fallback ?? self.engine.renderCG(req, colorSpace: display)
            let hist = cg.map { self.engine.histogram(of: $0) } ?? []
            if hot, let c = cg { let d = UserDefaults.standard; cg = self.engine.clippingOverlay(c, hot: d.object(forKey: "hotThreshold") as? Double ?? 1, cold: d.object(forKey: "coldThreshold") as? Double ?? 1, mono: d.integer(forKey: "clipMono") == 1) ?? c }
            if let p = proof, let c = cg { cg = self.engine.softProof(c, profile: p, gamutWarning: gamut) ?? c }
            DispatchQueue.main.async {
                guard gen == self.renderGen else { return }
                self.rendering = false
                if let cg { self.viewerImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)); self.viewerSize = CGSize(width: cg.width, height: cg.height); self.histogram = hist }
                else { self.viewerImage = nil; self.status = self.L("Could not decode this file", "Datei konnte nicht dekodiert werden") }
            }
        }
    }

    // MARK: import / export
    func runImport(_ urls: [URL], _ opts: ImportOptions) {
        progress = 0; status = L("Importing…", "Importiere …"); log("Import started (\(urls.count) items)")
        let imp = Importer(store: store); activeImporter = imp
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let rep = try imp.importFiles(urls, options: opts) { i, n in DispatchQueue.main.async { self.progress = n > 0 ? Double(i) / Double(n) : 1; self.status = self.L("Importing \(i)/\(n)…", "Importiere \(i)/\(n) …") } }
                DispatchQueue.main.async {
                    self.progress = nil; self.activeImporter = nil; self.status = rep.summary; self.log("Import finished: " + rep.summary)
                    if let p = rep.projectID { self.source = .container(p) }
                    if self.looksUpPlacesAutomatically { self.updatePlaceNames(ids: rep.versionIDs, quiet: true) }
                    var detail = rep.summary
                    if !rep.failed.isEmpty { detail += "\n\n" + rep.failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n") }
                    if !rep.duplicates.isEmpty { detail += "\n\n" + self.L("Duplicates (same checksum):", "Duplikate (gleiche Prüfsumme):") + "\n" + rep.duplicates.prefix(10).joined(separator: ", ") }
                    if !rep.notes.isEmpty { detail += "\n\n" + rep.notes.joined(separator: "\n") }
                    if !rep.duplicates.isEmpty || !rep.failed.isEmpty || !rep.skippedUnsupported.isEmpty || !rep.notes.isEmpty { self.alert = (self.L("Import finished", "Import abgeschlossen"), detail) }
                }
            } catch { DispatchQueue.main.async { self.progress = nil; self.activeImporter = nil; self.alert = ("Import", error.localizedDescription) } }
        }
    }
    func cancelImport() { activeImporter?.cancelled = true; status = L("Cancelling…", "Abbruch …") }
    func runMigration(_ lib: URL, limit: Int? = nil) {
        progress = 0.1; status = L("Importing legacy library…", "Importiere Legacy-Bibliothek …")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let rep = try LegacyLibraryImporter.importLibrary(at: lib, into: self.store, limitVersions: limit)
                DispatchQueue.main.async { self.progress = nil; self.status = L10n.migrated(rep.versions, self.lang); self.showMigrationReport = rep.text; self.source = .all }
            } catch { DispatchQueue.main.async { self.progress = nil; self.alert = ("Legacy library", error.localizedDescription) } }
        }
    }
    func runExport(_ preset: ExportPreset, folder: URL, naming: NamingPolicy, original: Bool, options: ExportOptions = ExportOptions(), custom: String = "Image", subfolder: SubfolderPolicy = .none, customSubfolder: String = "Folder", showAlert: Bool = false) {
        let ids = selection; guard !ids.isEmpty else { return }
        progress = 0; status = L("Exporting…", "Exportiere …")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ex = Exporter(store: self.store)
            do {
                let res = original ? try ex.exportOriginals(ids, to: folder) : try ex.export(ids, preset: preset, to: folder, naming: naming, custom: custom, subfolder: subfolder, customSubfolder: customSubfolder, options: options) { i, n in DispatchQueue.main.async { self.progress = Double(i) / Double(max(1, n)) } }
                DispatchQueue.main.async {
                    self.progress = nil; self.status = self.L("Exported \(res.written.count) files", "\(res.written.count) Dateien exportiert")
                    if !res.failed.isEmpty || !res.notes.isEmpty { self.alert = ("Export", (res.notes + res.failed.map { "\($0.0): \($0.1)" }).joined(separator: "\n")) }
                    if showAlert, let f = res.written.first {
                        // "Show alert when finished": count and path, with Reveal in Finder
                        let a = NSAlert(); a.messageText = self.L("Export finished", "Export abgeschlossen")
                        a.informativeText = self.L("\(res.written.count) versions exported to\n\(folder.path)", "\(res.written.count) Versionen exportiert nach\n\(folder.path)")
                        a.addButton(withTitle: "OK"); a.addButton(withTitle: self.L("Reveal in Finder", "Im Finder zeigen"))
                        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                    }
                }
            } catch { DispatchQueue.main.async { self.progress = nil; self.alert = ("Export", error.localizedDescription) } }
        }
    }
}

enum L10n {
    static func migrated(_ n: Int, _ lang: String) -> String { lang == "de" ? "\(n) Versionen aus Legacy-Bibliothek übernommen" : "\(n) versions imported from legacy library" }
}
