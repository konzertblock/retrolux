import SwiftUI

/// Own-drawn, Snow-Leopard-style colour icons. Designed on a 32×32 grid; unknown names fall back to SF Symbols.
struct IconView: View {
    let name: String
    var size: CGFloat = 32
    @ObservedObject private var theme = IconTheme.shared
    private static let map: [String: String] = [
        "info.circle.fill": "inspector", "arrow.down.circle.fill": "import", "plus.rectangle.on.folder.fill": "new",
        "person.text.rectangle": "name", "tag.fill": "keywords", "envelope.fill": "email", "cloud.fill": "mobileme",
        "f.square.fill": "facebook", "circle.grid.2x1.fill": "flickr", "square.grid.3x2.fill": "browser",
        "rectangle.split.1x2.fill": "split", "photo.fill": "viewer", "person.crop.square.fill": "faces", "map.fill": "places",
        "magnifyingglass.circle.fill": "loupe", "arrow.up.left.and.arrow.down.right": "fullscreen", "square.and.arrow.up": "export", "share.tile": "share",
        "photo.on.rectangle": "photos", "flag": "flag", "xmark.circle": "reject", "trash": "trash", "folder": "folder",
        "camera.aperture": "project", "rectangle.stack": "album", "gearshape": "smart", "book": "book", "person.crop.circle": "facesSmall", "map": "placesSmall",
    ]
    static func known(_ n: String) -> Bool { map[n] != nil }
    var body: some View {
        if let k = Self.map[name], let img = theme.image(k) { Image(nsImage: img).interpolation(.high).frame(width: max(size, img.size.width), height: max(size, min(img.size.height, 40))) }
        else if let k = Self.map[name] { drawn(k).frame(width: 32, height: 32).scaleEffect(size / 32).frame(width: size, height: size) }
        else { Image(systemName: name).frame(width: size, height: size) }
    }

    static let cream = Color(red: 0.93, green: 0.87, blue: 0.69), creamEdge = Color(red: 0.6, green: 0.5, blue: 0.3)
    static let blue = Color(red: 0.25, green: 0.45, blue: 0.82)

    func window(_ fill: AnyView) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 2).fill(LinearGradient(colors: [.white, Color(white: 0.8)], startPoint: .top, endPoint: .bottom))
            fill.padding(.top, 5).padding(2)
            HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.gray).frame(width: 1.8, height: 1.8) } }.padding(.top, 1.5).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 3)
        }.overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.45), lineWidth: 0.7)).frame(width: 28, height: 24).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }
    func mountain() -> AnyView {
        AnyView(ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.35, green: 0.6, blue: 0.95), Color(red: 0.75, green: 0.88, blue: 1)], startPoint: .top, endPoint: .bottom)
            Path { p in p.move(to: .init(x: 2, y: 16)); p.addLine(to: .init(x: 12, y: 4)); p.addLine(to: .init(x: 17, y: 9)); p.addLine(to: .init(x: 20, y: 6)); p.addLine(to: .init(x: 26, y: 16)); p.closeSubpath() }.fill(Color(red: 0.4, green: 0.45, blue: 0.55)).frame(width: 28, height: 16)
            Rectangle().fill(Color(red: 0.35, green: 0.55, blue: 0.3)).frame(height: 5)
        })
    }
    func tile(_ top: Color, _ bottom: Color, @ViewBuilder _ c: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.4), lineWidth: 0.7)).overlay(c()).frame(width: 26, height: 26).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }
    func box(_ w: CGFloat = 22) -> some View {
        ZStack { RoundedRectangle(cornerRadius: 2).fill(Self.cream); RoundedRectangle(cornerRadius: 2).stroke(Self.creamEdge, lineWidth: 0.8)
            VStack(spacing: 0) { Rectangle().fill(Self.creamEdge.opacity(0.5)).frame(height: 0.8).padding(.top, 5); Spacer() }
            Capsule().fill(Self.creamEdge).frame(width: w * 0.3, height: 2).offset(y: 1) }.frame(width: w, height: w * 0.8)
    }
    @ViewBuilder func drawn(_ k: String) -> some View {
        switch k {
        case "inspector":
            ZStack { Circle().fill(RadialGradient(colors: [Color(red: 0.6, green: 0.7, blue: 1), Color(red: 0.2, green: 0.3, blue: 0.8)], center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: 18)).frame(width: 27, height: 27).overlay(Circle().stroke(Color(red: 0.1, green: 0.15, blue: 0.5), lineWidth: 0.8)).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                Text("i").font(.system(size: 19, weight: .bold, design: .serif)).italic().foregroundColor(.white) }
        case "import":
            Path { p in p.move(to: .init(x: 11, y: 3)); p.addLine(to: .init(x: 21, y: 3)); p.addLine(to: .init(x: 21, y: 14)); p.addLine(to: .init(x: 27, y: 14)); p.addLine(to: .init(x: 16, y: 29)); p.addLine(to: .init(x: 5, y: 14)); p.addLine(to: .init(x: 11, y: 14)); p.closeSubpath() }
                .fill(LinearGradient(colors: [Color(red: 0.75, green: 0.85, blue: 0.97), Color(red: 0.3, green: 0.45, blue: 0.7)], startPoint: .top, endPoint: .bottom)).overlay(Path { p in p.move(to: .init(x: 11, y: 3)); p.addLine(to: .init(x: 21, y: 3)); p.addLine(to: .init(x: 21, y: 14)); p.addLine(to: .init(x: 27, y: 14)); p.addLine(to: .init(x: 16, y: 29)); p.addLine(to: .init(x: 5, y: 14)); p.addLine(to: .init(x: 11, y: 14)); p.closeSubpath() }.stroke(Color(red: 0.2, green: 0.3, blue: 0.5), lineWidth: 0.8))
        case "new":
            ZStack { RoundedRectangle(cornerRadius: 2).fill(Self.blue).frame(width: 17, height: 17).offset(x: -3, y: -5); RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.85, green: 0.5, blue: 0.25)).frame(width: 12, height: 15).offset(x: 6, y: -6); box(22).offset(y: 4)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 6)).foregroundColor(.black).offset(x: 14, y: 8) }
        case "name":
            ZStack { RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.92)).frame(width: 20, height: 24).overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color.gray, lineWidth: 0.8))
                Circle().fill(Color(white: 0.45)).frame(width: 9, height: 9).offset(y: -4); Capsule().fill(Color(white: 0.45)).frame(width: 15, height: 9).offset(y: 6) }
        case "keywords":
            ZStack { RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [Color(red: 0.98, green: 0.93, blue: 0.75), Color(red: 0.88, green: 0.78, blue: 0.5)], startPoint: .top, endPoint: .bottom)).frame(width: 28, height: 17).overlay(RoundedRectangle(cornerRadius: 4).stroke(Self.creamEdge, lineWidth: 0.8))
                Circle().fill(Color(red: 0.85, green: 0.35, blue: 0.35)).frame(width: 5, height: 5).offset(x: -9); VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Self.creamEdge).frame(width: 11, height: 1.2) } }.offset(x: 4) }.rotationEffect(.degrees(-8))
        case "email":
            ZStack { Rectangle().fill(Color.white).frame(width: 23, height: 27).overlay(Rectangle().stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 1.5])))
                Rectangle().fill(LinearGradient(colors: [Color(red: 0.3, green: 0.55, blue: 0.9), Color(red: 0.7, green: 0.85, blue: 1)], startPoint: .top, endPoint: .bottom)).frame(width: 17, height: 21)
                Path { p in p.move(to: .init(x: 2, y: 2)); p.addLine(to: .init(x: 8, y: 10)); p.addLine(to: .init(x: 14, y: 4)); p.addLine(to: .init(x: 10, y: 14)); p.closeSubpath() }.fill(Color(red: 0.5, green: 0.35, blue: 0.2)).frame(width: 16, height: 16).offset(y: 1) }
        case "mobileme":
            tile(Color(red: 0.45, green: 0.7, blue: 0.95), Color(red: 0.2, green: 0.45, blue: 0.85)) { Image(systemName: "cloud.fill").font(.system(size: 17)).foregroundColor(.white) }
        case "facebook":
            tile(Color(red: 0.35, green: 0.45, blue: 0.7), Color(red: 0.2, green: 0.3, blue: 0.55)) { Text("f").font(.system(size: 24, weight: .heavy)).foregroundColor(.white).offset(x: 3, y: 2) }
        case "flickr":
            tile(Color(white: 0.97), Color(white: 0.82)) { HStack(spacing: 1) { Circle().fill(Color(red: 0.2, green: 0.4, blue: 0.9)).frame(width: 9, height: 9); Circle().fill(Color(red: 1, green: 0.1, blue: 0.5)).frame(width: 9, height: 9) } }
        case "browser":
            window(AnyView(VStack(spacing: 1) { ForEach(0..<5, id: \.self) { _ in HStack(spacing: 1) { ForEach(0..<6, id: \.self) { _ in Rectangle().fill(Color(red: 0.4, green: 0.5, blue: 0.9)) } } } }.padding(1).background(Color(red: 0.8, green: 0.85, blue: 1))))
        case "split":
            window(AnyView(VStack(spacing: 1) { mountain().frame(height: 11); HStack(spacing: 1) { ForEach(0..<6, id: \.self) { _ in Rectangle().fill(Color(red: 0.4, green: 0.5, blue: 0.9)) } }.frame(height: 4) }))
        case "viewer": window(mountain())
        case "faces":
            window(AnyView(ZStack { LinearGradient(colors: [Color(red: 0.8, green: 0.5, blue: 0.95), Color(red: 0.5, green: 0.3, blue: 0.8)], startPoint: .top, endPoint: .bottom)
                Circle().fill(.black).frame(width: 9, height: 9).offset(y: -3); Capsule().fill(.black).frame(width: 17, height: 11).offset(y: 6) }.clipped()))
        case "places":
            ZStack(alignment: .bottomTrailing) {
                window(AnyView(ZStack { LinearGradient(colors: [Color(red: 0.75, green: 0.85, blue: 0.6), Color(red: 0.6, green: 0.8, blue: 0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(.red).frame(width: 4, height: 4).offset(x: -6, y: -3); Circle().fill(.red).frame(width: 4, height: 4).offset(x: 3, y: -5); Circle().fill(.red).frame(width: 4, height: 4).offset(x: -2, y: 4) }))
                Circle().fill(Color(red: 0.25, green: 0.7, blue: 0.25)).frame(width: 13, height: 13).overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundColor(.white)).offset(x: 2, y: 3)
            }
        case "loupe":
            ZStack { Ellipse().fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.6)], startPoint: .top, endPoint: .bottom)).frame(width: 26, height: 14).offset(y: 8)
                Ellipse().fill(Color(white: 0.2)).frame(width: 22, height: 11).offset(y: 1); Ellipse().fill(Color(red: 0.75, green: 0.85, blue: 1).opacity(0.9)).frame(width: 15, height: 7).offset(y: 1)
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.15)).frame(width: 14, height: 9).offset(y: -9) }
        case "fullscreen":
            ZStack { Image(systemName: "arrow.up.left").font(.system(size: 17, weight: .black)).offset(x: -5, y: -5); Image(systemName: "arrow.down.right").font(.system(size: 17, weight: .black)).offset(x: 5, y: 5) }.foregroundColor(Color(white: 0.4))
        case "share": tile(Color(red: 0.45, green: 0.65, blue: 0.95), Color(red: 0.2, green: 0.4, blue: 0.8)) { Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .bold)).foregroundColor(.white) }
        case "export": Image(systemName: "square.and.arrow.up").font(.system(size: 22, weight: .semibold)).foregroundColor(Self.blue)
        case "photos": tile(Color(red: 0.6, green: 0.8, blue: 1), Color(red: 0.3, green: 0.5, blue: 0.85)) { Image(systemName: "photo").font(.system(size: 13)).foregroundColor(.white) }.scaleEffect(0.95)
        case "flag":
            ZStack { Rectangle().fill(Color(red: 0.55, green: 0.35, blue: 0.1)).frame(width: 2.5, height: 26).offset(x: -8)
                Path { p in p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 18, y: 3)); p.addLine(to: .init(x: 14, y: 8)); p.addLine(to: .init(x: 18, y: 13)); p.addLine(to: .init(x: 0, y: 12)); p.closeSubpath() }.fill(Color(red: 1, green: 0.6, blue: 0.1)).frame(width: 18, height: 13).offset(x: 1, y: -6) }
        case "reject": Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundColor(Color(red: 0.8, green: 0.25, blue: 0.2))
        case "trash":
            ZStack { RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Color(white: 0.6), Color(white: 0.3)], startPoint: .leading, endPoint: .trailing)).frame(width: 18, height: 22).offset(y: 3)
                Capsule().fill(Color(white: 0.5)).frame(width: 22, height: 4).offset(y: -9); VStack(spacing: 2) { ForEach(0..<2, id: \.self) { _ in Rectangle().fill(Color.black.opacity(0.35)).frame(width: 12, height: 1.5) } }.offset(y: 4) }
        case "folder":
            ZStack(alignment: .topLeading) { RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.4, green: 0.65, blue: 0.9)).frame(width: 12, height: 6).offset(y: 1)
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Color(red: 0.7, green: 0.88, blue: 1), Color(red: 0.35, green: 0.6, blue: 0.9)], startPoint: .top, endPoint: .bottom)).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(red: 0.15, green: 0.35, blue: 0.65), lineWidth: 0.8)).frame(width: 28, height: 20).offset(y: 5) }.frame(width: 28, height: 26)
        case "project": box(26)
        case "album": ZStack { RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.85)).frame(width: 20, height: 20).offset(x: 3, y: -3); box(24).offset(y: 3) }
        case "smart": ZStack { box(24); Image(systemName: "gearshape.fill").font(.system(size: 11)).foregroundColor(Color(red: 0.3, green: 0.45, blue: 0.7)).offset(x: 6, y: 5) }
        case "book": RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.95, green: 0.7, blue: 0.3)).frame(width: 22, height: 24).overlay(Image(systemName: "photo").font(.system(size: 10)).foregroundColor(.white))
        case "facesSmall": tile(Color(red: 0.8, green: 0.5, blue: 0.95), Color(red: 0.5, green: 0.3, blue: 0.8)) { Image(systemName: "person.fill").font(.system(size: 14)).foregroundColor(.black) }
        case "placesSmall": tile(Color(red: 0.75, green: 0.9, blue: 0.6), Color(red: 0.55, green: 0.8, blue: 0.9)) { Image(systemName: "mappin").font(.system(size: 13, weight: .bold)).foregroundColor(.red) }
        default: EmptyView()
        }
    }
}
