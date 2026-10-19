import AppKit
import RetroluxCore

/// AppleScript commands declared in resources/Retrolux.sdef (class names must match the sdef-less Cocoa mapping below).
func appDelegate() -> AppDelegate? { NSApp.delegate as? AppDelegate }

@objc(RLImportFilesCommand)
final class ImportFilesCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let raw = directParameter
        let items: [Any] = (raw as? [Any]) ?? (raw.map { [$0] } ?? [])
        let urls: [URL] = items.compactMap { ($0 as? URL) ?? ($0 as? String).map { URL(fileURLWithPath: $0) } }
        DispatchQueue.main.async { if let m = appDelegate()?.model { m.runImport(urls, ImportOptions()) } }
        return urls.count
    }
}

@objc(RLCountVersionsCommand)
final class CountVersionsCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { MainActor.assumeIsolated { appDelegate()?.model.store.versions.count ?? 0 } }
}

@objc(RLExportSelectionCommand)
final class ExportSelectionCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let m = appDelegate()?.model else { return 0 }
        let n = m.selection.count
        guard let dest = (directParameter as? URL) ?? (directParameter as? String).map({ URL(fileURLWithPath: $0) }) else { return 0 }
        let ids = m.selection, store = m.store
        DispatchQueue.global().async { _ = try? Exporter(store: store).export(ids, preset: ExportPreset.factory.first { $0.format == .jpeg } ?? ExportPreset.factory[0], to: dest) }
        return n
    }
}
