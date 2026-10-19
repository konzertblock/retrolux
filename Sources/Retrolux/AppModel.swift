import SwiftUI
import AppKit
import Combine
import RetroluxCore

enum ViewMode: String { case browser, split, viewer }
enum BrowserMode: String { case grid, filmstrip, list }
enum InspectorTab: String, CaseIterable { case library = "Library", metadata = "Metadata", adjustments = "Adjustments" }
enum ViewerTool: Equatable { case select, crop, redEye, spotPatch, retouch, brush(String), wbPicker }
enum ViewerLayout: String { case one, multiple, threeUp, compare, stack }
enum HUDKind: String, CaseIterable { case inspector, keyword, liftStamp }
struct StampOptions { var ops: Set<String> = []; var rating = true, label = true, flag = true, keywords = true, caption = true, brushes = true }
struct GPSTrack: Identifiable { let id = UUID(); var name: String; var points: [TrackPoint]; var visible = true }
enum Source: Equatable { case all, trash, flagged, rejected, container(ID), person(ID), location([String]) }

final class AppModel: ObservableObject {
    let store: LibraryStore
    let engine = RenderEngine.shared
    // navigation
    @Published var source: Source = .all { didSet { reloadVersions(); if !shown.contains(where: { selection.contains($0.id) }) { selection = []; primary = shown.first?.id; if let p = primary { selection = [p] } } } }
    @Published var shown: [Version] = []
    @Published var selection: [ID] = []
    @Published var primary: ID? { didSet { if primary != oldValue { primaryChanged() } } }
    // view state
    @Published var viewMode: ViewMode = .split
    @Published var browserMode: BrowserMode = .grid
    @Published var inspectorTab: InspectorTab = .adjustments
    @Published var showInspector = true
    @Published var showToolStrip = true
    @Published var thumbSize: Double = 150
    @Published var sortKey: SortKey = .imageDate { didSet { reloadVersions() } }
    @Published var sortAscending = true { didSet { reloadVersions() } }
    @Published var searchText = "" { didSet { reloadVersions() } }
    @Published var minRating = -2 { didSet { reloadVersions() } }            // -2 = no filter
    @Published var filterLabel = -1 { didSet { reloadVersions() } }
    @Published var filterFlagged = false { didSet { reloadVersions() } }
    @Published var showMetaInBrowser = true
    @Published var showFilterHUD = false
    @Published var fullScreenViewer = false
    @Published var showMapLabels = true
    @Published var tool: ViewerTool = .select { didSet { if (tool == .crop) != (oldValue == .crop) { scheduleRender() } } }
    @Published var zoomActual = false
    @Published var showMaster = false
    @Published var hotCold = false
    @Published var compare: ID?
    // viewer layouts, loupe, HUDs
    @Published var viewerLayout: ViewerLayout = .one
    @Published var loupe = false { didSet { if loupe { renderLoupeSource() } else { loupeImage = nil } } }
    @Published var loupeZoom = 2.0
    @Published var loupeDiameter = 300.0
    @Published var loupeImage: CGImage?
    struct BrowserLoupeTarget: Equatable { var id: ID; var frac: CGPoint }
    @Published var bLoupe: BrowserLoupeTarget?
    @Published var bLoupeImg: NSImage?
    var bLoupeImgID: ID?
    @Published var huds: Set<HUDKind> = []
    @Published var quickPreview = false
    @Published var showMask = false
    @Published var brushTonal = 0
    @Published var brushEdge = false
    @Published var viewerBrightness = 0.5
    @Published var browserBrightness = 0.47
    @Published var showToolbar = true
    @Published var showActivitySheet = false
    @Published var showCustomizeToolbar = false
    @Published var showExportPresetEditor = false
    @Published var toolbarHidden: Set<String> = []
    @Published var labelNames: [String] = []
    @Published var stampOptions = StampOptions()
    @Published var userPresets: [UserPreset] = []
    @Published var showSavePreset = false
    @Published var viewerMeta = false
    @Published var imageTooltips = true
    @Published var primaryOnly = false
    @Published var browserFirst = false
    @Published var inspectorRight = false
    @Published var keywordControls = false
    @Published var secondaryMode = ""
    @Published var showProjectInfo = false
    @Published var metaViewName = "Photo Info" { didSet { UserDefaults.standard.set(metaViewName, forKey: "metaView") } }
    @Published var showBatchChange = false
    var activeImporter: Importer?
    let importPresetStore: ImportPresetStore
    @Published var showTether = false
    @Published var facesView = false
    @Published var proofOn = false
    @Published var proofProfile = "Generic CMYK (proof only)"
    @Published var gamutWarning = false
    @Published var useDisplayProfile = true
    @Published var showServices = false
    @Published var showPrint = false
    @Published var playSlideshow: ID?
    @Published var showSlideshowExport: ID?
    @Published var gpsTracks: [GPSTrack] = []
    @Published var movePins = false
    @Published var mapKind = 0            // 0 road, 1 satellite, 2 terrain (hybrid)
    @Published var placesSearch = ""
    @Published var slideBadges: [ID: String] = [:]     // duration badges shown on the filmstrip while a slideshow is open
    struct VisibleRegion: Equatable { var lat = 0.0, lon = 0.0, spanLat = 180.0, spanLon = 360.0, metersPerPoint = 0.0 }
    @Published var mapVisible = VisibleRegion()
    var mapPendingZoom: Double?
    @Published var placesView = false
    @Published var namingMode = false
    @Published var namingFace: ID?
    @Published var faceThreshold = 0.62
    @Published var facesAnalyzing = false
    @Published var facesPaused = false
    @Published var facesEnabled = true
    @Published var facesTick = 0
    @Published var showAssignLocation = false
    @Published var showGPX = false
    @Published var showMyPlaces = false
    @Published var addFaceMode = false
    let myPlaces: MyPlacesStore
    var mapRef: AnyObject?
    var tether: CameraManager?
    var tetherProject: ID?
    @Published var showIPhotoBrowser = false
    @Published var openStacks: Set<ID> = []
    @Published var showAutoStack = false
    @Published var showVaults = false
    @Published var showFirstAid = false
    @Published var showMergeProjects = false
    @Published var showMergeLibrary: URL? = nil
    var exportOriginalsRequested = false
    @Published var showAdjustDate = false
    @Published var showKeywordManager = false
    @Published var showMetaViewEditor = false
    @Published var showMetaPresetEditor = false
    @Published var showAutofillEditor = false
    @Published var configTick = 0
    // viewer output
    @Published var viewerImage: NSImage?
    @Published var viewerSize: CGSize = .zero
    @Published var histogram: [[Float]] = []
    @Published var rendering = false
    // adjustments of primary
    @Published var adjustments = AdjustmentSet()
    @Published var expanded: Set<String> = [Catalog.exposure, Catalog.wb, Catalog.enhance]
    @Published var brushOp = "dodge"
    @Published var brushRadius = 60.0
    @Published var brushSoftness = 0.5
    @Published var brushStrength = 1.0
    // activity
    @Published var status = "" { didSet { if !status.isEmpty { let t = status; DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in if self?.status == t { self?.status = "" } } } } }
    @Published var progress: Double? = nil
    @Published var activity: [String] = []
    @Published var thumbRevision: [ID: Int] = [:]
    @Published var lang: String = Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
    @Published var alert: (String, String)? = nil
    @Published var showImportSheet = false
    @Published var showExportSheet = false
    @Published var showMigrationReport: String? = nil
    @Published var pendingImportURLs: [URL] = []
    var viewerTargetPixel = 1800
    let userPresetStore: UserPresetStore
    let metaConfig: MetadataConfig
    let vaultManager: VaultManager
    var liftedSetPublic: AdjustmentSet? { liftedAdjustments }
    var liftedMetaPublic: Version? { liftedMeta }
    private var undoStack: [(String, () -> Void, () -> Void)] = [], redoStack: [(String, () -> Void, () -> Void)] = []
    var renderGen = 0
    let renderQ = DispatchQueue(label: "rl.render", qos: .userInteractive)
    var editSnapshot0: AdjustmentSet?
    var liftedAdjustments: AdjustmentSet?
    var liftedMeta: Version?
    var canStamp: Bool { (liftedAdjustments != nil || liftedMeta != nil) && !selection.isEmpty }
    private var cancellables = Set<AnyCancellable>()

    init(store: LibraryStore) {
        self.store = store
        userPresetStore = UserPresetStore(libraryRoot: store.root)
        metaConfig = MetadataConfig(libraryRoot: store.root)
        vaultManager = VaultManager(libraryRoot: store.root)
        importPresetStore = ImportPresetStore(libraryRoot: store.root)
        myPlaces = MyPlacesStore(libraryRoot: store.root)
        facesEnabled = UserDefaults.standard.object(forKey: "facesEnabled") as? Bool ?? true
        faceThreshold = UserDefaults.standard.object(forKey: "faceThreshold") as? Double ?? 0.62
        metaViewName = UserDefaults.standard.string(forKey: "metaView") ?? "Photo Info"
        userPresets = userPresetStore.presets
        let ud = UserDefaults.standard
        viewerBrightness = ud.object(forKey: "viewerBrightness") as? Double ?? 0.5; browserBrightness = ud.object(forKey: "browserBrightness") as? Double ?? 0.47
        labelNames = (ud.array(forKey: "labelNames") as? [String]) ?? []
        toolbarHidden = Set((ud.array(forKey: "toolbarHidden") as? [String]) ?? ["Export"])   // the original default toolbar has no Export button
        store.onChange = { [weak self] in DispatchQueue.main.async { self?.storeChanged() } }
        reloadVersions()
        primary = shown.first?.id; if let p = primary { selection = [p] }
    }

    func L(_ en: String, _ de: String) -> String { lang == "de" ? de : en }

    // MARK: browsing
    var title: String {
        switch source {
        case .all: return L("Photos", "Fotos"); case .trash: return L("Trash", "Papierkorb"); case .flagged: return L("Flagged", "Markiert"); case .rejected: return L("Rejected", "Abgelehnt")
        case .container(let id): return store.containers[id]?.name ?? ""
        case .person(let id): return store.people().first { $0.id == id }?.name ?? ""
        case .location(let path): return path.joined(separator: " ▸ ")
        }
    }
    func reloadVersions() {
        var vs: [Version]
        switch source {
        case .all: vs = store.versions(in: nil)
        case .trash: vs = store.versions(in: nil, includeTrashed: true)
        case .flagged: vs = store.versions(in: nil).filter(\.flagged)
        case .rejected: vs = store.versions(in: nil).filter { $0.rating < 0 }
        case .container(let id): vs = store.versions(in: id)
        case .person(let id): vs = store.versions(of: id)
        case .location(let path): vs = store.versions(in: nil).filter { v in let k = ["place.country", "place.state", "place.city", "place.name"]; return path.enumerated().allSatisfy { (i, p) in i >= k.count || (v.meta[k[i]] ?? (i == 0 ? "Unknown" : "")) == p } }
        }
        vs = vs.filter { !$0.hidden }
        if minRating != -2 { vs = vs.filter { minRating == -1 ? $0.rating < 0 : $0.rating >= minRating } }
        if filterLabel >= 0 { vs = vs.filter { $0.colorLabel == filterLabel } }
        if filterFlagged { vs = vs.filter(\.flagged) }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { vs = vs.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.keywords.contains { $0.localizedCaseInsensitiveContains(q) } || $0.caption.localizedCaseInsensitiveContains(q) } }
        var manual = false
        if case .container(let id) = source, let c = store.containers[id], c.kind != .project, c.kind != .folder, sortKey == .manual { manual = true }
        let sortedVs = manual ? vs : LibraryStore.sorted(vs, by: sortKey == .manual ? .imageDate : sortKey, ascending: sortAscending, masters: store.masters)
        shown = collapseStacks(sortedVs)
    }
    private func storeChanged() {
        reloadVersions()
        selection = selection.filter { store.versions[$0] != nil }
        if let p = primary, store.versions[p] == nil { primary = selection.first ?? shown.first?.id }
        objectWillChange.send()
    }
    var primaryVersion: Version? { primary.flatMap { store.versions[$0] } }
    var primaryMaster: Master? { primaryVersion.flatMap { store.masters[$0.masterID] } }
    var selectedVersions: [Version] { selection.compactMap { store.versions[$0] } }
    var statusLine: String {
        let n = shown.count, s = selection.count
        let sel = s > 0 ? L("\(s) selected – ", "\(s) ausgewählt – ") : ""
        return sel + L("\(n) items displayed", "\(n) Objekte angezeigt")
    }

    func click(_ id: ID, extend: Bool, toggle: Bool) {
        if extend, let last = primary, let a = shown.firstIndex(where: { $0.id == last }), let b = shown.firstIndex(where: { $0.id == id }) {
            let r = a <= b ? a...b : b...a; selection = shown[r].map(\.id); primary = id
        } else if toggle {
            if let i = selection.firstIndex(of: id) { selection.remove(at: i); if primary == id { primary = selection.last } } else { selection.append(id); primary = id }
        } else { selection = [id]; primary = id }
    }
    func move(_ dx: Int, columns: Int) {
        guard !shown.isEmpty else { return }
        let i = primary.flatMap { p in shown.firstIndex { $0.id == p } } ?? -1
        let n = min(shown.count - 1, max(0, i + dx * (abs(dx) == 1 ? 1 : 1)))
        let id = shown[n].id; selection = [id]; primary = id
    }
    func selectAll() { selection = shown.map(\.id); if primary == nil { primary = shown.first?.id } }
    func deselectAll() { selection = [] }
    func invertSelection() { let s = Set(selection); selection = shown.map(\.id).filter { !s.contains($0) } }

    // MARK: primary change → adjustments + render
    func primaryChanged() {
        undoAdj.removeAll()
        adjustments = primary.map { store.adjustments(for: $0) } ?? AdjustmentSet()
        tool = .select
        scheduleRender()
    }
    private var undoAdj: [AdjustmentSet] = []

    // MARK: metadata edits (undoable)
    func withUndo(_ name: String, ids: [ID], _ mutate: @escaping (inout Version) -> Void) {
        let before = ids.compactMap { store.versions[$0] }
        do { try store.update(ids, mutate) } catch { alert = ("Error", error.localizedDescription); return }
        let after = ids.compactMap { store.versions[$0] }
        pushUndo(name, undo: { [weak self] in self?.restore(before) }, redo: { [weak self] in self?.restore(after) })
    }
    private func restore(_ vs: [Version]) { let m = Dictionary(uniqueKeysWithValues: vs.map { ($0.id, $0) }); try? store.update(Array(m.keys)) { $0 = m[$0.id] ?? $0 } }
    func pushUndo(_ name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoStack.append((name, undo, redo)); redoStack.removeAll(); if undoStack.count > 200 { undoStack.removeFirst() }
        objectWillChange.send()
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoName: String { undoStack.last?.0 ?? "" }
    func undo() { guard let e = undoStack.popLast() else { return }; e.1(); redoStack.append(e); objectWillChange.send() }
    func redo() { guard let e = redoStack.popLast() else { return }; e.2(); undoStack.append(e); objectWillChange.send() }

    func setRating(_ r: Int) { let ids = selection; guard !ids.isEmpty else { return }; withUndo(L("Set Rating", "Bewertung ändern"), ids: ids) { $0.rating = r } }
    func adjustRating(_ d: Int) { let ids = selection; withUndo(L("Set Rating", "Bewertung ändern"), ids: ids) { $0.rating = max(0, min(5, max(0, $0.rating) + d)) } }
    func setLabel(_ l: Int) { let ids = selection; guard !ids.isEmpty else { return }
        let cur = primaryVersion?.colorLabel; withUndo(L("Set Label", "Etikett ändern"), ids: ids) { $0.colorLabel = (cur == l && l != 0) ? 0 : l } }
    func toggleFlag() { let ids = selection; guard !ids.isEmpty else { return }; let on = !(primaryVersion?.flagged ?? false); withUndo(L("Flag", "Markieren"), ids: ids) { $0.flagged = on } }
    func rotate(_ d: Int) { let ids = selection; guard !ids.isEmpty else { return }
        withUndo(L("Rotate", "Drehen"), ids: ids) { $0.rotation = (($0.rotation + d) % 360 + 360) % 360 }
        for i in ids { thumbRevision[i, default: 0] += 1 }; scheduleRender() }
    func rename(_ id: ID, _ name: String) { withUndo(L("Rename", "Umbenennen"), ids: [id]) { $0.name = name } }
    func setCaption(_ s: String) { let ids = selection; withUndo(L("Edit Caption", "Beschriftung"), ids: ids) { $0.caption = s } }
    func addKeyword(_ k: String) { let k = k.trimmingCharacters(in: .whitespaces); guard !k.isEmpty else { return }; withUndo(L("Add Keyword", "Schlagwort hinzufügen"), ids: selection) { if !$0.keywords.contains(k) { $0.keywords.append(k) } } }
    func removeKeyword(_ k: String) { withUndo(L("Remove Keyword", "Schlagwort entfernen"), ids: selection) { $0.keywords.removeAll { $0 == k } } }
    func moveToTrash() { let ids = selection; guard !ids.isEmpty else { return }; withUndo(L("Delete", "Löschen"), ids: ids) { $0.trashed = true }; status = L("\(ids.count) moved to Trash", "\(ids.count) in den Papierkorb gelegt") }
    func restoreFromTrash() { let ids = selection; withUndo(L("Restore", "Wiederherstellen"), ids: ids) { $0.trashed = false } }
    func emptyTrash() { do { try store.emptyTrash() } catch { alert = ("Error", error.localizedDescription) } }
    func duplicateVersion(fromMaster: Bool) {
        guard let p = primary, let v = try? store.duplicateVersion(p, fromMaster: fromMaster) else { return }
        selection = [v.id]; primary = v.id
    }

    // MARK: containers
    func newProject(_ name: String? = nil) {
        let f = DateFormatter(); f.dateStyle = .medium
        if let c = try? store.addContainer(Container(kind: .project, name: name ?? L("New Project", "Neues Projekt") + " " + f.string(from: Date()), parentID: parentForNew())) { source = .container(c.id) }
    }
    func newFolder() { _ = try? store.addContainer(Container(kind: .folder, name: L("Untitled Folder", "Unbenannter Ordner"), parentID: parentForNew())) }
    func newAlbum() {
        let ids = selection
        if let c = try? store.addContainer(Container(kind: .album, name: L("Untitled Album", "Unbenanntes Album"), parentID: parentForNew())) { if !ids.isEmpty { try? store.addToAlbum(c.id, ids) }; source = .container(c.id) }
    }
    func newSmartAlbum() {
        if let c = try? store.addContainer(Container(kind: .smartAlbum, name: L("Untitled Smart Album", "Unbenanntes intelligentes Album"), parentID: parentForNew(), query: SmartQuery(rules: [SmartRule(.rating, .atLeast, "3")]))) { source = .container(c.id) }
    }
    private func parentForNew() -> ID? {
        if case .container(let id) = source, let c = store.containers[id] { return c.kind == .folder ? id : (c.kind == .project ? c.parentID : c.parentID) }
        return nil
    }
    func deleteContainer(_ id: ID) { if source == .container(id) { source = .all }; try? store.deleteContainer(id) }
    func removeFromAlbum() { if case .container(let id) = source, let c = store.containers[id], c.kind == .album { try? store.removeFromAlbum(id, selection) } }

    // MARK: Lift & Stamp
    func lift(meta: Bool, adj: Bool) {
        guard let v = primaryVersion else { return }
        liftedAdjustments = adj ? store.adjustments(for: v.id) : nil; liftedMeta = meta ? v : nil
        status = L("Lifted \(meta && adj ? "metadata and adjustments" : meta ? "metadata" : "adjustments") from \(v.name) – select photos and click Stamp", "\(meta && adj ? "Metadaten und Anpassungen" : meta ? "Metadaten" : "Anpassungen") von \(v.name) aufgenommen – Fotos wählen und „Stempeln\" klicken")
        objectWillChange.send()
    }
    func resetAllAdjustments() {
        let ids = selection; guard !ids.isEmpty else { return }
        let before = ids.map { ($0, store.adjustments(for: $0)) }
        for id in ids { try? store.setAdjustments(id, AdjustmentSet()); thumbRevision[id, default: 0] += 1 }
        pushUndo(L("Reset Adjustments", "Anpassungen zurücksetzen"), undo: { [weak self] in for (id, s) in before { try? self?.store.setAdjustments(id, s); self?.thumbRevision[id, default: 0] += 1 }; self?.primaryChanged() },
                 redo: { [weak self] in for id in ids { try? self?.store.setAdjustments(id, AdjustmentSet()) }; self?.primaryChanged() })
        primaryChanged()
    }
}
