import SwiftUI
import AppKit
import RetroluxCore

enum EditorKind { case lightTable, book, slideshow, web }

extension AppModel {
    var editorContainer: Container? { if case .container(let id) = source, let c = store.containers[id], [.lightTable, .book, .slideshow, .webJournal].contains(c.kind) { return c }; return nil }
    var editorKind: EditorKind? { switch editorContainer?.kind { case .lightTable: return .lightTable; case .book: return .book; case .slideshow: return .slideshow; case .webJournal: return .web; default: return nil } }

    private func parentForNewDoc() -> ID? { if case .container(let id) = source, let c = store.containers[id] { return c.kind == .folder ? id : c.parentID }; return nil }
    @discardableResult func newDocument(_ kind: ContainerKind, name: String, members: [ID]) -> Container? {
        guard let c = try? store.addContainer(Container(kind: kind, name: name, parentID: parentForNewDoc())) else { return nil }
        if !members.isEmpty { try? store.addToAlbum(c.id, members) }
        source = .container(c.id); inspectorTab = .library; return c
    }
    func newLightTable() {
        let ids = selection
        guard let c = newDocument(.lightTable, name: L("Untitled Light Table", "Unbenannter Leuchttisch"), members: []) else { return }
        var doc = LightTableDoc(); var x = 160.0, y = 140.0
        for (i, id) in ids.enumerated() { let a = store.aspect(id); doc.items.append(LightTableItem(versionID: id, x: x, y: y, width: 220, height: 220 / a, z: i)); x += 240; if x > 900 { x = 160; y += 200 } }
        try? store.saveDocument(c.id, doc)
    }
    func newSlideshow() {
        let ids = selection.isEmpty ? shown.map(\.id) : selection
        guard let c = newDocument(.slideshow, name: L("Untitled Slideshow", "Unbenannte Diashow"), members: ids) else { return }
        try? store.saveDocument(c.id, SlideshowSettings())
    }
    func newBook(type: String = "Large Softcover", theme: String = "Photo Journal") {
        let ids = selection.isEmpty ? shown.map(\.id) : selection
        guard let c = newDocument(.book, name: L("Untitled Book", "Unbenanntes Buch"), members: ids) else { return }
        var d = BookDoc(); d.type = type; d.theme = theme; d.title = c.name
        d.pages = BookLayouts.autoflow(ids, theme: theme, captions: Dictionary(uniqueKeysWithValues: ids.compactMap { id in store.versions[id].map { (id, $0.caption) } }))
        try? store.saveDocument(c.id, d)
    }
    func newWebJournal() {
        let ids = selection.isEmpty ? shown.map(\.id) : selection
        guard let c = newDocument(.webJournal, name: L("Untitled Web Journal", "Unbenanntes Web-Journal"), members: ids) else { return }
        var d = WebDoc(); d.title = c.name; try? store.saveDocument(c.id, d)
    }
    func newWebPage(smart: Bool) {
        let ids = selection.isEmpty ? shown.map(\.id) : selection
        let c: Container?
        if smart { c = newDocument(.webJournal, name: L("Smart Web Page", "Intelligente Webseite"), members: []); if let c { store.setQuery(c.id, SmartQuery(rules: [SmartRule(.rating, .atLeast, "3")])) } }
        else { c = newDocument(.webJournal, name: L("Web Page", "Webseite"), members: ids) }
        if let c { var d = WebDoc(); d.title = c.name; try? store.saveDocument(c.id, d) }
    }
    /// Versions a document container shows: its members, or the result of the smart rules.
    func documentVersions(_ c: Container) -> [ID] { c.query != nil ? store.versions(in: nil).filter { store.matches($0, c.query!) }.sorted { $0.imageDate < $1.imageDate }.map(\.id) : c.members.filter { store.versions[$0] != nil } }

    // MARK: print (File ▸ Print…)
    func runPrint(layout: PrintLayout, options: PrintOptions, directPrint: Bool) {
        let ids = selection.isEmpty ? shown.map(\.id) : selection
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rl-print-\(UUID().uuidString).pdf")
        progress = 0.2; status = L("Preparing print…", "Druck wird vorbereitet …")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let pages = try PrintRenderer.pdf(layout: layout, versions: ids, options: options, store: self.store, to: url)
                DispatchQueue.main.async {
                    self.progress = nil; self.status = self.L("\(pages) pages ready", "\(pages) Seiten bereit")
                    if directPrint, let doc = PDFDocumentLoader.load(url) { PDFDocumentLoader.printDocument(doc, window: NSApp.keyWindow) } else { NSWorkspace.shared.open(url) }
                }
            } catch { DispatchQueue.main.async { self.progress = nil; self.alert = ("Print", error.localizedDescription) } }
        }
    }
}
