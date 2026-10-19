import SwiftUI
import AppKit
import AVKit
import ImageCaptureCore
import UniformTypeIdentifiers
import RetroluxCore

struct ImportItem: Identifiable, Hashable {
    let url: URL; let kind: MediaKind; let raw: Bool; var checked = true
    var id: String { url.path }
}

/// Import browser: pick a source (files, card, camera), look at enlarged previews, tick what to import, set options, save as preset.
struct ImportSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var camera = CameraManager()
    @State private var items: [ImportItem] = []
    @State private var selected: ImportItem?
    @State private var opts = ImportOptions()
    @State private var newProject = true
    @State private var projectName = ""
    @State private var existing: ID?
    @State private var metaPreset: ID?
    @State private var adjPreset = ""
    @State private var keywords = ""
    @State private var presetName = ""
    @State private var backupOn = false
    @State private var splitOn = false
    @State private var splitHours = 4.0
    @State private var ratingOn = false
    @State private var minRating = 1
    @State private var scriptTrusted = false
    @State private var cameraStatus = ""

    var checked: [ImportItem] { items.filter(\.checked) }
    var projects: [Container] { model.store.containers.values.filter { $0.kind == .project }.sorted { $0.name < $1.name } }
    var cards: [URL] { ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []).filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DCIM").path) } }

    func load(_ urls: [URL]) {
        items = Importer.expand(urls).compactMap { u in Importer.mediaKind(u).map { ImportItem(url: u, kind: $0.kind, raw: $0.raw) } }
        selected = items.first
    }
    func choose(dirs: Bool) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true; p.canChooseFiles = !dirs
        p.message = model.L("Choose photos, videos, audio files or folders", "Fotos, Videos, Audiodateien oder Ordner wählen")
        if p.runModal() == .OK { load(p.urls) }
    }
    func build() -> ImportOptions {
        var o = opts
        if newProject { o.newProjectName = projectName.isEmpty ? nil : projectName } else { o.projectID = existing }
        o.keywords = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let m = model.metaConfig.presets.first(where: { $0.id == metaPreset }) { o.metadata = m.fields }
        if let p = Presets.all.first(where: { $0.id == adjPreset }) { o.adjustments = p.make() } else if let u = model.userPresets.first(where: { $0.id == adjPreset }) { o.adjustments = u.set }
        if !backupOn { o.backupFolder = nil }
        o.splitGapHours = splitOn ? splitHours : nil
        o.minCameraRating = ratingOn ? minRating : nil
        if o.postScript != nil && !scriptTrusted { o.postScript = nil }
        let d = ImportOptions()
        if !tileVisible("rename") { o.namePolicy = d.namePolicy; o.customName = d.customName; o.counterStart = d.counterStart; o.renameFiles = d.renameFiles }
        if !tileVisible("metadata") { o.metadata = [:]; o.keywords = [] }
        if !tileVisible("adjust") { o.adjustments = nil }
        if !tileVisible("filter") { o.kinds = d.kinds; o.minCameraRating = nil }
        if !tileVisible("raw") { o.rawJPEG = d.rawJPEG }
        if !tileVisible("post") { o.postScript = nil }
        if !tileVisible("backup") { o.backupFolder = nil }
        return o
    }
    func start() {
        let o = build()
        if let s = o.postScript {
            let a = NSAlert(); a.alertStyle = .warning; a.messageText = model.L("Run this script after the import?", "Dieses Skript nach dem Import ausführen?")
            a.informativeText = s.path + "\n" + model.L("It will be executed with the imported file paths as arguments.", "Es wird mit den Pfaden der importierten Dateien als Argumente ausgeführt.")
            a.addButton(withTitle: model.L("Run Script", "Skript ausführen")); a.addButton(withTitle: model.L("Import Without Script", "Ohne Skript importieren"))
            if a.runModal() != .alertFirstButtonReturn { var o2 = o; o2.postScript = nil; model.showImportSheet = false; model.runImport(checked.map(\.url), o2); return }
        }
        model.showImportSheet = false; model.runImport(checked.map(\.url), o)
    }

    @State private var moreOpen = false
    /// Settings tiles the user switched off in "Import Settings" (as usual's tile menu); hidden tiles do not apply their settings.
    @AppStorage("importHiddenTiles") private var hiddenTilesRaw = ""
    static let tiles: [(id: String, en: String, de: String)] = [("rename", "Rename Files", "Dateien umbenennen"), ("metadata", "Apply Metadata", "Metadaten anwenden"), ("adjust", "Apply Adjustments", "Anpassungen anwenden"), ("filter", "Filter", "Filter"), ("raw", "RAW+JPEG Pairs", "RAW+JPEG-Paare"), ("post", "Post-Import", "Nach dem Import"), ("backup", "Back Up Files", "Dateien sichern")]
    var hiddenTiles: Set<String> { Set(hiddenTilesRaw.split(separator: ",").map(String.init)) }
    func tileVisible(_ id: String) -> Bool { !hiddenTiles.contains(id) }
    func toggleTile(_ id: String) { var h = hiddenTiles; if h.contains(id) { h.remove(id) } else { h.insert(id) }; hiddenTilesRaw = h.sorted().joined(separator: ",") }
    @State private var previewOpen = false
    @State private var thumbWidth = 126.0
    @State private var listMode = false

    var body: some View {
        HStack(spacing: 0) {
            sources.frame(width: 190)
            Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                grid
                gridFooter
                FolderColumns { url in load([url]) }.frame(height: 170)
            }.frame(minWidth: 380)
            Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
            options.frame(width: 330)
        }
        .padding(.top, 6)
        .frame(width: 1040, height: 680).background(Theme.chrome)
        .overlay { if previewOpen, let s = selected { ZStack { Color.black.opacity(0.85); PreviewPane(item: s).id(s.id).padding(20) }.onTapGesture { previewOpen = false }.overlay(alignment: .topTrailing) { Button(model.L("Close", "Schließen")) { previewOpen = false }.buttonStyle(AquaButtonStyle()).padding(12) } } }
        .onAppear { if !model.pendingImportURLs.isEmpty { load(model.pendingImportURLs) }; applyDefaults() }
        .onDisappear { camera.disconnect() }
    }
    var topBar: some View {
        AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
            HStack(spacing: 8) {
                Button(model.L("Check All", "Alle markieren")) { for i in items.indices { items[i].checked = true } }.buttonStyle(AquaButtonStyle())
                Button(model.L("Uncheck All", "Alle abwählen")) { for i in items.indices { items[i].checked = false } }.buttonStyle(AquaButtonStyle())
                Spacer()
                Menu(model.L("Import Settings", "Importeinstellungen")) {
                    ForEach(model.importPresetStore.presets) { p in Button(p.name) { opts = p.options; backupOn = p.options.backupFolder != nil; splitOn = p.options.splitGapHours != nil; splitHours = p.options.splitGapHours ?? 4; ratingOn = p.options.minCameraRating != nil; minRating = p.options.minCameraRating ?? 1; keywords = p.options.keywords.joined(separator: ", ") } }
                    if model.importPresetStore.presets.isEmpty { Text("—") }
                    Divider()
                    ForEach(Self.tiles, id: \.id) { t in Button((tileVisible(t.id) ? "✓ " : "    ") + model.L(t.en, t.de)) { toggleTile(t.id) } }
                    Divider()
                    Button(model.L("Save Current as Preset…", "Aktuelle als Voreinstellung sichern …")) { askPresetName() }
                    ForEach(model.importPresetStore.presets) { p in Button(model.L("Delete ", "Löschen ") + p.name) { model.importPresetStore.remove(p.id); model.configChanged() } }
                }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 10).frame(height: 32)
        }
    }
    var gridFooter: some View {
        AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
            HStack(spacing: 8) {
                Picker("", selection: $listMode) { Image(systemName: "square.grid.2x2").tag(false); Image(systemName: "list.bullet").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 70).controlSize(.mini)
                Spacer(); Text(model.L("\(items.count) items displayed", "\(items.count) Objekte angezeigt")).font(Theme.tiny); Spacer()
                Image(systemName: "photo").font(.system(size: 8)); Slider(value: $thumbWidth, in: 80...220).frame(width: 90).controlSize(.mini); Image(systemName: "photo").font(.system(size: 12))
            }.padding(.horizontal, 10).frame(height: 24)
        }
    }
    func applyDefaults() { opts.managed = UserDefaults.standard.object(forKey: "importManaged") as? Bool ?? true; opts.skipDuplicates = UserDefaults.standard.object(forKey: "importSkipDupes") as? Bool ?? true }

    var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.L("IMPORT", "IMPORT")).font(Theme.font(10, bold: true)).foregroundColor(Theme.hex(0x555555))
            Text(model.L("SOURCES", "QUELLEN")).font(Theme.font(9, bold: true)).foregroundColor(Theme.hex(0x777777))
            Button { choose(dirs: false) } label: { Label(model.L("Files and Folders…", "Dateien und Ordner …"), systemImage: "folder").font(Theme.small) }.buttonStyle(.plain)
            Button { model.showImportSheet = false; model.runPhotosImport() } label: { Label(model.L("Photos Library", "Fotos-Mediathek"), systemImage: "photo.on.rectangle").font(Theme.small) }.buttonStyle(.plain)
            Button { model.showImportSheet = false; model.chooseIPhotoLibrary() } label: { Label(model.L("iPhoto Library…", "iPhoto-Mediathek …"), systemImage: "camera").font(Theme.small) }.buttonStyle(.plain)
            Text(model.L("MEMORY CARDS", "SPEICHERKARTEN")).font(Theme.font(9, bold: true)).foregroundColor(Theme.hex(0x777777)).padding(.top, 8)
            ForEach(cards, id: \.self) { c in Button { load([c.appendingPathComponent("DCIM")]) } label: { Label(c.lastPathComponent, systemImage: "sdcard").font(Theme.small) }.buttonStyle(.plain) }
            if cards.isEmpty { Text(model.L("none found", "keine gefunden")).font(Theme.tiny).foregroundColor(.gray) }
            Text(model.L("CAMERAS", "KAMERAS")).font(Theme.font(9, bold: true)).foregroundColor(Theme.hex(0x777777)).padding(.top, 8)
            ForEach(Array(camera.cameras.enumerated()), id: \.offset) { _, cam in Button { camera.connect(cam) } label: { Label(cam.name ?? "Camera", systemImage: "camera.fill").font(Theme.small).foregroundColor(camera.connected === cam ? Theme.accent : .black) }.buttonStyle(.plain) }
            if camera.cameras.isEmpty { Text(model.L("no camera connected", "keine Kamera verbunden")).font(Theme.tiny).foregroundColor(.gray) }
            if camera.connected != nil {
                Text(camera.message).font(Theme.tiny).foregroundColor(.gray)
                if camera.ready { Button(model.L("Download \(camera.files.count) items", "\(camera.files.count) Objekte laden")) { downloadFromCamera() }.buttonStyle(AquaButtonStyle()) }
            }
            if !cameraStatus.isEmpty { Text(cameraStatus).font(Theme.tiny) }
            Spacer()
            Text(model.L("Tethered shooting: File ▸ Tether ▸ Start Session…", "Tethered Shooting: Ablage ▸ Tether ▸ Sitzung starten …")).font(Theme.font(9)).foregroundColor(.gray)
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxHeight: .infinity, alignment: .top).background(Theme.sourceList)
    }
    func downloadFromCamera() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rl-camera-\(getpid())")
        cameraStatus = model.L("Downloading…", "Lade …")
        camera.download(camera.files, to: dir, progress: { i, n in DispatchQueue.main.async { cameraStatus = "\(i)/\(n)" } }) { urls in cameraStatus = model.L("\(urls.count) files downloaded", "\(urls.count) Dateien geladen"); load(urls) }
    }

    var grid: some View {
        ScrollView {
            if listMode {
                LazyVStack(spacing: 0) { ForEach($items) { $it in
                    HStack(spacing: 8) { Toggle("", isOn: $it.checked).toggleStyle(.checkbox).labelsHidden(); Text(it.url.lastPathComponent).font(Theme.small); Spacer(); if it.raw { Text("RAW").font(Theme.font(9, bold: true)) } }
                        .foregroundColor(.white).padding(.horizontal, 10).padding(.vertical, 3).background(selected?.id == it.id ? Theme.accent.opacity(0.6) : Color.clear).contentShape(Rectangle())
                        .onTapGesture(count: 2) { selected = it; previewOpen = true }.onTapGesture { selected = it }
                } }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(thumbWidth) + 16, maximum: CGFloat(thumbWidth) + 16), spacing: 8)], spacing: 14) {
                    ForEach($items) { $it in
                        VStack(spacing: 3) {
                            ImportThumb(item: it).frame(width: CGFloat(thumbWidth), height: CGFloat(thumbWidth) * 0.75).overlay(Rectangle().stroke(selected?.id == it.id ? Color.white : Color.clear, lineWidth: 2))
                                .overlay(alignment: .bottomTrailing) { if it.raw { Text("RAW").font(Theme.font(8, bold: true)).padding(2).background(Color.black.opacity(0.6)).foregroundColor(.white) } }
                            HStack(spacing: 3) { Toggle("", isOn: $it.checked).toggleStyle(.checkbox).labelsHidden().controlSize(.small); Text(it.url.lastPathComponent).font(Theme.font(11, bold: true)).foregroundColor(.white).lineLimit(1) }.frame(width: CGFloat(thumbWidth))
                        }.onTapGesture(count: 2) { selected = it; previewOpen = true }.onTapGesture { selected = it }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 14)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.hex(0x686868))
        .overlay { if items.isEmpty { Text(model.L("Choose a source", "Quelle wählen")).foregroundColor(Color.white.opacity(0.7)).font(Theme.small) } }
    }

    func formRow<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View { HStack { Text(label).frame(width: 92, alignment: .trailing); c() } }
    var destinationBinding: Binding<String> { Binding(get: { newProject ? "new" : (existing ?? "new") }, set: { if $0 == "new" { newProject = true } else { newProject = false; existing = $0 } }) }
    var summary: String {
        let n = checked.count
        if newProject { return model.L("Import \(n) files into a new project named “\(projectName.isEmpty ? "Import" : projectName)”", "\(n) Dateien in ein neues Projekt „\(projectName.isEmpty ? "Import" : projectName)“ importieren") }
        return model.L("Import \(n) files into the project “\(model.store.containers[existing ?? ""]?.name ?? "—")”", "\(n) Dateien in das Projekt „\(model.store.containers[existing ?? ""]?.name ?? "—")“ importieren")
    }
    var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.L("Retrolux Library", "Retrolux-Bibliothek")).font(Theme.font(12, bold: true))
                    formRow(model.L("Destination:", "Ziel:")) { Picker("", selection: destinationBinding) { Text(model.L("New Project", "Neues Projekt")).tag("new"); Divider(); ForEach(projects) { Text($0.name).tag($0.id) } }.labelsHidden() }
                    formRow(model.L("Project Name:", "Projektname:")) { TextField("", text: $projectName).textFieldStyle(.roundedBorder).disabled(!newProject) }
                    HStack { Spacer().frame(width: 100); VStack(alignment: .leading, spacing: 4) {
                        Toggle(model.L("Automatically split projects", "Projekte automatisch teilen"), isOn: $splitOn).disabled(!newProject)
                        Toggle(model.L("Do not import duplicates", "Duplikate nicht importieren"), isOn: $opts.skipDuplicates) } }
                    formRow(model.L("Store Files:", "Dateien ablegen:")) { Picker("", selection: $opts.managed) { Text(model.L("In the Library", "In der Bibliothek")).tag(true); Text(model.L("In their current location", "Am bisherigen Ort")).tag(false) }.labelsHidden() }
                    if splitOn { Stepper(model.L("gap: \(Int(splitHours)) h", "Abstand: \(Int(splitHours)) Std."), value: $splitHours, in: 1...72).padding(.leading, 100) }
                    moreOptions
                }.padding(.horizontal, 14).padding(.vertical, 12)
            }
            Spacer(minLength: 0)
            Etched()
            VStack(alignment: .leading, spacing: 8) {
                Text(summary).font(Theme.small).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer()
                    Button(model.L("Cancel", "Abbrechen")) { model.showImportSheet = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(model.L("Import Checked", "Markierte importieren")) { start() }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction).disabled(checked.isEmpty || (!newProject && existing == nil)) }
            }.padding(.horizontal, 14).padding(.vertical, 12)
        }.font(Theme.small).background(Theme.inspector)
    }
    func sectionTitle(_ en: String, _ de: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Etched(); Text(model.L(en, de)).font(Theme.font(12, bold: true)) }.padding(.top, 4)
    }
    /// Tiles in this order : Project Destination, Rename Files, Apply Metadata,
    /// Apply Adjustments, Filter, RAW+JPEG Pairs, Post-Import, Back Up Files. (Adjust Time Zone is not offered.)
    var moreOptions: some View {
        VStack(alignment: .leading, spacing: 9) {
            if opts.managed { formRow(model.L("Subfolder:", "Unterordner:")) { Picker("", selection: $opts.folderPolicy) { ForEach(FolderPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden() } }
            if tileVisible("rename") {
            sectionTitle("Rename Files", "Dateien umbenennen")
            formRow(model.L("Version Name:", "Versionsname:")) { Picker("", selection: $opts.namePolicy) { ForEach(ImportNamePolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden() }
            if [.customIndex, .customIndexNoSpaces, .customCounter].contains(opts.namePolicy) { formRow(model.L("Name Text:", "Nametext:")) { TextField("", text: $opts.customName).textFieldStyle(.roundedBorder) } }
            if [.versionNameSequence, .customCounter].contains(opts.namePolicy) { Stepper(model.L("counter starts at \(opts.counterStart)", "Zähler beginnt bei \(opts.counterStart)"), value: $opts.counterStart, in: 0...99999).padding(.leading, 100) }
            if opts.managed { Toggle(model.L("Rename Master File", "Master-Datei umbenennen"), isOn: $opts.renameFiles).padding(.leading, 100) }
            }
            if tileVisible("metadata") {
            sectionTitle("Apply Metadata", "Metadaten anwenden")
            formRow(model.L("Metadata:", "Metadaten:")) { Picker("", selection: $metaPreset) { Text(model.L("None", "Keine")).tag(ID?.none); ForEach(model.metaConfig.presets) { Text($0.name).tag(ID?.some($0.id)) } }.labelsHidden() }
            formRow(model.L("Keywords:", "Schlagwörter:")) { TextField("", text: $keywords).textFieldStyle(.roundedBorder) }
            }
            if tileVisible("adjust") {
            sectionTitle("Apply Adjustments", "Anpassungen anwenden")
            formRow(model.L("Preset:", "Voreinstellung:")) { Picker("", selection: $adjPreset) { Text(model.L("None", "Keine")).tag(""); ForEach(Presets.all) { Text($0.folder + " ▸ " + $0.name).tag($0.id) }; ForEach(model.userPresets) { Text("★ " + $0.name).tag($0.id) } }.labelsHidden() }
            }
            if tileVisible("filter") {
            sectionTitle("Filter", "Filter")
            HStack { Spacer().frame(width: 100); ForEach([(MediaKind.image, "photo"), (.video, "film"), (.audio, "waveform")], id: \.0) { k in Toggle(isOn: Binding(get: { opts.kinds.contains(k.0) }, set: { if $0 { opts.kinds.insert(k.0) } else { opts.kinds.remove(k.0) } })) { Image(systemName: k.1) }.toggleStyle(.checkbox) } }
            Toggle(model.L("Only photos the camera rated ≥", "Nur Fotos, die die Kamera ≥ bewertet hat"), isOn: $ratingOn).padding(.leading, 100); if ratingOn { Stepper("★ \(minRating)", value: $minRating, in: 1...5).padding(.leading, 100) }
            }
            if tileVisible("raw") {
            sectionTitle("RAW+JPEG Pairs", "RAW+JPEG-Paare")
            formRow(model.L("Import:", "Importieren:")) { Picker("", selection: $opts.rawJPEG) {
                Text(model.L("Both (JPEG as Master)", "Beide (JPEG als Master)")).tag(RawJPEGMode.bothJPEGMaster); Text(model.L("Both (RAW as Master)", "Beide (RAW als Master)")).tag(RawJPEGMode.bothRAWMaster)
                Text(model.L("Both (Separate Masters)", "Beide (getrennte Master)")).tag(RawJPEGMode.both); Text(model.L("JPEG files only", "Nur JPEG-Dateien")).tag(RawJPEGMode.jpegOnly); Text(model.L("RAW files only", "Nur RAW-Dateien")).tag(RawJPEGMode.rawOnly)
                Divider(); Text(model.L("Matching RAW files", "Passende RAW-Dateien")).tag(RawJPEGMode.matchingRAWOnly) }.labelsHidden() }
            }
            if tileVisible("post") {
            sectionTitle("Post-Import", "Nach dem Import")
            formRow(model.L("Script:", "Skript:")) { Text(opts.postScript?.lastPathComponent ?? "").font(Theme.tiny).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Spacer().frame(width: 100)
                Button(model.L("Choose…", "Wählen …")) { let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; if p.runModal() == .OK { opts.postScript = p.url; scriptTrusted = true } }.buttonStyle(AquaButtonStyle())
                Button(model.L("Clear", "Löschen")) { opts.postScript = nil }.buttonStyle(AquaButtonStyle()).disabled(opts.postScript == nil) }
            }
            if tileVisible("backup") {
            sectionTitle("Back Up Files", "Dateien sichern")
            formRow(model.L("Backup To:", "Sichern nach:")) {
                Picker("", selection: Binding(get: { !backupOn ? 0 : (opts.backupFolder == FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ? 1 : 2) }, set: { c in
                    if c == 0 { backupOn = false }
                    else if c == 1 { backupOn = true; opts.backupFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }
                    else { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; if p.runModal() == .OK, let u = p.url { backupOn = true; opts.backupFolder = u } } })) {
                    Text(model.L("None", "Keiner")).tag(0); Text(model.L("Documents", "Dokumente")).tag(1); Text(model.L("Choose…", "Wählen …")).tag(2) }.labelsHidden() }
            if backupOn, let f = opts.backupFolder { Text(f.path).font(Theme.tiny).foregroundColor(.gray).lineLimit(1).truncationMode(.middle).padding(.leading, 100) }
            }
        }
    }
    func askPresetName() {
        let a = NSAlert(); a.messageText = model.L("Preset name", "Name der Voreinstellung"); let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); a.accessoryView = tf
        a.addButton(withTitle: model.L("Save", "Sichern")); a.addButton(withTitle: model.L("Cancel", "Abbrechen"))
        if a.runModal() == .alertFirstButtonReturn, !tf.stringValue.isEmpty { var o = build(); o.projectID = nil; o.newProjectName = nil; o.postScript = opts.postScript; model.importPresetStore.save(ImportPreset(name: tf.stringValue, options: o)); model.configChanged() }
    }
}

struct ImportThumb: View {
    let item: ImportItem
    @State private var img: NSImage?
    var body: some View {
        ZStack { Rectangle().fill(Color.black.opacity(0.25))
            if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) } else if item.kind == .audio { Image(systemName: "waveform").foregroundColor(.white) } else { ProgressView().controlSize(.mini) } }
        .task(id: item.id) { img = await ImportThumb.load(item, px: 200) }
    }
    static func load(_ item: ImportItem, px: Int) async -> NSImage? {
        await Task.detached(priority: .utility) {
            var cg: CGImage?
            if item.kind == .video { cg = MediaProbe.poster(item.url, maxPixel: px) }
            else if item.kind == .image, let src = CGImageSourceCreateWithURL(item.url as CFURL, nil) { cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: px] as CFDictionary) }
            return cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }.value
    }
}

/// Enlarged preview with metadata; plays video and audio before they are imported.
struct PreviewPane: View {
    let item: ImportItem
    @State private var img: NSImage?
    @State private var player: AVPlayer?
    @State private var info = ""
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if item.kind == .image { if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) } else { ProgressView() } }
            else if let p = player { PlayerSurface(player: p) }
            Text(info).font(Theme.tiny).foregroundColor(.white).padding(4).background(Color.black.opacity(0.6)).cornerRadius(3).padding(6)
        }
        .task(id: item.id) {
            if item.kind == .image { img = await ImportThumb.load(item, px: 900) }
            else { player = AVPlayer(url: item.url); if item.kind == .audio { player?.play() } }
            var parts = [item.url.lastPathComponent]
            let ex = ExifReader.values(for: item.url, master: nil, isMissing: false, version: nil)
            if let c = ex["exif.camera"] { parts.append(c) }; if let a = ex["exif.aperture"] { parts.append(a) }; if let s = ex["exif.shutter"] { parts.append(s) }; if let i = ex["exif.iso"] { parts.append("ISO " + i) }
            if let sz = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) { parts.append(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file)) }
            info = parts.joined(separator: " · ")
        }
        .onDisappear { player?.pause() }
    }
}

/// Finder-style column browser for choosing the folder to import from (computer, volumes, home folders).
struct FolderColumns: View {
    var onSelect: (URL) -> Void
    struct Node: Identifiable, Hashable { let url: URL; let name: String; var id: String { url.path } }
    @State private var chosen: [Node] = []     // selected node per column
    static func node(_ u: URL, _ n: String? = nil) -> Node { Node(url: u, name: n ?? FileManager.default.displayName(atPath: u.path)) }
    func children(of col: Int) -> [Node] {
        let fm = FileManager.default
        if col == 0 {
            let home = fm.homeDirectoryForCurrentUser
            let vols = ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent != "Macintosh HD" }.map { Self.node($0) }
            let homes = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }.map { Self.node($0) }
            return [Self.node(URL(fileURLWithPath: "/"), "Macintosh HD")] + vols + [Self.node(home, NSUserName())] + homes
        }
        guard col - 1 < chosen.count else { return [] }
        let urls = (try? fm.contentsOfDirectory(at: chosen[col - 1].url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map { Self.node($0) }
    }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(0...chosen.count, id: \.self) { col in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(children(of: col)) { n in
                                let sel = col < chosen.count && chosen[col] == n
                                HStack { Text(n.name).font(Theme.small).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.system(size: 8)).opacity(0.6) }
                                    .foregroundColor(sel ? .white : .black).padding(.horizontal, 8).frame(height: 18).background(sel ? Theme.sourceSelected : Color.clear).contentShape(Rectangle())
                                    .onTapGesture { chosen = Array(chosen.prefix(col)) + [n]; onSelect(n.url) }
                            }
                        }
                    }.frame(width: 170).background(col % 2 == 0 ? Theme.hex(0xF4F4F4) : Theme.hex(0xFAFAFA))
                    Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
                }
            }
        }.background(Theme.hex(0xF4F4F4))
    }
}
