import SwiftUI
import AppKit
import Darwin

struct MTNode: Identifiable, Hashable, Sendable {
    let id: Int
    let parentID: Int?
    let name: String
    /// Directories keep their absolute path. Files intentionally keep this empty
    /// to avoid storing the same parent path hundreds of thousands of times.
    let path: String
    let isDirectory: Bool
    let logicalSize: UInt64
    let allocatedSize: UInt64
    let fileCount: UInt64
    let modifiedTime: TimeInterval
    var children: [Int]
}

struct MTProgress: Sendable {
    let items: UInt64
    let files: UInt64
    let logical: UInt64
    let allocated: UInt64
    let currentPath: String
    let elapsed: TimeInterval
}

struct MTSnapshot: Sendable {
    let nodes: [MTNode]
    let rootID: Int
    let items: UInt64
    let files: UInt64
    let logical: UInt64
    let allocated: UInt64
    let elapsed: TimeInterval
}

// MARK: - Paths / permissions

func mtResolvedPath(_ nodeID: Int, nodes: [MTNode]) -> String {
    guard nodes.indices.contains(nodeID) else { return "" }
    let node = nodes[nodeID]
    if !node.path.isEmpty { return node.path }

    guard let parentID = node.parentID, nodes.indices.contains(parentID) else {
        return node.name
    }
    let parent = nodes[parentID]
    let parentPath = !parent.path.isEmpty ? parent.path : mtResolvedPath(parentID, nodes: nodes)
    if parentPath == "/" { return "/" + node.name }
    if parentPath.isEmpty { return node.name }
    return parentPath + "/" + node.name
}

func mtResolvedPath(_ node: MTNode, nodes: [MTNode]) -> String {
    mtResolvedPath(node.id, nodes: nodes)
}

/// Best-effort Full Disk Access probe. TCC itself is protected, while Mail,
/// Messages and Safari are useful fallbacks on machines where those folders exist.
func mtHasFullDiskAccess() -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        home + "/Library/Mail",
        home + "/Library/Messages",
        home + "/Library/Safari"
    ]

    for path in candidates where FileManager.default.fileExists(atPath: path) {
        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        if fd >= 0 {
            Darwin.close(fd)
            return true
        }
    }
    return false
}

// MARK: - Search

@MainActor
final class MTSearchModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var resultIDs: [Int] = []
    @Published private(set) var isSearching = false

    private var nodes: [MTNode] = []
    private var task: Task<Void, Never>?

    func setNodes(_ newNodes: [MTNode]) {
        task?.cancel()
        task = nil
        nodes = newNodes
        query = ""
        resultIDs = []
        isSearching = false
    }

    func search(_ text: String) {
        task?.cancel()
        query = text
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            resultIDs = []
            isSearching = false
            task = nil
            return
        }

        let snapshot = nodes
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let lowered = needle.lowercased()

            let ids = await Task.detached(priority: .utility) {
                var hits: [(Int, UInt64)] = []
                hits.reserveCapacity(750)

                for node in snapshot.dropFirst() {
                    if Task.isCancelled { return [Int]() }
                    let nameMatches = node.name.lowercased().contains(lowered)

                    var pathMatches = false
                    if !nameMatches {
                        if !node.path.isEmpty {
                            pathMatches = node.path.lowercased().contains(lowered)
                        } else if let parentID = node.parentID, snapshot.indices.contains(parentID) {
                            // The filename was already checked, so matching the parent directory
                            // is enough and avoids constructing a full path for every file.
                            pathMatches = snapshot[parentID].path.lowercased().contains(lowered)
                        }
                    }

                    if nameMatches || pathMatches {
                        hits.append((node.id, node.allocatedSize))
                        if hits.count >= 2500 { break }
                    }
                }

                hits.sort { $0.1 > $1.1 }
                return Array(hits.prefix(1000).map { $0.0 })
            }.value

            guard !Task.isCancelled, let self else { return }
            self.resultIDs = ids
            self.isSearching = false
            self.task = nil
        }
    }
}

// MARK: - File actions

enum MTFileActions {
    static func open(_ node: MTNode, path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func reveal(_ node: MTNode, path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openContainingFolder(_ node: MTNode, path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }

    static func copyPath(_ node: MTNode, path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func copyName(_ node: MTNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.name, forType: .string)
    }

    static func openTerminal(_ node: MTNode, path: String) {
        let target = node.isDirectory ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", target]
        try? process.run()
    }

    static func getInfo(_ node: MTNode, path: String) {
        let escaped = appleScriptEscaped(path)
        let script = "tell application \"Finder\" to open information window of (POSIX file \"\(escaped)\" as alias)"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    static func moveToTrash(_ node: MTNode, path rawPath: String) {
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        let path = url.path

        guard FileManager.default.fileExists(atPath: path) else {
            showTrashError(node: node, path: path, detail: mtL("The item no longer exists at this location."))
            return
        }

        let protectedRoots: Set<String> = ["/", "/System", "/bin", "/sbin", "/usr", "/private"]
        guard !protectedRoots.contains(path) else {
            showTrashError(node: node, path: path, detail: mtL("macOS protects this system location."))
            return
        }

        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = mtL("Move to Trash?")
        let fileText = node.isDirectory
            ? "\(node.fileCount.formatted()) \(mtL("files"))"
            : mtL("File")
        confirmation.informativeText = "\(node.name)\n\(mtBytes(node.allocatedSize)) • \(fileText)\n\n\(mtL("This item will be moved to the Trash."))"
        confirmation.addButton(withTitle: mtL("Move to Trash"))
        confirmation.addButton(withTitle: mtL("Cancel"))
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            NSWorkspace.shared.noteFileSystemChanged(url.deletingLastPathComponent().path)
            return
        } catch {
            let directError = error.localizedDescription
            if tryFinderTrash(path: path) {
                NSWorkspace.shared.noteFileSystemChanged(url.deletingLastPathComponent().path)
                return
            }
            showTrashError(node: node, path: path, detail: directError)
        }
    }

    /// Finder can request administrator authorization for some writable system-owned
    /// locations where FileManager simply returns EPERM/EACCES.
    private static func tryFinderTrash(path: String) -> Bool {
        let escaped = appleScriptEscaped(path)
        let source = "tell application \"Finder\" to delete (POSIX file \"\(escaped)\" as alias)"
        guard let script = NSAppleScript(source: source) else { return false }
        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func showTrashError(node: MTNode, path: String, detail: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = mtL("Could not move item to Trash")
        alert.informativeText = "\(node.name)\n\n\(detail)\n\n\(mtL("The item may be protected by macOS or require additional permission."))"
        alert.addButton(withTitle: mtL("Show in Finder"))
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

// MARK: - Semantic file categories

enum MTCategory: String, CaseIterable {
    case application = "Apps"
    case video = "Video"
    case image = "Images"
    case archive = "Archives"
    case audio = "Audio"
    case document = "Docs"
    case code = "Code / Dev"
    case database = "Database"
    case cache = "Cache"
    case appData = "App Data"
    case gameData = "Game Data"
    case config = "Config"
    case logs = "Logs"
    case temp = "Temp"
    case system = "System"
    case other = "Other"

    var color: Color {
        switch self {
        case .application: return Color(hue: 0.34, saturation: 0.70, brightness: 0.78)
        case .video: return Color(hue: 0.78, saturation: 0.66, brightness: 0.82)
        case .image: return Color(hue: 0.93, saturation: 0.68, brightness: 0.86)
        case .archive: return Color(hue: 0.08, saturation: 0.76, brightness: 0.88)
        case .audio: return Color(hue: 0.53, saturation: 0.66, brightness: 0.82)
        case .document: return Color(hue: 0.60, saturation: 0.68, brightness: 0.84)
        case .code: return Color(hue: 0.50, saturation: 0.62, brightness: 0.75)
        case .database: return Color(hue: 0.68, saturation: 0.56, brightness: 0.78)
        case .cache: return Color(hue: 0.14, saturation: 0.80, brightness: 0.88)
        case .appData: return Color(hue: 0.46, saturation: 0.58, brightness: 0.77)
        case .gameData: return Color(hue: 0.01, saturation: 0.70, brightness: 0.82)
        case .config: return Color(hue: 0.09, saturation: 0.44, brightness: 0.68)
        case .logs: return Color(hue: 0.60, saturation: 0.06, brightness: 0.56)
        case .temp: return Color(hue: 0.10, saturation: 0.68, brightness: 0.82)
        case .system: return Color(hue: 0.41, saturation: 0.58, brightness: 0.70)
        case .other: return Color(hue: 0.62, saturation: 0.10, brightness: 0.48)
        }
    }
}

func mtDirectCategory(_ node: MTNode, nodes: [MTNode]? = nil) -> MTCategory {
    let name = node.name.lowercased()

    if !node.isDirectory {
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "app", "appex", "xpc", "exe": return .application
        case "mp4", "mov", "mkv", "avi", "webm", "m4v", "mpeg", "mpg", "bik", "bink": return .video
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp", "svg", "icns": return .image
        case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso", "jar", "asar": return .archive
        case "mp3", "aac", "m4a", "wav", "flac", "ogg", "aiff", "bank", "caf": return .audio
        case "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "csv", "xls", "xlsx", "ppt", "pptx": return .document
        case "swift", "c", "cpp", "cc", "h", "hpp", "js", "ts", "py", "java", "kt", "rs", "go", "rb", "php", "css", "html", "sh", "frag", "vert", "glsl", "metal", "air", "wasm", "map": return .code
        case "db", "sqlite", "sqlite3", "realm", "mdb", "db-wal", "db-shm": return .database
        case "ini", "cfg", "conf", "plist", "yaml", "yml", "toml", "json", "xml", "strings", "stringsdict": return .config
        case "log": return .logs
        case "pak", "vpk", "wad", "pck", "bundle", "assets", "asset", "res", "ress", "resource", "dat", "bin", "obb", "unity3d", "forge": return .gameData
        case "dylib", "so", "framework", "kext", "metallib", "car", "mom", "momd", "nib", "storyboardc": return .system
        default: break
        }
    }

    let resolvedPath: String
    if !node.path.isEmpty {
        resolvedPath = node.path
    } else if let nodes {
        resolvedPath = mtResolvedPath(node.id, nodes: nodes)
    } else {
        resolvedPath = ""
    }
    let path = resolvedPath.lowercased()

    if node.isDirectory {
        if path.contains("/library/caches/") || name == "cache" || name == "caches" || name == "cacheddata" ||
            name == "code cache" || name == "gpucache" || name.hasSuffix(".cache") { return .cache }
        if path.contains("/library/logs/") || name == "log" || name == "logs" || name.hasSuffix(".log") { return .logs }
        if path.contains("/library/preferences/") || name == "preferences" || name == "config" || name == "configs" ||
            name == ".config" || name == "settings" { return .config }
        if name == "tmp" || name == "temp" || name == "temporary" || path.contains("/tmp/") { return .temp }
        if path.contains("/steamapps/common/") || path.contains("/games/") || name == "gamedata" || name == "game data" { return .gameData }
        if name.hasSuffix(".app") || name.hasSuffix(".appex") || name.hasSuffix(".xpc") { return .application }
        if path.contains("/library/application support/") || path.contains("/library/containers/") ||
            path.contains("/library/group containers/") || name == "application support" || name == "containers" ||
            name == "group containers" || name == "saved application state" { return .appData }
        if path.contains("/developer/") || path.contains("/deriveddata/") || path.contains("/sourcepackages/") ||
            name == "developer" || name == "deriveddata" || name == "sourcepackages" || name == "node_modules" ||
            name == ".gradle" || name == ".swiftpm" || name == ".npm" || name == ".cargo" { return .code }
        if path.contains("/system/") || path.contains("/library/frameworks/") || name.hasSuffix(".framework") || name == "coreservices" { return .system }
        if ["movies", "videos", "video"].contains(name) { return .video }
        if ["pictures", "images", "image", "photos"].contains(name) { return .image }
        if ["music", "audio", "sounds", "sound"].contains(name) { return .audio }
        if ["documents", "docs"].contains(name) { return .document }
        if ["database", "databases"].contains(name) { return .database }
        return .other
    }

    if path.contains("/library/caches/") || path.contains("/cache/") { return .cache }
    if path.contains("/library/logs/") { return .logs }
    if path.contains("/library/preferences/") { return .config }
    if path.contains("/tmp/") || path.contains("/temp/") { return .temp }
    if path.contains("/steamapps/common/") || path.contains("/games/") { return .gameData }
    if path.contains("/developer/") || path.contains("/deriveddata/") || path.contains("/sourcepackages/") ||
        path.contains("/node_modules/") { return .code }
    if path.contains("/system/") || path.contains("/library/frameworks/") { return .system }
    if path.contains(".app/contents/") || path.contains(".appex/contents/") || path.contains(".xpc/contents/") { return .application }
    if path.contains("/library/application support/") || path.contains("/library/containers/") ||
        path.contains("/library/group containers/") { return .appData }
    return .other
}

func mtBestCategory(_ nodeID: Int, _ nodes: [MTNode]) -> MTCategory {
    guard nodes.indices.contains(nodeID) else { return .other }
    let node = nodes[nodeID]
    let direct = mtDirectCategory(node, nodes: nodes)
    if direct != .other { return direct }
    guard node.isDirectory && !node.children.isEmpty else { return .other }

    var weights: [MTCategory: UInt64] = [:]
    for childID in node.children.prefix(40) {
        guard nodes.indices.contains(childID) else { continue }
        let child = nodes[childID]
        let category = mtDirectCategory(child, nodes: nodes)
        if category == .other && child.isDirectory {
            for grandID in child.children.prefix(10) {
                guard nodes.indices.contains(grandID) else { continue }
                let grand = nodes[grandID]
                let grandCategory = mtDirectCategory(grand, nodes: nodes)
                if grandCategory != .other {
                    weights[grandCategory, default: 0] = mtSafeAdd(weights[grandCategory, default: 0], grand.allocatedSize)
                }
            }
        } else if category != .other {
            weights[category, default: 0] = mtSafeAdd(weights[category, default: 0], child.allocatedSize)
        }
    }
    return weights.max(by: { $0.value < $1.value })?.key ?? .other
}

func mtCategoryForGroup(_ ids: ArraySlice<Int>, _ nodes: [MTNode], fallback: MTCategory) -> MTCategory {
    var weights: [MTCategory: UInt64] = [:]
    for id in ids.prefix(80) {
        guard nodes.indices.contains(id) else { continue }
        let category = mtBestCategory(id, nodes)
        if category != .other {
            weights[category, default: 0] = mtSafeAdd(weights[category, default: 0], nodes[id].allocatedSize)
        }
    }
    return weights.max(by: { $0.value < $1.value })?.key ?? fallback
}

// MARK: - Utilities

func mtRectFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite &&
    rect.width >= 0 && rect.height >= 0
}

func mtSafeInset(_ rect: CGRect, _ amount: CGFloat) -> CGRect {
    guard mtRectFinite(rect) else { return .zero }
    let dx = min(max(0, amount), max(0, rect.width / 2 - 0.05))
    let dy = min(max(0, amount), max(0, rect.height / 2 - 0.05))
    let result = rect.insetBy(dx: dx, dy: dy)
    return mtRectFinite(result) ? result : rect
}

func mtSafeAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (value, overflow) = a.addingReportingOverflow(by: b)
    return overflow ? UInt64.max : value
}

func mtSafeMultiply(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    return overflow ? UInt64.max : value
}

func mtEllipsize(_ text: String, maxCharacters: Int) -> String {
    guard maxCharacters > 1, text.count > maxCharacters else { return text }
    let end = text.index(text.startIndex, offsetBy: max(1, maxCharacters - 1))
    return String(text[..<end]) + "…"
}

func mtFileTypeLabel(_ node: MTNode) -> String {
    let ext = (node.name as NSString).pathExtension.lowercased()
    return ext.isEmpty ? mtL("File") : ".\(ext)"
}

func mtBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
