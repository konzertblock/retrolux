import SwiftUI
import AVKit
import AppKit
import RetroluxCore

/// Plays video/audio masters in the viewer with trim controls (original untouched; points are stored on the version).
final class MediaController: ObservableObject {
    let player = AVPlayer()
    @Published var duration = 0.0
    @Published var time = 0.0
    @Published var playing = false
    private var loaded: ID?
    private var observer: Any?
    var inPoint = 0.0, outPoint: Double?
    func load(_ v: Version, url: URL, store: LibraryStore) {
        guard loaded != v.id else { return }
        loaded = v.id
        let item = AVPlayerItem(url: url); player.replaceCurrentItem(with: item)
        inPoint = v.videoIn; outPoint = v.videoOut
        if let o = observer { player.removeTimeObserver(o) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.time = t.seconds; self.playing = self.player.rate != 0
            if let o = self.outPoint, t.seconds >= o { self.player.pause(); self.player.seek(to: CMTime(seconds: self.inPoint, preferredTimescale: 600)) }
        }
        player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600))
        Task { @MainActor in if let d = try? await item.asset.load(.duration) { self.duration = d.seconds } }
    }
    func toggle() { if player.rate == 0 { if let o = outPoint, time >= o { player.seek(to: CMTime(seconds: inPoint, preferredTimescale: 600)) }; player.play() } else { player.pause() } }
    func seek(_ t: Double) { player.seek(to: CMTime(seconds: t, preferredTimescale: 600)); time = t }
    func stop() { player.pause(); loaded = nil }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let v = AVPlayerView(); v.controlsStyle = .none; v.player = player; return v }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

struct MediaViewer: View {
    @ObservedObject var model: AppModel
    @StateObject private var mc = MediaController()
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.primaryMaster?.kind == .video { PlayerSurface(player: mc.player) }
                else { VStack(spacing: 8) { Image(systemName: "waveform").font(.system(size: 64)).foregroundColor(Theme.wellTextDim); Text(model.primaryMaster?.originalName ?? "").font(Theme.body).foregroundColor(Theme.wellText) } }
            }.background(Color.black)
            VStack(spacing: 4) {
                Slider(value: Binding(get: { mc.time }, set: { mc.seek($0) }), in: 0...max(0.1, mc.duration)).controlSize(.small)
                HStack(spacing: 8) {
                    Button { mc.toggle() } label: { Image(systemName: mc.playing ? "pause.fill" : "play.fill").frame(width: 24) }.buttonStyle(.plain)
                    Text(fmt(mc.time) + " / " + fmt(mc.duration)).font(Theme.tiny).monospacedDigit()
                    Spacer()
                    if model.primaryMaster?.kind == .video {
                        Button(model.L("Set In", "Anfang setzen")) { set(inPoint: mc.time) }.buttonStyle(AquaButtonStyle())
                        Button(model.L("Set Out", "Ende setzen")) { set(outPoint: mc.time) }.buttonStyle(AquaButtonStyle())
                        Button(model.L("Poster Frame", "Standbild")) { if let id = model.primary { try? model.store.setVideoTrim(id, inPoint: nil, outPoint: nil, poster: mc.time); model.thumbRevision[id, default: 0] += 1 } }.buttonStyle(AquaButtonStyle())
                        Button(model.L("Reset Trim", "Schnitt zurücksetzen")) { reset() }.buttonStyle(AquaButtonStyle())
                    }
                    if let v = model.primaryVersion, v.videoIn > 0 || v.videoOut != nil { Text(model.L("Trimmed ", "Gekürzt ") + fmt(v.videoIn) + "–" + fmt(v.videoOut ?? mc.duration)).font(Theme.tiny).foregroundColor(.orange) }
                }
            }.padding(8).background(Theme.chrome)
        }
        .onAppear(perform: load).onChange(of: model.primary) { _ in load() }.onDisappear { mc.stop() }
    }
    func fmt(_ t: Double) -> String { String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
    func load() { if let v = model.primaryVersion, let m = model.primaryMaster, m.kind != .image { mc.load(v, url: model.store.masterURL(m), store: model.store) } }
    func set(inPoint: Double? = nil, outPoint: Double? = nil) {
        guard let id = model.primary else { return }
        try? model.store.setVideoTrim(id, inPoint: inPoint, outPoint: outPoint)
        if let i = inPoint { mc.inPoint = i }; if let o = outPoint { mc.outPoint = o }
        model.status = model.L("Trim points stored; the original clip is unchanged", "Schnittpunkte gespeichert; das Original bleibt unverändert")
    }
    func reset() { guard let id = model.primary else { return }; try? model.store.update([id]) { $0.meta["video.in"] = nil; $0.meta["video.out"] = nil }; mc.inPoint = 0; mc.outPoint = nil }
}
