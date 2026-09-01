import SwiftUI
import AppKit
import Darwin

struct MTNode: Identifiable, Hashable, Sendable {
    let id: Int
    let parentID: Int?
    let name: String
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

actor MTScanner {
    private struct Builder {
        let id: Int
        let parentID: Int?
        let name: String
        let path: String
        let isDirectory: Bool
        var logicalSize: UInt64
        var allocatedSize: UInt64
        var fileCount: UInt64
        let modifiedTime: TimeInterval
        var children: [Int]
    }

    func scan(root: URL, progress: @escaping @Sendable (MTProgress) async -> Void) async throws -> MTSnapshot {
        let started = CFAbsoluteTimeGetCurrent()
        let rootPath = root.standardizedFileURL.path
        let rootName = root.lastPathComponent.isEmpty ? "Macintosh HD" : root.lastPathComponent

        var builders: [Builder] = [
            Builder(id: 0, parentID: nil, name: rootName, path: rootPath, isDirectory: true,
                    logicalSize: 0, allocatedSize: 0, fileCount: 0, modifiedTime: 0, children: [])
        ]
        builders.reserveCapacity(rootPath == "/" ? 750_000 : 400_000)

        var directoryIDs: [String: Int] = ["": 0]
        directoryIDs.reserveCapacity(rootPath == "/" ? 120_000 : 60_000)

        var items: UInt64 = 0
        var files: UInt64 = 0
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var publishCounter = 0
        var currentPath = rootPath

        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else {
            throw NSError(domain: "MacTree", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Selected location could not be scanned."])
        }

        while let relative = enumerator.nextObject() as? String {
            if Task.isCancelled { break }
            items += 1
            publishCounter += 1

            let fullPath = rootPath == "/" ? "/" + relative : rootPath + "/" + relative
            currentPath = fullPath

            var info = stat()
            if fullPath.withCString({ lstat($0, &info) }) != 0 { continue }

            let fileType = info.st_mode & mode_t(S_IFMT)
            let isDirectory = fileType == mode_t(S_IFDIR)
            if fileType == mode_t(S_IFLNK) { continue }

            if isDirectory && shouldSkip(relative) {
                enumerator.skipDescendants()
                continue
            }

            let parentRelative: String
            let name: String
            if let slash = relative.lastIndex(of: "/") {
                parentRelative = String(relative[..<slash])
                name = String(relative[relative.index(after: slash)...])
            } else {
                parentRelative = ""
                name = relative
            }

            guard let parentID = directoryIDs[parentRelative] else {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            let logicalSize: UInt64
            let allocatedSize: UInt64
            let fileCount: UInt64
            if isDirectory {
                logicalSize = 0
                allocatedSize = 0
                fileCount = 0
            } else {
                logicalSize = info.st_size > 0 ? UInt64(info.st_size) : 0
                allocatedSize = info.st_blocks > 0 ? UInt64(info.st_blocks) * 512 : logicalSize
                fileCount = 1
                files += 1
                logical = mtSafeAdd(logical, logicalSize)
                allocated = mtSafeAdd(allocated, allocatedSize)
            }

            let id = builders.count
            builders.append(
                Builder(id: id, parentID: parentID, name: name, path: fullPath, isDirectory: isDirectory,
                        logicalSize: logicalSize, allocatedSize: allocatedSize, fileCount: fileCount,
                        modifiedTime: TimeInterval(info.st_mtimespec.tv_sec), children: [])
            )
            builders[parentID].children.append(id)
            if isDirectory { directoryIDs[relative] = id }

            if publishCounter >= 100_000 {
                await progress(MTProgress(items: items, files: files, logical: logical, allocated: allocated,
                                          currentPath: currentPath, elapsed: CFAbsoluteTimeGetCurrent() - started))
                publishCounter = 0
            }
        }

        if builders.count > 1 {
            for index in stride(from: builders.count - 1, through: 1, by: -1) {
                guard let parent = builders[index].parentID else { continue }
                builders[parent].logicalSize = mtSafeAdd(builders[parent].logicalSize, builders[index].logicalSize)
                builders[parent].allocatedSize = mtSafeAdd(builders[parent].allocatedSize, builders[index].allocatedSize)
                builders[parent].fileCount = mtSafeAdd(builders[parent].fileCount, builders[index].fileCount)
            }
        }

        var nodes = builders.map {
            MTNode(id: $0.id, parentID: $0.parentID, name: $0.name, path: $0.path,
                   isDirectory: $0.isDirectory, logicalSize: $0.logicalSize,
                   allocatedSize: $0.allocatedSize, fileCount: $0.fileCount,
                   modifiedTime: $0.modifiedTime, children: $0.children)
        }

        let sizeReference = nodes
        for index in nodes.indices where !nodes[index].children.isEmpty {
            nodes[index].children.sort {
                let lhs = sizeReference[$0]
                let rhs = sizeReference[$1]
                if lhs.allocatedSize != rhs.allocatedSize { return lhs.allocatedSize > rhs.allocatedSize }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        await progress(MTProgress(items: items, files: files, logical: logical, allocated: allocated,
                                  currentPath: currentPath, elapsed: elapsed))
        return MTSnapshot(nodes: nodes, rootID: 0, items: items, files: files,
                          logical: logical, allocated: allocated, elapsed: elapsed)
    }

    private func shouldSkip(_ relative: String) -> Bool {
        if relative == "Volumes" || relative.hasPrefix("Volumes/") { return true }
        if relative == "dev" || relative.hasPrefix("dev/") { return true }
        if relative == "System/Volumes" || relative.hasPrefix("System/Volumes/") { return true }
        let marker = "/" + relative
        if marker.contains("/Library/CloudStorage") { return true }
        if marker.contains("/Library/Mobile Documents") { return true }
        if marker.contains("/Library/Application Support/CloudDocs") { return true }
        return false
    }
}

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
                    if node.name.lowercased().contains(lowered) || node.path.lowercased().contains(lowered) {
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

@MainActor
final class MTController: ObservableObject {
    @Published var rootURL = URL(fileURLWithPath: "/", isDirectory: true)
    @Published var nodes: [MTNode] = []
    @Published var rootID = 0
    @Published var items: UInt64 = 0
    @Published var files: UInt64 = 0
    @Published var logical: UInt64 = 0
    @Published var allocated: UInt64 = 0
    @Published var elapsed: TimeInterval = 0
    @Published var currentPath = ""
    @Published var isScanning = false
    @Published var scanVersion = 0
    @Published var errorMessage: String?
    @Published var fullDiskAccess = false
    @Published var volumeTotal: UInt64 = 0
    @Published var volumeFree: UInt64 = 0

    let search = MTSearchModel()
    private let scanner = MTScanner()
    private var task: Task<Void, Never>?

    init() {
        refreshFullDiskAccess()
        refreshVolumeSpace()
    }

    func chooseHome() {
        rootURL = FileManager.default.homeDirectoryForCurrentUser
        refreshVolumeSpace()
    }

    func chooseDisk() {
        rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        refreshVolumeSpace()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a disk or folder"
        panel.message = "iCloud and File Provider folders are skipped automatically."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            refreshVolumeSpace()
        }
    }

    func refreshFullDiskAccess() {
        fullDiskAccess = access("/Library/Application Support/com.apple.TCC/TCC.db", R_OK) == 0
    }

    func refreshVolumeSpace() {
        do {
            let values = try rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            volumeTotal = values.volumeTotalCapacity.map { UInt64(max(0, $0)) } ?? 0
            volumeFree = values.volumeAvailableCapacity.map { UInt64(max(0, $0)) } ?? 0
        } catch {
            volumeTotal = 0
            volumeFree = 0
        }
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func start() {
        task?.cancel()
        refreshVolumeSpace()
        nodes = []
        search.setNodes([])
        items = 0
        files = 0
        logical = 0
        allocated = 0
        elapsed = 0
        currentPath = rootURL.path
        errorMessage = nil
        isScanning = true

        let selected = rootURL
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await scanner.scan(root: selected) { update in
                    await MainActor.run {
                        self.items = update.items
                        self.files = update.files
                        self.logical = update.logical
                        self.allocated = update.allocated
                        self.currentPath = update.currentPath
                        self.elapsed = update.elapsed
                    }
                }
                self.nodes = snapshot.nodes
                self.rootID = snapshot.rootID
                self.items = snapshot.items
                self.files = snapshot.files
                self.logical = snapshot.logical
                self.allocated = snapshot.allocated
                self.elapsed = snapshot.elapsed
                self.search.setNodes(snapshot.nodes)
                self.refreshVolumeSpace()
                self.scanVersion += 1
            } catch {
                if !Task.isCancelled { self.errorMessage = error.localizedDescription }
            }
            self.isScanning = false
            self.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isScanning = false
    }
}

enum MTFileActions {
    static func open(_ node: MTNode) {
        NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
    }

    static func reveal(_ node: MTNode) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    static func openContainingFolder(_ node: MTNode) {
        let url = URL(fileURLWithPath: node.path)
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }

    static func copyPath(_ node: MTNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    static func copyName(_ node: MTNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.name, forType: .string)
    }

    static func openTerminal(_ node: MTNode) {
        let target = node.isDirectory ? node.path : URL(fileURLWithPath: node.path).deletingLastPathComponent().path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", target]
        try? process.run()
    }

    static func getInfo(_ node: MTNode) {
        let escaped = node.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to open information window of (POSIX file \"\(escaped)\" as alias)"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    static func moveToTrash(_ node: MTNode) {
        let url = URL(fileURLWithPath: node.path).standardizedFileURL
        let path = url.path

        guard FileManager.default.fileExists(atPath: path) else {
            showTrashError(node: node, path: path, detail: mtL("The item no longer exists at this location."))
            return
        }

        // Never offer to trash filesystem roots. Items below these locations may still
        // be removable; macOS will decide and we surface its real error if it refuses.
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
        } catch {
            showTrashError(node: node, path: path, detail: error.localizedDescription)
        }
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

func mtDirectCategory(_ node: MTNode) -> MTCategory {
    let name = node.name.lowercased()
    let path = node.path.lowercased()

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
    let direct = mtDirectCategory(node)
    if direct != .other { return direct }
    guard node.isDirectory && !node.children.isEmpty else { return .other }

    var weights: [MTCategory: UInt64] = [:]
    for childID in node.children.prefix(40) {
        guard nodes.indices.contains(childID) else { continue }
        let child = nodes[childID]
        let category = mtDirectCategory(child)
        if category == .other && child.isDirectory {
            for grandID in child.children.prefix(10) {
                guard nodes.indices.contains(grandID) else { continue }
                let grand = nodes[grandID]
                let grandCategory = mtDirectCategory(grand)
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
    return ext.isEmpty ? "File" : ".\(ext)"
}

func mtBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
}
