import AppKit
import RetroluxCore

/// Present-day equivalents of the 2010 online services (MobileMe → iCloud Drive, Facebook/Messages/… → system Share menu,
/// print service → print-lab export). Nothing is uploaded by this app and no success is simulated.
extension AppModel {
    static var iCloudDrive: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs") }

    /// MobileMe Gallery → web gallery written into iCloud Drive (syncs; share a link from Finder ▸ Share).
    func shareICloud() {
        guard !selection.isEmpty else { return }
        guard FileManager.default.fileExists(atPath: Self.iCloudDrive.path) else { alert = ("iCloud Drive", L("iCloud Drive is not enabled on this Mac (System Settings ▸ Apple ID ▸ iCloud).", "iCloud Drive ist auf diesem Mac nicht aktiviert (Systemeinstellungen ▸ Apple-ID ▸ iCloud).")); return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let dir = Self.iCloudDrive.appendingPathComponent("Retrolux Galleries/Gallery " + f.string(from: Date()))
        var doc = WebDoc(); doc.title = L("Gallery", "Galerie"); let ids = selection, store = store
        status = L("Writing gallery to iCloud Drive…", "Schreibe Galerie nach iCloud Drive …")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = Result { try WebExporter.export(doc, versions: ids, store: store, to: dir) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .success(let x): self.status = self.L("\(x.images) images in iCloud Drive", "\(x.images) Bilder in iCloud Drive"); NSWorkspace.shared.activateFileViewerSelecting([dir])
                case .failure(let e): self.alert = ("iCloud Drive", e.localizedDescription)
                }
            }
        }
    }

    /// Facebook/Flickr/Messages/AirDrop/… → the system Share menu over medium-size JPEGs (no location, no people).
    func shareSelection(from view: NSView? = nil) {
        let ids = selection; guard !ids.isEmpty else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-share-\(getpid())")
        var o = ExportOptions(); o.includeLocation = false; o.includePeople = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let res = try? Exporter(store: self.store).export(ids, preset: ExportPreset.factory[1], to: dir, options: o) else { return }
            DispatchQueue.main.async {
                guard let v = view ?? NSApp.keyWindow?.contentView else { return }
                NSSharingServicePicker(items: res.written).show(relativeTo: NSRect(x: v.bounds.midX, y: v.bounds.maxY - 60, width: 1, height: 1), of: v, preferredEdge: .minY)
            }
        }
    }

    /// Photo prints → print-ready JPEGs (300 ppi, sRGB, no location/people) for a lab of the user's choice.
    static let printSizes: [(String, Int)] = [("9 × 13 cm", 1535), ("10 × 15 cm", 1772), ("13 × 18 cm", 2126), ("15 × 21 cm", 2480), ("20 × 30 cm", 3543)]
    func exportForPrintLab() {
        guard !selection.isEmpty else { return }
        let a = NSAlert(); a.messageText = L("Export for Print Lab", "Für Fotolabor exportieren")
        a.informativeText = L("Writes JPEGs at 300 ppi (long edge for the chosen size) with sRGB. Upload the folder to a lab of your choice; this app orders nothing.", "Schreibt JPEGs mit 300 ppi (lange Kante für die gewählte Größe) in sRGB. Lade den Ordner bei einem Fotolabor deiner Wahl hoch; diese App bestellt nichts.")
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24)); pop.addItems(withTitles: Self.printSizes.map { $0.0 }); pop.selectItem(at: 1); a.accessoryView = pop
        a.addButton(withTitle: L("Choose Folder…", "Ordner wählen …")); a.addButton(withTitle: L("Cancel", "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let sz = Self.printSizes[pop.indexOfSelectedItem]
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        guard p.runModal() == .OK, let dir = p.url else { return }
        var o = ExportOptions(); o.includeLocation = false; o.includePeople = false
        runExport(ExportPreset(name: "Print " + sz.0, format: .jpeg, size: .fit(sz.1), deep: true, quality: 0.95), folder: dir, naming: .versionName, original: false, options: o)
    }
}
