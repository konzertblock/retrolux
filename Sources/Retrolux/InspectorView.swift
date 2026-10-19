import SwiftUI
import AppKit
import RetroluxCore

struct InspectorView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(InspectorTab.allCases, id: \.self) { t in
                    Button { model.inspectorTab = t } label: {
                        Text(model.lang == "de" ? ["Library": "Bibliothek", "Metadata": "Metadaten", "Adjustments": "Anpassungen"][t.rawValue]! : t.rawValue)
                            .font(Theme.font(11, bold: model.inspectorTab == t)).foregroundColor(.black).frame(maxWidth: .infinity).frame(height: 22)
                            .background(model.inspectorTab == t ? LinearGradient(colors: [Theme.hex(0xF4F4F4), Theme.hex(0xDCDCDC)], startPoint: .top, endPoint: .bottom) : LinearGradient(colors: [Theme.hex(0xBEBEBE), Theme.hex(0xA6A6A6)], startPoint: .top, endPoint: .bottom))
                            .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                    }.buttonStyle(.plain)
                }
            }
            Group {
                switch model.inspectorTab {
                case .library: LibraryTab(model: model)
                case .metadata: MetadataTab(model: model)
                case .adjustments: AdjustmentsTab(model: model)
                }
            }.background(model.inspectorTab == .library ? Theme.sourceList : Theme.inspector)
        }
    }
}

// MARK: - Library tree
struct LibraryTab: View {
    @ObservedObject var model: AppModel
    @State private var renaming: ID?
    @State private var newName = ""
    @State private var editQuery: ID?

    func row(_ title: String, _ icon: String, _ src: Source, depth: Int = 0, id: ID? = nil, badge: Int? = nil) -> some View {
        let sel = model.source == src
        return HStack(spacing: 5) {
            Spacer().frame(width: CGFloat(depth) * 14)
            IconView(name: icon, size: 16).frame(width: 16)
            if renaming != nil, renaming == id {
                TextField("", text: $newName, onCommit: { if let id { try? model.store.renameContainer(id, newName) }; renaming = nil }).textFieldStyle(.roundedBorder).font(Theme.small)
            } else { Text(title).font(Theme.small).foregroundColor(sel ? .white : .black).lineLimit(1) }
            Spacer()
            if let b = badge { Text("\(b)").font(Theme.tiny).foregroundColor(sel ? .white : .gray) }
        }
        .padding(.horizontal, 8).frame(height: 19).background(sel ? LinearGradient(colors: [Theme.sourceSelected, Theme.sourceSelected], startPoint: .top, endPoint: .bottom) : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let id { renaming = id; newName = model.store.containers[id]?.name ?? "" } }
        .onTapGesture { model.source = src }
        .dropDestination(for: String.self) { ids, _ in if let id, let c = model.store.containers[id], c.kind != .smartAlbum { try? model.store.addToAlbum(id, ids); return true }; return false }
    }

    func tree(_ parent: ID?, depth: Int) -> AnyView {
        AnyView(ForEach(model.store.children(of: parent)) { c in
            VStack(spacing: 0) {
                row(c.name, icon(c.kind), .container(c.id), depth: depth, id: c.id, badge: c.kind == .folder ? nil : model.store.versions(in: c.id).count)
                    .contextMenu {
                        Button(model.L("Rename", "Umbenennen")) { renaming = c.id; newName = c.name }
                        if c.kind == .smartAlbum { Button(model.L("Edit Smart Album…", "Intelligentes Album bearbeiten …")) { editQuery = c.id } }
                        Button(model.L("Delete", "Löschen"), role: .destructive) { model.deleteContainer(c.id) }
                    }
                tree(c.id, depth: depth + 1)
            }
        })
    }
    func icon(_ k: ContainerKind) -> String {
        switch k { case .folder: return "folder"; case .project: return "camera.aperture"; case .album: return "rectangle.stack"; case .smartAlbum: return "gearshape"; case .book: return "book"; case .lightTable: return "square.grid.3x3"; case .slideshow: return "play.rectangle"; case .webJournal: return "globe" }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    header(model.L("LIBRARY", "BIBLIOTHEK"))
                    row(model.L("Photos", "Fotos"), "photo.on.rectangle", .all, badge: model.store.versions(in: nil).count)
                    row(model.L("Flagged", "Markiert"), "flag", .flagged)
                    row(model.L("Rejected", "Abgelehnt"), "xmark.circle", .rejected)
                    row(model.L("Trash", "Papierkorb"), "trash", .trash, badge: model.store.versions.values.filter(\.trashed).count)
                    header(model.L("PROJECTS", "PROJEKTE"))
                    tree(nil, depth: 0)
                    header(model.L("FACES", "GESICHTER"))
                    HStack { Image(systemName: "person.crop.rectangle").font(.system(size: 10)).frame(width: 14); Text(model.L("Open Faces…", "Gesichter öffnen …")).font(Theme.small); Spacer() }.padding(.horizontal, 8).frame(height: 19).contentShape(Rectangle()).onTapGesture { model.placesView = false; model.facesView = true }
                    ForEach(model.peopleList) { p in row(p.name, "person", .person(p.id), badge: model.store.versions(of: p.id, includeSuggested: false).count) }
                    header(model.L("PLACES", "ORTE"))
                    HStack { Image(systemName: "map").font(.system(size: 10)).frame(width: 14); Text(model.L("Open Places…", "Orte öffnen …")).font(Theme.small); Spacer(); Text("\(model.store.geotaggedCount)").font(Theme.tiny).foregroundColor(.gray) }.padding(.horizontal, 8).frame(height: 19).contentShape(Rectangle()).onTapGesture { model.facesView = false; model.placesView = true }
                    PlaceTree(model: model, row: { t, i, src, d, b in AnyView(row(t, i, src, depth: d, badge: b)) })
                    header(model.L("NOT IN THIS RELEASE", "NICHT ENTHALTEN"))
                    ForEach(["Books", "Slideshows", "Light Tables", "Web Journals"].filter { _ in false }, id: \.self) { n in Text(n) }
                }
            }
            Etched()
            HStack(spacing: 4) {
                Menu { Button(model.L("Project", "Projekt")) { model.newProject() }; Button(model.L("Folder", "Ordner")) { model.newFolder() }; Button(model.L("Album", "Album")) { model.newAlbum() }; Button(model.L("Smart Album", "Intelligentes Album")) { model.newSmartAlbum() } } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).frame(width: 30)
                Spacer()
                Text(model.store.root.deletingPathExtension().lastPathComponent).font(Theme.tiny).foregroundColor(.gray).lineLimit(1)
            }.padding(.horizontal, 8).frame(height: 24)
        }
        .sheet(isPresented: Binding(get: { editQuery != nil }, set: { if !$0 { editQuery = nil } })) { if let q = editQuery { SmartAlbumSheet(model: model, id: q) { editQuery = nil } } }
    }
    func header(_ t: String) -> some View { HStack { Text(t).font(Theme.font(9, bold: true)).foregroundColor(Theme.hex(0x777777)); Spacer() }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2) }
}

struct SmartAlbumSheet: View {
    @ObservedObject var model: AppModel
    let id: ID
    var done: () -> Void
    @State private var q = SmartQuery(rules: [])
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Smart Album Rules", "Regeln für intelligentes Album")).font(Theme.title)
            Picker("", selection: $q.matchAll) { Text(model.L("Match all rules", "Alle Regeln erfüllen")).tag(true); Text(model.L("Match any rule", "Mindestens eine Regel")).tag(false) }.pickerStyle(.segmented).frame(width: 300)
            ForEach(q.rules.indices, id: \.self) { i in
                HStack {
                    Picker("", selection: $q.rules[i].field) { ForEach(SmartRule.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 130)
                    Picker("", selection: $q.rules[i].op) { ForEach(opsFor(q.rules[i].field), id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110)
                    TextField("", text: $q.rules[i].value).frame(width: 110)
                    Button { q.rules.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            HStack { Button("+ " + model.L("Rule", "Regel")) { q.rules.append(SmartRule(.rating, .atLeast, "3")) }.buttonStyle(AquaButtonStyle()); Spacer()
                Button(model.L("Cancel", "Abbrechen"), action: done).buttonStyle(AquaButtonStyle())
                Button("OK") { model.store.setQuery(id, q); model.reloadVersions(); done() }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 520).background(Theme.chrome)
        .onAppear { q = model.store.containers[id]?.query ?? q }
    }
    func opsFor(_ f: SmartRule.Field) -> [SmartRule.Op] {
        switch f { case .rating: return [.equals, .atLeast, .atMost]; case .flagged, .hasAdjustments, .isRaw: return [.isTrue, .isFalse]; case .colorLabel: return [.equals, .notEquals]; case .imageDate: return [.after, .before]; default: return [.contains, .notEquals] }
    }
}

struct FlowTags: View {
    var tags: [String]; var remove: (String) -> Void
    var body: some View {
        if tags.isEmpty { Text("—").font(Theme.tiny).foregroundColor(.gray) }
        else { LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), alignment: .leading)], alignment: .leading, spacing: 3) {
            ForEach(tags, id: \.self) { t in HStack(spacing: 2) { Text(t.split(separator: "/").last.map(String.init) ?? t).font(Theme.tiny); Button { remove(t) } label: { Image(systemName: "xmark").font(.system(size: 7)) }.buttonStyle(.plain) }
                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.hex(0xC9D5E8)).cornerRadius(8).help(t) } } }
    }
}


struct PlaceTree: View {
    @ObservedObject var model: AppModel
    var row: (String, String, Source, Int, Int?) -> AnyView
    var body: some View {
        let t = model.store.locationTree()
        ForEach(t.keys.sorted(), id: \.self) { country in
            let states = t[country]!
            row(country, "globe", .location([country]), 0, states.values.flatMap { $0.values }.reduce(0, +))
            ForEach(states.keys.sorted().filter { !$0.isEmpty }, id: \.self) { st in
                row(st, "mappin.and.ellipse", .location([country, st]), 1, states[st]!.values.reduce(0, +))
                ForEach(states[st]!.keys.sorted().filter { !$0.isEmpty }, id: \.self) { city in row(city, "building.2", .location([country, st, city]), 2, states[st]![city]) }
            }
        }
    }
}
