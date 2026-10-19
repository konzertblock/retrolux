import SwiftUI
import AppKit
import RetroluxCore

extension AppModel {
    func regenerateThumbnails() {
        let dir = store.cacheDir
        try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for v in shown { thumbRevision[v.id, default: 0] += 1 }
        status = L("Thumbnails are being regenerated", "Miniaturen werden neu erzeugt"); log("Regenerate thumbnails")
    }
    // MARK: activity log
    func log(_ s: String) { let f = DateFormatter(); f.timeStyle = .medium; activity.insert("\(f.string(from: Date()))  \(s)", at: 0); if activity.count > 300 { activity.removeLast() } }

    // MARK: label names (Preferences ▸ Labels)
    func labelName(_ i: Int) -> String {
        guard i > 0, i < Labels.names.count else { return "" }
        if i - 1 < labelNames.count, !labelNames[i - 1].isEmpty { return labelNames[i - 1] }
        return lang == "de" ? Labels.namesDE[i] : Labels.names[i]
    }
    func setLabelName(_ i: Int, _ n: String) {
        var a = labelNames; while a.count < 7 { a.append("") }; a[i - 1] = n; labelNames = a; UserDefaults.standard.set(a, forKey: "labelNames")
    }
    func saveBrightness() { UserDefaults.standard.set(viewerBrightness, forKey: "viewerBrightness"); UserDefaults.standard.set(browserBrightness, forKey: "browserBrightness") }
    func wellColor(viewer: Bool) -> Color { if fullScreenViewer && viewer { let v = UserDefaults.standard.double(forKey: "fullScreenBrightness") * 0.62; return Color(.sRGB, red: v, green: v, blue: v) }; let b = viewer ? viewerBrightness : browserBrightness; let v = 0.12 + 0.62 * b; return Color(.sRGB, red: v, green: v, blue: v) }
    func toggleToolbarItem(_ id: String) { if toolbarHidden.contains(id) { toolbarHidden.remove(id) } else { toolbarHidden.insert(id) }; UserDefaults.standard.set(Array(toolbarHidden), forKey: "toolbarHidden") }

    // MARK: loupe
    func renderLoupeSource() {
        guard let v = primaryVersion, let m = primaryMaster, m.kind == .image else { return }
        let url = store.masterURL(m); let set = adjustments
        let req = RenderRequest(url: url, isRaw: m.isRaw, originalSize: CGSize(width: m.width, height: m.height), rotation: v.rotation, adjustments: set, maxPixel: min(max(m.width, m.height), 7000))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cg = self?.engine.renderCG(req)
            DispatchQueue.main.async { if self?.loupe == true { self?.loupeImage = cg } }
        }
    }

    // MARK: white balance picker
    /// `p` = click in fractions of the displayed (cropped, rotated) image
    func pickWhiteBalance(at p: CGPoint) {
        guard let m = primaryMaster, let mp = masterPoint(fromDisplay: p), m.width > 0, let id = primary else { return }
        let url = store.masterURL(m), size = CGSize(width: m.width, height: m.height), set = adjustments
        let start = (set.item(Catalog.wb)?.value("inputTemperature") ?? 5000, set.item(Catalog.wb)?.value("inputTint") ?? 0)
        let frac = CGPoint(x: mp[0] / Double(m.width), y: mp[1] / Double(m.height))
        status = L("Picking white balance…", "Weißabgleich wird ermittelt …")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let r = self.engine.solveWhiteBalance(url: url, isRaw: m.isRaw, originalSize: size, adjustments: set, at: frac, start: start)
            DispatchQueue.main.async {
                guard self.primary == id else { return }
                guard let r else { self.status = self.L("Could not neutralize this point", "Dieser Punkt lässt sich nicht neutralisieren"); return }
                self.beginEdit(); self.setParam(Catalog.wb, "inputTemperature", r.temperature); self.setParam(Catalog.wb, "inputTint", r.tint)
                self.commitAdjustments(self.L("White Balance", "Weißabgleich")); self.tool = .select
                self.status = self.L(String(format: "White balance: %.0f K, tint %.0f", r.temperature, r.tint), String(format: "Weißabgleich: %.0f K, Tönung %.0f", r.temperature, r.tint))
            }
        }
    }

    // MARK: auto exposure
    func autoExposure() {
        guard histogram.count == 4, primary != nil else { return }
        let h = histogram[3]; let tot = h.reduce(0, +); guard tot > 0 else { return }
        var mean: Float = 0; for i in 0..<256 { mean += Float(i) * h[i] }; mean /= tot * 255
        var acc: Float = 0, lo = 0
        for i in 0..<256 { acc += h[i]; if acc / tot > 0.002 { lo = i; break } }
        let current = value(Catalog.exposure, "inputEV")
        let ev = max(-2, min(2, current + log2(Double(0.42) / Double(max(0.02, mean)))))   // mid-gray target for the current rendering
        beginEdit(); setParam(Catalog.exposure, "inputEV", ev); setParam(Catalog.exposure, "inputBias", Double(lo) / 255 * 20); commitAdjustments(L("Auto Exposure", "Auto-Belichtung"))
    }

    // MARK: user presets
    func saveCurrentAsPreset(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty, adjustments.hasAny || !adjustments.items.isEmpty else { return }
        var s = adjustments; s.brushes = []                         // presets carry global adjustments only
        _ = try? userPresetStore.add(UserPreset(name: n, set: s)); userPresets = userPresetStore.presets; status = L("Preset saved", "Voreinstellung gespeichert")
    }
    func apply(user p: UserPreset, replace: Bool) {
        guard primary != nil else { return }
        beginEdit()
        var cur = replace ? AdjustmentSet(brushes: adjustments.brushes) : adjustments
        for a in p.set.items { cur.upsert(a) }
        adjustments = cur; commitAdjustments(L("Apply Preset", "Voreinstellung anwenden")); scheduleRender()
    }
    func deleteUserPreset(_ id: ID) { try? userPresetStore.remove(id); userPresets = userPresetStore.presets }
    func exportUserPreset(_ id: ID) { let p = NSSavePanel(); p.nameFieldStringValue = (userPresets.first { $0.id == id }?.name ?? "Preset") + ".rlpreset"; if p.runModal() == .OK, let u = p.url { try? userPresetStore.export(id, to: u) } }
    func importUserPresets() {
        let p = NSOpenPanel(); p.allowedContentTypes = []; p.allowsMultipleSelection = true
        if p.runModal() == .OK { for u in p.urls { _ = try? userPresetStore.importFile(u) }; userPresets = userPresetStore.presets }
    }

    // MARK: selective stamp
    func prepareStampOptions() {
        if let s = liftedAdjustments { stampOptions.ops = Set(s.items.map(\.id)) }
    }
    func stampSelective() {
        let ids = selection.filter { $0 != primary || selection.count == 1 }
        guard !ids.isEmpty else { return }
        if let a = liftedAdjustments {
            for id in ids {
                var cur = store.adjustments(for: id)
                for it in a.items where stampOptions.ops.contains(it.id) { cur.upsert(it) }
                if stampOptions.brushes { cur.brushes = a.brushes }
                try? store.setAdjustments(id, cur); thumbRevision[id, default: 0] += 1
            }
        }
        if let m = liftedMeta {
            let o = stampOptions
            withUndo(L("Stamp", "Stempeln"), ids: ids) { v in
                if o.rating { v.rating = m.rating }; if o.label { v.colorLabel = m.colorLabel }; if o.flag { v.flagged = m.flagged }
                if o.keywords { v.keywords = Array(Set(v.keywords + m.keywords)) }; if o.caption, !m.caption.isEmpty { v.caption = m.caption }
            }
        }
        primaryChanged(); status = L("Stamped \(ids.count) photos", "\(ids.count) Fotos gestempelt")
    }
    func stamp() { if liftedAdjustments != nil || liftedMeta != nil { if stampOptions.ops.isEmpty { prepareStampOptions() }; stampSelective() } }

    // MARK: compare
    func setCompare() { compare = primary; viewerLayout = .compare }
    func clearCompare() { compare = nil; if viewerLayout == .compare { viewerLayout = .one } }
    func selectCompare() { if let c = compare { let old = primary; compare = old; selection = [c]; primary = c } }
    func cycleLayout(_ l: ViewerLayout) { viewerLayout = viewerLayout == l ? .one : l }
    func toggleHUD(_ k: HUDKind) { if huds.contains(k) { huds.remove(k) } else { huds.insert(k) }; if k == .liftStamp { prepareStampOptions() } }
}
