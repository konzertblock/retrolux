import SwiftUI
import AppKit
import RetroluxCore

/// Snow-Leopard-era look drawn from scratch: light grey Aqua chrome, dark image wells.
private struct HUDDarkKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var hudDark: Bool { get { self[HUDDarkKey.self] } set { self[HUDDarkKey.self] = newValue } } }

enum Theme {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color { Color(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, opacity: a) }
    static let chrome = hex(0xE8E8E8)
    static let chromeDark = hex(0xD2D2D2)
    static let toolbarTop = hex(0xD1D4D3), toolbarBottom = hex(0xB4B6B6), toolbarLine = hex(0x6F6F6F)  // sampled from reference screenshots
    static let sourceList = hex(0xC9CBCB), sourceSelected = hex(0x83868E)
    static let inspector = hex(0xE1E1E1), brickHeaderTop = hex(0xF1F1F1), brickHeaderBottom = hex(0xD5D5D5)
    static let etchLight = Color.white.opacity(0.85), etchDark = Color.black.opacity(0.25)
    static let well = hex(0x404040), wellDark = hex(0x2B2B2B), wellText = hex(0xD8D8D8), wellTextDim = hex(0x9A9A9A)
    static let accent = hex(0x4D88D8)
    static let labelColors: [Color] = [.clear, hex(0xD9453B), hex(0xE98B2B), hex(0xE3C93B), hex(0x6FB04A), hex(0x4B86D6), hex(0x9660BE), hex(0x8A8A8A)]
    static let selectedBar = hex(0x6B9AD8)

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        if NSFont(name: "LucidaGrande", size: size) != nil { return .custom(bold ? "LucidaGrande-Bold" : "LucidaGrande", size: size) }
        return .system(size: size, weight: bold ? .bold : .regular)
    }
    static let small = font(11), tiny = font(10), body = font(12), title = font(12, bold: true)
}

struct AquaBar<Content: View>: View {
    var top: Color = Theme.toolbarTop, bottom: Color = Theme.toolbarBottom, line: Color = Theme.toolbarLine, bottomLine = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .background(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .top))
            .overlay(alignment: .bottom) { if bottomLine { Rectangle().fill(line).frame(height: 1) } }
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.6)).frame(height: 1) }
    }
}

/// Aqua-style slider: grey groove, round knob; double-click resets to the default. Reports editing start/end for undo coalescing.
struct AquaSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var def: Double
    var onEdit: (Bool) -> Void = { _ in }
    var label = ""
    @State private var dragging = false
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, span = range.upperBound - range.lowerBound
            let frac = span > 0 ? min(1, max(0, (value - range.lowerBound) / span)) : 0
            let x = 6 + (w - 12) * frac
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.12)], startPoint: .top, endPoint: .bottom)).frame(height: 4)
                    .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 0.5).offset(y: 0.5))
                Circle().fill(RadialGradient(colors: [.white, Theme.hex(0xC4C4C4)], center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: 8))
                    .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .frame(width: 11, height: 11).offset(x: x - 5.5)
            }
            .frame(height: g.size.height)
            .contentShape(Rectangle())
            .accessibilityElement().accessibilityLabel(label).accessibilityValue(Text(String(format: "%.2f", value)))
            .accessibilityAdjustableAction { dir in let st = (range.upperBound - range.lowerBound) / 50; onEdit(true); value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? st : -st))); onEdit(false) }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    if !dragging { dragging = true; onEdit(true) }
                    let f = min(1, max(0, (d.location.x - 6) / max(1, w - 12)))
                    value = range.lowerBound + f * span
                }
                .onEnded { _ in dragging = false; onEdit(false) })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onEdit(true); value = def; onEdit(false) })
        }
        .frame(height: 16)
    }
}

struct AquaButtonStyle: ButtonStyle {
    var dark = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.small).foregroundColor(dark ? Theme.wellText : .black)
            .padding(.horizontal, 8).frame(minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: configuration.isPressed ? [Theme.hex(0xB5B5B5), Theme.hex(0xD5D5D5)] : (dark ? [Theme.hex(0x6A6A6A), Theme.hex(0x4A4A4A)] : [.white, Theme.hex(0xC9C9C9)]), startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.5), lineWidth: 0.75))
    }
}

struct Etched: View { var vertical = false
    var body: some View {
        if vertical { HStack(spacing: 0) { Rectangle().fill(Theme.etchDark).frame(width: 1); Rectangle().fill(Theme.etchLight).frame(width: 1) } }
        else { VStack(spacing: 0) { Rectangle().fill(Theme.etchDark).frame(height: 1); Rectangle().fill(Theme.etchLight).frame(height: 1) } }
    }
}

struct StarsView: View {
    var rating: Int
    var body: some View {
        if rating < 0 { Text("✕").font(Theme.tiny).foregroundColor(.red) }
        else { HStack(spacing: 0) { ForEach(0..<max(0, rating), id: \.self) { _ in Text("★").font(.system(size: 9)).foregroundColor(.white).shadow(color: .black, radius: 1) } } }
    }
}
