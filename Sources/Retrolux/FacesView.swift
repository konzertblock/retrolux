import SwiftUI
import AppKit
import RetroluxCore

final class FaceCropCache {
    static let shared = FaceCropCache()
    private let cache = NSCache<NSString, NSImage>()
    func image(for f: Face, store: LibraryStore) async -> NSImage? {
        if let h = cache.object(forKey: f.id as NSString) { return h }
        guard let v = store.versions[f.versionID], let m = store.masters[v.masterID] else { return nil }
        let url = store.masterURL(m), size = CGSize(width: m.width, height: m.height), isRaw = m.isRaw, rot = v.rotation, rect = f.rect
        let img: NSImage? = await Task.detached(priority: .utility) {
            guard let cg = RenderEngine.shared.renderCG(RenderRequest(url: url, isRaw: isRaw, originalSize: size, rotation: rot, adjustments: AdjustmentSet(), maxPixel: 1000)) else { return nil }
            let W = CGFloat(cg.width), H = CGFloat(cg.height)
            let pad = rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let c = cg.cropping(to: CGRect(x: pad.minX * W, y: pad.minY * H, width: pad.width * W, height: pad.height * H).integral) else { return nil }
            return NSImage(cgImage: c, size: NSSize(width: c.width, height: c.height))
        }.value
        if let img { cache.setObject(img, forKey: f.id as NSString) }
        return img
    }
}

struct FaceThumb: View {
    @ObservedObject var model: AppModel
    let face: Face
    var size: CGFloat = 90
    var height: CGFloat? = nil
    var corner: CGFloat = 6
    @State private var img: NSImage?
    var body: some View {
        ZStack { Rectangle().fill(Color.black.opacity(0.3))
            if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else { ProgressView().controlSize(.small) } }
            .frame(width: size, height: height ?? size).clipShape(RoundedRectangle(cornerRadius: corner)).overlay(RoundedRectangle(cornerRadius: corner).stroke(corner == 0 ? Color.black.opacity(0.2) : Color.white.opacity(0.6), lineWidth: corner == 0 ? 0.5 : 1))
            .task(id: face.id) { img = await FaceCropCache.shared.image(for: face, store: model.store) }
    }
}

/// Polaroid card at the measured native geometry (133×133 px, photo 120×102 at (7,7), name strip 23 px); `k` scales everything.
struct PolaroidCard: View {
    @ObservedObject var model: AppModel
    let name: String
    let face: Face?
    let k: CGFloat
    var body: some View {
        let theme = IconTheme.shared.polaroid()
        let hole = theme?.hole ?? CGRect(x: 7, y: 7, width: 120, height: 102), label = theme?.label ?? CGRect(x: 7, y: 109, width: 120, height: 23)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.86)], startPoint: .top, endPoint: .bottom)).frame(width: 133 * k, height: 133 * k)
                .shadow(color: .black.opacity(0.55), radius: 2 * k, x: 0, y: 1.5 * k)
            Group { if let face { FaceThumb(model: model, face: face, size: hole.width * k + 1, height: hole.height * k + 1, corner: 0) } else { Rectangle().fill(Color.black.opacity(0.3)) } }
                .frame(width: hole.width * k + 1, height: hole.height * k + 1).offset(x: hole.minX * k - 0.5, y: hole.minY * k - 0.5)
            if let t = theme { Image(nsImage: t.image).resizable().interpolation(k == 1 ? .none : .high).frame(width: 133 * k, height: 133 * k) }
            Text(name).font(Font.custom("MarkerFelt-Wide", size: 14 * k)).scaleEffect(x: 0.8, y: 1).foregroundColor(Color(white: 0.08)).lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: label.width * k, height: label.height * k).offset(x: label.minX * k, y: label.minY * k)
        }.frame(width: 133 * k, height: 133 * k)
    }
}

/// The Faces corkboard: people cards, unnamed groups, suggestions to confirm.
struct FacesView: View {
    @ObservedObject var model: AppModel
    @State private var clusters: [[Face]] = []
    @State private var name = ""
    @State private var selectedPerson: ID?
    @State private var showUnnamed = false
    @AppStorage("faceCardScale") private var cardScale = 1.0
    @State private var query = ""
    var body: some View {
        let _ = model.facesTick
        VStack(spacing: 0) {
            AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
                HStack { Spacer(); TextField(model.L("Search names", "Namen suchen"), text: $query).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 170) }.padding(.horizontal, 8).frame(height: 24)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.facesEnabled { Text(model.L("Face analysis is turned off (Preferences ▸ Faces).", "Gesichtsanalyse ist ausgeschaltet (Einstellungen ▸ Gesichter).")).font(Theme.small).foregroundColor(.orange) }
                    peopleGrid
                    if showUnnamed { unnamedSection }
                }.padding(.leading, 17).padding(.top, 19).padding(.bottom, 14).padding(.trailing, 14)
            }.background(Group { if let c = IconTheme.shared.cork() { Image(nsImage: c).resizable(resizingMode: .tile) } else { Color(.sRGB, red: 0.45, green: 0.36, blue: 0.27) } })     // cork
            AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
                HStack(spacing: 10) {
                    Button(showUnnamed ? model.L("Hide Unnamed Faces", "Unbenannte Gesichter ausblenden") : model.L("Show Unnamed Faces", "Unbenannte Gesichter zeigen")) { showUnnamed.toggle(); reload() }.buttonStyle(AquaButtonStyle())
                    if model.facesAnalyzing { ProgressView().controlSize(.small).scaleEffect(0.7); Text(model.L("analyzing…", "analysiere …")).font(Theme.tiny) }
                    Spacer()
                    Text(model.L("Strictness", "Strenge")).font(Theme.tiny); Slider(value: Binding(get: { 1.2 - model.faceThreshold }, set: { model.setFaceThreshold(1.2 - $0); }), in: 0.2...0.9, onEditingChanged: { if !$0 { model.resuggest(); reload() } }).frame(width: 90).controlSize(.mini)
                    Button(model.facesPaused ? model.L("Resume", "Fortsetzen") : model.L("Pause", "Pausieren")) { model.facesPaused.toggle(); if !model.facesPaused { model.startFaceAnalysis() } }.buttonStyle(AquaButtonStyle())
                    Button(model.L("Analyze Now", "Jetzt analysieren")) { model.facesPaused = false; model.startFaceAnalysis(); model.detectMissingFaces() }.buttonStyle(AquaButtonStyle())
                    Image(systemName: "photo").font(.system(size: 8)); Slider(value: $cardScale, in: 0.6...1.6).frame(width: 90).controlSize(.mini); Image(systemName: "photo").font(.system(size: 12))
                }.padding(.horizontal, 10).frame(height: 28)
            }
        }
        .onAppear(perform: reload)
        .sheet(item: Binding(get: { selectedPerson.map { PID(id: $0) } }, set: { if $0 == nil { selectedPerson = nil } })) { p in PersonDetail(model: model, personID: p.id) { selectedPerson = nil; reload() } }
    }
    struct PID: Identifiable { let id: ID }
    func reload() { clusters = Array(model.analyzer.clusterUnnamed().prefix(40)) }
    @ViewBuilder var peopleGrid: some View {
        let k = CGFloat(cardScale)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 133 * k, maximum: 133 * k), spacing: 32 * k, alignment: .topLeading)], alignment: .leading, spacing: 31 * k) {
            ForEach(model.peopleList.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { p in
                let faces = model.store.faces(of: p.id, confirmedOnly: true)
                let sugg = model.store.allFaces().filter { $0.suggestedID == p.id && !$0.confirmed }.count
                PolaroidCard(model: model, name: p.name, face: faces.first(where: { $0.id == p.keyFace }) ?? faces.first, k: k)
                .help(model.L("\(model.store.versions(of: p.id, includeSuggested: false).count) photos", "\(model.store.versions(of: p.id, includeSuggested: false).count) Fotos") + (sugg > 0 ? " · " + model.L("\(sugg) to confirm", "\(sugg) bestätigen") : ""))
                .onTapGesture(count: 2) { model.source = .person(p.id); model.facesView = false }
                .onTapGesture { selectedPerson = p.id }
                .contextMenu {
                    Button(model.L("Show Photos", "Fotos zeigen")) { model.source = .person(p.id); model.facesView = false }
                    Button(model.L("Rename…", "Umbenennen …")) { rename(p) }
                    Menu(model.L("Merge Into", "Zusammenführen mit")) { ForEach(model.peopleList.filter { $0.id != p.id }) { o in Button(o.name) { try? model.store.mergePeople(p.id, into: o.id); model.faceTick(); reload() } } }
                    Button(model.L("Delete Person", "Person löschen"), role: .destructive) { try? model.store.deletePerson(p.id); model.faceTick(); reload() }
                }
            }
            if model.peopleList.isEmpty { Text(model.L("No named people yet. Name the faces below.", "Noch keine benannten Personen. Benenne die Gesichter unten.")).font(Theme.small).foregroundColor(.white) }
        }
    }
    func rename(_ p: Person) {
        let a = NSAlert(); a.messageText = model.L("Rename person", "Person umbenennen"); let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); tf.stringValue = p.name; a.accessoryView = tf
        a.addButton(withTitle: "OK"); a.addButton(withTitle: model.L("Cancel", "Abbrechen"))
        if a.runModal() == .alertFirstButtonReturn, !tf.stringValue.isEmpty { try? model.store.renamePerson(p.id, tf.stringValue); model.faceTick() }
    }
    var unnamedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.L("Unnamed faces", "Unbenannte Gesichter")).font(Theme.font(12, bold: true)).foregroundColor(.white)
            ForEach(Array(clusters.enumerated()), id: \.offset) { _, group in
                ClusterRow(model: model, group: group) { reload() }
            }
            if clusters.isEmpty { Text(model.facesAnalyzing ? model.L("Analysis running…", "Analyse läuft …") : model.L("No unnamed faces.", "Keine unbenannten Gesichter.")).font(Theme.small).foregroundColor(.white.opacity(0.85)) }
        }
    }
}

struct ClusterRow: View {
    @ObservedObject var model: AppModel
    let group: [Face]
    var done: () -> Void
    @State private var name = ""
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollView(.horizontal) { HStack(spacing: 4) { ForEach(group.prefix(12)) { f in FaceThumb(model: model, face: f, size: 64).onTapGesture { model.source = .container(model.store.versions[f.versionID]?.projectID ?? ""); model.facesView = false; model.click(f.versionID, extend: false, toggle: false) } } } }.frame(maxWidth: 520)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.L("\(group.count) similar faces", "\(group.count) ähnliche Gesichter")).font(Theme.tiny).foregroundColor(.white)
                HStack { TextField(model.L("Name", "Name"), text: $name, onCommit: apply).textFieldStyle(.roundedBorder).frame(width: 150)
                    Menu { ForEach(model.peopleList) { p in Button(p.name) { name = p.name; apply() } } } label: { Image(systemName: "person.crop.circle") }.menuStyle(.borderlessButton).frame(width: 30)
                    Button(model.L("Name All", "Alle benennen")) { apply() }.buttonStyle(AquaButtonStyle()).disabled(name.isEmpty)
                    Button(model.L("Not a face", "Kein Gesicht")) { for f in group { try? model.store.markNotAFace(f.id) }; model.faceTick(); done() }.buttonStyle(AquaButtonStyle()) }
            }
        }.padding(8).background(Color.black.opacity(0.22)).cornerRadius(8)
    }
    func apply() { guard !name.isEmpty else { return }; model.nameFaces(group.map(\.id), as: name); name = ""; done() }
}

/// One person: all confirmed faces plus suggestions that wait for a yes/no.
struct PersonDetail: View {
    @ObservedObject var model: AppModel
    let personID: ID
    var close: () -> Void
    var person: Person? { model.store.people().first { $0.id == personID } }
    var body: some View {
        let _ = model.facesTick
        let confirmed = model.store.faces(of: personID, confirmedOnly: true)
        let suggestions = model.store.allFaces().filter { $0.suggestedID == personID && !$0.confirmed }
        VStack(alignment: .leading, spacing: 10) {
            Text(person?.name ?? "").font(Theme.font(14, bold: true))
            if !suggestions.isEmpty {
                Text(model.L("Is this \(person?.name ?? "")?", "Ist das \(person?.name ?? "")?")).font(Theme.small)
                ScrollView(.horizontal) { HStack { ForEach(suggestions) { f in
                    VStack(spacing: 3) { FaceThumb(model: model, face: f, size: 80)
                        HStack { Button("✓") { try? model.store.confirmSuggestion(f.id); model.resuggest() }.buttonStyle(AquaButtonStyle()); Button("✕") { try? model.store.rejectSuggestion(f.id); model.faceTick() }.buttonStyle(AquaButtonStyle()) } } } } }
                Button(model.L("Confirm All", "Alle bestätigen")) { for f in suggestions { try? model.store.confirmSuggestion(f.id) }; model.resuggest() }.buttonStyle(AquaButtonStyle())
            }
            Text(model.L("\(confirmed.count) confirmed faces", "\(confirmed.count) bestätigte Gesichter")).font(Theme.small)
            ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 6) { ForEach(confirmed) { f in
                FaceThumb(model: model, face: f, size: 80).contextMenu { Button(model.L("This is not \(person?.name ?? "")", "Das ist nicht \(person?.name ?? "")")) { try? model.store.unnameFace(f.id); model.resuggest() } } } } }.frame(height: 200)
            HStack { Button(model.L("Show Photos", "Fotos zeigen")) { model.source = .person(personID); model.facesView = false; close() }.buttonStyle(AquaButtonStyle()); Spacer(); Button("OK", action: close).buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 560).background(Theme.chrome)
    }
}

struct FaceNameSheet: View {
    @ObservedObject var model: AppModel
    let faceID: ID
    @State private var name = ""
    var face: Face? { model.store.allFaces().first { $0.id == faceID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let f = face {
                HStack(spacing: 12) {
                    FaceThumb(model: model, face: f, size: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        if let s = f.suggestedID, !f.confirmed, let p = model.store.people().first(where: { $0.id == s }) {
                            Text(model.L("Is this \(p.name)?", "Ist das \(p.name)?")).font(Theme.font(13, bold: true))
                            HStack { Button(model.L("Yes", "Ja")) { try? model.store.confirmSuggestion(f.id); model.resuggest(); model.namingFace = nil }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction)
                                Button(model.L("No", "Nein")) { try? model.store.rejectSuggestion(f.id); model.faceTick() }.buttonStyle(AquaButtonStyle()) }
                        } else { Text(model.L("Who is this?", "Wer ist das?")).font(Theme.font(13, bold: true)) }
                        TextField(model.L("Name", "Name"), text: $name, onCommit: { model.nameFace(f.id, as: name) }).textFieldStyle(.roundedBorder).frame(width: 220)
                        ScrollView(.horizontal) { HStack { ForEach(model.peopleList) { p in Button(p.name) { model.nameFace(f.id, as: p.name) }.buttonStyle(AquaButtonStyle()) } } }.frame(width: 260)
                    }
                }
                HStack { if f.personID != nil { Button(model.L("Remove Name", "Namen entfernen")) { try? model.store.unnameFace(f.id); model.faceTick() }.buttonStyle(AquaButtonStyle()) }
                    Button(model.L("Not a Face", "Kein Gesicht")) { try? model.store.markNotAFace(f.id); model.faceTick(); model.namingFace = nil }.buttonStyle(AquaButtonStyle()); Spacer()
                    Button(model.L("Cancel", "Abbrechen")) { model.namingFace = nil }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(model.L("Name", "Benennen")) { model.nameFace(f.id, as: name) }.buttonStyle(AquaButtonStyle()).disabled(name.isEmpty) }
            }
        }.padding(16).frame(width: 440).background(Theme.chrome)
    }
}
