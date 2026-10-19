import AppKit
import ImageIO
import UniformTypeIdentifiers
import RetroluxCore

extension AppDelegate {
    /// Onscreen proofing, external-editor round trip, reprocessing.
    func registerColorCommands() {
        c("View/Onscreen Proofing") { m in m.proofOn.toggle(); m.scheduleRender() }
        c("View/Proofing Profile") { m in
            let a = NSAlert(); a.messageText = m.L("Proofing Profile", "Proof-Profil")
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            pop.addItems(withTitles: ColorProfiles.builtin.map { $0.name }); pop.selectItem(withTitle: m.proofProfile)
            let gam = NSButton(checkboxWithTitle: m.L("Gamut warning", "Gamutwarnung"), target: nil, action: nil); gam.state = m.gamutWarning ? .on : .off
            let st = NSStackView(views: [pop, gam]); st.orientation = .vertical; st.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
            a.accessoryView = st; a.addButton(withTitle: "OK"); a.addButton(withTitle: m.L("Cancel", "Abbrechen"))
            if a.runModal() == .alertFirstButtonReturn { m.proofProfile = pop.titleOfSelectedItem ?? m.proofProfile; m.gamutWarning = gam.state == .on; m.proofOn = true; m.scheduleRender() }
        }
        c("Photos/Edit with External Editor…") { m in m.editExternally(copy: false) }
        c("Photos/Edit a Copy with External Editor…") { m in m.editExternally(copy: true) }
        c("Photos/Reprocess Masters…") { m in m.reprocess() }
        c("Photos/Use Editable Recipe") { m in
            for id in m.selection { try? m.store.dropFallback(id) }
            m.scheduleRender(); m.status = m.L("Fallback rendering removed", "Gerenderte Fassung entfernt")
        }
    }
}

extension AppModel {
    /// Render → temp TIFF → open in the default editor → re-import the saved file as a new version.
    func editExternally(copy: Bool) {
        guard let v = primaryVersion, let m = primaryMaster else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Retrolux-Edit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970), src = store.masterURL(m)
        let url: URL
        if copy && !m.isRaw {   // "Edit a Copy": hand over a copy of the untouched original
            url = dir.appendingPathComponent(src.deletingPathExtension().lastPathComponent + "-copy-\(stamp)." + src.pathExtension)
            do { try FileManager.default.copyItem(at: src, to: url) } catch { alert = ("Edit", error.localizedDescription); return }
        } else {
            let ud = UserDefaults.standard
            guard let cg = store.renderedImage(v.id, maxPixel: nil, deep: ud.object(forKey: "editorDeep") as? Bool ?? true) else { alert = ("Edit", L("Could not render the image", "Bild konnte nicht gerendert werden")); return }
            url = dir.appendingPathComponent((v.name.isEmpty ? "image" : v.name) + "-edit-\(stamp).tiff")
            guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else { return }
            let dpi = ud.integer(forKey: "editorDPI"); CGImageDestinationAddImage(d, cg, dpi > 0 && dpi != 72 ? [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary : nil); guard CGImageDestinationFinalize(d) else { return }
        }
        func mtime() -> Date { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast }
        let before = mtime()
        if let app = UserDefaults.standard.string(forKey: "editorAppPath"), FileManager.default.fileExists(atPath: app) { NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration()) } else { NSWorkspace.shared.open(url) }
        status = L("Waiting for the external editor to save…", "Warte auf Speichern im externen Editor …")
        var fired = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if mtime() > before, !fired {
                fired = true; t.invalidate()
                var o = ImportOptions(); o.projectID = v.projectID
                self.runImport([url], o)
            }
        }
    }

    /// Rewrite the selected recipes with the current engine version (masters stay untouched).
    func reprocess() {
        var n = 0
        for id in selection { var a = store.adjustments(for: id); a.engineVersion = AdjustmentSet.currentEngineVersion; try? store.setAdjustments(id, a); n += 1 }
        scheduleRender(); status = L("Reprocessed \(n) versions", "\(n) Versionen neu bearbeitet")
    }
}

/// Plug-in adapters: ~/Library/Application Support/Retrolux/PlugIns/<n>.rlplugin/plugin.json
/// {"name": "...", "executable": "run.sh"}; invoked as `executable <input.tiff> <output.tiff>`. Binary plug-ins are not supported.
struct PlugIn { let name: String; let exe: URL }
enum PlugInHost {
    static var dir: URL { ProcessInfo.processInfo.environment["RL_PLUGIN_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Retrolux/PlugIns") }
    static func discover() -> [PlugIn] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "rlplugin" }.compactMap { d in
            guard let j = try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent("plugin.json"))) as? [String: String],
                  let n = j["name"], let e = j["executable"] else { return nil }
            return PlugIn(name: n, exe: d.appendingPathComponent(e))
        }
    }
}

extension AppDelegate {
    func registerPlugInCommands() {
        c("Photos/Edit with Plug-in") { m in
            let plugs = PlugInHost.discover()
            let a = NSAlert(); a.messageText = m.L("Edit with Plug-in", "Mit Plug-in bearbeiten")
            guard !plugs.isEmpty else { a.informativeText = m.L("No plug-ins found in:\n", "Keine Plug-ins gefunden in:\n") + PlugInHost.dir.path + "\n" + m.L("Plug-ins are small scripts; see the README.", "Plug-ins sind kleine Skripte; siehe README."); a.runModal(); return }
            a.informativeText = m.L("A plug-in is an executable that runs with your user rights. Only run plug-ins you trust.", "Ein Plug-in ist ein ausführbares Programm mit Ihren Benutzerrechten. Nur vertrauenswürdige Plug-ins ausführen.")
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); pop.addItems(withTitles: plugs.map { $0.name }); a.accessoryView = pop
            a.addButton(withTitle: m.L("Run", "Ausführen")); a.addButton(withTitle: m.L("Cancel", "Abbrechen"))
            if a.runModal() == .alertFirstButtonReturn { m.runPlugIn(plugs[pop.indexOfSelectedItem]) }
        }
    }
}

extension AppModel {
    func runPlugIn(_ p: PlugIn) {
        guard let v = primaryVersion, let cg = store.renderedImage(v.id, maxPixel: nil, deep: true) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Retrolux-PlugIn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inp = dir.appendingPathComponent("in-\(UUID().uuidString).tiff"), out = dir.appendingPathComponent("out-\(UUID().uuidString).tiff")
        guard let d = CGImageDestinationCreateWithURL(inp as CFURL, UTType.tiff.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, cg, nil); guard CGImageDestinationFinalize(d) else { return }
        status = L("Running plug-in…", "Plug-in läuft …")
        var o = ImportOptions(); o.projectID = v.projectID
        DispatchQueue.global().async { [weak self] in
            let t = Process(); t.executableURL = p.exe; t.arguments = [inp.path, out.path]
            let ok = (try? t.run()) != nil; if ok { t.waitUntilExit() }
            DispatchQueue.main.async {
                guard let self else { return }
                if ok, t.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) { self.runImport([out], o) }
                else { self.alert = (p.name, self.L("The plug-in failed.", "Das Plug-in ist fehlgeschlagen.")) }
            }
        }
    }
}
