import SwiftUI
import AppKit
import RetroluxCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var fsTop = ProcessInfo.processInfo.environment["RL_FS_REVEAL"] != nil      // snapshot aid
    @State private var fsBottom = ProcessInfo.processInfo.environment["RL_FS_REVEAL"] != nil
    @State private var fsTopSticky = false
    @State private var fsBottomSticky = false
    var mainColumn: some View {
        if model.facesView { return AnyView(FacesView(model: model)) }
        return AnyView(mainColumnBody)
    }
    @ViewBuilder func editor(_ c: Container) -> some View {
        switch c.kind {
        case .lightTable: LightTableView(model: model, container: c)
        case .slideshow: SlideshowEditor(model: model, container: c)
        case .book: BookEditor(model: model, container: c)
        default: WebEditor(model: model, container: c)
        }
    }
    var mainColumnBody: some View {
        VStack(spacing: 0) {
            if model.placesView && !model.fullScreenViewer { PlacesView(model: model).frame(minHeight: 260); Rectangle().fill(Color.black).frame(height: 1) }
            else if let c = model.editorContainer, !model.fullScreenViewer { editor(c).frame(minHeight: model.viewMode == .viewer ? 400 : 330); Rectangle().fill(Color.black).frame(height: 1) }
            if model.browserFirst && model.viewMode == .split && !model.fullScreenViewer { BrowserPane(model: model); Rectangle().fill(Color.black).frame(height: 1) }
            if (model.viewMode != .browser || model.fullScreenViewer) && !model.placesView && model.editorContainer == nil { ViewerPane(model: model) }
            if model.viewMode == .split && !model.fullScreenViewer && !model.browserFirst && !model.placesView && model.editorContainer == nil { Rectangle().fill(Color.black).frame(height: 1) }
            if model.viewMode != .viewer && !model.fullScreenViewer && !(model.browserFirst && model.viewMode == .split) { BrowserPane(model: model) }
            if model.keywordControls && !model.fullScreenViewer { KeywordControlBar(model: model) }
            if model.fullScreenViewer { FullScreenFilmstrip(model: model) }
        }
        .background(model.wellColor(viewer: true))
    }
    /// Full Screen: black full-bleed viewer; toolbar slides in at the top edge, filmstrip at the bottom edge (pointer-revealed).
    var fullScreenBody: some View {
        ViewerPane(model: model).background(Color.black)
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    Color.clear.frame(height: 24).contentShape(Rectangle()).onHover { fsTop = $0 }
                    if fsTop || fsTopSticky { FullScreenToolbar(model: model).padding(.top, 6).onHover { fsTopSticky = $0 }.transition(.opacity) }
                }.frame(maxWidth: .infinity, alignment: .top)
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    Color.clear.frame(height: 24).contentShape(Rectangle()).onHover { fsBottom = $0 }
                    if fsBottom || fsBottomSticky { FullScreenFilmstrip(model: model).onHover { fsBottomSticky = $0 }.transition(.opacity) }
                }.frame(maxWidth: .infinity, alignment: .bottom)
            }
            .animation(.easeInOut(duration: 0.15), value: fsTop || fsTopSticky)
            .animation(.easeInOut(duration: 0.15), value: fsBottom || fsBottomSticky)
            .overlay(alignment: .topTrailing) { HUDLayer(model: model).padding(.top, 48) }
    }
    var content: some View {
        if model.fullScreenViewer { return AnyView(fullScreenBody) }
        return AnyView(normalContent)
    }
    var normalContent: some View {
        VStack(spacing: 0) {
            if model.showToolbar && !model.fullScreenViewer { ToolbarView(model: model) }
            else { Color.clear.frame(height: 28) }
            HStack(spacing: 0) {
                if model.showInspector && !model.fullScreenViewer && !model.inspectorRight {
                    InspectorView(model: model).frame(width: 244)
                    Rectangle().fill(Theme.hex(0x5E5E5E)).frame(width: 1)
                }
                mainColumn
                if model.showInspector && !model.fullScreenViewer && model.inspectorRight {
                    Rectangle().fill(Theme.hex(0x5E5E5E)).frame(width: 1)
                    InspectorView(model: model).frame(width: 244)
                }
            }
            StatusBar(model: model)
        }
        .overlay(alignment: .topTrailing) { HUDLayer(model: model).padding(.top, 48) }
    }
    var body: some View {
        content
        .background(Theme.chrome)
        .sheet(isPresented: $model.showImportSheet) { ImportSheet(model: model) }
        .sheet(isPresented: $model.showExportSheet) { ExportSheet(model: model) }
        .sheet(isPresented: $model.showActivitySheet) { ActivitySheet(model: model) }
        .sheet(isPresented: $model.showCustomizeToolbar) { CustomizeToolbarSheet(model: model) }
        .sheet(isPresented: $model.showExportPresetEditor) { ExportPresetEditor(model: model) }
        .sheet(isPresented: $model.showSavePreset) { SavePresetSheet(model: model) }
        .sheet(isPresented: $model.showProjectInfo) { ProjectInfoSheet(model: model) }
        .sheet(isPresented: $model.showBatchChange) { BatchChangeSheet(model: model) }
        .sheet(isPresented: $model.showAdjustDate) { AdjustDateSheet(model: model) }
        .sheet(isPresented: $model.showKeywordManager) { KeywordManagerSheet(model: model) }
        .sheet(isPresented: $model.showMetaViewEditor) { MetaViewEditorSheet(model: model) }
        .sheet(isPresented: $model.showMetaPresetEditor) { MetaPresetEditorSheet(model: model) }
        .sheet(isPresented: $model.showAutofillEditor) { AutofillEditorSheet(model: model) }
        .sheet(isPresented: $model.showTether) { TetherSheet(model: model) }
        .sheet(isPresented: $model.showServices) { ServicesSheet(model: model) }
        .sheet(isPresented: $model.showPrint) { PrintSheet(model: model) }
        .sheet(isPresented: $model.showAssignLocation) { AssignLocationSheet(model: model) }
        .sheet(isPresented: $model.showGPX) { GPXSheet(model: model) }
        .sheet(isPresented: $model.showMyPlaces) { MyPlacesSheet(model: model) }
        .sheet(item: Binding(get: { model.namingFace.map { Report(text: $0) } }, set: { if $0 == nil { model.namingFace = nil } })) { r in FaceNameSheet(model: model, faceID: r.text) }
        .sheet(isPresented: $model.showAutoStack) { AutoStackSheet(model: model) }
        .sheet(isPresented: $model.showVaults) { VaultsSheet(model: model) }
        .sheet(isPresented: $model.showFirstAid) { FirstAidSheet(model: model) }
        .sheet(isPresented: $model.showMergeProjects) { MergeProjectsSheet(model: model) }
        .sheet(item: Binding(get: { model.showMigrationReport.map { Report(text: $0) } }, set: { if $0 == nil { model.showMigrationReport = nil } })) { r in
            ReportSheet(title: model.L("Legacy library import", "Import der Legacy-Bibliothek"), text: r.text) { model.showMigrationReport = nil }
        }
        .alert(model.alert?.0 ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) { Button("OK") { model.alert = nil } } message: { Text(model.alert?.1 ?? "") }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []; let g = DispatchGroup()
            for p in providers { g.enter(); _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; g.leave() } }
            g.notify(queue: .main) { if !urls.isEmpty { model.pendingImportURLs = urls; model.showImportSheet = true } }
            return true
        }
    }
}

struct Report: Identifiable { let id = UUID(); let text: String }

struct ReportSheet: View {
    var title: String, text: String, close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.title)
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(width: 520, height: 260).background(Color.white).overlay(Rectangle().stroke(Color.black.opacity(0.4)))
            HStack { Spacer(); Button("OK", action: close).buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).background(Theme.chrome)
    }
}

struct StatusBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        AquaBar(top: Theme.hex(0xD9D9D9), bottom: Theme.hex(0xC2C2C2)) {
            HStack(spacing: 8) {
                Text(model.status.isEmpty ? model.statusLine : model.status).font(Theme.tiny).foregroundColor(Theme.hex(0x333333)).lineLimit(1)
                Spacer()
                if model.viewMode != .viewer { Image(systemName: "photo").font(.system(size: 8)); Slider(value: $model.thumbSize, in: 70...320).frame(width: 90).controlSize(.mini); Image(systemName: "photo").font(.system(size: 12)) }
                if let p = model.progress { ProgressView(value: p).progressViewStyle(.linear).frame(width: 140).controlSize(.small); if model.activeImporter != nil { Button(model.L("Cancel", "Abbrechen")) { model.cancelImport() }.buttonStyle(.plain).font(Theme.tiny).foregroundColor(.red) } }
                if model.rendering { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14) }
            }.padding(.horizontal, 10).frame(height: 20)
        }
    }
}

struct ToolbarView: View {
    @ObservedObject var model: AppModel
    @ViewBuilder func item(_ symbol: String, _ en: String, _ de: String, color: Color = Theme.hex(0x333333), enabled: Bool = true, active: Bool = false, action: @escaping () -> Void) -> some View {
        if !model.toolbarHidden.contains(en) {
            Button(action: action) {
                VStack(spacing: 1) {
                    IconView(name: symbol, size: 30).opacity(enabled ? 1 : 0.4).frame(height: 34)
                    Text(model.L(en, de)).font(Theme.tiny)
                }.frame(minWidth: 54).foregroundColor(enabled ? Theme.hex(0x222222) : Theme.hex(0x777777)).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.vertical, 1).background(active ? Color.black.opacity(0.12) : Color.clear).cornerRadius(5)
            }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(model.L(en, de))
        }
    }
    func at<V: View>(_ W: CGFloat, _ x: CGFloat, right: Bool = false, @ViewBuilder _ v: () -> V) -> some View { v().frame(width: 62).position(x: right ? W - (1440 - x) : x, y: 27) }
    func sep(_ W: CGFloat, _ x: CGFloat, right: Bool = false) -> some View {
        Path { p in p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 0, y: 38)) }.stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [1, 2])).frame(width: 1, height: 38).position(x: right ? W - (1440 - x) : x, y: 27)
    }
    var body: some View {
        AquaBar {
            GeometryReader { g in
                // Item centres measured from the reference screenshot (1440 px wide): left group from the left edge, right group from the right edge.
                let W = g.size.width
                ZStack {
                    at(W, 38) { item("info.circle.fill", "Inspector", "Inspektor", color: .blue, active: model.showInspector) { model.showInspector.toggle() } }
                    at(W, 91) { item("arrow.down.circle.fill", "Import", "Importieren", color: Theme.hex(0x4A78B8)) { model.pendingImportURLs = []; model.showImportSheet = true } }
                    at(W, 133) {
                        Menu {
                            Button(model.L("Project", "Projekt")) { model.newProject() }; Button(model.L("Folder", "Ordner")) { model.newFolder() }; Button(model.L("Album", "Album")) { model.newAlbum() }; Button(model.L("Smart Album", "Intelligentes Album")) { model.newSmartAlbum() }
                            Divider(); Button(model.L("Book", "Buch")) { model.newBook() }; Button(model.L("Light Table", "Leuchttisch")) { model.newLightTable() }; Button(model.L("Slideshow", "Diashow")) { model.newSlideshow() }; Button(model.L("Web Journal", "Web-Journal")) { model.newWebJournal() }
                        } label: { VStack(spacing: 1) { IconView(name: "plus.rectangle.on.folder.fill", size: 30).frame(height: 34); Text(model.L("New", "Neu")).font(Theme.tiny).foregroundColor(Theme.hex(0x222222)) }.frame(minWidth: 54) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }
                    sep(W, 167)
                    at(W, 193) { item("person.text.rectangle", "Name", "Name", color: .gray, enabled: !model.selection.isEmpty) { model.inspectorTab = .metadata; model.showInspector = true } }
                    at(W, 246) { item("tag.fill", "Keywords", "Schlagwörter", color: Theme.hex(0xE0B030), enabled: !model.selection.isEmpty) { model.toggleHUD(.keyword) } }
                    sep(W, 284)
                    at(W, 311) { item("envelope.fill", "Email", "E-Mail", color: Theme.hex(0x4A78B8), enabled: !model.selection.isEmpty) { model.shareByEmail() } }
                    at(W, 363) { item("cloud.fill", "iCloud", "iCloud", color: Theme.hex(0x7FB2E5), enabled: !model.selection.isEmpty) { model.shareICloud() } }
                    at(W, 426) { item("share.tile", "Share", "Teilen", color: Theme.hex(0x3B5998), enabled: !model.selection.isEmpty) { model.shareSelection() } }
                    at(W, 477) { item("circle.grid.2x1.fill", "Flickr", "Flickr", color: Theme.hex(0xE0368B)) { model.showServices = true } }
                    at(W, 540) { item("square.and.arrow.up", "Export", "Exportieren", color: Theme.hex(0x4A78B8), enabled: !model.selection.isEmpty) { model.showExportSheet = true } }
                    at(W, 1074, right: true) { item("square.grid.3x2.fill", "Browser", "Browser", color: Theme.hex(0x4A78B8), active: model.viewMode == .browser && !model.facesView && !model.placesView) { model.facesView = false; model.placesView = false; model.viewMode = .browser } }
                    at(W, 1132, right: true) { item("rectangle.split.1x2.fill", "Split View", "Geteilt", color: Theme.hex(0x4A78B8), active: model.viewMode == .split && !model.facesView && !model.placesView) { model.facesView = false; model.placesView = false; model.viewMode = .split } }
                    at(W, 1186, right: true) { item("photo.fill", "Viewer", "Viewer", color: Theme.hex(0x4A78B8), active: model.viewMode == .viewer && !model.facesView && !model.placesView) { model.facesView = false; model.placesView = false; model.viewMode = .viewer } }
                    sep(W, 1217, right: true)
                    at(W, 1243, right: true) { item("person.crop.square.fill", "Faces", "Gesichter", color: Theme.hex(0x6A4C93), active: model.facesView) { model.placesView = false; model.facesView.toggle() } }
                    at(W, 1287, right: true) { item("map.fill", "Places", "Orte", color: Theme.hex(0x3E9B4F), active: model.placesView) { model.facesView = false; model.placesView.toggle(); if model.placesView { model.browserMode = .filmstrip } } }
                    sep(W, 1316, right: true)
                    at(W, 1343, right: true) { item("magnifyingglass.circle.fill", "Loupe", "Lupe", color: .black, active: model.loupe) { model.loupe.toggle() } }
                    at(W, 1402, right: true) { item("arrow.up.left.and.arrow.down.right", "Full Screen", "Vollbild", color: .gray, active: model.fullScreenViewer) { model.fullScreenViewer.toggle() } }
                }
            }.padding(.top, 3).frame(height: 58)
            .overlay(alignment: .top) { Text("Retrolux").font(Theme.font(13)).foregroundColor(Theme.hex(0x333333)).shadow(color: .white.opacity(0.7), radius: 0, y: 1).padding(.top, 5).offset(y: -27).allowsHitTesting(false) }
        }
    }
}

struct ViewerPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.viewerLayout == .one, let k = model.primaryMaster?.kind, k != .image { MediaViewer(model: model) }
                else if model.viewerLayout == .one { ViewerCanvas(model: model) } else { model.wellColor(viewer: true); MultiViewer(model: model) }
                if model.namingMode { VStack { Spacer(); HStack(spacing: 14) {
                    Text(model.L("Name faces by typing in a face label.", "Gesichter benennen: Namen in die Beschriftung tippen.")).font(Theme.font(11)).foregroundColor(.white)
                    Button(model.addFaceMode ? model.L("Drag a box…", "Rahmen aufziehen …") : model.L("Add Missing Face", "Fehlendes Gesicht hinzufügen")) { model.addFaceMode.toggle() }.buttonStyle(AquaButtonStyle())
                    Button(model.L("Done", "Fertig")) { model.namingMode = false; model.addFaceMode = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(Color.black.opacity(0.78)).cornerRadius(10).padding(.bottom, 16) } }
                if model.primaryVersion == nil { Text(model.L("No Image Selected", "Kein Bild ausgewählt")).font(Theme.body).foregroundColor(Theme.wellTextDim) }
                else if model.viewerLayout == .one, model.viewerImage == nil && !model.rendering { Text(model.primaryMaster.map { model.store.isMissing($0) ? model.L("Original is offline", "Original ist offline") : ($0.kind == .image ? model.L("Preview unavailable", "Vorschau nicht verfügbar") : "") } ?? "").font(Theme.body).foregroundColor(Theme.wellTextDim) }
                VStack { HStack(spacing: 6) {
                    if model.showMaster { badge(model.L("Master", "Original")) }
                    if model.quickPreview { badge(model.L("Quick Preview", "Schnellvorschau")) }
                    if model.hotCold { badge(model.L("Hot & Cold Areas", "Lichter & Tiefen")) }
                    if model.showMask { badge(model.L("Brush Mask", "Pinselmaske")) }
                    if model.proofOn { badge(model.L("Proof: ", "Proof: ") + model.proofProfile + (model.gamutWarning ? " ⚠" : "")) }
                    if let v = model.primaryVersion, v.meta["render.fallback"] != nil { badge(model.L("Rendered version – recipe not editable", "Gerenderte Fassung – Rezept nicht editierbar")) }
                    if model.adjustments.needsEngineUpdate { badge(model.L("Older engine", "Älterer Rechenkern")) }
                    Spacer() }; Spacer()
                    if model.viewerMeta, let v = model.primaryVersion { HStack { VStack(alignment: .leading, spacing: 1) { Text(v.name).font(Theme.font(12, bold: true)); HStack { StarsView(rating: v.rating); Text(v.imageDate.formatted(date: .abbreviated, time: .shortened)).font(Theme.tiny) }; if !v.caption.isEmpty { Text(v.caption).font(Theme.tiny) } }.foregroundColor(.white).padding(6).background(Color.black.opacity(0.55)).cornerRadius(4); Spacer() } }
                }.padding(8).allowsHitTesting(false)
            }
            .background(model.wellColor(viewer: true))
            if model.showToolStrip && !model.fullScreenViewer { ToolStrip(model: model) }
        }
    }
    func badge(_ t: String) -> some View { Text(t).font(Theme.tiny).foregroundColor(.white).padding(4).background(Color.black.opacity(0.6)).cornerRadius(3) }
}

struct ToolStrip: View {
    @ObservedObject var model: AppModel
    func layoutName(_ l: ViewerLayout) -> String { switch l { case .one: return model.L("Show One", "Eines zeigen"); case .multiple: return model.L("Show Multiple", "Mehrere zeigen"); case .threeUp: return model.L("Three Up", "Drei nebeneinander"); case .compare: return model.L("Compare", "Vergleichen"); case .stack: return model.L("Stack", "Stapel") } }
    func toolBtn(_ symbol: String, _ t: ViewerTool, help: String) -> some View {
        Button { model.tool = (model.tool == t && t != .select) ? .select : t } label: {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 20)
                .background(model.tool == t ? Theme.hex(0x9DB7DC) : Color.clear).cornerRadius(3)
        }.buttonStyle(.plain).help(help)
    }
    var body: some View {
        AquaBar(top: Theme.hex(0xDADADA), bottom: Theme.hex(0xB4B4B4)) {
            HStack(spacing: 2) {
                toolBtn("cursorarrow", .select, help: model.L("Select", "Auswahl"))
                toolBtn("crop", .crop, help: model.L("Crop", "Zuschneiden"))
                toolBtn("eye", .redEye, help: model.L("Red Eye", "Rote Augen"))
                toolBtn("bandage", .spotPatch, help: model.L("Spot & Patch", "Fleck & Flicken"))
                toolBtn("wand.and.stars", .retouch, help: model.L("Retouch (⌥-click sets source)", "Retusche (⌥-Klick: Quelle)"))
                toolBtn("eyedropper", .wbPicker, help: model.L("White Balance Picker", "Weißabgleich-Pipette"))
                Menu {
                    ForEach(Catalog.brushes, id: \.id) { b in Button(model.lang == "de" ? b.de : b.en) { model.brushOp = b.id; model.tool = .brush(b.id) } }
                } label: { Image(systemName: "paintbrush").font(.system(size: 12)); }
                    .menuStyle(.borderlessButton).frame(width: 40).help(model.L("Quick Brushes", "Quick-Brush-Pinsel"))
                if case .brush(let op) = model.tool { Text(Catalog.brushSpec(op).map { model.lang == "de" ? $0.de : $0.en } ?? "").font(Theme.tiny) }
                if model.tool != .select && model.tool != .crop {
                    Text(model.L("Size", "Größe")).font(Theme.tiny); Slider(value: $model.brushRadius, in: 5...300).frame(width: 90).controlSize(.mini)
                    Text(model.L("Softness", "Weichheit")).font(Theme.tiny); Slider(value: $model.brushSoftness, in: 0...1).frame(width: 70).controlSize(.mini)
                    if case .brush = model.tool {
                        Picker("", selection: $model.brushTonal) { Text(model.L("All tones", "Alle Töne")).tag(0); Text(model.L("Shadows", "Tiefen")).tag(1); Text(model.L("Midtones", "Mitten")).tag(2); Text(model.L("Highlights", "Lichter")).tag(3) }.labelsHidden().frame(width: 100).controlSize(.mini)
                        Toggle(model.L("Edges", "Kanten"), isOn: $model.brushEdge).toggleStyle(.checkbox).controlSize(.mini).font(Theme.tiny)
                    }
                    Button(model.L("Clear", "Löschen")) { model.clearStrokes() }.buttonStyle(AquaButtonStyle())
                }
                if model.tool == .crop {
                    Menu(model.L("Aspect", "Format")) {
                        Button(model.L("Original", "Original")) { model.applyAspect(nil) }
                        Button("1:1") { model.applyAspect(1) }; Button("4:3") { model.applyAspect(4.0 / 3) }; Button("3:2") { model.applyAspect(1.5) }
                        Button("16:9") { model.applyAspect(16.0 / 9) }; Button("5:4") { model.applyAspect(1.25) }; Button("7:5") { model.applyAspect(1.4) }
                        Button("2:3") { model.applyAspect(2.0 / 3) }; Button("3:4") { model.applyAspect(0.75) }
                    }.menuStyle(.borderlessButton).frame(width: 70)
                }
                if model.namingMode { Button(model.addFaceMode ? model.L("Drag a box…", "Rahmen aufziehen …") : model.L("Add Face", "Gesicht hinzufügen")) { model.addFaceMode.toggle() }.buttonStyle(AquaButtonStyle()); Button(model.L("Done Naming", "Fertig")) { model.namingMode = false; model.addFaceMode = false }.buttonStyle(AquaButtonStyle()) }
                Spacer()
                Button { model.loupe.toggle() } label: { Image(systemName: "magnifyingglass").font(.system(size: 12)).frame(width: 24).background(model.loupe ? Theme.hex(0x9DB7DC) : Color.clear).cornerRadius(3) }.buttonStyle(.plain).help(model.L("Loupe (`)", "Lupe (`)"))
                Button { model.hotCold.toggle(); model.scheduleRender() } label: { Image(systemName: "sun.max.trianglebadge.exclamationmark").font(.system(size: 12)).frame(width: 24).background(model.hotCold ? Theme.hex(0x9DB7DC) : Color.clear).cornerRadius(3) }.buttonStyle(.plain).help(model.L("Hot & Cold Areas", "Lichter & Tiefen anzeigen"))
                Button { model.showMask.toggle(); model.scheduleRender() } label: { Image(systemName: "paintbrush.pointed").font(.system(size: 12)).frame(width: 24).background(model.showMask ? Theme.hex(0x9DB7DC) : Color.clear).cornerRadius(3) }.buttonStyle(.plain).help(model.L("Show Brush Mask", "Pinselmaske anzeigen"))
                Menu { ForEach([ViewerLayout.one, .multiple, .threeUp, .compare, .stack], id: \.self) { l in Button(layoutName(l)) { model.viewerLayout = l } } } label: { Image(systemName: "rectangle.split.3x1").font(.system(size: 12)) }.menuStyle(.borderlessButton).frame(width: 36)
                Button { model.zoomActual.toggle(); model.scheduleRender() } label: { Text(model.zoomActual ? "1:1" : "Fit").font(Theme.tiny).frame(width: 28) }.buttonStyle(.plain)
                Button { model.showMaster.toggle(); model.scheduleRender() } label: { Image(systemName: "photo").font(.system(size: 12)).frame(width: 24).background(model.showMaster ? Theme.hex(0x9DB7DC) : Color.clear).cornerRadius(3) }.buttonStyle(.plain).help(model.L("Show Master Image", "Original anzeigen"))
            }.padding(.horizontal, 8).frame(height: 26)
        }
    }
}

/// Compact dark toolbar that appears at the top edge in Full Screen (icons only, as usual.
struct FullScreenToolbar: View {
    @ObservedObject var model: AppModel
    func btn(_ symbol: String, _ en: String, _ de: String, active: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { IconView(name: symbol, size: 24).frame(width: 34, height: 30).opacity(enabled ? 1 : 0.35).background(active ? Color.white.opacity(0.22) : Color.clear).cornerRadius(5) }
            .buttonStyle(.plain).disabled(!enabled).help(model.L(en, de)).accessibilityLabel(model.L(en, de))
    }
    var body: some View {
        HStack(spacing: 4) {
            btn("info.circle.fill", "Inspector HUD", "Inspektor-HUD", active: model.huds.contains(.inspector)) { model.toggleHUD(.inspector) }
            btn("tag.fill", "Keywords HUD", "Schlagwort-HUD", active: model.huds.contains(.keyword), enabled: !model.selection.isEmpty) { model.toggleHUD(.keyword) }
            btn("magnifyingglass.circle.fill", "Loupe", "Lupe", active: model.loupe) { model.loupe.toggle() }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 20).padding(.horizontal, 4)
            btn("square.and.arrow.up", "Export", "Exportieren", enabled: !model.selection.isEmpty) { model.showExportSheet = true }
            btn("arrow.up.left.and.arrow.down.right", "Exit Full Screen", "Vollbild beenden") { model.fullScreenViewer = false }
        }.padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.78)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.18)))
    }
}

struct FullScreenFilmstrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) { LazyHStack(spacing: 4) { ForEach(model.shown) { v in Cell(model: model, v: v).id(v.id).scaleEffect(0.6).frame(width: CGFloat(model.thumbSize) * 0.6) } }.padding(4) }
                .onChange(of: model.primary) { id in if let id { proxy.scrollTo(id) } }
        }.frame(height: 120).background(Color.black.opacity(0.7))
    }
}

struct ActivitySheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Activity", "Aktivität")).font(Theme.title)
            if let p = model.progress { ProgressView(value: p) }
            ScrollView { VStack(alignment: .leading, spacing: 2) { ForEach(Array(model.activity.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 11, design: .monospaced)) }
                if model.activity.isEmpty { Text(model.L("No background tasks.", "Keine Hintergrundaufgaben.")).font(Theme.small).foregroundColor(.gray) } }.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(width: 520, height: 240).background(Color.white).overlay(Rectangle().stroke(Color.black.opacity(0.4)))
            HStack { Spacer(); Button("OK") { model.showActivitySheet = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).background(Theme.chrome)
    }
}

struct CustomizeToolbarSheet: View {
    @ObservedObject var model: AppModel
    static let all = [("Inspector", "Inspektor"), ("Import", "Importieren"), ("Name", "Name"), ("Keywords", "Schlagwörter"), ("Email", "E-Mail"), ("iCloud", "iCloud"), ("Share", "Teilen"), ("Flickr", "Flickr"), ("Browser", "Browser"), ("Split View", "Geteilt"), ("Viewer", "Viewer"), ("Faces", "Gesichter"), ("Places", "Orte"), ("Loupe", "Lupe"), ("Full Screen", "Vollbild"), ("Export", "Exportieren")]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Customize Toolbar", "Symbolleiste anpassen")).font(Theme.title)
            ForEach(Self.all, id: \.0) { it in Toggle(model.L(it.0, it.1), isOn: Binding(get: { !model.toolbarHidden.contains(it.0) }, set: { _ in model.toggleToolbarItem(it.0) })).toggleStyle(.checkbox) }
            HStack { Spacer(); Button("OK") { model.showCustomizeToolbar = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 300).background(Theme.chrome)
    }
}

struct SavePresetSheet: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Save Adjustment Preset", "Voreinstellung sichern")).font(Theme.title)
            TextField(model.L("Preset name", "Name der Voreinstellung"), text: $name).textFieldStyle(.roundedBorder).frame(width: 280)
            HStack { Spacer(); Button(model.L("Cancel", "Abbrechen")) { model.showSavePreset = false }.buttonStyle(AquaButtonStyle())
                Button(model.L("Save", "Sichern")) { model.saveCurrentAsPreset(name); model.showSavePreset = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction).disabled(name.isEmpty) }
        }.padding(16).background(Theme.chrome)
    }
}

struct KeywordControlBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.store.allKeywords.prefix(30)), id: \.self) { k in
                        let on = !model.selection.isEmpty && model.selectedVersions.allSatisfy { $0.keywords.contains(k) }
                        Button { on ? model.removeKeyword(k) : model.addKeyword(k) } label: { Text(k.split(separator: "/").last.map(String.init) ?? k).font(Theme.tiny).padding(.horizontal, 8).padding(.vertical, 2).background(on ? Theme.accent : Color.white).foregroundColor(on ? .white : .black).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.4))) }.buttonStyle(.plain)
                    }
                    if model.store.allKeywords.isEmpty { Text(model.L("No keywords yet – add some in the Metadata tab", "Noch keine Schlagwörter – im Reiter „Metadaten“ hinzufügen")).font(Theme.tiny).foregroundColor(.gray) }
                }.padding(.horizontal, 8)
            }.frame(height: 26)
        }
    }
}
