import SwiftUI
import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import RetroluxCore

// MARK: - playback engine
final class SlideshowController: ObservableObject {
    let ids: [ID]; var settings: SlideshowSettings; let store: LibraryStore
    @Published var index = 0
    @Published var prevIndex: Int? = nil
    @Published var elapsed = 0.0                 // seconds in the current slide
    @Published var paused = false
    @Published var images: [ID: NSImage] = [:]
    @Published var finished = false
    @Published var recording = false
    var video = AVPlayer()
    private var timer: Timer?
    private var music: AVAudioPlayer?
    private var songIdx = 0
    private var photoAudio: AVAudioPlayer?
    private let q = DispatchQueue(label: "rl.slides", qos: .userInitiated)

    init(ids: [ID], settings: SlideshowSettings, store: LibraryStore, recording: Bool = false) {
        var o = ids; if settings.shuffle { o.shuffle() }
        self.ids = o; self.settings = settings; self.store = store; self.recording = recording
        preload(0); preload(1)
    }
    var current: ID? { ids.indices.contains(index) ? ids[index] : nil }
    func isVideo(_ id: ID) -> Bool { store.versions[id].flatMap { store.masters[$0.masterID] }?.kind == .video }
    func duration(_ id: ID) -> Double {
        if isVideo(id), let v = store.versions[id], let m = store.masters[v.masterID] { return max(1, (v.videoOut ?? m.duration) - v.videoIn) }
        return settings.duration(for: id)
    }
    func preload(_ i: Int) {
        guard ids.indices.contains(i), images[ids[i]] == nil else { return }
        let id = ids[i]
        q.async { [weak self] in
            guard let self, let cg = self.store.renderedImage(id, maxPixel: 2200) else { return }
            DispatchQueue.main.async { self.images[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }
    func start() {
        playSlideSideEffects(); startMusic()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() { timer?.invalidate(); music?.stop(); photoAudio?.stop(); video.pause() }
    private func tick() {
        guard !paused, !finished, let id = current else { return }
        elapsed += 1.0 / 30
        if settings.manualTiming && !recording && settings.timings[id] == nil { return }       // waits for the user
        if !settings.manualTiming || !recording, elapsed >= duration(id) { advance() }
    }
    func advance() {
        if recording, let id = current { settings.timings[id] = (elapsed * 10).rounded() / 10 }       //: record the viewer's own timing
        if index + 1 >= ids.count { if settings.loop { goto(0) } else { finished = true; if recording { onFinishRecording?(settings.timings) } }; return }
        goto(index + 1)
    }
    var onFinishRecording: (([ID: Double]) -> Void)?
    func back() { if index > 0 { goto(index - 1) } }
    func goto(_ i: Int) { prevIndex = index; index = i; elapsed = 0; preload(i + 1); preload(i); playSlideSideEffects() }
    func togglePause() {
        paused.toggle()
        if paused { music?.pause(); video.pause() }
        else { music?.play(); if isVideo(current ?? "") { video.play() } }
    }
    private func playSlideSideEffects() {
        photoAudio?.stop(); video.pause()
        guard let id = current, let v = store.versions[id] else { return }
        if let u = store.attachmentURL(v) { photoAudio = try? AVAudioPlayer(contentsOf: u); photoAudio?.play() }
        if isVideo(id), let m = store.masters[v.masterID] {
            video.replaceCurrentItem(with: AVPlayerItem(url: store.masterURL(m))); video.volume = Float(settings.videoVolume)
            video.seek(to: CMTime(seconds: v.videoIn, preferredTimescale: 600)); video.play()
            if settings.duckMusicDuringVideo { music?.volume = Float(settings.musicVolume) * 0.15 }
        } else { music?.volume = Float(settings.musicVolume) }
    }
    private func startMusic() {
        guard !settings.songs.isEmpty else { return }
        func play(_ i: Int) {
            guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: settings.songs[i % settings.songs.count])) else { return }
            music = p; p.volume = Float(settings.musicVolume); p.play(); songIdx = i
        }
        play(0)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.finished && !self.settings.loop { t.invalidate(); return }
            if let m = self.music, !m.isPlaying, !self.paused { if self.songIdx + 1 < self.settings.songs.count || self.settings.loopSoundtrack { play(self.songIdx + 1) } }
        }
    }
}

// MARK: - stages (the 8 styles)
struct SlideStage: View {
    @ObservedObject var c: SlideshowController
    var body: some View {
        GeometryReader { g in
            let fade = max(0.05, min(c.settings.fadeTime, c.settings.displayTime * 0.8))
            let t = min(1, c.elapsed / fade)
            let ease = t * t * (3 - 2 * t)
            ZStack {
                Color(white: c.settings.background)
                if let id = c.current { stage(g.size, id, ease) }
                if c.settings.showTitle, let id = c.current, let v = c.store.versions[id] {
                    VStack { Spacer(); Text(c.settings.overrides[id]?.title ?? v.name).font(.system(size: 22, weight: .medium)).foregroundColor(.white).shadow(radius: 4).padding(.bottom, 30) }
                }
            }
        }
    }
    func img(_ id: ID?) -> NSImage? { id.flatMap { c.images[$0] } }
    var prevID: ID? { c.prevIndex.flatMap { c.ids.indices.contains($0) ? c.ids[$0] : nil } }
    func photo(_ i: NSImage, fit: CGSize) -> some View { Image(nsImage: i).resizable().aspectRatio(contentMode: .fit).frame(width: fit.width, height: fit.height) }
    @ViewBuilder func stage(_ s: CGSize, _ id: ID, _ e: Double) -> some View {
        let cur = img(id), prev = img(prevID)
        let kb = c.settings.style == .kenBurns
        let p = min(1, c.elapsed / max(0.1, c.duration(id)))
        switch c.settings.style {
        case .classic, .kenBurns:
            ZStack {
                if let pv = prev, c.prevIndex != c.index, e < 1 { photo(pv, fit: s).opacity(c.settings.transition == "Fade" ? max(0, 1 - e * 2) : 1 - e) }
                if c.isVideo(id) { PlayerSurface(player: c.video) }
                else if let ci = cur { photo(ci, fit: s).scaleEffect(kb ? 1 + 0.12 * p : 1).offset(x: kb ? CGFloat(-20 * p) : 0, y: kb ? CGFloat(-10 * p) : 0).opacity(c.settings.transition == "Fade" ? max(0, e * 2 - 1) + (e >= 0.5 ? 0 : 0) : e) }
            }
        case .photoEdges:
            ZStack {
                if let pv = prev, e < 1 { framed(pv, s, rot: -3).offset(x: -s.width * 1.1 * e).rotationEffect(.degrees(-8 * e)) }
                if let ci = cur { framed(ci, s, rot: 3).offset(x: s.width * 1.1 * (1 - e)).rotationEffect(.degrees(8 * (1 - e))) }
            }
        case .scrapbook:
            ZStack {
                LinearGradient(colors: [Color(red: 0.55, green: 0.42, blue: 0.3), Color(red: 0.4, green: 0.3, blue: 0.2)], startPoint: .top, endPoint: .bottom)
                if let pv = prev { framed(pv, s, rot: tilt(prevID)).scaleEffect(0.95) }
                if let ci = cur { framed(ci, s, rot: tilt(id)).offset(y: -s.height * (1 - e)).rotationEffect(.degrees(tilt(id) * e)).scaleEffect(1.1 - 0.15 * e) }
            }
        case .shatter:
            ZStack {
                if let ci = cur { photo(ci, fit: s) }
                if let pv = prev, e < 1 { Tiles(image: pv, size: s, progress: e) }
            }
        case .slidingPanels:
            ZStack {
                if let pv = prev { photo(pv, fit: s) }
                if let ci = cur { Panels(image: ci, size: s, progress: e) }
            }
        case .snapshots:
            ZStack {
                if let pv = prev, e < 1 { polaroid(pv, s, id: prevID).offset(y: s.height * e).rotationEffect(.degrees(10 * e)) }
                if let ci = cur { polaroid(ci, s, id: id).scaleEffect(0.8 + 0.2 * e).opacity(e).rotationEffect(.degrees(tilt(id) * 0.5)) }
            }
        case .watercolorPanels:
            ZStack {
                if let pv = prev { photo(pv, fit: s) }
                if let ci = cur { WatercolorPanels(image: ci, size: s, progress: e) }
            }
        }
    }
    func tilt(_ id: ID?) -> Double { guard let id else { return 0 }; return Double(abs(id.hashValue) % 17) - 8 }
    func framed(_ i: NSImage, _ s: CGSize, rot: Double) -> some View { photo(i, fit: CGSize(width: s.width * 0.78, height: s.height * 0.78)).padding(14).background(Color.white).shadow(color: .black.opacity(0.7), radius: 14, y: 6).rotationEffect(.degrees(rot)) }
    func polaroid(_ i: NSImage, _ s: CGSize, id: ID?) -> some View {
        VStack(spacing: 8) { photo(i, fit: CGSize(width: s.width * 0.62, height: s.height * 0.62)); Text(id.flatMap { c.store.versions[$0]?.name } ?? "").font(.custom("MarkerFelt-Thin", size: 22)).foregroundColor(.black.opacity(0.7)) }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14).background(Color.white).shadow(color: .black.opacity(0.6), radius: 10, y: 5)
    }
}
struct Tiles: View {
    let image: NSImage; let size: CGSize; let progress: Double
    var body: some View {
        let cols = 8, rows = 5, tw = size.width / CGFloat(cols), th = size.height / CGFloat(rows)
        ZStack { ForEach(0..<(cols * rows), id: \.self) { n in
            let cx = n % cols, cy = n / cols, delay = Double((cx * 3 + cy * 5) % 9) / 14, tp = max(0, min(1, (progress - delay) / (1 - 0.65)))
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height)
                .frame(width: tw, height: th, alignment: .topLeading).mask(Rectangle().frame(width: tw, height: th)) // placeholder frame
                .overlay(Color.clear)
                .offset(x: CGFloat(cx) * tw + tw / 2 - size.width / 2 + CGFloat(tp * Double(cx - cols / 2) * 60), y: CGFloat(cy) * th + th / 2 - size.height / 2 + CGFloat(tp * tp * 500)).rotationEffect(.degrees(tp * Double((cx + cy) % 3 - 1) * 90)).opacity(1 - tp)
        } }.frame(width: size.width, height: size.height)
    }
}
struct Panels: View {
    let image: NSImage; let size: CGSize; let progress: Double
    var body: some View {
        let n = 6, pw = size.width / CGFloat(n)
        HStack(spacing: 0) { ForEach(0..<n, id: \.self) { i in
            let delay = Double(i) * 0.08, tp = max(0, min(1, (progress - delay) / (1 - Double(n) * 0.08)))
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height).frame(width: pw, alignment: .leading).clipped().offset(x: -CGFloat(i) * pw + (size.width - size.width) / 2, y: 0)
                .offset(y: (i % 2 == 0 ? -1 : 1) * size.height * CGFloat(1 - tp)).frame(width: pw, height: size.height).clipped()
        } }
    }
}
struct WatercolorPanels: View {
    let image: NSImage; let size: CGSize; let progress: Double
    var body: some View {
        let cols = 3, rows = 2, pw = size.width / CGFloat(cols), ph = size.height / CGFloat(rows)
        ZStack(alignment: .topLeading) { ForEach(0..<(cols * rows), id: \.self) { n in
            let delay = Double(n) * 0.1, tp = max(0, min(1, (progress - delay) / 0.5)), x = CGFloat(n % cols) * pw, y = CGFloat(n / cols) * ph
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height).offset(x: -x, y: -y).frame(width: pw, height: ph, alignment: .topLeading).clipped()
                .blur(radius: CGFloat(14 * (1 - tp))).opacity(tp).clipShape(RoundedRectangle(cornerRadius: 18 * (1 - tp))).offset(x: x, y: y)
        } }.frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

struct SlideshowPlayerView: View {
    @ObservedObject var c: SlideshowController
    var close: () -> Void
    var body: some View {
        ZStack { Color.black; SlideStage(c: c)
            if c.finished && !c.settings.loop { VStack(spacing: 10) { Text("The End").font(.system(size: 30, weight: .light)).foregroundColor(.white); Button("Close", action: close).buttonStyle(AquaButtonStyle(dark: true)) } }
            if c.paused { Image(systemName: "pause.fill").font(.system(size: 60)).foregroundColor(.white.opacity(0.6)) }
            if c.recording { VStack { HStack { Spacer(); Text("● REC  Space/→ next, ← back").font(.system(size: 12)).padding(6).background(Color.red.opacity(0.7)).foregroundColor(.white).cornerRadius(4) }; Spacer() }.padding(12) }
        }.ignoresSafeArea()
    }
}

final class SlideshowWindowController: NSObject {
    var window: NSWindow?; var monitor: Any?; let c: SlideshowController
    init(_ c: SlideshowController) { self.c = c }
    func show() {
        let secondary = UserDefaults.standard.bool(forKey: "slideshowSecondary") && NSScreen.screens.count > 1
        guard let screen = secondary ? NSScreen.screens[1] : NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver; w.backgroundColor = .black; w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SlideshowPlayerView(c: c, close: { [weak self] in self?.close() }))
        w.makeKeyAndOrderFront(nil); NSCursor.hide(); window = w
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode { case 53: self.close(); return nil; case 49: if self.c.recording { self.c.advance() } else { self.c.togglePause() }; return nil
            case 124, 125: self.c.advance(); return nil; case 123, 126: self.c.back(); return nil; default: return e }
        }
        c.start()
    }
    func close() { c.stop(); if let m = monitor { NSEvent.removeMonitor(m) }; NSCursor.unhide(); window?.orderOut(nil); window = nil }
}

// MARK: - editor
struct SlideshowEditor: View {
    @ObservedObject var model: AppModel
    let container: Container
    @State private var s = SlideshowSettings()
    @State private var loaded: ID?
    @State private var exporting: Double?
    @State private var exportPreset = 1
    @State private var exportNote = ""
    static var live: [SlideshowWindowController] = []
    var ids: [ID] { model.documentVersions(model.store.containers[container.id] ?? container) }
    func save() { try? model.store.saveDocument(container.id, s) }
    func play(record: Bool = false) {
        let list = ids; guard !list.isEmpty else { return }
        var st = s; if !record && s.manualTiming && s.timings.isEmpty { st.manualTiming = false }
        let c = SlideshowController(ids: list, settings: st, store: model.store, recording: record)
        c.onFinishRecording = { t in DispatchQueue.main.async { s.timings = t; save(); model.status = model.L("Timing recorded for \(t.count) slides", "Zeiten für \(t.count) Folien aufgenommen") } }
        let wc = SlideshowWindowController(c); SlideshowEditor.live.append(wc); wc.show()
    }
    @State private var showSettings = false
    @State private var showSlides = false
    var selectedID: ID? { if let p = model.primary, ids.contains(p) { return p }; return ids.first }
    func refreshBadges() {
        var d: [ID: String] = [:]
        for id in ids { d[id] = String(format: "%.1fs", s.overrides[id]?.duration ?? s.timings[id] ?? s.displayTime) }
        model.slideBadges = d
    }
    var body: some View {
        VStack(spacing: 0) {
            AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
                HStack {
                    Button { showSettings.toggle() } label: { HStack(spacing: 4) { Image(systemName: "rectangle.stack").font(.system(size: 10)); Text(model.L("Theme", "Thema")) } }.buttonStyle(AquaButtonStyle())
                        .popover(isPresented: $showSettings, arrowEdge: .bottom) { ScrollView { settingsPanel.padding(12) }.frame(width: 360, height: 560) }
                    Text(container.name).font(Theme.font(11, bold: true)).padding(.leading, 6)
                    Spacer()
                    Menu(model.L("Export…", "Exportieren …")) { ForEach(Array(SlideshowExporter.Preset.all.enumerated()), id: \.offset) { i, p in Button(p.name) { exportPreset = i; exportMovie() } } }
                        .menuStyle(.button).buttonStyle(.plain).fixedSize().padding(.horizontal, 10).padding(.vertical, 2).background(LinearGradient(colors: [.white, Theme.hex(0xD0D0D0)], startPoint: .top, endPoint: .bottom)).cornerRadius(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.45), lineWidth: 0.7)).disabled(ids.isEmpty || exporting != nil)
                }.padding(.horizontal, 10).frame(height: 30)
            }
            ZStack {
                Color(white: 0.2)
                ZStack { Color.black; if let id = selectedID { SlideStill(model: model, id: id) } else { Text(model.L("No slides", "Keine Folien")).foregroundColor(.gray).font(Theme.small) } }
                    .aspectRatio(4.0 / 3.0, contentMode: .fit).padding(.horizontal, 10)
                if let e = exporting { VStack { Spacer(); ProgressView(value: e).padding() } }
            }
            AquaBar(top: Theme.hex(0xD6D6D6), bottom: Theme.hex(0xB2B2B2)) {
                HStack(spacing: 8) {
                    Button { play() } label: { Image(systemName: "play.circle.fill").font(.system(size: 14)) }.buttonStyle(.plain).help(model.L("Play (⇧S)", "Abspielen (⇧S)")).disabled(ids.isEmpty)
                    Button { play() } label: { Image(systemName: "play.fill").font(.system(size: 11)) }.buttonStyle(.plain).help(model.L("Play with last settings", "Mit letzten Einstellungen abspielen")).disabled(ids.isEmpty)
                    Menu { Toggle(model.L("Repeat", "Wiederholen"), isOn: Binding(get: { s.loop }, set: { s.loop = $0; save() })); Toggle(model.L("Shuffle", "Zufällige Reihenfolge"), isOn: Binding(get: { s.shuffle }, set: { s.shuffle = $0; save() }))
                        Toggle(model.L("Show titles", "Titel anzeigen"), isOn: Binding(get: { s.showTitle }, set: { s.showTitle = $0; save() })) } label: { Image(systemName: "gearshape.fill") }.menuStyle(.borderlessButton).frame(width: 34)
                    Button { s.manualTiming = true; save(); play(record: true) } label: { Image(systemName: "stopwatch").font(.system(size: 12)) }.buttonStyle(.plain).help(model.L("Record timing…", "Zeiten aufnehmen …")).disabled(ids.isEmpty)
                    Spacer()
                    Text(model.L("\(ids.count) slides", "\(ids.count) Folien")).font(Theme.tiny)
                    Spacer()
                    Button { showSlides.toggle() } label: { Image(systemName: "list.bullet.rectangle") }.buttonStyle(.plain).help(model.L("Slide titles and durations", "Folientitel und Dauer"))
                        .popover(isPresented: $showSlides, arrowEdge: .top) { slideList.frame(width: 420, height: 380) }
                    Button { showSettings = true } label: { Image(systemName: "music.note") }.buttonStyle(.plain).help(model.L("Soundtrack", "Soundtrack"))
                }.padding(.horizontal, 10).frame(height: 28)
            }
        }
        .onAppear { load(); model.browserMode = .filmstrip; refreshBadges() }.onChange(of: container.id) { _ in load(); refreshBadges() }
        .onChange(of: ids) { _ in refreshBadges() }.onChange(of: s) { _ in refreshBadges() }
        .onDisappear { model.slideBadges = [:] }
    }
    var slideList: some View {
        VStack(spacing: 0) {
            List {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        TileThumb(model: model, id: id).frame(width: 70, height: 50)
                        VStack(alignment: .leading, spacing: 2) { Text(model.store.versions[id]?.name ?? "").font(Theme.small)
                            HStack { Text(model.L("Duration", "Dauer")).font(Theme.tiny); TextField("", value: Binding(get: { s.overrides[id]?.duration ?? s.timings[id] ?? s.displayTime }, set: { v in var o = s.overrides[id] ?? SlideOverride(); o.duration = v; s.overrides[id] = o; save() }), format: .number).textFieldStyle(.roundedBorder).frame(width: 50)
                                TextField(model.L("Title", "Titel"), text: Binding(get: { s.overrides[id]?.title ?? "" }, set: { v in var o = s.overrides[id] ?? SlideOverride(); o.title = v.isEmpty ? nil : v; s.overrides[id] = o; save() })).textFieldStyle(.roundedBorder) } }
                        Spacer()
                    }
                }.onMove { from, to in
                    var l = ids; l.move(fromOffsets: from, toOffset: to)
                    try? model.store.removeFromAlbum(container.id, container_members()); try? model.store.addToAlbum(container.id, l)
                }.onDelete { off in let l = ids; try? model.store.removeFromAlbum(container.id, off.map { l[$0] }) }
            }
            HStack { Button(model.L("Add Selected", "Auswahl hinzufügen")) { try? model.store.addToAlbum(container.id, model.selection) }.buttonStyle(AquaButtonStyle()).disabled(model.selection.isEmpty); Spacer() }.padding(8)
        }
    }
    func container_members() -> [ID] { model.store.containers[container.id]?.members ?? [] }
    func load() { s = model.store.document(container.id, as: SlideshowSettings.self) ?? SlideshowSettings(); loaded = container.id }
    var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(model.L("Preset", "Voreinstellung"), selection: Binding(get: { s.preset }, set: { n in if let p = SlideshowSettings.presets.first(where: { $0.0 == n }) { var x = p.1; x.songs = s.songs; x.overrides = s.overrides; x.timings = s.timings; s = x; save() } })) { ForEach(SlideshowSettings.presets, id: \.0) { Text($0.0).tag($0.0) } }
            Picker(model.L("Theme", "Thema"), selection: Binding(get: { s.style }, set: { s.style = $0; save() })) { ForEach(SlideshowStyle.allCases, id: \.self) { Text($0.title).tag($0) } }
            if s.style.fixedTransition { Text(model.L("This theme brings its own transitions; they cannot be changed.", "Dieses Thema bringt eigene Übergänge mit; sie lassen sich nicht ändern.")).font(Theme.tiny).foregroundColor(.gray) }
            else { Picker(model.L("Transition", "Übergang"), selection: Binding(get: { s.transition }, set: { s.transition = $0; save() })) { Text("Dissolve").tag("Dissolve"); Text("Fade through black").tag("Fade") } }
            Stepper(model.L("Each slide: ", "Jede Folie: ") + String(format: "%.1f s", s.displayTime), value: Binding(get: { s.displayTime }, set: { s.displayTime = $0; save() }), in: 1...30, step: 0.5)
            Stepper(model.L("Transition: ", "Übergang: ") + String(format: "%.1f s", s.fadeTime), value: Binding(get: { s.fadeTime }, set: { s.fadeTime = $0; save() }), in: 0...5, step: 0.25)
            HStack { Text(model.L("Background", "Hintergrund")).font(Theme.tiny); Slider(value: Binding(get: { s.background }, set: { s.background = $0; save() }), in: 0...1).frame(width: 120) }
            Toggle(model.L("Repeat", "Wiederholen"), isOn: Binding(get: { s.loop }, set: { s.loop = $0; save() })); Toggle(model.L("Shuffle", "Zufällige Reihenfolge"), isOn: Binding(get: { s.shuffle }, set: { s.shuffle = $0; save() })); Toggle(model.L("Show titles", "Titel anzeigen"), isOn: Binding(get: { s.showTitle }, set: { s.showTitle = $0; save() }))
            Toggle(model.L("Manual timing (use recorded times)", "Manuelle Zeiten (aufgenommene Zeiten nutzen)"), isOn: Binding(get: { s.manualTiming }, set: { s.manualTiming = $0; save() }))
            HStack { Button(model.L("Record Timing…", "Zeiten aufnehmen …")) { s.manualTiming = true; save(); play(record: true) }.buttonStyle(AquaButtonStyle()); if !s.timings.isEmpty { Button(model.L("Clear", "Löschen")) { s.timings = [:]; save() }.buttonStyle(AquaButtonStyle()); Text("\(s.timings.count)").font(Theme.tiny) } }
            Etched()
            Text(model.L("Soundtrack", "Soundtrack")).font(Theme.font(11, bold: true))
            ForEach(Array(s.songs.enumerated()), id: \.offset) { i, p in HStack { Image(systemName: "music.note"); Text(URL(fileURLWithPath: p).lastPathComponent).font(Theme.tiny).lineLimit(1); Spacer(); Button { s.songs.remove(at: i); save() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain) } }
            Button(model.L("Add Music…", "Musik hinzufügen …")) { let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = true; if p.runModal() == .OK { s.songs += p.urls.map(\.path); save() } }.buttonStyle(AquaButtonStyle())
            Toggle(model.L("Loop soundtrack", "Soundtrack wiederholen"), isOn: Binding(get: { s.loopSoundtrack }, set: { s.loopSoundtrack = $0; save() }))
            HStack { Text(model.L("Music", "Musik")).font(Theme.tiny); Slider(value: Binding(get: { s.musicVolume }, set: { s.musicVolume = $0; save() }), in: 0...1).frame(width: 90); Text(model.L("Video", "Video")).font(Theme.tiny); Slider(value: Binding(get: { s.videoVolume }, set: { s.videoVolume = $0; save() }), in: 0...1).frame(width: 90) }
            Toggle(model.L("Lower music during video clips", "Musik bei Videoclips absenken"), isOn: Binding(get: { s.duckMusicDuringVideo }, set: { s.duckMusicDuringVideo = $0; save() }))
            Etched()
            HStack { Button(model.L("Play (⇧S)", "Abspielen (⇧S)")) { play() }.buttonStyle(AquaButtonStyle()).disabled(ids.isEmpty)
                Picker("", selection: $exportPreset) { ForEach(Array(SlideshowExporter.Preset.all.enumerated()), id: \.offset) { Text($1.name).tag($0) } }.labelsHidden().frame(width: 130)
                Button(model.L("Export Movie…", "Film exportieren …")) { exportMovie() }.buttonStyle(AquaButtonStyle()).disabled(ids.isEmpty || exporting != nil) }
            if let e = exporting { ProgressView(value: e) }
            if !exportNote.isEmpty { Text(exportNote).font(Theme.tiny).foregroundColor(.gray) }
        }.font(Theme.small)
    }
    func exportMovie() {
        let p = NSSavePanel(); p.allowedContentTypes = [.quickTimeMovie]; p.nameFieldStringValue = container.name + ".mov"
        guard p.runModal() == .OK, let u = p.url else { return }
        exporting = 0; let list = ids, st = s, preset = SlideshowExporter.Preset.all[exportPreset], store = model.store
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try SlideshowExporter.export(list, settings: st, store: store, preset: preset, to: u) { v in DispatchQueue.main.async { exporting = v } } }
            DispatchQueue.main.async { exporting = nil
                switch r { case .success(let x): exportNote = String(format: "%.0f s – ", x.seconds) + x.note; NSWorkspace.shared.activateFileViewerSelecting([u]); case .failure(let e): model.alert = ("Slideshow", e.localizedDescription) } }
        }
    }
}

struct TileThumb: View {
    @ObservedObject var model: AppModel
    let id: ID
    @State private var img: NSImage?
    var body: some View { ZStack { Rectangle().fill(Color.black.opacity(0.25)); if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) } }.task(id: id) { if let v = model.store.versions[id] { img = await ThumbnailProvider.shared.image(for: v, store: model.store, px: 200) } } }
}

/// Large still of the selected slide for the preview area.
struct SlideStill: View {
    @ObservedObject var model: AppModel
    let id: ID
    @State private var img: NSImage?
    var body: some View {
        ZStack { if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit) } else { ProgressView() } }
            .task(id: id) { if let v = model.store.versions[id] { img = await ThumbnailProvider.shared.image(for: v, store: model.store, px: 1400) } }
    }
}
