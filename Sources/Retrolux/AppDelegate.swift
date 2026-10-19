import AppKit
import MapKit
import SwiftUI
import RetroluxCore

struct MenuNode: Decodable { let en: String; let de: String; let key: String; let keyDE: String?; let alt: Bool; let sep: Bool; let children: [MenuNode] }

struct LaunchArgs {
    var library: URL?
    var importLegacy: URL?
    var importLimit: Int?
    var importFolder: URL?
    var snapshot: URL?
    var tab: InspectorTab?
    var mode: ViewMode?
    var select: Int?
    var selectAdjusted = false
    var selectOp: String?
    var preset: String?
    var lang: String?
    var tool: String?
    var selftest = false
    var faces = false
    var doc: String?
    var places = false
    var dumpMenu = false
    var delay = 2.5
    init(_ a: [String]) {
        var i = 1
        func next() -> String? { i += 1; return i < a.count ? a[i] : nil }
        while i < a.count {
            switch a[i] {
            case "--library": library = next().map { URL(fileURLWithPath: $0) }
            case "--import-legacy": importLegacy = next().map { URL(fileURLWithPath: $0) }
            case "--limit": importLimit = next().flatMap(Int.init)
            case "--import-folder": importFolder = next().map { URL(fileURLWithPath: $0) }
            case "--snapshot": snapshot = next().map { URL(fileURLWithPath: $0) }
            case "--tab": tab = next().flatMap { t in InspectorTab.allCases.first { $0.rawValue.lowercased() == t.lowercased() } }
            case "--mode": mode = next().flatMap { ViewMode(rawValue: $0) }
            case "--select": select = next().flatMap(Int.init)
            case "--select-adjusted": selectAdjusted = true
            case "--select-op": selectOp = next()
            case "--preset": preset = next()
            case "--lang": lang = next()
            case "--tool": tool = next()
            case "--selftest": selftest = true
            case "--faces": faces = true
            case "--doc": doc = next()
            case "--places": places = true
            case "--dump-menu": dumpMenu = true
            case "--delay": delay = next().flatMap(Double.init) ?? 2.5
            default: break
            }
            i += 1
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    var window: NSWindow!
    var model: AppModel!
    var args = LaunchArgs(CommandLine.arguments)
    var commands: [String: (AppModel) -> Void] = [:]
    var prefsWindow: NSWindow?
    var secondaryWindow: NSWindow?
    var monitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        let defaultLib = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Retrolux Library.retrolux")
        let last = UserDefaults.standard.string(forKey: "lastLibrary").map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        // the self-test imports fixed images, so it always gets a fresh private library (never the user's)
        let libURL = args.selftest && args.library == nil ? FileManager.default.temporaryDirectory.appendingPathComponent("rl-selftest-lib-\(getpid()).retrolux") : (args.library ?? last ?? defaultLib)
        do { model = AppModel(store: try LibraryStore(root: libURL)) } catch {
            let a = NSAlert(); a.messageText = "Library could not be opened"; a.informativeText = error.localizedDescription; a.runModal(); NSApp.terminate(nil); return
        }
        if args.library == nil && !args.selftest { AppModel.rememberLibrary(libURL) }
        if let l = args.lang { model.lang = l }
        if let t = args.tab { model.inspectorTab = t }
        if let m = args.mode { model.viewMode = m }
        NSApp.appearance = NSAppearance(named: .aqua)          // era look: always light Aqua chrome
        buildCommands(); buildMenus()
        let host = NSHostingView(rootView: MainView(model: model))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.contentView = host; window.minSize = NSSize(width: 1000, height: 640); window.center()
        window.setFrameAutosaveName("RLMain"); window.delegate = self; window.title = "Retrolux"
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        AppUpdater.shared.start()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e }
        model.$lang.sink { [weak self] _ in DispatchQueue.main.async { self?.buildMenus() } }.store(in: &bag)
        if let lib = args.importLegacy { model.runMigration(lib, limit: args.importLimit) }
        if let f = args.importFolder { var o = ImportOptions(); o.managed = false; model.runImport([f], o) }
        if args.dumpMenu { dumpMenus(); exit(0) }
        if !args.selftest && args.snapshot == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in model.startFaceAnalysis() } }
        if args.selftest { Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [self] _ in SelfTest.run(model); fflush(stdout); exit(SelfTest.failed ? 1 : 0) } }   // timer (not a GCD block) so the nested run loop can drain the main queue
        if args.snapshot != nil { DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["RL_SNAPSHOT_DELAY"] ?? "") ?? 1.2)) { [self] in prepareSnapshot() } }
    }
    var bag = Set<AnyCancellable>()

    func dumpMenus() {
        func walk(_ m: NSMenu, _ d: Int) {
            for i in m.items {
                if i.isSeparatorItem { continue }
                let en = i.target != nil ? validateMenuItem(i) : true
                print(String(repeating: "  ", count: d) + "\(i.title)\t[\(i.keyEquivalentModifierMask.rawValue >> 17):\(i.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) }.joined())]\t\(en ? "on" : "off")")
                if let s = i.submenu { walk(s, d + 1) }
            }
        }
        if let m = NSApp.mainMenu { walk(m, 0) }
    }

    func prepareSnapshot() {
        if let op = args.selectOp, let v = model.shown.first(where: { model.store.adjustments(for: $0.id).item(op) != nil }) { model.click(v.id, extend: false, toggle: false) }
        else if args.selectAdjusted, let v = model.shown.first(where: { $0.hasAdjustments }) { model.click(v.id, extend: false, toggle: false) }
        else if let s = args.select, s < model.shown.count { model.click(model.shown[s].id, extend: false, toggle: false) }
        else if model.primary == nil, let f = model.shown.first { model.click(f.id, extend: false, toggle: false) }
        if let p = args.preset, let pr = Presets.all.first(where: { $0.name == p }) { model.applyPreset(pr) }
        if let t = args.tool, t == "crop" { model.tool = .crop }
        if ProcessInfo.processInfo.environment["RL_FULLSCREEN"] != nil { model.fullScreenViewer = true }
        if args.faces {
            let ids = model.store.versions.values.filter { model.store.containers[$0.projectID]?.name == "Portrait Session" }.sorted { $0.name < $1.name }.prefix(14).map(\.id)
            for id in ids { _ = try? model.analyzer.analyze(version: id) }
            if let first = model.store.allFaces().first, let p = try? model.store.createPerson("Nathan") { try? model.store.nameFace(first.id, person: p.id); _ = try? model.analyzer.suggestAll() }
            model.facesView = true; model.faceTick()
        }
        if args.places { model.placesView = true }
        if let d = args.doc {
            let ids = model.store.versions.values.filter { model.store.containers[$0.projectID]?.name == "Bears" }.sorted { $0.name < $1.name }.prefix(10).map(\.id)
            model.selection = Array(ids); model.primary = ids.first
            switch d { case "print": model.showPrint = true; case "import": model.showImportSheet = true; case "export": model.showExportSheet = true; case "presets": model.showExportPresetEditor = true; case "prefs": showPrefs(model); case "myplaces": if model.myPlaces.places.isEmpty { model.myPlaces.add(MyPlace(name: "Brandenburger Tor", latitude: 52.5163, longitude: 13.3777, radius: 300)) }; model.showMyPlaces = true; case "lighttable": model.selection = Array(model.shown.prefix(5).map(\.id)); model.newLightTable(); case "book": model.newBook(theme: "Photo Journal"); case "slideshow": model.newSlideshow(); default: model.newWebPage(smart: false) }
        }
        model.scheduleRender()
        DispatchQueue.main.asyncAfter(deadline: .now() + args.delay) { [self] in
            guard let v = window.attachedSheet?.contentView ?? prefsWindow?.contentView ?? window.contentView, let out = args.snapshot else { return }   // an open sheet is captured instead of the window
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            // cacheDisplay skips MapKit's annotation container; composite the pin views by hand so snapshots show them
            func annotationViews(_ x: NSView) -> [MKAnnotationView] { (x as? MKAnnotationView).map { [$0] } ?? x.subviews.flatMap(annotationViews) }
            let pins = annotationViews(v)
            if !pins.isEmpty, let g = NSGraphicsContext(bitmapImageRep: rep) {
                let sc = CGFloat(rep.pixelsWide) / v.bounds.width
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
                for a in pins {
                    let f = v.convert(a.bounds, from: a), img = a.image ?? NSImage(size: a.bounds.size)   // the image lives in the layer, not in drawRect
                    let y = v.isFlipped ? (v.bounds.height - f.maxY) : f.minY
                    img.draw(in: NSRect(x: f.minX, y: y, width: f.width, height: f.height), from: .zero, operation: .sourceOver, fraction: 1)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("snapshot written: \(out.path) \(Int(v.bounds.width))x\(Int(v.bounds.height)) versions=\(model.store.versions.count) shown=\(model.shown.count) primary=\(model.primaryVersion?.name ?? "-") viewer=\(model.viewerImage != nil)")
            fflush(stdout); exit(0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    /// Quit; if AppKit does not finish within 2 s (open sheet, background work) exit anyway. SQLite commits are transactional, so nothing is lost.
    func quit() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
    func application(_ sender: NSApplication, open urls: [URL]) { model.pendingImportURLs = urls; model.showImportSheet = true }

    // MARK: keys (arrow navigation when no text field is editing)
    func key(_ e: NSEvent) -> NSEvent? {
        if window?.firstResponder is NSText { return e }
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return e }
        switch e.keyCode {
        case 123: model.move(-1, columns: 1); return nil
        case 124: model.move(1, columns: 1); return nil
        case 125: model.move(model.viewMode == .viewer ? 1 : 1, columns: 1); return nil
        case 126: model.move(-1, columns: 1); return nil
        case 51: model.moveToTrash(); return nil        // delete key
        case 53: if model.fullScreenViewer { model.fullScreenViewer = false; if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }; return nil }; return e
        default: return e
        }
    }

    // MARK: menus
    func parseKey(_ s: String) -> (String, NSEvent.ModifierFlags) {
        var mask: NSEvent.ModifierFlags = []; var rest = Substring(s)
        while let c = rest.first, "⌘⌥⇧⌃".contains(c) { switch c { case "⌘": mask.insert(.command); case "⌥": mask.insert(.option); case "⇧": mask.insert(.shift); default: mask.insert(.control) }; rest = rest.dropFirst() }
        var k = String(rest)
        if k.hasPrefix("'\\u"), k.count >= 8, let v = UInt32(k.dropFirst(3).prefix(4), radix: 16), let sc = Unicode.Scalar(v) { k = String(Character(sc)) }
        else if k.hasPrefix("'"), k.hasSuffix("'"), k.count > 2 { k = String(k.dropFirst().dropLast()) }
        switch k { case "⌫": k = "\u{8}"; case "↩": k = "\r"; case "⎋": k = "\u{1b}"; case "⌦": k = "\u{7f}"; case "Space": k = " "; case "⇥": k = "\t"; case "↑": k = "\u{f700}"; case "↓": k = "\u{f701}"; case "←": k = "\u{f702}"; case "→": k = "\u{f703}"; default: break }
        if k.count == 1, k.first!.isLetter { k = k.lowercased() }
        return (k, mask)
    }

    func buildMenus() {
        guard let data = menuJSON.data(using: .utf8), let nodes = try? JSONDecoder().decode([MenuNode].self, from: data) else { return }
        let main = NSMenu()
        for top in nodes {
            let title = model.lang == "de" ? top.de : top.en
            let item = NSMenuItem(title: top.en == "Retrolux" ? "Retrolux" : title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: top.en == "Retrolux" ? "Retrolux" : title)
            addItems(top.children, to: sub, path: top.en)
            item.submenu = sub; main.addItem(item)
            switch top.en {
            case "Window": NSApp.windowsMenu = sub
            case "Help": NSApp.helpMenu = sub
            default: break
            }
        }
        NSApp.mainMenu = main
        injectCustomMenuItems()
    }

    func addItems(_ nodes: [MenuNode], to menu: NSMenu, path: String) {
        for n in nodes where !n.en.contains("Feedback") {   // no feedback channel in this independent app
            if n.sep { menu.addItem(.separator()); continue }
            var title = model.lang == "de" ? n.de : n.en
            if title.hasSuffix(" ") { title = String(title.dropLast()) }
            let p = path + "/" + n.en.trimmingCharacters(in: .whitespaces)
            let item = NSMenuItem(title: title.replacingOccurrences(of: "Retrolux", with: "Retrolux"), action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = p
            let keyStr = (model.lang == "de" ? n.keyDE : nil) ?? n.key
            if !keyStr.isEmpty { let (k, m) = parseKey(keyStr); item.keyEquivalent = k; item.keyEquivalentModifierMask = m }
            if n.alt { item.isAlternate = true }
            if p.hasSuffix("/Switch to Library") {
                let sub = NSMenu(title: "LIBS"); sub.delegate = self; item.action = nil; item.submenu = sub; menu.addItem(item); continue
            }
            if p.hasSuffix("/Add Adjustment Preset") || p.hasSuffix("/Replace with Adjustment Preset") {
                let sub = NSMenu(title: p.hasSuffix("/Add Adjustment Preset") ? "PRESETS:add" : "PRESETS:replace"); sub.delegate = self; item.action = nil; item.submenu = sub; menu.addItem(item); continue
            }
            if !n.children.isEmpty || p.hasSuffix("/Label") {
                let sub = NSMenu(title: title); item.action = nil
                if p.hasSuffix("/Label") {
                    for i in 1...7 { let c = NSMenuItem(title: model.lang == "de" ? Labels.namesDE[i] : Labels.names[i], action: #selector(menuAction(_:)), keyEquivalent: i <= 6 ? "\(i)" : ""); c.keyEquivalentModifierMask = [.command]
                        c.representedObject = "Metadata/Label/\(i)"; c.target = self; sub.addItem(c) }
                    let none = NSMenuItem(title: model.lang == "de" ? "Kein Etikett" : "No Label", action: #selector(menuAction(_:)), keyEquivalent: "0"); none.keyEquivalentModifierMask = [.command]; none.representedObject = "Metadata/Label/0"; none.target = self; sub.addItem(none)
                } else if p.hasSuffix("/Services") { NSApp.servicesMenu = sub }
                else if p.contains("Add Keyword") || p.contains("Remove Keyword") { addKeywordMenu(sub, remove: p.contains("Remove")) }
                else { addItems(n.children, to: sub, path: p) }
                item.submenu = sub
            }
            menu.addItem(item)
        }
    }
    func addKeywordMenu(_ sub: NSMenu, remove: Bool) {
        sub.delegate = self; sub.removeAllItems()
    }

    @objc func menuAction(_ s: NSMenuItem) {
        guard let path = s.representedObject as? String else { return }
        if path.hasPrefix("Metadata/Label/"), let i = Int(path.split(separator: "/").last ?? "") { model.setLabel(i); return }
        if path.hasPrefix("LIB:") { model.switchLibrary(to: URL(fileURLWithPath: String(path.dropFirst(4)))); return }
        if path.hasPrefix("PRESET:") {
            let parts = path.split(separator: ":", maxSplits: 2).map(String.init); guard parts.count == 3 else { return }
            let replace = parts[1] == "replace"
            if let sp = Presets.all.first(where: { $0.id == parts[2] }) { model.applyPreset(sp, replace: replace) }
            else if let up = model.userPresets.first(where: { $0.id == parts[2] }) { model.apply(user: up, replace: replace) }
            return
        }
        if path.hasPrefix("KW:"), let kw = path.split(separator: ":", maxSplits: 2).last.map(String.init) { path.contains("KW:A:") ? model.addKeyword(kw) : model.removeKeyword(kw); return }
        commands[path]?(model)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let path = item.representedObject as? String else { return true }
        // plain-key shortcuts must not steal typing from text fields
        if window?.firstResponder is NSText, item.keyEquivalentModifierMask.intersection([.command, .control]).isEmpty, !item.keyEquivalent.isEmpty { return false }
        if path.hasPrefix("LIB:") { return true }
        if path.hasPrefix("Metadata/Label/") || path.hasPrefix("KW:") || path.hasPrefix("PRESET:") { return !model.selection.isEmpty }
        switch path {   // present-day equivalents keep the classic menu slot
        case "File/Share/MobileMe Gallery…": item.title = model.lang == "de" ? "iCloud-Drive-Galerie …" : "iCloud Drive Gallery…"
        case "File/Share/Facebook…": item.title = model.lang == "de" ? "Teilen …" : "Share…"
        case "File/Order Prints…": item.title = model.lang == "de" ? "Fotoabzüge exportieren …" : "Export Prints for Lab…"
        default: break }
        if path == "Edit/Undo" { item.title = (model.lang == "de" ? "Widerrufen " : "Undo ") + model.undoName; return model.canUndo || window?.firstResponder is NSText }
        if path == "Edit/Redo" { return model.canRedo || window?.firstResponder is NSText }
        if ["Edit/Cut", "Edit/Copy", "Edit/Paste", "Edit/Spelling/Spelling…", "Edit/Spelling/Check Spelling", "Edit/Spelling/Check Spelling as You Type", "Edit/Show Fonts"].contains(path) { return window?.firstResponder is NSText }
        if path.hasSuffix("/Hide Retrolux") || path.hasSuffix("/Hide Others") || path.hasSuffix("/Show All") || path.hasSuffix("/Quit Retrolux") || path.hasSuffix("/Close Window") || path.hasSuffix("/Minimize") || path.hasSuffix("/Zoom") { return true }
        if path == "Metadata/Manage My Places…" { return true }
        let needsSel = ["Photos/", "Metadata/", "Stacks/"].contains { path.hasPrefix($0) } || ["File/Delete", "File/Delete Master Image and All Versions", "File/Relocate Master…", "File/Consolidate Master…"].contains(path) || path.hasPrefix("File/Export/Version") || path.hasPrefix("File/Export/Master") || path.hasPrefix("File/Export/Metadata") || path == "File/Share/Email…"
        if commands[path] == nil { return false }
        if needsSel && model.selection.isEmpty && !path.contains("Stamp") { return false }
        return true
    }

    func buildCommands() {
        func c(_ p: String, _ f: @escaping (AppModel) -> Void) { commands[p] = f }
        c("Retrolux/About Retrolux") { _ in NSApp.orderFrontStandardAboutPanel(nil) }
        c("Retrolux/Check for Updates…") { _ in AppUpdater.shared.checkForUpdates() }
        c("Retrolux/Preferences…") { [unowned self] m in showPrefs(m) }
        c("Retrolux/Presets/Image Export…") { $0.showExportPresetEditor = true }
        c("Retrolux/Empty Retrolux Trash…") { m in
            let a = NSAlert(); a.messageText = m.L("Empty the Trash?", "Papierkorb leeren?"); a.informativeText = m.L("Versions and managed originals in the Trash are deleted permanently. Referenced originals are never touched.", "Versionen und verwaltete Originale im Papierkorb werden endgültig gelöscht. Referenzierte Originale bleiben unangetastet.")
            a.addButton(withTitle: m.L("Empty Trash", "Papierkorb leeren")).hasDestructiveAction = true; a.addButton(withTitle: m.L("Cancel", "Abbrechen"))
            if a.runModal() == .alertFirstButtonReturn { m.emptyTrash() } }
        // File
        c("File/New/Project") { $0.newProject() }; c("File/New/Folder") { $0.newFolder() }; c("File/New/Album") { $0.newAlbum() }; c("File/New/Smart Album") { $0.newSmartAlbum() }
        c("File/Import/Files…") { m in m.pendingImportURLs = []; m.showImportSheet = true }
        c("File/Import/Folders as Projects…") { m in
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
            if p.runModal() == .OK { for u in p.urls { var o = ImportOptions(); o.newProjectName = u.lastPathComponent; m.runImport([u], o) } } }
        c("File/Import/Library/Project…") { m in
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = true; p.message = m.L("Choose a legacy library (.aplibrary)", "Legacy-Bibliothek (.aplibrary) wählen")
            if p.runModal() == .OK, let u = p.url { m.runMigration(u) } }
        c("File/Delete") { $0.moveToTrash() }
        c("File/Duplicate Album") { _ in }; commands["File/Duplicate Album"] = nil
        // Edit
        c("Edit/Undo") { [unowned self] m in if let t = window.firstResponder as? NSText { t.undoManager?.undo() } else { m.undo() } }
        c("Edit/Redo") { [unowned self] m in if let t = window.firstResponder as? NSText { t.undoManager?.redo() } else { m.redo() } }
        c("Edit/Cut") { _ in NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }; c("Edit/Copy") { _ in NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }; c("Edit/Paste") { _ in NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
        c("Edit/Duplicate") { $0.duplicateVersion(fromMaster: false) }
        c("Edit/Select All") { [unowned self] m in if window.firstResponder is NSText { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } else { m.selectAll() } }
        c("Edit/Deselect All") { $0.deselectAll() }; c("Edit/Invert Selection") { $0.invertSelection() }
        c("Edit/Find…") { [unowned self] _ in focusSearch() }
        // Photos
        c("Photos/Show Photo Info") { $0.inspectorTab = .metadata; $0.showInspector = true }
        c("Photos/Rotate Clockwise") { $0.rotate(90) }; c("Photos/Rotate Counterclockwise") { $0.rotate(-90) }
        c("Photos/Reset All Adjustments") { $0.resetAllAdjustments() }
        c("Photos/Duplicate Version") { $0.duplicateVersion(fromMaster: false) }; c("Photos/New Version from Master") { $0.duplicateVersion(fromMaster: true) }
        c("Photos/Remove from Album") { $0.removeFromAlbum() }
        c("Photos/Add Adjustment") { $0.inspectorTab = .adjustments; $0.showInspector = true }
        c("Photos/Set Key Photo for Project") { m in if case .container(let id) = m.source, let p = m.primary { try? m.store.setKeyPhoto(id, p) } }
        // Metadata
        for (i, s) in ["★★★★★", "★★★★", "★★★", "★★", "★"].enumerated() { c("Metadata/Rating/\(s)") { $0.setRating(5 - i) } }
        c("Metadata/Rating/Unrated") { $0.setRating(0) }; c("Metadata/Rating/Rejected") { $0.setRating(-1) }
        c("Metadata/Rating/Increase Rating") { $0.adjustRating(1) }; c("Metadata/Rating/Decrease Rating") { $0.adjustRating(-1) }
        c("Metadata/Flag") { $0.toggleFlag() }
        c("Metadata/Lift Metadata") { $0.lift(meta: true, adj: false) }; c("Metadata/Lift Adjustments") { $0.lift(meta: false, adj: true) }
        c("Metadata/Lift Metadata & Adjustments") { $0.lift(meta: true, adj: true) }; c("Metadata/Stamp") { $0.stamp() }
        c("Metadata/New Keyword") { $0.inspectorTab = .metadata; $0.showInspector = true }
        // View
        c("View/Browser") { $0.viewMode = .browser }; c("View/Split View") { $0.viewMode = .split }; c("View/Viewer") { $0.viewMode = .viewer }
        c("View/Cycle View Mode") { m in m.viewMode = m.viewMode == .split ? .viewer : (m.viewMode == .viewer ? .browser : .split) }
        c("View/Full Screen") { [unowned self] _ in window.toggleFullScreen(nil) }
        c("View/Zoom to Actual Size") { m in m.zoomActual.toggle(); m.scheduleRender() }
        c("View/Show Master Image") { m in m.showMaster.toggle(); m.scheduleRender() }
        c("View/Browser/Filmstrip") { $0.browserMode = .filmstrip }; c("View/Browser/Grid") { $0.browserMode = .grid }; c("View/Browser/List") { $0.browserMode = .list }
        c("View/Inspector/Library") { $0.inspectorTab = .library; $0.showInspector = true }; c("View/Inspector/Metadata") { $0.inspectorTab = .metadata; $0.showInspector = true }
        c("View/Inspector/Adjustments") { $0.inspectorTab = .adjustments; $0.showInspector = true }
        c("View/Inspector/Next Tab") { m in let all = InspectorTab.allCases; m.inspectorTab = all[(all.firstIndex(of: m.inspectorTab)! + 1) % all.count] }
        c("View/Zoom In") { m in m.zoomActual = true; m.scheduleRender() }; c("View/Zoom Out") { m in m.zoomActual = false; m.scheduleRender() }
        c("View/Metadata Display/Browser/Show Metadata") { $0.showMetaInBrowser.toggle() }
        // Window
        c("Window/Minimize") { [unowned self] _ in window.miniaturize(nil) }; c("Window/Zoom") { [unowned self] _ in window.zoom(nil) }
        c("Window/Show Inspector") { $0.showInspector.toggle() }; c("Window/Show Control Bar") { $0.showToolStrip.toggle() }
        c("Window/Show Activity") { m in m.status = m.statusLine }
        registerMore()
        c("Retrolux/Hide Retrolux") { _ in NSApp.hide(nil) }
        c("Retrolux/Hide Others") { _ in NSApp.hideOtherApplications(nil) }
        c("Retrolux/Show All") { _ in NSApp.unhideAllApplications(nil) }
        c("Retrolux/Quit Retrolux") { [unowned self] _ in quit() }
        c("File/Close Window") { [unowned self] _ in window.performClose(nil) }
    }
    func focusSearch() { window.contentView?.firstSubview(ofType: NSSearchField.self)?.becomeFirstResponder() }

    // standard app items need real selectors
    @objc func hideApp(_ s: Any?) { NSApp.hide(nil) }

    func showPrefs(_ m: AppModel) {
        if prefsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = m.L("Preferences", "Einstellungen"); w.contentView = NSHostingView(rootView: PreferencesView(model: m)); w.center(); w.isReleasedWhenClosed = false; prefsWindow = w
        }
        prefsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension NSView {
    func firstSubview<T: NSView>(ofType: T.Type) -> T? { for s in subviews { if let t = s as? T { return t }; if let t = s.firstSubview(ofType: ofType) { return t } }; return nil }
}
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "LIBS" {
            menu.removeAllItems()
            for u in model.recentLibraries { let i = NSMenuItem(title: u.deletingPathExtension().lastPathComponent, action: #selector(menuAction(_:)), keyEquivalent: ""); i.target = self; i.representedObject = "LIB:" + u.path; i.toolTip = u.path; menu.addItem(i) }
            if !model.recentLibraries.isEmpty { menu.addItem(.separator()) }
            for (t, p) in [(model.L("Open Library…", "Bibliothek öffnen …"), "File/Switch to Library/Other/New…"), (model.L("Clear Menu", "Menü löschen"), "File/Switch to Library/Clear Menu")] { let i = NSMenuItem(title: t, action: #selector(menuAction(_:)), keyEquivalent: ""); i.target = self; i.representedObject = p; menu.addItem(i) }
            return
        }
        if menu.title.hasPrefix("PRESETS:") {
            let kind = menu.title.hasSuffix("replace") ? "replace" : "add"
            menu.removeAllItems()
            for f in Presets.folders {
                let sub = NSMenu(title: f)
                for p in Presets.all where p.folder == f { let i = NSMenuItem(title: p.name, action: #selector(menuAction(_:)), keyEquivalent: ""); i.target = self; i.representedObject = "PRESET:\(kind):\(p.id)"; sub.addItem(i) }
                let it = NSMenuItem(title: f, action: nil, keyEquivalent: ""); it.submenu = sub; menu.addItem(it)
            }
            if !model.userPresets.isEmpty {
                let sub = NSMenu(title: "User")
                for p in model.userPresets { let i = NSMenuItem(title: p.name, action: #selector(menuAction(_:)), keyEquivalent: ""); i.target = self; i.representedObject = "PRESET:\(kind):\(p.id)"; sub.addItem(i) }
                let it = NSMenuItem(title: model.L("My Presets", "Meine Voreinstellungen"), action: nil, keyEquivalent: ""); it.submenu = sub; menu.addItem(it)
            }
            return
        }
        // dynamic keyword submenus (Metadata ▸ Add/Remove Keyword)
        menu.removeAllItems()
        let remove = menu.supermenu?.items.first(where: { $0.submenu === menu })?.title.hasPrefix("Remove") == true || menu.supermenu?.items.first(where: { $0.submenu === menu })?.title.hasPrefix("Schlagwort entfernen") == true
        if !remove {
            let slots = model.activeKeywordSet.keywords
            for (i, k) in slots.enumerated() where i < 9 && !k.isEmpty {
                let it = NSMenuItem(title: k, action: #selector(menuAction(_:)), keyEquivalent: "\(i + 1)"); it.keyEquivalentModifierMask = [.option]; it.target = self; it.representedObject = "KW:A:" + k; menu.addItem(it)
            }
            if !slots.allSatisfy({ $0.isEmpty }) { menu.addItem(.separator()) }
        }
        let kws = remove ? Array(Set(model.selectedVersions.flatMap(\.keywords))).sorted() : model.store.allKeywords
        if kws.isEmpty { let i = NSMenuItem(title: model.L("(none)", "(keine)"), action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        for k in kws.prefix(40) { let i = NSMenuItem(title: k, action: #selector(menuAction(_:)), keyEquivalent: ""); i.target = self; i.representedObject = (remove ? "KW:R:" : "KW:A:") + k; menu.addItem(i) }
        if remove { menu.addItem(.separator()); let i = NSMenuItem(title: model.L("Remove All Keywords", "Alle Schlagwörter entfernen"), action: #selector(menuAction(_:)), keyEquivalent: ""); i.target = self; i.representedObject = "Metadata/Remove Keyword/Remove All Keywords"; menu.addItem(i) }
    }
}
import Combine
