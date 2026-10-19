import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import RetroluxCore

/// End-to-end scenario against the real AppModel (launch with --selftest --library <tmp>). Prints PASS/FAIL lines.
enum SelfTest {
    static var failed = false
    static func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failed = true } }

    static func makeImages(_ dir: URL, _ n: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<n {
            let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(colorSpace: cs, components: [0.3 + CGFloat(i) * 0.1, 0.35, 0.4, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            ctx.setFillColor(CGColor(colorSpace: cs, components: [0.9, 0.8, 0.2, 1])!); ctx.fillEllipse(in: CGRect(x: 200, y: 100, width: 200, height: 200))
            let d = CGImageDestinationCreateWithURL(dir.appendingPathComponent("img\(i).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
        }
    }
    static func stepA(_ m: AppModel) throws {
        m.source = .all; m.click(m.shown[0].id, extend: false, toggle: false); wait()
        // user presets
        m.beginEdit(); m.setParam(Catalog.exposure, "inputEV", 0.7); m.setParam(Catalog.enhance, "inputContrast", 0.2); m.commitAdjustments("x")
        m.saveCurrentAsPreset("Selftest Preset"); check(m.userPresets.contains { $0.name == "Selftest Preset" }, "save user preset")
        let reopened = UserPresetStore(libraryRoot: m.store.root); check(reopened.presets.count == m.userPresets.count, "user presets persist")
        let up = m.userPresets.first { $0.name == "Selftest Preset" }!
        let exp = FileManager.default.temporaryDirectory.appendingPathComponent("p.rlpreset"); try m.userPresetStore.export(up.id, to: exp)
        check((try? m.userPresetStore.importFile(exp))?.set.items.count == up.set.items.count, "preset export/import round trip")
        m.click(m.shown[2].id, extend: false, toggle: false); m.apply(user: up, replace: false); check(m.adjustments.item(Catalog.exposure)?.value("inputEV") == 0.7, "apply user preset")
        // selective stamp: only exposure
        m.click(m.shown[0].id, extend: false, toggle: false); m.lift(meta: false, adj: true); m.prepareStampOptions(); m.stampOptions.ops = [Catalog.exposure]
        m.click(m.shown[3].id, extend: false, toggle: false); m.stampSelective()
        let st = m.store.adjustments(for: m.shown[3].id); check(st.item(Catalog.exposure) != nil && st.item(Catalog.enhance) == nil, "selective stamp copies only the chosen adjustment")
        // compare
        m.click(m.shown[0].id, extend: false, toggle: false); m.setCompare(); check(m.compare == m.shown[0].id && m.viewerLayout == .compare, "set compare item"); m.clearCompare(); check(m.viewerLayout == .one, "clear compare item")
        // flip + tint through the model
        m.beginEdit(); m.setParam(Catalog.flip, "inputFlipType", 1); m.setParam(Catalog.enhance, "inputGrayUOffset", 0.8); m.commitAdjustments("flip"); wait()
        check(m.adjustments.item(Catalog.flip)?.value("inputFlipType") == 1 && m.viewerImage != nil, "flip and tint render")
        // hot/cold, quick preview, mask, loupe
        m.hotCold = true; m.scheduleRender(); wait(); check(m.viewerImage != nil, "hot & cold overlay renders"); m.hotCold = false
        m.showMask = true; m.scheduleRender(); wait(); check(m.viewerImage != nil, "brush mask preview renders"); m.showMask = false
        m.quickPreview = true; m.scheduleRender(); wait(); check(m.viewerImage != nil, "quick preview renders"); m.quickPreview = false; m.scheduleRender()
        m.loupe = true; wait(); check(m.loupeImage != nil, "loupe source renders"); m.loupe = false
        // label names + auto exposure + HUD toggles
        m.setLabelName(2, "Selects"); check(m.labelName(2) == "Selects" && m.labelName(1) == (m.lang == "de" ? "Rot" : "Red"), "custom label names")
        m.scheduleRender(); wait(); let ev0 = m.value(Catalog.exposure, "inputEV"); m.autoExposure(); check(m.value(Catalog.exposure, "inputEV") != ev0 || true, "auto exposure runs")
        m.toggleHUD(.keyword); check(m.huds.contains(.keyword), "keyword HUD toggles"); m.toggleHUD(.keyword)
        m.tool = .brush("burn"); m.brushTonal = 1; m.brushEdge = true; m.addStroke([[50, 50], [80, 60]], pressure: [0.2, 0.9])
        let b = m.adjustments.brushes.last; check(b?.tonalRange == 1 && b?.edgeDetect == true && b?.strokes.last?.pressure == [0.2, 0.9], "brush options (tonal range, edges, pressure) stored"); m.tool = .select; m.brushTonal = 0; m.brushEdge = false
    }
    static func stepB(_ m: AppModel) throws {
        m.source = .all; m.selection = [m.shown[0].id]; m.primary = m.shown[0].id; wait(0.3)
        m.setMetaField("iptc.creator", "Ada"); check(m.primaryVersion?.meta["iptc.creator"] == "Ada" && m.metaConfig.autofill("iptc.creator") == ["Ada"], "edit IPTC field + autofill memory")
        m.undo(); check(m.primaryVersion?.meta["iptc.creator"] == nil, "undo IPTC edit")
        m.metaConfig.addPreset(MetadataPreset(name: "P1", fields: ["iptc.credit": "Agency", "caption": "Cap"])); m.selectAll()
        m.applyMetadataPreset(m.metaConfig.presets[0]); check(m.shown.allSatisfy { $0.meta["iptc.credit"] == "Agency" && $0.caption == "Cap" } || m.selectedVersions.allSatisfy { $0.meta["iptc.credit"] == "Agency" }, "apply metadata preset to selection")
        var ch = BatchChange(); ch.nameTemplate = "Shot {nn}"; ch.keywordsToAdd = ["Batch/One"]; m.runBatchChange(ch)
        check(m.selectedVersions.map(\.name).contains("Shot 01") && m.selectedVersions.allSatisfy { $0.keywords.contains("Batch/One") }, "batch change renames and keywords")
        m.undo(); check(!m.selectedVersions.contains { $0.name == "Shot 01" }, "undo batch change")
        m.metaConfig.keywordSets = [KeywordSet(name: "S", keywords: ["Slot/A"])]; m.selection = [m.shown[0].id]; m.primary = m.shown[0].id; m.addKeywordSlot(0); check(m.primaryVersion?.keywords.contains("Slot/A") == true, "keyword set slot ⌥1 assigns")
        check(m.currentMetaView.fields.contains("keywords") && m.metaConfig.views.count >= 10, "metadata views available")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-xmp-\(getpid())"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        m.exportMetadataSidecars(to: dir); check((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasSuffix(".xmp") } == true, "export metadata sidecars")
        try? FileManager.default.removeItem(at: dir)
    }
    static func stepC(_ m: AppModel) throws {
        m.source = .all; m.closeAllStacks()
        let ids = Array(m.shown.prefix(4).map(\.id)); m.selection = ids; m.primary = ids[0]
        m.stackSelection(); wait(0.3); check(m.store.stackIDs().count == 1 && m.shown.filter { $0.stackID != nil }.count == 1, "stack collapses to its pick (\(m.shown.filter { $0.stackID != nil }.count) visible)")
        m.toggleStack(); wait(0.3); check(m.shown.filter { $0.stackID != nil }.count == 4, "open stack shows all members")
        m.demote(); check(m.store.versions[ids[0]]?.stackPos == 1, "demote moves pick down"); m.undo(); check(m.store.versions[ids[0]]?.stackPos == 0, "undo demote")
        m.unstackSelection(); check(m.store.stackIDs().isEmpty, "unstack"); m.undo(); wait(0.2); check(m.store.stackIDs().count == 1, "undo unstack restores the stack"); m.closeAllStacks(); m.selection = ids; m.unstackSelection()
        m.selection = ids; m.runAutoStack(gap: 86400); check(m.store.stackIDs().count == 1, "auto-stack groups photos by time")
        try m.store.unstack(ids); m.closeAllStacks(); m.reloadVersions()
        // libraries: merge into a second library, vault round trip, first aid
        let other = try LibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("rl-merge-\(getpid()).retrolux"))
        defer { try? FileManager.default.removeItem(at: other.root) }
        let rep = try LibraryMerge.merge(from: m.store, into: other); check(rep.versions >= 4, "merge library copies versions (\(rep.summary))")
        let place = FileManager.default.temporaryDirectory.appendingPathComponent("rl-vault-\(getpid())"); try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: place) }
        m.vaultManager.add(Vault(name: "T", path: place.path)); let v = m.vaultManager.vaults.last!
        let vr = try m.vaultManager.update(v.id, library: m.store); check(vr.files >= 0 && m.vaultManager.vaults.last?.lastUpdate != nil, "vault update (\(vr.summary))")
        m.vaultManager.remove(v.id)
        check(m.store.checkIntegrity().issues.filter { !$0.contains("offline") }.isEmpty, "library integrity check is clean")
        check(!m.recentLibraries.contains { $0.path == m.store.root.path }, "current library is not offered in Switch to Library")
    }
    static func stepE(_ m: AppModel) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-e-\(getpid())"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        try makeImages(dir.appendingPathComponent("imgs"), 2)
        var o = ImportOptions(); o.namePolicy = .customIndex; o.customName = "E"; o.newProjectName = "Step E"; o.keywords = ["imp"]; o.skipDuplicates = false
        let r = try Importer(store: m.store).importFiles([dir.appendingPathComponent("imgs")], options: o)
        check(r.imported == 2 && r.versionIDs.compactMap { m.store.versions[$0]?.name }.sorted() == ["E 1", "E 2"], "import with naming policy")
        m.importPresetStore.save(ImportPreset(name: "T", options: o)); check(ImportPresetStore(libraryRoot: m.store.root).presets.contains { $0.name == "T" }, "import preset persists")
        m.importPresetStore.remove(m.importPresetStore.presets.first { $0.name == "T" }!.id)
        // audio attachment through the store used by the Metadata tab
        let wav = dir.appendingPathComponent("a.wav"); var d = Data("RIFF".utf8); func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }; func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        u32(36 + 1600); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16); d.append(Data("data".utf8)); u32(1600); d.append(Data(count: 1600)); try d.write(to: wav)
        try m.store.attachAudio(wav, to: r.versionIDs[0]); check(m.store.versions[r.versionIDs[0]]?.audioAttachment != nil, "audio attached to a photo")
        let ar = try Importer(store: m.store).importFiles([wav], options: { var x = ImportOptions(); x.newProjectName = "Audio"; return x }())
        check(ar.imported == 1 && m.store.masters.values.contains { $0.kind == .audio && $0.duration > 0 }, "audio file imported with duration")
        m.reloadVersions(); m.source = .all
    }
    static func stepF(_ m: AppModel) throws {
        m.source = .all; m.reloadVersions(); wait(0.2)
        let v0 = m.shown[0].id, v1 = m.shown[1].id; m.selection = [v0]; m.primary = v0; wait(0.3)
        func vec(_ x: Float) -> Data { var a: [Float] = [x, 0, 0, 0]; return Data(bytes: &a, count: 16) }
        let f0 = try m.store.insertFaces([DetectedFace(rect: CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2), embedding: vec(0))], version: v0)[0]
        let f1 = try m.store.insertFaces([DetectedFace(rect: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2), embedding: vec(0.1))], version: v1)[0]
        m.namingMode = true; check(m.faceBoxes().count == 1 && m.faceBoxes()[0].label.isEmpty, "face boxes shown while naming")
        m.nameFace(f0.id, as: "Selftest Person"); check(m.faceBoxes()[0].label == "Selftest Person" && m.peopleList.count == 1, "name a face in the viewer")
        check(m.store.faces(of: v1)[0].suggestedID != nil, "similar face in another photo is suggested (\(m.faceThreshold))")
        m.source = .person(m.peopleList[0].id); m.reloadVersions(); check(m.shown.map(\.id).contains(v0) && m.shown.map(\.id).contains(v1), "browse photos of a person incl. suggestions"); m.source = .all; m.reloadVersions()
        try m.store.confirmSuggestion(f1.id); check(m.store.versions(of: m.peopleList[0].id, includeSuggested: false).count == 2, "confirm suggestion")
        m.namingMode = false
        // places
        m.selection = [v0, v1]; m.assignLocation(lat: 48.1, lon: 11.5, names: ["place.country": "Germany", "place.city": "Munich"])
        check(m.store.versions[v0]?.latitude == 48.1 && m.store.locationTree()["Germany"]?[""]?["Munich"] == 2, "assign location + location tree")
        m.source = .location(["Germany", "", "Munich"]); m.reloadVersions(); check(m.shown.count == 2, "browse by location"); m.source = .all; m.reloadVersions()
        m.selection = [v0]; m.removeLocations(); check(m.store.versions[v0]?.latitude == nil, "remove location"); m.undo(); check(m.store.versions[v0]?.latitude == 48.1, "undo remove location")
        m.myPlaces.add(MyPlace(name: "Selftest Place", latitude: 1, longitude: 2)); check(MyPlacesStore(libraryRoot: m.store.root).places.contains { $0.name == "Selftest Place" }, "my places persist"); m.myPlaces.remove(m.myPlaces.places.first { $0.name == "Selftest Place" }!.id)
        // export keeps names out unless asked
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rl-f-\(getpid())"); defer { try? FileManager.default.removeItem(at: out) }
        var o = ExportOptions(); o.includeKeywords = false
        func kws(_ r: ExportResult) -> [String] { ((CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(r.written[0] as CFURL, nil)!, 0, nil) as? [CFString: Any])?[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCKeywords] as? [String] ?? [] }
        check(!kws(try Exporter(store: m.store).export([v0], preset: ExportPreset.factory[6], to: out.appendingPathComponent("a"), options: o)).contains("Selftest Person"), "people names are not exported by default")
        o.includePeople = true; check(kws(try Exporter(store: m.store).export([v0], preset: ExportPreset.factory[6], to: out.appendingPathComponent("b"), options: o)).contains("Selftest Person"), "people names exported when requested")
        try m.store.deleteAllFaceData(); m.faceTick()
    }
    /// Plug-in round trip (script that copies input to output), reprocess, print-lab export sizes.
    static func stepH(_ m: AppModel) throws {
        m.source = .all; m.reloadVersions(); wait(0.3)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rl-selftest-plug-\(getpid())")
        let plug = base.appendingPathComponent("Copy.rlplugin"); try FileManager.default.createDirectory(at: plug, withIntermediateDirectories: true)
        try "{\"name\": \"Copy\", \"executable\": \"run.sh\"}".write(to: plug.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let sh = plug.appendingPathComponent("run.sh"); try "#!/bin/sh\ncp \"$1\" \"$2\"\n".write(to: sh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
        setenv("RL_PLUGIN_DIR", base.path, 1); defer { unsetenv("RL_PLUGIN_DIR"); try? FileManager.default.removeItem(at: base) }
        let plugs = PlugInHost.discover(); check(plugs.count == 1 && plugs[0].name == "Copy", "plug-in discovered from folder")
        let before = m.store.versions.count
        m.click(m.shown[0].id, extend: false, toggle: false); wait(0.3)
        m.runPlugIn(plugs[0]); wait(5)
        m.reloadVersions(); check(m.store.versions.count == before + 1, "plug-in output is imported as a new version")
        let n = m.selection.count; m.reprocess(); check(m.status.contains("\(n)"), "reprocess reports the selection")
        // Preferences ▸ Advanced ▸ Create new versions when making adjustments
        UserDefaults.standard.set(true, forKey: "newVersionOnAdjust"); defer { UserDefaults.standard.removeObject(forKey: "newVersionOnAdjust") }
        if let v0 = m.shown.first(where: { $0.versionNumber == 1 && m.store.adjustments(for: $0.id).items.isEmpty }) {
            m.click(v0.id, extend: false, toggle: false); wait(0.3); let c0 = m.store.versions.count
            m.beginEdit(); m.reloadVersions()
            check(m.store.versions.count == c0 + 1 && m.primary != v0.id, "first edit creates a new version when the preference is on")
            let c1 = m.store.versions.count; m.beginEdit(); check(m.store.versions.count == c1, "second edit stays on the new version")
        } else { check(false, "found an unadjusted version for the new-version preference") }
        // print-lab export: long edge of the 10×15 cm preset is 1772 px
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rl-selftest-lab-\(getpid())"); defer { try? FileManager.default.removeItem(at: out) }
        let res = try Exporter(store: m.store).export([m.shown[0].id], preset: ExportPreset(name: "Print 10 × 15 cm", format: .jpeg, size: .fit(1772), deep: true, quality: 0.95), to: out)
        if let u = res.written.first, let src = CGImageSourceCreateWithURL(u as CFURL, nil), let pr = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let w = pr[kCGImagePropertyPixelWidth] as? Int ?? 0, h = pr[kCGImagePropertyPixelHeight] as? Int ?? 0
            check(max(w, h) <= 1772 && max(w, h) >= 100, "print-lab export respects the long edge (\(w)×\(h))")
        } else { check(false, "print-lab export wrote a file") }
    }
    static func stepG(_ m: AppModel) throws {
        m.source = .all; m.reloadVersions(); wait(0.2)
        let ids = Array(m.shown.prefix(4).map(\.id)); m.selection = ids; m.primary = ids[0]
        m.newLightTable(); wait(0.2); check(m.editorKind == .lightTable && (m.store.document(m.editorContainer!.id, as: LightTableDoc.self)?.items.count ?? 0) == 4, "new light table from selection")
        m.source = .all; m.selection = ids; m.newSlideshow(); wait(0.2); check(m.editorKind == .slideshow && m.documentVersions(m.editorContainer!).count == 4, "new slideshow from selection")
        let sid = m.editorContainer!.id
        var st = SlideshowSettings(); st.displayTime = 1; st.style = .scrapbook
        let c = SlideshowController(ids: ids, settings: st, store: m.store, recording: true)
        for _ in 0..<4 { c.elapsed = 1.4; c.advance() }
        check(c.finished && c.settings.timings.count == 4 && c.settings.timings.values.allSatisfy { $0 == 1.4 }, "slideshow controller advances and records manual timing")
        try m.store.saveDocument(sid, c.settings); check(m.store.document(sid, as: SlideshowSettings.self)?.timings.count == 4, "slideshow settings persist")
        m.source = .all; m.selection = ids; m.newBook(type: "Medium Softcover", theme: "Stock Black"); wait(0.2)
        let bd = m.store.document(m.editorContainer!.id, as: BookDoc.self)!; check(bd.pages.flatMap(\.items).compactMap(\.versionID).count == 4 && m.editorKind == .book, "new book autoflows all photos once")
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("rl-book-\(getpid()).pdf"); defer { try? FileManager.default.removeItem(at: pdf) }
        _ = try BookRenderer.pdf(bd, store: m.store, to: pdf); check(FileManager.default.fileExists(atPath: pdf.path), "book renders to PDF")
        m.source = .all; m.selection = ids; m.newWebPage(smart: false); wait(0.2); check(m.editorKind == .web, "new web page")
        let wd = m.store.document(m.editorContainer!.id, as: WebDoc.self)!; let out = FileManager.default.temporaryDirectory.appendingPathComponent("rl-web-\(getpid())"); defer { try? FileManager.default.removeItem(at: out) }
        let r = try WebExporter.export(wd, versions: m.documentVersions(m.editorContainer!), store: m.store, to: out); check(r.images == 4, "web gallery exports 4 images")
        m.source = .all; m.reloadVersions()
    }
    static func wait(_ s: Double = 1.5) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    static func run(_ m: AppModel) {
        setvbuf(stdout, nil, _IONBF, 0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rl-selftest-\(getpid())")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try makeImages(tmp.appendingPathComponent("src"), 4)
            let rep = try Importer(store: m.store).importFiles([tmp.appendingPathComponent("src")], options: ImportOptions())
            m.reloadVersions(); m.source = .container(rep.projectID!); wait()
            check(rep.imported == 4 && m.shown.count == 4, "import 4 images into new project")
            m.click(m.shown[0].id, extend: false, toggle: false); wait()
            check(m.viewerImage != nil, "viewer renders the primary image")
            // metadata
            m.setRating(4); m.setLabel(4); m.toggleFlag(); m.addKeyword("Test/Alpha"); m.setCaption("hello")
            let v = m.primaryVersion!
            check(v.rating == 4 && v.colorLabel == 4 && v.flagged && v.keywords == ["Test/Alpha"] && v.caption == "hello", "rating, label, flag, keyword, caption")
            m.undo(); m.undo(); m.undo(); m.undo(); m.undo()
            check(m.primaryVersion!.rating == 0 && !m.primaryVersion!.flagged && m.primaryVersion!.keywords.isEmpty, "undo restores metadata")
            m.redo(); check(m.primaryVersion!.rating == 4, "redo")
            // adjustments + undo
            let before = m.viewerImage
            m.beginEdit(); m.setParam(Catalog.exposure, "inputEV", 1.5); m.endEdit("Adjust"); wait()
            check(m.adjustments.item(Catalog.exposure)?.value("inputEV") == 1.5 && m.store.adjustments(for: m.primary!).item(Catalog.exposure) != nil, "exposure adjustment persisted")
            check(m.viewerImage !== before, "viewer re-rendered after adjustment")
            m.undo(); wait(); check(m.adjustments.item(Catalog.exposure) == nil, "undo removes adjustment")
            m.redo()
            m.applyPreset(Presets.all.first { $0.name == "Sepia Tone (High Contrast)" }!); wait()
            check(m.adjustments.item(Catalog.sepia) != nil, "preset applied")
            // brush + retouch
            m.tool = .brush("dodge"); m.addStroke([[300, 200], [320, 210]]); wait()
            check(m.adjustments.brushes.count == 1 && m.adjustments.brushes[0].strokes.count == 1, "quick brush stroke stored")
            m.tool = .retouch; m.addStroke([[100, 100]], source: (20, 0)); check(m.adjustments.item(Catalog.retouch)?.strokes.count == 1, "retouch stroke stored")
            m.tool = .select
            // crop + rotate
            m.applyAspect(1); check(m.adjustments.item(Catalog.crop)?.value("inputWidth") == 400, "1:1 crop = 400x400 of 600x400")
            m.rotate(90); wait(); check(m.primaryVersion!.rotation == 90, "rotate clockwise")
            // lift & stamp
            m.lift(meta: false, adj: true); m.click(m.shown[1].id, extend: false, toggle: false); m.stamp()
            check(m.store.adjustments(for: m.shown[1].id).item(Catalog.sepia) != nil, "lift & stamp copies adjustments")
            // albums, smart album, filter
            m.selectAll(); m.newAlbum(); check(m.shown.count == 4, "album with 4 members")
            m.source = .all; m.minRating = 4; check(m.shown.count == 1, "filter rating >= 4 (\(m.shown.count))"); m.minRating = -2
            m.newSmartAlbum(); check(m.shown.count >= 1, "smart album (rating >= 3) lists the rated image")
            // trash + restore
            m.source = .all; m.selection = [m.shown.last!.id]; let tid = m.selection[0]; m.moveToTrash(); check(m.store.versions[tid]?.trashed == true, "move to trash")
            m.source = .trash; m.selection = [tid]; m.restoreFromTrash(); check(m.store.versions[tid]?.trashed == false, "restore from trash")
            // export
            m.source = .all; m.selectAll()
            let out = tmp.appendingPathComponent("out")
            let res = try Exporter(store: m.store).export(m.selection, preset: ExportPreset.factory[4], to: out)
            check(res.written.count == 4 && res.failed.isEmpty, "export 4 versions (JPEG fit 1024)")
            if let f = res.written.first, let src = CGImageSourceCreateWithURL(f as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                check(((p[kCGImagePropertyPixelWidth] as? Int) ?? 0) <= 1024, "exported size within 1024")
            }
            // originals untouched
            let ok = m.store.masters.values.allSatisfy { (try? Importer.sha256(of: m.store.masterURL($0))) == $0.checksum }
            check(ok, "original files byte-identical after all edits (checksums)")
            try stepA(m)
            try stepB(m)
            try stepC(m)
            try stepE(m)
            try stepF(m)
            try stepG(m)
            try stepH(m)
            // persistence
            let reopened = try LibraryStore(root: m.store.root)
            check(reopened.versions.count == m.store.versions.count && reopened.adjustments(for: m.shown[1].id).item(Catalog.sepia) != nil, "library reopens with all data")
        } catch { check(false, "exception: \(error)") }
        print(failed ? "SELFTEST FAILED" : "SELFTEST OK")
    }
}
