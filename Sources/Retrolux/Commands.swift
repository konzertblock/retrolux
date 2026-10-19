import AppKit
import SwiftUI
import RetroluxCore

extension AppDelegate {
    func c(_ p: String, _ f: @escaping (AppModel) -> Void) { commands[p] = f }

    /// Called at the end of buildCommands(); later feature groups add their own register functions here.
    func registerMore() {
        registerViewCommands()
        registerEditCommands()
        registerWindowCommands()
        registerMetadataCommands()
        registerLibraryCommands()
        registerFacePlaceCommands()
        registerDocumentCommands()
        registerColorCommands()
        registerPlugInCommands()
    }

    func registerViewCommands() {
        c("View/Main Viewer/Show Multiple") { $0.cycleLayout(.multiple) }; c("View/Main Viewer/Show One") { $0.viewerLayout = .one }
        c("View/Main Viewer/Three Up") { $0.cycleLayout(.threeUp) }; c("View/Main Viewer/Compare") { m in if m.compare == nil { m.setCompare() } else { m.cycleLayout(.compare) } }
        c("View/Main Viewer/Stack") { $0.cycleLayout(.stack) }
        c("View/Quick Preview") { m in m.quickPreview.toggle(); m.scheduleRender() }
        c("View/Highlight Hot & Cold Areas") { m in m.hotCold.toggle(); m.scheduleRender() }
        c("View/Show Loupe") { $0.loupe.toggle() }
        c("View/Loupe Options/Increase Zoom") { $0.loupeZoom = min(8, $0.loupeZoom * 1.5) }; c("View/Loupe Options/Decrease Zoom") { $0.loupeZoom = max(1, $0.loupeZoom / 1.5) }
        c("View/Loupe Options/Increase Diameter") { $0.loupeDiameter = min(700, $0.loupeDiameter + 60) }; c("View/Loupe Options/Decrease Diameter") { $0.loupeDiameter = max(120, $0.loupeDiameter - 60) }
        c("View/Show Toolbar") { $0.showToolbar.toggle() }; c("View/Customize Toolbar…") { $0.showCustomizeToolbar = true }
        c("View/Full Screen") { [unowned self] m in m.fullScreenViewer.toggle(); if m.fullScreenViewer != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } }
        c("View/Show Projects") { m in m.inspectorTab = .library; m.showInspector = true; m.source = .all }
        c("View/Browser/Swap Position") { $0.browserFirst.toggle() }; c("View/Browser/Rotate Position") { $0.browserFirst.toggle() }
        c("View/Inspector/Swap Position") { $0.inspectorRight.toggle() }
        c("View/Metadata Display/Viewer/Show Metadata") { $0.viewerMeta.toggle() }
        c("View/Metadata Display/Image Tooltips") { $0.imageTooltips.toggle() }
        c("View/Secondary Viewer/Mirror") { [unowned self] m in setSecondary("mirror", m) }
        c("View/Secondary Viewer/Alternate") { [unowned self] m in setSecondary("alternate", m) }
        c("View/Secondary Viewer/Blank") { [unowned self] m in setSecondary("blank", m) }
    }

    func registerEditCommands() {
        c("Edit/Set Compare Item") { $0.setCompare() }; c("Edit/Clear Compare Item") { $0.clearCompare() }; c("Edit/Select Compare Item") { $0.selectCompare() }
        c("Edit/Primary Only") { $0.primaryOnly.toggle() }
        c("Edit/Reduce Selection") { m in if let p = m.primary { m.selection = [p] } }
        c("Edit/Select to Beginning") { m in guard let p = m.primary, let i = m.shown.firstIndex(where: { $0.id == p }) else { return }; m.selection = m.shown[0...i].map(\.id) }
        c("Edit/Select to End") { m in guard let p = m.primary, let i = m.shown.firstIndex(where: { $0.id == p }) else { return }; m.selection = m.shown[i...].map(\.id) }
        c("Photos/Add Adjustment Preset") { _ in }      // dynamic submenu (see menuNeedsUpdate)
        commands["Photos/Add Adjustment Preset"] = nil
    }

    func registerWindowCommands() {
        c("Window/Show Inspector HUD") { $0.toggleHUD(.inspector) }; c("Window/Show Keyword HUD") { $0.toggleHUD(.keyword) }; c("Window/Show Lift & Stamp HUD") { $0.toggleHUD(.liftStamp) }
        c("Window/Show Keyword Controls") { $0.keywordControls.toggle() }
        c("Window/Show Activity") { $0.showActivitySheet = true }
        c("Window/Show Project Info") { $0.showProjectInfo = true }
    }

    // MARK: secondary viewer window (Mirror / Alternate / Blank)
    func setSecondary(_ mode: String, _ m: AppModel) {
        if secondaryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = m.L("Secondary Viewer", "Zweiter Viewer"); w.contentView = NSHostingView(rootView: SecondaryViewerView(model: m)); w.isReleasedWhenClosed = false
            secondaryWindow = w
        }
        m.secondaryMode = mode; secondaryWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SecondaryViewerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Color.black
            switch model.secondaryMode {
            case "mirror": if let i = model.viewerImage { Image(nsImage: i).resizable().aspectRatio(contentMode: .fit) }
            case "alternate":
                if let id = model.compare ?? model.shown.first(where: { $0.id != model.primary })?.id { TileView(model: model, id: id) }
            default: EmptyView()
            }
        }
    }
}

struct ProjectInfoSheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let vs = model.shown
        let raws = vs.filter { model.store.masters[$0.masterID]?.isRaw == true }.count
        let bytes = Set(vs.map(\.masterID)).compactMap { model.store.masters[$0]?.fileSize }.reduce(0, +)
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title).font(Theme.font(14, bold: true))
            Group {
                Text(model.L("\(vs.count) versions, \(raws) RAW, \(vs.count - raws) other", "\(vs.count) Versionen, \(raws) RAW, \(vs.count - raws) andere"))
                Text(model.L("Originals: ", "Originale: ") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                if let a = vs.map(\.imageDate).min(), let b = vs.map(\.imageDate).max() { Text("\(a.formatted(date: .abbreviated, time: .omitted)) – \(b.formatted(date: .abbreviated, time: .omitted))") }
                Text(model.L("Rated: ", "Bewertet: ") + "\(vs.filter { $0.rating > 0 }.count), " + model.L("Flagged: ", "Markiert: ") + "\(vs.filter(\.flagged).count), " + model.L("Edited: ", "Bearbeitet: ") + "\(vs.filter(\.hasAdjustments).count)")
            }.font(Theme.small)
            HStack { Spacer(); Button("OK") { model.showProjectInfo = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 380).background(Theme.chrome)
    }
}

extension AppDelegate {
    func registerMetadataCommands() {
        c("Metadata/Batch Change…") { $0.showBatchChange = true }
        c("Metadata/Edit AutoFill List…") { $0.showAutofillEditor = true }
        c("Metadata/Adjust Date and Time…") { $0.showAdjustDate = true }
        c("Metadata/Update from Master") { $0.updateFromMaster() }
        c("Metadata/Write IPTC to Master") { $0.writeIPTCToMaster() }
        c("Metadata/New Keyword") { $0.inspectorTab = .metadata; $0.showKeywordManager = true }
        c("Metadata/Remove Keyword/Remove All Keywords") { $0.removeAllKeywords() }
        c("File/Export/Version…") { $0.showExportSheet = true }
        c("File/Export/Master…") { $0.exportOriginalsRequested = true; $0.showExportSheet = true }
        c("File/Export/Metadata…") { m in
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.message = m.L("Choose a folder for the .xmp files", "Ordner für die .xmp-Dateien wählen")
            if p.runModal() == .OK, let u = p.url { m.exportMetadataSidecars(to: u) } }
        c("File/Export/Folder…") { m in m.exportContainerFolder() }
        c("File/Share/Email…") { m in m.shareByEmail() }
        c("File/Show in Finder") { m in if let v = m.primaryVersion, let ms = m.store.masters[v.masterID] { NSWorkspace.shared.activateFileViewerSelecting([m.store.masterURL(ms)]) } }
        c("File/Show in Project") { m in if let v = m.primaryVersion { m.source = .container(v.projectID); m.inspectorTab = .library } }
    }
}

extension AppModel {
    /// File ▸ Export ▸ Folder…: writes the selected project/folder as a directory tree of originals (+ .xmp sidecars).
    func exportContainerFolder() {
        guard case .container(let id) = source, let c = store.containers[id] else { alert = (L("Export Folder", "Ordner exportieren"), L("Select a project or folder in the Library first.", "Wähle zuerst ein Projekt oder einen Ordner in der Bibliothek.")); return }
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        guard p.runModal() == .OK, let dest = p.url else { return }
        let root = dest.appendingPathComponent(c.name)
        var n = 0
        func walk(_ cid: ID, _ dir: URL) {
            guard let c = store.containers[cid] else { return }
            if c.kind == .project {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for v in store.versions(in: cid) { guard let m = store.masters[v.masterID] else { continue }
                    let dst = Exporter.unique(dir.appendingPathComponent(m.originalName)); if (try? FileManager.default.copyItem(at: store.masterURL(m), to: dst)) != nil { n += 1; _ = try? MetadataWriter.writeSidecar(for: v, nextTo: dst) } }
            } else if c.kind == .folder { for ch in store.children(of: cid) { walk(ch.id, dir.appendingPathComponent(ch.name)) } }
        }
        walk(id, root)
        status = L("Exported \(n) originals to \(root.lastPathComponent)", "\(n) Originale nach \(root.lastPathComponent) exportiert"); NSWorkspace.shared.activateFileViewerSelecting([root])
    }
    func shareByEmail() {
        let ids = selection; guard !ids.isEmpty else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-mail-\(getpid())")
        let preset = ExportPreset.all.first { $0.name == UserDefaults.standard.string(forKey: "emailPresetName") } ?? ExportPreset.factory[1]    // default: Email Medium - JPEG
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let res = try? Exporter(store: self.store).export(ids, preset: preset, to: dir) else { return }
            DispatchQueue.main.async {
                if let svc = NSSharingService(named: .composeEmail), svc.canPerform(withItems: res.written) { svc.perform(withItems: res.written) }
                else { self.alert = (self.L("Email", "E-Mail"), self.L("No mail client available. The files are in \(dir.path).", "Kein E-Mail-Programm verfügbar. Die Dateien liegen in \(dir.path).")); NSWorkspace.shared.activateFileViewerSelecting(res.written) }
            }
        }
    }
}

extension AppDelegate {
    func registerLibraryCommands() {
        c("Stacks/Stack") { $0.stackSelection() }; c("Stacks/Unstack") { $0.unstackSelection() }; c("Stacks/Split Stack") { $0.splitStack() }
        c("Stacks/Extract from Stack") { $0.extractFromStack() }; c("Stacks/Auto-Stack") { $0.showAutoStack = true }
        c("Stacks/Pick") { $0.setPick() }; c("Stacks/Set Album Pick") { $0.setAlbumPick() }; c("Stacks/Promote") { $0.promote() }; c("Stacks/Demote") { $0.demote() }
        c("Stacks/Select All Items in Stack") { $0.selectStackItems() }; c("Stacks/Previous Stack") { $0.gotoStack(-1) }; c("Stacks/Next Stack") { $0.gotoStack(1) }
        c("Stacks/Open/Close Stack") { $0.toggleStack() }; c("Stacks/Open All Stacks") { $0.openAllStacks() }; c("Stacks/Close All Stacks") { $0.closeAllStacks() }
        c("File/Duplicate Album") { $0.duplicateContainer() }; c("File/Duplicate Project Structure") { $0.duplicateContainer() }
        c("File/Merge Projects…") { $0.showMergeProjects = true }
        c("File/Delete Master Image and All Versions") { $0.deleteMastersAndVersions() }
        c("File/Relocate Master…") { $0.relocateMasters() }; c("File/Consolidate Master…") { $0.consolidateMasters() }; c("File/Locate Referenced Files…") { $0.locateReferenced() }
        c("File/Vault/Update All Vaults") { $0.updateAllVaults() }; c("File/Vault/Add Vault…") { $0.addVault() }
        c("File/Vault/Update Vault Path…") { $0.showVaults = true }; c("File/Vault/Remove Vault") { $0.showVaults = true }; c("File/Vault/Restore Library…") { $0.restoreLibrary() }
        c("Window/Show Vaults") { $0.showVaults = true }
        c("File/Switch to Library/Other/New…") { $0.chooseLibrary() }; c("File/Switch to Library/Clear Menu") { $0.clearRecentLibraries() }
        // additions without a classic counterpart
        c("File/Merge Library…") { m in let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.treatsFilePackagesAsDirectories = true; p.message = m.L("Choose a Retrolux library to merge into this one", "Retrolux-Bibliothek zum Zusammenführen wählen")
            if p.runModal() == .OK, let u = p.url { m.mergeLibrary(u) } }
        c("File/Export/Project as Library…") { $0.exportSelectionAsLibrary() }
        c("File/Library First Aid…") { $0.showFirstAid = true }
        c("File/New Library…") { $0.newLibrary() }
        c("File/Import/iPhoto Library…") { $0.chooseIPhotoLibrary() }; c("File/Import/Show iPhoto Browser") { $0.chooseIPhotoLibrary() }
        c("File/Import/Photos Library…") { $0.runPhotosImport() }
        c("File/Tether/Start Session...") { $0.showTether = true }; c("File/Tether/Stop Session") { $0.tether?.stopTether(); $0.tether?.disconnect(); $0.tether = nil; $0.status = $0.L("Tether session stopped", "Tether-Sitzung beendet") }; c("File/Tether/Show Tether HUD") { $0.showTether = true }
        c("Metadata/Attach Audio File…") { $0.attachAudioFile() }
    }

    /// Items without a classic counterpart (kept next to their relatives). path = parent menu, after = English title to insert behind.
    func injectCustomMenuItems() {
        func menu(_ titles: [String]) -> NSMenu? { var m: NSMenu? = NSApp.mainMenu; for t in titles { m = m?.items.first { $0.representedObject as? String == t || $0.title == t }?.submenu }; return m }
        func add(_ parent: NSMenu?, after: String, title: String, path: String, key: String = "") {
            guard let parent else { return }
            let idx = (parent.items.firstIndex { ($0.representedObject as? String)?.hasSuffix("/" + after) == true } ?? parent.items.count - 1) + 1
            let it = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key); it.target = self; it.representedObject = path; parent.insertItem(it, at: min(idx, parent.items.count))
        }
        if let appMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { ($0.representedObject as? String)?.hasPrefix("Retrolux/") == true } == true })?.submenu {
            add(appMenu, after: "About Retrolux", title: model.L("Check for Updates…", "Nach Updates suchen …"), path: "Retrolux/Check for Updates…")
        }
        guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { ($0.representedObject as? String)?.hasPrefix("File/") == true } == true })?.submenu else { return }
        add(file, after: "Switch to Library", title: model.L("New Library…", "Neue Bibliothek …"), path: "File/New Library…")
        add(file, after: "Merge Projects…", title: model.L("Merge Library…", "Bibliothek zusammenführen …"), path: "File/Merge Library…")
        add(file, after: "Vault", title: model.L("Library First Aid…", "Bibliothek-Erste-Hilfe …"), path: "File/Library First Aid…")
        if let imp = file.items.first(where: { ($0.representedObject as? String) == "File/Import" })?.submenu { add(imp, after: "iPhoto Library…", title: model.L("Photos Library…", "Fotos-Mediathek …"), path: "File/Import/Photos Library…") }
        if let export = file.items.first(where: { ($0.representedObject as? String) == "File/Export" })?.submenu { add(export, after: "Folder…", title: model.L("Project as Library…", "Projekt als Bibliothek …"), path: "File/Export/Project as Library…") }
    }
}

extension AppDelegate {
    func registerFacePlaceCommands() {
        c("View/Faces") { m in m.placesView = false; m.facesView.toggle() }
        c("View/Places") { m in m.facesView = false; m.placesView.toggle() }
        c("Photos/Detect Missing Faces") { $0.detectMissingFaces() }
        c("Metadata/Assign Names") { m in m.namingMode.toggle(); if m.namingMode { m.facesView = false; m.viewMode = m.viewMode == .browser ? .split : m.viewMode; if let p = m.primary, m.store.faces(of: p).isEmpty { m.detectMissingFaces() } }; m.scheduleRender() }
        c("Metadata/Assign Location…") { $0.showAssignLocation = true }
        c("Metadata/Remove Locations") { $0.removeLocations() }
        c("Metadata/Manage My Places…") { $0.showMyPlaces = true }
    }
}

extension AppDelegate {
    func registerDocumentCommands() {
        c("File/New/Book") { $0.newBook() }; c("File/New/Light Table") { $0.newLightTable() }; c("File/New/Slideshow") { $0.newSlideshow() }
        c("File/New/Web Journal") { $0.newWebJournal() }; c("File/New/Web Page") { $0.newWebPage(smart: false) }; c("File/New/Smart Web Page") { $0.newWebPage(smart: true) }
        c("File/Play Slideshow…") { $0.playCurrentSlideshow(lastSettings: false) }; c("File/Play Slideshow With Last Settings") { $0.playCurrentSlideshow(lastSettings: true) }
        c("File/Print…") { $0.showPrint = true }; c("File/Order Prints…") { $0.exportForPrintLab() }
        c("File/Share/MobileMe Gallery…") { $0.shareICloud() }; c("File/Share/Flickr…") { $0.showServices = true }; c("File/Share/Facebook…") { $0.shareSelection() }
        c("View/Metadata Display/Light Table") { m in if let c = m.editorContainer, c.kind == .lightTable, var d = m.store.document(c.id, as: LightTableDoc.self) { d.showLabels.toggle(); try? m.store.saveDocument(c.id, d) } }
        c("View/Metadata Display/Customize…") { $0.showMetaViewEditor = true }
    }
}

extension AppModel {
    func playCurrentSlideshow(lastSettings: Bool) {
        var ids = selection.isEmpty ? shown.map(\.id) : selection; var st = SlideshowSettings()
        if let c = editorContainer, c.kind == .slideshow { ids = documentVersions(c); st = store.document(c.id, as: SlideshowSettings.self) ?? st; UserDefaults.standard.set(c.id, forKey: "lastSlideshow") }
        else if lastSettings, let id = UserDefaults.standard.string(forKey: "lastSlideshow"), let s = store.document(id, as: SlideshowSettings.self) { st = s }
        guard !ids.isEmpty else { return }
        let wc = SlideshowWindowController(SlideshowController(ids: ids, settings: st, store: store)); SlideshowEditor.live.append(wc); wc.show()
    }
}
