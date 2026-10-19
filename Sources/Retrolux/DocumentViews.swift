import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import RetroluxCore

enum PDFDocumentLoader {
    static func load(_ u: URL) -> PDFDocument? { PDFDocument(url: u) }
    static func printDocument(_ d: PDFDocument, window: NSWindow?) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo; info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        if let op = d.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: true) { if let w = window { op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil) } else { op.run() } }
    }
}

// MARK: - Print sheet
struct PrintSheet: View {
    @ObservedObject var model: AppModel
    @State private var layout = PrintLayout(name: "Standard", columns: 1, rows: 1, framed: false, labels: false, title: "Standard")
    @State private var o = PrintOptions()
    @State private var paper = 0
    @State private var rows = 1
    @State private var cols = 1
    @State private var page = 0
    @State private var moreOptions = true
    @AppStorage("printOptions") private var saved = ""
    static let builtIn = [PrintLayout(name: "Standard", columns: 1, rows: 1, framed: false, labels: false, title: "Standard"), PrintLayout(name: "ContactSheets", columns: 6, rows: 6, framed: false, labels: true, title: "Contact Sheets")]
    var ids: [ID] { model.selection.isEmpty ? model.shown.map(\.id) : model.selection }
    var effective: PrintLayout { var l = layout; l.columns = cols; l.rows = rows; return l }
    var paperIn: (w: Double, h: Double) { o.landscape ? (o.paperHeightIn, o.paperWidthIn) : (o.paperWidthIn, o.paperHeightIn) }
    var pageCount: Int { max(1, Int(ceil(Double(ids.count) / Double(max(1, rows * cols))))) }
    static let papers: [(String, Double, Double)] = [("US Letter", 8.5, 11), ("A4", 8.27, 11.69), ("A3", 11.69, 16.54), ("4 × 6 in", 4, 6)]

    func pick(_ l: PrintLayout) { layout = l; rows = l.rows; cols = l.columns }
    func miniIcon(_ l: PrintLayout) -> some View {
        VStack(spacing: 1) { ForEach(0..<min(l.rows, 5), id: \.self) { _ in HStack(spacing: 1) { ForEach(0..<min(l.columns, 5), id: \.self) { _ in Rectangle().fill(Color(red: 0.35, green: 0.5, blue: 0.75)) } } } }
            .padding(3).frame(width: 34, height: 28).background(Color.white).overlay(Rectangle().stroke(Color.black.opacity(0.4), lineWidth: 0.5))
    }
    func presetRow(_ l: PrintLayout) -> some View {
        HStack(spacing: 8) { miniIcon(l); Text(l.title).font(Theme.small); Spacer() }.padding(.horizontal, 8).frame(height: 36)
            .background(layout.name == l.name ? Theme.sourceSelected.opacity(0.9) : Color.clear).foregroundColor(layout.name == l.name ? .white : .black).contentShape(Rectangle()).onTapGesture { pick(l) }
    }
    func pill(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double, _ unit: String = "in.") -> some View {
        HStack { Text(title).font(Theme.tiny).frame(width: 84, alignment: .trailing)
            HStack(spacing: 0) {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: { Image(systemName: "arrowtriangle.left.fill").font(.system(size: 6)).frame(width: 12, height: 16) }.buttonStyle(.plain)
                Text(String(format: "%.2f", value.wrappedValue)).font(Theme.tiny).frame(width: 40)
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 6)).frame(width: 12, height: 16) }.buttonStyle(.plain)
            }.foregroundColor(Color(white: 0.4)).background(LinearGradient(colors: [.white, Theme.hex(0xE2E2E2)], startPoint: .top, endPoint: .bottom)).clipShape(Capsule()).overlay(Capsule().stroke(Color.black.opacity(0.4), lineWidth: 0.7))
            Text(unit).font(Theme.tiny) }
    }
    func intPill(_ title: String, _ value: Binding<Int>) -> some View {
        HStack { Text(title).font(Theme.tiny).frame(width: 84, alignment: .trailing)
            HStack(spacing: 0) {
                Button { value.wrappedValue = max(1, value.wrappedValue - 1) } label: { Image(systemName: "arrowtriangle.left.fill").font(.system(size: 6)).frame(width: 12, height: 16) }.buttonStyle(.plain)
                Text("\(value.wrappedValue)").font(Theme.tiny).frame(width: 40)
                Button { value.wrappedValue = min(12, value.wrappedValue + 1) } label: { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 6)).frame(width: 12, height: 16) }.buttonStyle(.plain)
            }.foregroundColor(Color(white: 0.4)).background(LinearGradient(colors: [.white, Theme.hex(0xE2E2E2)], startPoint: .top, endPoint: .bottom)).clipShape(Capsule()).overlay(Capsule().stroke(Color.black.opacity(0.4), lineWidth: 0.7)) }
    }
    func section(_ t: String) -> some View { Text(t).font(Theme.font(11, bold: true)).padding(.top, 8) }

    var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                section(model.L("Printer", "Drucker"))
                HStack { Text(model.L("Printer:", "Drucker:")).font(Theme.tiny).frame(width: 84, alignment: .trailing); Text(model.L("System dialog", "Systemdialog")).font(Theme.tiny).foregroundColor(.gray) }
                HStack { Text(model.L("Paper Size:", "Papier:")).font(Theme.tiny).frame(width: 84, alignment: .trailing)
                    Picker("", selection: $paper) { ForEach(Self.papers.indices, id: \.self) { Text(Self.papers[$0].0).tag($0) } }.labelsHidden().onChange(of: paper) { p in o.paperWidthIn = Self.papers[p].1; o.paperHeightIn = Self.papers[p].2; page = 0 } }
                section(model.L("Layout", "Layout"))
                HStack { Text(model.L("Orientation:", "Ausrichtung:")).font(Theme.tiny).frame(width: 84, alignment: .trailing)
                    Picker("", selection: $o.landscape) { Text(model.L("Portrait", "Hochformat")).tag(false); Text(model.L("Landscape", "Querformat")).tag(true) }.labelsHidden() }
                intPill(model.L("Rows:", "Zeilen:"), $rows); intPill(model.L("Columns:", "Spalten:"), $cols)
                pill(model.L("Spacing:", "Abstand:"), $o.gapIn, 0...1, 0.01)
                section(model.L("Margins", "Ränder"))
                pill(model.L("Margin:", "Rand:"), $o.margin, 0...2, 0.05); pill(model.L("Border:", "Rahmen:"), $o.border, 0...1, 0.05)
                section(model.L("Rendering", "Wiedergabe"))
                HStack { Text(model.L("Resolution:", "Auflösung:")).font(Theme.tiny).frame(width: 84, alignment: .trailing); Stepper("\(Int(o.dpi)) dpi", value: $o.dpi, in: 100...600, step: 20).font(Theme.tiny) }
                section(model.L("Print information", "Druckinformationen"))
                VStack(alignment: .leading, spacing: 2) { Toggle(model.L("Name", "Name"), isOn: $o.showName); Toggle(model.L("Date", "Datum"), isOn: $o.showDate); Toggle(model.L("Caption", "Beschriftung"), isOn: $o.showCaption); Toggle(model.L("EXIF (aperture, time, ISO)", "EXIF (Blende, Zeit, ISO)"), isOn: $o.showExif); Toggle(model.L("Page numbers", "Seitenzahlen"), isOn: $o.pageNumbers) }.font(Theme.tiny).padding(.leading, 8)
                TextField(model.L("Header text", "Kopfzeile"), text: $o.header).textFieldStyle(.roundedBorder); TextField(model.L("Footer text", "Fußzeile"), text: $o.footer).textFieldStyle(.roundedBorder); TextField(model.L("Watermark text", "Wasserzeichen-Text"), text: $o.watermark).textFieldStyle(.roundedBorder)
                Text(model.L("Colors are printed as sRGB images; the printer profile is applied by the print system.", "Farben werden als sRGB-Bilder gedruckt; das Druckerprofil wendet das Drucksystem an.")).font(Theme.font(9)).foregroundColor(.gray)
            }.padding(10)
        }.background(Theme.hex(0xD6D6D6))
    }

    var preview: some View {
        GeometryReader { g in
            let pw = paperIn.w, ph = paperIn.h
            let avail = CGSize(width: g.size.width - 80, height: g.size.height - 70)
            let sc = min(avail.width / pw, avail.height / ph)
            let W = pw * sc, H = ph * sc
            ZStack(alignment: .topLeading) {
                Theme.hex(0xB9B9B9)
                VStack(spacing: 0) {
                    HStack(spacing: 0) { Color.clear.frame(width: 20, height: 18); ZStack(alignment: .topLeading) { Rectangle().fill(Theme.hex(0xEDEDED)).frame(width: W, height: 18); ForEach(0..<Int(pw), id: \.self) { i in Text("\(i + 1)").font(Theme.font(8)).offset(x: CGFloat(i + 1) * sc + 2, y: 3); Rectangle().fill(Color.gray).frame(width: 0.5, height: 8).offset(x: CGFloat(i + 1) * sc, y: 10) } }.frame(width: W, height: 18); Spacer() }
                    HStack(spacing: 0) {
                        ZStack(alignment: .topLeading) { Rectangle().fill(Theme.hex(0xEDEDED)).frame(width: 20, height: H); ForEach(0..<Int(ph), id: \.self) { i in Text("\(i + 1)").font(Theme.font(8)).offset(x: 6, y: CGFloat(i + 1) * sc - 10); Rectangle().fill(Color.gray).frame(width: 8, height: 0.5).offset(x: 12, y: CGFloat(i + 1) * sc) } }.frame(width: 20, height: H)
                        pageView(W: W, H: H, sc: sc).frame(width: W, height: H).shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                        Spacer()
                    }
                    Spacer()
                }.padding(.leading, 30).padding(.top, 12)
            }
        }
    }
    func pageView(W: CGFloat, H: CGFloat, sc: CGFloat) -> some View {
        let m = CGFloat(o.margin) * sc, per = max(1, rows * cols), gap = CGFloat(o.gapIn) * sc
        let cw = (W - 2 * m - gap * CGFloat(cols - 1)) / CGFloat(cols), ch = (H - 2 * m - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let slice = Array(ids.dropFirst(page * per).prefix(per))
        return ZStack(alignment: .topLeading) {
            Color.white
            ForEach(0..<(rows * cols), id: \.self) { i in
                let r = i / cols, c = i % cols
                ZStack {
                    Rectangle().stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
                    if i < slice.count, let v = model.store.versions[slice[i]] { ThumbView(model: model, v: v, size: max(40, min(cw, ch * 4 / 3))).frame(width: cw, height: ch).clipped() }
                }.frame(width: cw, height: ch).offset(x: m + CGFloat(c) * (cw + gap), y: m + CGFloat(r) * (ch + gap))
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView { VStack(spacing: 0) {
                        ForEach(Self.builtIn) { presetRow($0) }
                        Text(model.L("CUSTOM PRESETS", "EIGENE VOREINSTELLUNGEN")).font(Theme.font(9, bold: true)).foregroundColor(Theme.hex(0x666666)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 8)
                        ForEach(PrintLayout.presets) { presetRow($0) }
                    } }.frame(height: 220).background(Theme.hex(0xC4C4C4))
                    Etched()
                    if moreOptions { settings }
                    else { Spacer() }
                }.frame(width: 270)
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
                VStack(spacing: 0) {
                    preview
                    HStack(spacing: 14) {
                        Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.buttonStyle(AquaButtonStyle()).disabled(page == 0)
                        Text(model.L("\(ids.count) Photos: \(pageCount) Page\(pageCount == 1 ? "" : "s") – \(Self.papers[min(paper, 3)].0) (\(String(format: "%.4g", paperIn.w))×\(String(format: "%.4g", paperIn.h)) in.)", "\(ids.count) Fotos: \(pageCount) Seite\(pageCount == 1 ? "" : "n") – \(Self.papers[min(paper, 3)].0) (\(String(format: "%.4g", paperIn.w))×\(String(format: "%.4g", paperIn.h)) in.)")).font(Theme.small)
                        Button { page = min(pageCount - 1, page + 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(AquaButtonStyle()).disabled(page >= pageCount - 1)
                    }.padding(8).frame(maxWidth: .infinity).background(Theme.hex(0xC4C4C4))
                }
            }
            Etched()
            HStack {
                Button(moreOptions ? model.L("Fewer Options", "Weniger Optionen") : model.L("More Options", "Mehr Optionen")) { moreOptions.toggle() }.buttonStyle(AquaButtonStyle())
                Menu { Button(model.L("Reset Settings", "Einstellungen zurücksetzen")) { o = PrintOptions(); pick(Self.builtIn[0]); paper = 0 } } label: { Image(systemName: "gearshape.fill") }.menuStyle(.borderlessButton).frame(width: 34)
                Spacer()
                Button(model.L("Save PDF…", "PDF sichern …")) { save() }.buttonStyle(AquaButtonStyle())
                Button(model.L("Cancel", "Abbrechen")) { model.showPrint = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.cancelAction)
                Button(model.L("Print…", "Drucken …")) { remember(); model.showPrint = false; model.runPrint(layout: effective, options: o, directPrint: true) }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction)
            }.padding(10).background(Theme.chrome)
        }
        .frame(width: 1040, height: 700).background(Theme.chrome)
        .onAppear { if let d = saved.data(using: .utf8), let x = try? JSONDecoder().decode(PrintOptions.self, from: d) { o = x }; pick(layout) }
    }
    func remember() { if let d = try? JSONEncoder().encode(o), let s = String(data: d, encoding: .utf8) { saved = s } }
    func save() {
        remember(); let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = layout.name + ".pdf"
        guard p.runModal() == .OK, let u = p.url else { return }
        let list = ids, l = effective, opts = o
        DispatchQueue.global(qos: .userInitiated).async { _ = try? PrintRenderer.pdf(layout: l, versions: list, options: opts, store: model.store, to: u); DispatchQueue.main.async { model.showPrint = false; NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    }
}

// MARK: - Services (historical online services,…D04)
struct ServicesSheet: View {
    @ObservedObject var model: AppModel
    struct Service: Identifiable { let id: String; let name: String; let note: String; let button: String; let action: () -> Void; var secondary: (String, () -> Void)? = nil }
    var services: [Service] { [
        Service(id: "icloud", name: model.L("iCloud Drive Gallery (replaces MobileMe Gallery)", "iCloud-Drive-Galerie (ersetzt MobileMe-Galerie)"), note: model.L("MobileMe was shut down in 2012. The selected photos are written as a web gallery into iCloud Drive; share a link from Finder.", "MobileMe wurde 2012 eingestellt. Die gewählten Fotos werden als Webgalerie in iCloud Drive geschrieben; den Link teilst du im Finder."), button: model.L("Write Gallery to iCloud Drive", "Galerie nach iCloud Drive schreiben"), action: { model.showServices = false; model.shareICloud() }),
        Service(id: "share", name: model.L("Share… (replaces Facebook sharing)", "Teilen … (ersetzt Facebook-Freigabe)"), note: model.L("Opens the macOS Share menu (Messages, AirDrop, Mail, Notes and installed share extensions) with medium-size JPEGs. Location and people are not included.", "Öffnet das macOS-Teilen-Menü (Nachrichten, AirDrop, Mail, Notizen und installierte Erweiterungen) mit mittelgroßen JPEGs. Ort und Personen sind nicht enthalten."), button: model.L("Share Selection…", "Auswahl teilen …"), action: { model.showServices = false; model.shareSelection() }),
        Service(id: "flickr", name: "Flickr", note: model.L("No Flickr account or API key is configured. The selected photos are exported to a folder and Flickr's upload page opens in your browser.", "Kein Flickr-Konto und kein API-Schlüssel eingerichtet. Die gewählten Fotos werden in einen Ordner exportiert und Flickrs Upload-Seite öffnet sich im Browser."), button: model.L("Export Selected & Open in Browser", "Auswahl exportieren & im Browser öffnen"), action: { exportAndOpen("https://www.flickr.com/photos/upload") }),
        Service(id: "prints", name: model.L("Photo Prints (print-lab export)", "Fotoabzüge (Export für Fotolabor)"), note: model.L("There is no built-in print service. Export print-ready JPEGs at 300 ppi for a lab of your choice, or print directly.", "Es gibt keinen eingebauten Bestellservice. Exportiere druckfertige JPEGs mit 300 ppi für ein Fotolabor deiner Wahl oder drucke direkt."), button: model.L("Export for Print Lab…", "Für Fotolabor exportieren …"), action: { model.showServices = false; model.exportForPrintLab() }, secondary: (model.L("Print…", "Drucken …"), { model.showServices = false; model.showPrint = true })),
    ] }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.L("Sharing & Prints", "Teilen & Abzüge")).font(Theme.font(14, bold: true))
            Text(model.L("Nothing is published automatically and no success is ever simulated. This app only writes files or hands them to the macOS Share menu.", "Es wird nichts automatisch veröffentlicht und nie ein Erfolg vorgetäuscht. Diese App schreibt nur Dateien oder übergibt sie an das macOS-Teilen-Menü.")).font(Theme.tiny).foregroundColor(.gray)
            ForEach(services) { s in
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name).font(Theme.font(12, bold: true)); Text(s.note).font(Theme.tiny).fixedSize(horizontal: false, vertical: true)
                    HStack { Button(s.button, action: s.action).buttonStyle(AquaButtonStyle()).disabled(model.selection.isEmpty && s.id != "prints")
                        if let sec = s.secondary { Button(sec.0, action: sec.1).buttonStyle(AquaButtonStyle()) } }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8).background(Color.white.opacity(0.5)).cornerRadius(6)
            }
            HStack { Button(model.L("Create Web Gallery…", "Webgalerie erstellen …")) { model.showServices = false; model.newWebJournal() }.buttonStyle(AquaButtonStyle()); Spacer(); Button("OK") { model.showServices = false }.buttonStyle(AquaButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 560).background(Theme.chrome)
    }
    func exportAndOpen(_ url: String) {
        let n = model.selection.count
        let a = NSAlert(); a.messageText = model.L("Export \(n) photos for upload?", "\(n) Fotos zum Hochladen exportieren?"); a.informativeText = model.L("Target: a folder you choose; metadata: keywords, caption and credits are included, location and people are NOT. Nothing is uploaded by this app.", "Ziel: ein Ordner deiner Wahl; Metadaten: Schlagwörter, Beschriftung und Urheberangaben sind enthalten, Ort und Personen NICHT. Diese App lädt nichts hoch.")
        a.addButton(withTitle: model.L("Choose Folder…", "Ordner wählen …")); a.addButton(withTitle: model.L("Cancel", "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        guard p.runModal() == .OK, let dir = p.url else { return }
        var o = ExportOptions(); o.includeLocation = false; o.includePeople = false
        model.showServices = false
        model.runExport(ExportPreset.factory[4], folder: dir, naming: .versionName, original: false, options: o)
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
