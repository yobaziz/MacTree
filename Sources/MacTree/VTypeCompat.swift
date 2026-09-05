import Darwin
import Foundation
import AppKit

// Darwin exposes fsobj_type_t / VDIR / VREG / VLNK as the C enum `vtype`.
// Swift 6 no longer accepts UInt32(vtype) through the generic integer initializer,
// so provide the exact conversion used by FastScanner.
extension UInt32 {
    init(_ value: vtype) {
        self = UInt32(truncatingIfNeeded: value.rawValue)
    }
}

private func mtPermissionError(_ error: NSError) -> Bool {
    if error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM)) {
        return true
    }
    if error.domain == NSCocoaErrorDomain {
        let permissionCodes: Set<Int> = [
            CocoaError.Code.fileReadNoPermission.rawValue,
            CocoaError.Code.fileWriteNoPermission.rawValue
        ]
        if permissionCodes.contains(error.code) { return true }
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        return mtPermissionError(underlying)
    }
    return false
}

// MARK: - File actions that do not require Finder Automation permission

@MainActor
enum MTNativeFileActions {
    static func showInfo(_ node: MTNode, path: String) {
        let url = URL(fileURLWithPath: path)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSWorkspace.shared.icon(forFile: path)
        alert.messageText = node.name

        var lines: [String] = []
        lines.append("\(mtActionL("Kind", "Tür")): \(node.isDirectory ? mtActionL("Folder", "Klasör") : mtFileTypeLabel(node))")
        lines.append("\(mtActionL("Logical size", "Mantıksal boyut")): \(mtBytes(node.logicalSize))")
        lines.append("\(mtActionL("Allocated", "Ayrılan")): \(mtBytes(node.allocatedSize))")
        if node.isDirectory {
            lines.append("\(mtActionL("Files", "Dosyalar")): \(node.fileCount.formatted())")
        }
        if node.modifiedTime > 0 {
            let date = Date(timeIntervalSince1970: node.modifiedTime)
            lines.append("\(mtActionL("Modified", "Değiştirilme")): \(date.formatted(date: .numeric, time: .shortened))")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let permissions = attrs[.posixPermissions] as? NSNumber {
            lines.append(String(format: "%@: %03o", mtActionL("Permissions", "İzinler"), permissions.intValue & 0o777))
        }
        lines.append("")
        lines.append(url.path)

        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: mtActionL("Show in Finder", "Finder'da Göster"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func moveToTrash(_ node: MTNode, path rawPath: String) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        let path = url.path

        guard fm.fileExists(atPath: path) else {
            showTrashError(node: node, path: path,
                           detail: mtActionL("The item no longer exists at this location.", "Öğe artık bu konumda bulunmuyor."))
            return
        }

        if mtIsProtectedSystemPath(path) {
            showTrashError(node: node, path: path,
                           detail: mtActionL("macOS protects this system location.", "macOS bu sistem konumunu koruyor."))
            return
        }

        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = mtActionL("Move to Trash?", "Çöp Sepetine taşınsın mı?")
        let fileText = node.isDirectory
            ? "\(node.fileCount.formatted()) \(mtActionL("files", "dosya"))"
            : mtActionL("File", "Dosya")
        confirmation.informativeText = "\(node.name)\n\(mtBytes(node.allocatedSize)) • \(fileText)\n\n\(mtActionL("This item will be moved to the Trash.", "Bu öğe Çöp Sepetine taşınacak."))"
        confirmation.addButton(withTitle: mtActionL("Move to Trash", "Çöp Sepetine Taşı"))
        confirmation.addButton(withTitle: mtActionL("Cancel", "Vazgeç"))
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            var resultingURL: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resultingURL)
            NSWorkspace.shared.noteFileSystemChanged(url.deletingLastPathComponent().path)
            return
        } catch {
            let ns = error as NSError
            guard mtPermissionError(ns) else {
                showTrashError(node: node, path: path, detail: error.localizedDescription)
                return
            }

            // Finder AppleScript used to be the fallback here. That asks for
            // Automation privacy permission and is especially annoying for Debug
            // builds. Instead, request normal macOS administrator authentication and
            // move the item into the user's Trash directly.
            switch privilegedTrash(sourceURL: url) {
            case .success:
                NSWorkspace.shared.noteFileSystemChanged(url.deletingLastPathComponent().path)
            case .cancelled:
                return
            case .failure(let detail):
                showTrashError(node: node, path: path, detail: detail)
            }
        }
    }

    private enum PrivilegedTrashResult {
        case success
        case cancelled
        case failure(String)
    }

    private static func privilegedTrash(sourceURL: URL) -> PrivilegedTrashResult {
        let fm = FileManager.default
        let trashURL = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        do {
            try fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
        } catch {
            return .failure(error.localizedDescription)
        }

        let destination = uniqueTrashDestination(for: sourceURL.lastPathComponent, in: trashURL)
        let command = "/bin/mv " + shellQuote(sourceURL.path) + " " + shellQuote(destination.path)
        let source = "do shell script \"\(appleScriptString(command))\" with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            return .failure(mtActionL("Could not create the administrator request.", "Yönetici isteği oluşturulamadı."))
        }

        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = (errorInfo["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
            if number == -128 { return .cancelled }
            let message = (errorInfo["NSAppleScriptErrorMessage"] as? String)
                ?? mtActionL("Administrator operation failed.", "Yönetici işlemi başarısız oldu.")
            return .failure(message)
        }

        return fm.fileExists(atPath: sourceURL.path)
            ? .failure(mtActionL("The item is still present after the administrator operation.", "Yönetici işleminden sonra öğe hâlâ yerinde duruyor."))
            : .success
    }

    private static func uniqueTrashDestination(for name: String, in trashURL: URL) -> URL {
        let fm = FileManager.default
        var candidate = trashURL.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let original = URL(fileURLWithPath: name)
        let ext = original.pathExtension
        let stem = ext.isEmpty ? name : original.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let fileName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            candidate = trashURL.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func showTrashError(node: MTNode, path: String, detail: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = mtActionL("Could not move item to Trash", "Öğe Çöp Sepetine taşınamadı")
        alert.informativeText = "\(node.name)\n\n\(detail)\n\n\(mtActionL("The item may be protected by macOS or require additional permission.", "Öğe macOS tarafından korunuyor veya ek izin gerektiriyor olabilir."))"
        alert.addButton(withTitle: mtActionL("Show in Finder", "Finder'da Göster"))
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

private func mtIsProtectedSystemPath(_ path: String) -> Bool {
    if path == "/" || path == "/System" || path.hasPrefix("/System/") { return true }
    if path == "/bin" || path.hasPrefix("/bin/") { return true }
    if path == "/sbin" || path.hasPrefix("/sbin/") { return true }
    if path == "/usr" { return true }
    if path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/") { return true }
    if path == "/private" || path.hasPrefix("/private/etc/") || path.hasPrefix("/private/var/db/") || path.hasPrefix("/private/var/root/") {
        return true
    }
    return false
}

private func mtActionL(_ english: String, _ turkish: String) -> String {
    let language = UserDefaults.standard.string(forKey: "mactree.language") ?? "en"
    return language == "tr" ? turkish : english
}

