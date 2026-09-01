import SwiftUI
import AppKit
import Darwin

@main
struct MacTreeV6App: App {
    var body: some Scene {
        WindowGroup {
            MainViewV6()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 860)
    }
}

// MARK: - Model

struct MT6Node: Identifiable, Hashable, Sendable {
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

struct MT6Progress: Sendable {
    let items: UInt64
    let files: UInt64
    let logical: UInt64
    let allocated: UInt64
    let currentPath: String
    let elapsed: TimeInterval
}

struct MT6Snapshot: Sendable {
    let nodes: [MT6Node]
    let rootID: Int
    let items: UInt64
    let files: UInt64
    let logical: UInt64
    let allocated: UInt64
    let elapsed: TimeInterval
}

// MARK: - Scanner

actor MT6Scanner {
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

    func scan(
        root: URL,
        progress: @escaping @Sendable (MT6Progress) async -> Void
    ) async throws -> MT6Snapshot {
        let started = CFAbsoluteTimeGetCurrent()
        let rootPath = root.standardizedFileURL.path
        let rootName = root.lastPathComponent.isEmpty ? "Macintosh HD" : root.lastPathComponent

        var builders: [Builder] = [
            Builder(
                id: 0,
                parentID: nil,
                name: rootName,
                path: rootPath,
                isDirectory: true,
                logicalSize: 0,
                allocatedSize: 0,
                fileCount: 0,
                modifiedTime: 0,
                children: []
            )
        ]
        builders.reserveCapacity(400_000)

        var directoryIDs: [String: Int] = ["": 0]
        directoryIDs.reserveCapacity(60_000)

        var items: UInt64 = 0
        var files: UInt64 = 0
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var publishCounter = 0
        var currentPath = rootPath

        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else {
            throw NSError(
                domain: "MacTree",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Selected location could not be scanned."]
            )
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
            let isSymlink = fileType == mode_t(S_IFLNK)
            if isSymlink { continue }

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
                logical += logicalSize
                allocated += allocatedSize
            }

            let id = builders.count
            builders.append(
                Builder(
                    id: id,
                    parentID: parentID,
                    name: name,
                    path: fullPath,
                    isDirectory: isDirectory,
                    logicalSize: logicalSize,
                    allocatedSize: allocatedSize,
                    fileCount: fileCount,
                    modifiedTime: TimeInterval(info.st_mtimespec.tv_sec),
                    children: []
                )
            )
            builders[parentID].children.append(id)

            if isDirectory {
                directoryIDs[relative] = id
            }

            if publishCounter >= 35_000 {
                await progress(
                    MT6Progress(
                        items: items,
                        files: files,
                        logical: logical,
                        allocated: allocated,
                        currentPath: currentPath,
                        elapsed: CFAbsoluteTimeGetCurrent() - started
                    )
                )
                publishCounter = 0
            }
        }

        if builders.count > 1 {
            for index in stride(from: builders.count - 1, through: 1, by: -1) {
                guard let parent = builders[index].parentID else { continue }
                builders[parent].logicalSize += builders[index].logicalSize
                builders[parent].allocatedSize += builders[index].allocatedSize
                builders[parent].fileCount += builders[index].fileCount
            }
        }

        var nodes = builders.map {
            MT6Node(
                id: $0.id,
                parentID: $0.parentID,
                name: $0.name,
                path: $0.path,
                isDirectory: $0.isDirectory,
                logicalSize: $0.logicalSize,
                allocatedSize: $0.allocatedSize,
                fileCount: $0.fileCount,
                modifiedTime: $0.modifiedTime,
                children: $0.children
            )
        }

        let sizeReference = nodes
        for index in nodes.indices where !nodes[index].children.isEmpty {
            nodes[index].children.sort {
                let lhs = sizeReference[$0]
                let rhs = sizeReference[$1]
                if lhs.allocatedSize != rhs.allocatedSize {
                    return lhs.allocatedSize > rhs.allocatedSize
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        await progress(
            MT6Progress(
                items: items,
                files: files,
                logical: logical,
                allocated: allocated,
                currentPath: currentPath,
                elapsed: elapsed
            )
        )

        return MT6Snapshot(
            nodes: nodes,
            rootID: 0,
            items: items,
            files: files,
            logical: logical,
            allocated: allocated,
            elapsed: elapsed
        )
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

// MARK: - Controller

@MainActor
final class MT6Controller: ObservableObject {
    @Published var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @Published var nodes: [MT6Node] = []
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

    private let scanner = MT6Scanner()
    private var task: Task<Void, Never>?

    init() {
        refreshFullDiskAccess()
    }

    func chooseHome() {
        rootURL = FileManager.default.homeDirectoryForCurrentUser
    }

    func chooseDisk() {
        rootURL = URL(fileURLWithPath: "/", isDirectory: true)
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
        }
    }

    func refreshFullDiskAccess() {
        fullDiskAccess = access("/Library/Application Support/com.apple.TCC/TCC.db", R_OK) == 0
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        task?.cancel()
        nodes = []
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
                self.scanVersion += 1
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
            self.isScanning = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isScanning = false
    }
}

// MARK: - Main UI

struct MainViewV6: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MT6Controller()
    @State private var expanded: Set<Int> = []
    @State private var selectedID: Int?
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()

            VSplitView {
                tree
                    .frame(minHeight: 290)

                MT6Treemap(
                    nodes: controller.nodes,
                    rootID: controller.rootID,
                    selectedID: $selectedID
                )
                .frame(minHeight: 320)
            }

            Divider()
            status
        }
        .onChange(of: controller.scanVersion) { _, _ in
            expanded.removeAll()
            selectedID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.refreshFullDiskAccess()
            }
        }
        .alert(
            "MacTree",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Home Folder") { controller.chooseHome() }
                Button("Macintosh HD") { controller.chooseDisk() }
                Divider()
                Button("Choose Folder…") { controller.chooseFolder() }
            } label: {
                Label(locationTitle, systemImage: "internaldrive")
                    .frame(minWidth: 160, alignment: .leading)
            }
            .menuStyle(.borderlessButton)

            if controller.isScanning {
                Button("Stop", role: .destructive) { controller.stop() }
            } else {
                Button("Scan") { controller.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }

            Button { controller.openFullDiskAccess() } label: {
                Label(
                    controller.fullDiskAccess ? "Full Disk Access" : "Grant Full Disk Access",
                    systemImage: controller.fullDiskAccess ? "lock.open.fill" : "lock.shield"
                )
            }
            .foregroundStyle(controller.fullDiskAccess ? Color.green : Color.secondary)

            Spacer()

            TextField("Search files and folders", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            Label(
                controller.isScanning ? "Scanning" : "Ready",
                systemImage: controller.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
            )
            .foregroundStyle(controller.isScanning ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            metric("Allocated", mt6Bytes(controller.allocated))
            metric("Logical", mt6Bytes(controller.logical))
            metric("Files", controller.files.formatted())
            metric("Items", controller.items.formatted())

            Text("iCloud skipped")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1), in: Capsule())

            Spacer()
            if controller.isScanning {
                ProgressView().controlSize(.small)
            }
            Text(controller.elapsed.formatted(.number.precision(.fractionLength(1))) + " s")
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var tree: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { row in
                        MT6TreeRow(
                            node: row.node,
                            depth: row.depth,
                            total: max(controller.allocated, 1),
                            isExpanded: expanded.contains(row.node.id),
                            isSelected: selectedID == row.node.id,
                            toggle: { toggle(row.node.id) },
                            select: { selectedID = row.node.id },
                            open: {
                                selectedID = row.node.id
                                if row.node.isDirectory && !row.node.children.isEmpty {
                                    toggle(row.node.id)
                                }
                            }
                        )
                    }
                } header: {
                    HStack(spacing: 0) {
                        header("Name", 330, .leading)
                        header("Size", 105, .trailing)
                        header("Allocated", 105, .trailing)
                        header("Files", 90, .trailing)
                        header("% Disk", 145, .leading)
                        header("Modified", 165, .leading)
                        header("Path", 390, .leading)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.vertical, 7)
                    .background(.bar)
                }
            }
            .frame(minWidth: 1280, alignment: .topLeading)
        }
        .id(controller.scanVersion)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private var status: some View {
        HStack(spacing: 10) {
            if controller.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning \(controller.items.formatted()) items")
                    .fontWeight(.semibold)
                Text(controller.currentPath)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            } else {
                Text("Scanned \(controller.files.formatted()) files in \(controller.elapsed.formatted(.number.precision(.fractionLength(1)))) s")
            }

            Spacer()

            if let selectedID, controller.nodes.indices.contains(selectedID) {
                let node = controller.nodes[selectedID]
                Text("Selected: \(node.path)   \(mt6Bytes(node.allocatedSize))")
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private struct Row: Identifiable {
        let node: MT6Node
        let depth: Int
        var id: Int { node.id }
    }

    private var rows: [Row] {
        guard !controller.nodes.isEmpty else { return [] }

        if !search.isEmpty {
            var matches: [Row] = []
            matches.reserveCapacity(300)
            for node in controller.nodes.dropFirst() {
                if node.name.localizedCaseInsensitiveContains(search) || node.path.localizedCaseInsensitiveContains(search) {
                    matches.append(Row(node: node, depth: 0))
                    if matches.count >= 2_000 { break }
                }
            }
            matches.sort { $0.node.allocatedSize > $1.node.allocatedSize }
            return matches
        }

        var result: [Row] = []
        func appendChildren(_ parent: Int, depth: Int) {
            guard controller.nodes.indices.contains(parent) else { return }
            for childID in controller.nodes[parent].children {
                guard controller.nodes.indices.contains(childID) else { continue }
                let child = controller.nodes[childID]
                result.append(Row(node: child, depth: depth))
                if child.isDirectory && expanded.contains(child.id) {
                    appendChildren(child.id, depth: depth + 1)
                }
            }
        }
        appendChildren(controller.rootID, depth: 0)
        return result
    }

    private var locationTitle: String {
        if controller.rootURL.path == "/" { return "Macintosh HD" }
        let name = controller.rootURL.lastPathComponent
        return name.isEmpty ? controller.rootURL.path : name
    }

    private func toggle(_ id: Int) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title + ":").foregroundStyle(Color.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }

    private func header(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text).frame(width: width, alignment: alignment).padding(.horizontal, 6)
    }
}

private struct MT6TreeRow: View {
    let node: MT6Node
    let depth: Int
    let total: UInt64
    let isExpanded: Bool
    let isSelected: Bool
    let toggle: () -> Void
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(depth) * 17)

                if node.isDirectory && !node.children.isEmpty {
                    Button(action: toggle) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14)
                }

                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : Color.secondary)
                    .frame(width: 17)

                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 330, alignment: .leading)
            .padding(.horizontal, 6)

            cell(mt6Bytes(node.logicalSize), 105, .trailing)
            cell(mt6Bytes(node.allocatedSize), 105, .trailing)
            cell(node.fileCount.formatted(), 90, .trailing)

            HStack(spacing: 7) {
                let ratio = Double(node.allocatedSize) / Double(max(total, 1))
                ProgressView(value: ratio).frame(width: 66)
                Text(ratio, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
            .frame(width: 145, alignment: .leading)
            .padding(.horizontal, 6)

            let modified = node.modifiedTime > 0
                ? Date(timeIntervalSince1970: node.modifiedTime).formatted(date: .numeric, time: .shortened)
                : "—"
            cell(modified, 165, .leading)

            Text(node.path)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 390, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .font(.callout)
        .frame(height: 29)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.28)
                : (node.id.isMultiple(of: 2) ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.28))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
    }

    private func cell(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
    }
}

// MARK: - Semantic color categories

private enum MT6Category: String, CaseIterable {
    case application = "Apps"
    case video = "Video"
    case image = "Images"
    case archive = "Archives"
    case audio = "Audio"
    case document = "Docs"
    case code = "Code"
    case database = "Database"
    case gameData = "Game data"
    case system = "System"
    case other = "Other"

    var color: Color {
        switch self {
        case .application: return .green
        case .video: return .purple
        case .image: return .pink
        case .archive: return .orange
        case .audio: return .cyan
        case .document: return .blue
        case .code: return .teal
        case .database: return .indigo
        case .gameData: return .red
        case .system: return .mint
        case .other: return Color(nsColor: .systemGray)
        }
    }
}

private func mt6Category(for node: MT6Node) -> MT6Category {
    if node.isDirectory {
        if node.name.lowercased().hasSuffix(".app") { return .application }
        if node.name.lowercased().hasSuffix(".framework") { return .system }
        return .other
    }

    let ext = (node.name as NSString).pathExtension.lowercased()
    switch ext {
    case "app", "exe": return .application
    case "mp4", "mov", "mkv", "avi", "webm", "m4v": return .video
    case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp": return .image
    case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso": return .archive
    case "mp3", "aac", "m4a", "wav", "flac", "ogg", "bank": return .audio
    case "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "csv", "xls", "xlsx", "ppt", "pptx": return .document
    case "swift", "c", "cpp", "cc", "h", "hpp", "js", "ts", "py", "java", "kt", "rs", "go", "json", "xml", "plist", "yaml", "yml", "toml", "sh": return .code
    case "db", "sqlite", "sqlite3", "realm": return .database
    case "pak", "vpk", "wad", "pck", "bundle", "assets", "asset", "res", "resource", "dat", "bin", "cache", "obb", "unity3d": return .gameData
    case "dylib", "so", "framework", "kext": return .system
    default: return .other
    }
}

// MARK: - Treemap model

private enum MT6CellKind {
    case file
    case aggregate
}

private struct MT6Cell: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let depth: Int
    let kind: MT6CellKind
    let labelOverride: String?
    let representedAllocated: UInt64
    let representedFiles: UInt64
}

private struct MT6Frame: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let headerRect: CGRect?
    let depth: Int
    let label: String
    let isSteamGame: Bool
}

private struct MT6RenderModel {
    let cells: [MT6Cell]
    let frames: [MT6Frame]
    let buckets: [[Int]]
    let cols: Int
    let rows: Int
    let size: CGSize

    static func empty(size: CGSize = .zero) -> MT6RenderModel {
        MT6RenderModel(cells: [], frames: [], buckets: [], cols: 0, rows: 0, size: size)
    }

    func hitTest(_ point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0,
              point.x < size.width, point.y < size.height,
              cols > 0, rows > 0, !buckets.isEmpty else { return nil }

        let nx = max(0, min(0.999999, point.x / max(1, size.width)))
        let ny = max(0, min(0.999999, point.y / max(1, size.height)))
        guard nx.isFinite, ny.isFinite else { return nil }

        let gx = min(cols - 1, max(0, Int(nx * CGFloat(cols))))
        let gy = min(rows - 1, max(0, Int(ny * CGFloat(rows))))
        let bucketIndex = gy * cols + gx
        guard buckets.indices.contains(bucketIndex) else { return nil }

        for index in buckets[bucketIndex].reversed() {
            guard cells.indices.contains(index) else { continue }
            if cells[index].rect.contains(point) {
                return index
            }
        }
        return nil
    }
}

private struct MT6WeightedEntry {
    let token: Int
    let weight: UInt64
}

private struct MT6WeightedLayout {
    func layout(_ entries: [MT6WeightedEntry], in rect: CGRect) -> [(Int, CGRect)] {
        let safeRect = rect.standardized
        guard mt6RectFinite(safeRect), safeRect.width > 0.5, safeRect.height > 0.5 else { return [] }

        let valid = entries.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard !valid.isEmpty else { return [] }

        var output: [(Int, CGRect)] = []
        output.reserveCapacity(valid.count)
        split(valid, in: safeRect, output: &output)
        return output
    }

    private func split(
        _ entries: [MT6WeightedEntry],
        in rect: CGRect,
        output: inout [(Int, CGRect)]
    ) {
        guard !entries.isEmpty, mt6RectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }

        if entries.count == 1 {
            output.append((entries[0].token, rect))
            return
        }

        let total = entries.reduce(UInt64(0)) { partial, entry in
            let (value, overflow) = partial.addingReportingOverflow(entry.weight)
            return overflow ? UInt64.max : value
        }
        guard total > 0 else { return }

        let target = Double(total) / 2
        var running = 0.0
        var splitIndex = 1

        for index in 0..<(entries.count - 1) {
            running += Double(entries[index].weight)
            splitIndex = index + 1
            if running >= target { break }
        }

        splitIndex = max(1, min(entries.count - 1, splitIndex))
        let left = Array(entries[..<splitIndex])
        let right = Array(entries[splitIndex...])
        let leftTotal = left.reduce(UInt64(0)) { partial, entry in
            let (value, overflow) = partial.addingReportingOverflow(entry.weight)
            return overflow ? UInt64.max : value
        }

        var fraction = Double(leftTotal) / Double(total)
        if !fraction.isFinite { fraction = 0.5 }
        fraction = max(0.001, min(0.999, fraction))

        if rect.width >= rect.height {
            let width = rect.width * CGFloat(fraction)
            guard width.isFinite else { return }
            let first = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            let second = CGRect(x: rect.minX + width, y: rect.minY, width: max(0, rect.width - width), height: rect.height)
            split(left, in: first, output: &output)
            split(right, in: second, output: &output)
        } else {
            let height = rect.height * CGFloat(fraction)
            guard height.isFinite else { return }
            let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            let second = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(0, rect.height - height))
            split(left, in: first, output: &output)
            split(right, in: second, output: &output)
        }
    }
}

// MARK: - Semantic / coverage-preserving builder

private struct MT6TreemapBuilder {
    let nodes: [MT6Node]

    private let maxLeafCells = 1900
    private let maxDepth = 12
    private let minExpandArea: CGFloat = 220
    private let minExpandSide: CGFloat = 12
    private let maxChildrenPerFolder = 48

    func build(rootID: Int, size: CGSize) -> MT6RenderModel {
        guard nodes.indices.contains(rootID),
              size.width.isFinite, size.height.isFinite,
              size.width > 4, size.height > 4 else {
            return .empty(size: size)
        }

        let rootChildren = nodes[rootID].children.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }
        guard !rootChildren.isEmpty else { return .empty(size: size) }

        let rootTotal = safeSum(rootChildren.map { nodes[$0].allocatedSize })
        guard rootTotal > 0 else { return .empty(size: size) }

        let layout = MT6WeightedLayout()
        let rootEntries = rootChildren.map { MT6WeightedEntry(token: $0, weight: nodes[$0].allocatedSize) }
        let rootRects = layout.layout(rootEntries, in: CGRect(origin: .zero, size: size))

        var cells: [MT6Cell] = []
        var frames: [MT6Frame] = []
        cells.reserveCapacity(maxLeafCells)
        frames.reserveCapacity(320)

        var remainingBudget = maxLeafCells
        for (index, pair) in rootRects.enumerated() {
            let id = pair.0
            let rect = pair.1
            let weight = nodes[id].allocatedSize
            let proportional = max(1, Int((Double(maxLeafCells) * Double(weight) / Double(rootTotal)).rounded(.down)))
            let siblingsLeft = rootRects.count - index
            let budget = max(1, min(max(1, remainingBudget - max(0, siblingsLeft - 1)), proportional))

            renderNode(
                id: id,
                rect: rect,
                depth: 0,
                budget: budget,
                layout: layout,
                cells: &cells,
                frames: &frames
            )
            remainingBudget = max(0, maxLeafCells - cells.count)
        }

        return makeRenderModel(cells: cells, frames: frames, size: size)
    }

    private func renderNode(
        id: Int,
        rect: CGRect,
        depth: Int,
        budget: Int,
        layout: MT6WeightedLayout,
        cells: inout [MT6Cell],
        frames: inout [MT6Frame]
    ) {
        let rect = rect.standardized
        guard nodes.indices.contains(id), mt6RectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }

        let node = nodes[id]
        if !node.isDirectory {
            appendCell(node: node, rect: rect, depth: depth, kind: .file, label: nil, allocated: node.allocatedSize, files: 1, cells: &cells)
            return
        }

        let area = rect.width * rect.height
        let children = node.children.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }
        let specialGame = mt6SteamGameName(forPath: node.path) == node.name
        let canExpand = budget > 1 &&
            depth < maxDepth &&
            area.isFinite && area >= minExpandArea &&
            rect.width >= minExpandSide && rect.height >= minExpandSide &&
            !children.isEmpty

        guard canExpand else {
            appendCell(node: node, rect: rect, depth: depth, kind: .aggregate, label: nil, allocated: node.allocatedSize, files: node.fileCount, cells: &cells)
            return
        }

        let headerHeight: CGFloat
        if specialGame && rect.width >= 90 && rect.height >= 52 {
            headerHeight = 21
        } else if depth <= 2 && rect.width >= 105 && rect.height >= 58 {
            headerHeight = 17
        } else {
            headerHeight = 0
        }

        let content = CGRect(
            x: rect.minX + 1,
            y: rect.minY + headerHeight + 1,
            width: max(0, rect.width - 2),
            height: max(0, rect.height - headerHeight - 2)
        )

        guard mt6RectFinite(content), content.width > 2, content.height > 2 else {
            appendCell(node: node, rect: rect, depth: depth, kind: .aggregate, label: nil, allocated: node.allocatedSize, files: node.fileCount, cells: &cells)
            return
        }

        if headerHeight > 0 || depth <= 2 || specialGame {
            let frameLabel = specialGame ? "🎮 \(node.name)" : node.name
            frames.append(
                MT6Frame(
                    id: frames.count,
                    nodeID: id,
                    rect: rect,
                    headerRect: headerHeight > 0 ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight) : nil,
                    depth: depth,
                    label: frameLabel,
                    isSteamGame: specialGame
                )
            )
        }

        let allowedEntries = max(1, min(maxChildrenPerFolder, budget))
        let keepCount = min(children.count, allowedEntries)
        var realChildren = Array(children.prefix(keepCount))
        var remainderWeight: UInt64 = 0
        var remainderFiles: UInt64 = 0

        if children.count > keepCount {
            realChildren = Array(children.prefix(max(1, keepCount - 1)))
            for childID in children.dropFirst(realChildren.count) {
                remainderWeight = safeAdd(remainderWeight, nodes[childID].allocatedSize)
                remainderFiles = safeAdd(remainderFiles, nodes[childID].fileCount)
            }
        }

        var entries = realChildren.map { MT6WeightedEntry(token: $0, weight: nodes[$0].allocatedSize) }
        let remainderToken = -1
        if remainderWeight > 0 {
            entries.append(MT6WeightedEntry(token: remainderToken, weight: remainderWeight))
        }

        guard !entries.isEmpty else {
            appendCell(node: node, rect: content, depth: depth + 1, kind: .aggregate, label: nil, allocated: node.allocatedSize, files: node.fileCount, cells: &cells)
            return
        }

        let rects = layout.layout(entries, in: content)
        let totalWeight = safeSum(entries.map { $0.weight })
        let entryCount = rects.count
        let extraBudget = max(0, budget - entryCount)

        var extraShares = Array(repeating: 0, count: entryCount)
        if extraBudget > 0 && totalWeight > 0 {
            var assigned = 0
            for index in rects.indices {
                let token = rects[index].0
                let weight = token == remainderToken ? remainderWeight : (nodes.indices.contains(token) ? nodes[token].allocatedSize : 0)
                let share = Int((Double(extraBudget) * Double(weight) / Double(totalWeight)).rounded(.down))
                extraShares[index] = max(0, share)
                assigned += extraShares[index]
            }
            var unassigned = max(0, extraBudget - assigned)
            var cursor = 0
            while unassigned > 0 && !extraShares.isEmpty {
                extraShares[cursor % extraShares.count] += 1
                cursor += 1
                unassigned -= 1
            }
        }

        for index in rects.indices {
            let token = rects[index].0
            let childRect = rects[index].1
            if token == remainderToken {
                appendCell(
                    node: node,
                    rect: childRect,
                    depth: depth + 1,
                    kind: .aggregate,
                    label: "Other items",
                    allocated: remainderWeight,
                    files: remainderFiles,
                    cells: &cells
                )
            } else {
                renderNode(
                    id: token,
                    rect: childRect,
                    depth: depth + 1,
                    budget: 1 + extraShares[index],
                    layout: layout,
                    cells: &cells,
                    frames: &frames
                )
            }
        }
    }

    private func appendCell(
        node: MT6Node,
        rect: CGRect,
        depth: Int,
        kind: MT6CellKind,
        label: String?,
        allocated: UInt64,
        files: UInt64,
        cells: inout [MT6Cell]
    ) {
        let safe = mt6SafeInset(rect, 0.38)
        guard mt6RectFinite(safe), safe.width > 0.25, safe.height > 0.25 else { return }
        cells.append(
            MT6Cell(
                id: cells.count,
                nodeID: node.id,
                rect: safe,
                depth: depth,
                kind: kind,
                labelOverride: label,
                representedAllocated: allocated,
                representedFiles: files
            )
        )
    }

    private func makeRenderModel(cells: [MT6Cell], frames: [MT6Frame], size: CGSize) -> MT6RenderModel {
        let cols = max(14, min(54, Int(max(1, size.width) / 28)))
        let rows = max(9, min(36, Int(max(1, size.height) / 28)))
        var buckets = Array(repeating: [Int](), count: max(1, cols * rows))

        for (index, cell) in cells.enumerated() {
            let rect = cell.rect.standardized
            guard mt6RectFinite(rect), rect.width > 0, rect.height > 0 else { continue }

            let minNX = max(0, min(0.999999, rect.minX / max(1, size.width)))
            let maxNX = max(0, min(0.999999, max(rect.minX, rect.maxX - 0.01) / max(1, size.width)))
            let minNY = max(0, min(0.999999, rect.minY / max(1, size.height)))
            let maxNY = max(0, min(0.999999, max(rect.minY, rect.maxY - 0.01) / max(1, size.height)))
            guard minNX.isFinite, maxNX.isFinite, minNY.isFinite, maxNY.isFinite else { continue }

            let minX = min(cols - 1, max(0, Int(minNX * CGFloat(cols))))
            let maxX = min(cols - 1, max(0, Int(maxNX * CGFloat(cols))))
            let minY = min(rows - 1, max(0, Int(minNY * CGFloat(rows))))
            let maxY = min(rows - 1, max(0, Int(maxNY * CGFloat(rows))))
            guard minX <= maxX, minY <= maxY else { continue }

            for y in minY...maxY {
                for x in minX...maxX {
                    let bucket = y * cols + x
                    if buckets.indices.contains(bucket) {
                        buckets[bucket].append(index)
                    }
                }
            }
        }

        return MT6RenderModel(cells: cells, frames: frames, buckets: buckets, cols: cols, rows: rows, size: size)
    }

    private func safeAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? UInt64.max : value
    }

    private func safeSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(UInt64(0), safeAdd)
    }
}

// MARK: - Treemap views

private struct MT6Treemap: View {
    let nodes: [MT6Node]
    let rootID: Int
    @Binding var selectedID: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(Color.secondary)

                Text(rootPath)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if nodes.indices.contains(rootID) {
                    Text(mt6Bytes(nodes[rootID].allocatedSize))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }

                Spacer()
                Text("Steam games highlighted • hover for details")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))

            colorLegend
            Divider()

            GeometryReader { proxy in
                let size = CGSize(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
                let model = MT6TreemapBuilder(nodes: nodes).build(rootID: rootID, size: size)

                MT6TreemapSurface(
                    nodes: nodes,
                    model: model,
                    selectedID: $selectedID
                )
            }
        }
    }

    private var colorLegend: some View {
        HStack(spacing: 11) {
            legend(.application)
            legend(.video)
            legend(.image)
            legend(.archive)
            legend(.audio)
            legend(.document)
            legend(.code)
            legend(.gameData)
            legend(.system)
            legend(.other)
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func legend(_ category: MT6Category) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(category.color)
                .frame(width: 9, height: 9)
            Text(category.rawValue)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
    }

    private var rootPath: String {
        nodes.indices.contains(rootID) ? nodes[rootID].path : "Treemap"
    }
}

private struct MT6TreemapSurface: View {
    let nodes: [MT6Node]
    let model: MT6RenderModel
    @Binding var selectedID: Int?
    @State private var hoveredCellIndex: Int?
    @State private var hoverAnchor: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(Color(nsColor: .windowBackgroundColor))
                    )

                    for cell in model.cells {
                        guard nodes.indices.contains(cell.nodeID), mt6RectFinite(cell.rect) else { continue }
                        let node = nodes[cell.nodeID]
                        let category = cell.kind == .file
                            ? mt6Category(for: node)
                            : mt6DominantCategory(nodeID: node.id, nodes: nodes)
                        let base = category.color
                        let gradient = GraphicsContext.Shading.linearGradient(
                            Gradient(colors: [base.opacity(0.94), base.opacity(0.68)]),
                            startPoint: CGPoint(x: cell.rect.minX, y: cell.rect.minY),
                            endPoint: CGPoint(x: cell.rect.maxX, y: cell.rect.maxY)
                        )

                        context.fill(Path(cell.rect), with: gradient)
                        context.stroke(
                            Path(cell.rect),
                            with: .color(selectedID == node.id ? Color.white : Color.black.opacity(0.44)),
                            lineWidth: selectedID == node.id ? 2.2 : 0.55
                        )

                        let label = cell.labelOverride ?? node.name
                        let isImportantFolder = node.isDirectory && cell.kind == .aggregate
                        let labelThreshold = isImportantFolder ? (68.0, 30.0) : (92.0, 42.0)
                        if cell.rect.width > labelThreshold.0 && cell.rect.height > labelThreshold.1 {
                            let maxChars = max(5, Int(cell.rect.width / 7.0))
                            let title = Text(mt6Ellipsize(label, maxCharacters: maxChars))
                                .font(isImportantFolder ? .caption2.weight(.bold) : .caption2.weight(.semibold))
                                .foregroundStyle(Color.white)
                            context.draw(
                                title,
                                at: CGPoint(x: cell.rect.minX + 5, y: cell.rect.minY + 4),
                                anchor: .topLeading
                            )

                            if cell.rect.width > 120 && cell.rect.height > 61 {
                                let subtitle = Text(mt6Bytes(cell.representedAllocated))
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.9))
                                context.draw(
                                    subtitle,
                                    at: CGPoint(x: cell.rect.minX + 5, y: cell.rect.minY + 21),
                                    anchor: .topLeading
                                )
                            }
                        }
                    }

                    for frame in model.frames {
                        guard nodes.indices.contains(frame.nodeID), mt6RectFinite(frame.rect) else { continue }

                        if let header = frame.headerRect, mt6RectFinite(header) {
                            context.fill(
                                Path(header),
                                with: .color(frame.isSteamGame ? Color.black.opacity(0.76) : Color.black.opacity(frame.depth == 0 ? 0.58 : 0.45))
                            )
                            let maxChars = max(6, Int(header.width / 7.0))
                            let titleText = mt6Ellipsize(frame.label, maxCharacters: maxChars)
                            let label = Text(titleText)
                                .font(frame.isSteamGame ? .caption.weight(.bold) : (frame.depth == 0 ? .caption.weight(.bold) : .caption2.weight(.semibold)))
                                .foregroundStyle(frame.isSteamGame ? Color.yellow : Color.white.opacity(0.97))
                            context.draw(
                                label,
                                at: CGPoint(x: header.minX + 5, y: header.minY + 2),
                                anchor: .topLeading
                            )

                            if frame.isSteamGame && header.width > 180 {
                                let sizeLabel = Text(mt6Bytes(nodes[frame.nodeID].allocatedSize))
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.82))
                                context.draw(
                                    sizeLabel,
                                    at: CGPoint(x: header.maxX - 5, y: header.minY + 3),
                                    anchor: .topTrailing
                                )
                            }
                        }

                        context.stroke(
                            Path(frame.rect),
                            with: .color(frame.isSteamGame ? Color.yellow.opacity(0.75) : Color.white.opacity(frame.depth == 0 ? 0.40 : 0.18)),
                            lineWidth: frame.isSteamGame ? 1.7 : (frame.depth == 0 ? 1.35 : 0.7)
                        )
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let hit = model.hitTest(point)
                        if hit != hoveredCellIndex {
                            hoveredCellIndex = hit
                            hoverAnchor = point
                        }
                    case .ended:
                        hoveredCellIndex = nil
                    }
                }
                .onTapGesture {
                    if let index = hoveredCellIndex,
                       model.cells.indices.contains(index) {
                        selectedID = model.cells[index].nodeID
                    }
                }

                if let index = hoveredCellIndex,
                   model.cells.indices.contains(index) {
                    hoverCard(cell: model.cells[index], containerSize: proxy.size)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
    }

    private func hoverCard(cell: MT6Cell, containerSize: CGSize) -> some View {
        let node = nodes[cell.nodeID]
        let category = cell.kind == .file ? mt6Category(for: node) : mt6DominantCategory(nodeID: node.id, nodes: nodes)
        let gameName = mt6SteamGameName(forPath: node.path)
        let cardWidth: CGFloat = 430
        let cardHeight: CGFloat = gameName == nil ? 142 : 162

        let rightCandidate = hoverAnchor.x + 18
        let x: CGFloat
        if rightCandidate + cardWidth <= containerSize.width - 8 {
            x = rightCandidate
        } else {
            x = max(8, hoverAnchor.x - cardWidth - 18)
        }

        let y = min(max(8, hoverAnchor.y + 14), max(8, containerSize.height - cardHeight - 8))

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : category.color)

                Text(cell.labelOverride ?? node.name)
                    .font(.callout.weight(.bold))
                    .lineLimit(1)

                Spacer()

                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(category.color)
                        .frame(width: 10, height: 10)
                    Text(category.rawValue)
                        .font(.caption.weight(.semibold))
                }
            }

            if let gameName {
                HStack(spacing: 5) {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(Color.yellow)
                    Text("Steam game: \(gameName)")
                        .font(.caption.weight(.semibold))
                }
            }

            HStack(spacing: 14) {
                infoPair("Allocated", mt6Bytes(cell.representedAllocated))
                infoPair("Logical", mt6Bytes(node.logicalSize))
                infoPair("Files", cell.representedFiles.formatted())
                infoPair("Type", node.isDirectory ? (cell.labelOverride == "Other items" ? "Grouped" : "Folder") : mt6FileTypeLabel(node))
            }
            .font(.caption2)

            Text(node.path)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(11)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(radius: 8)
        .offset(x: x, y: y)
    }

    private func infoPair(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).foregroundStyle(Color.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }
}

// MARK: - Helpers

private func mt6RectFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite &&
    rect.origin.y.isFinite &&
    rect.size.width.isFinite &&
    rect.size.height.isFinite &&
    rect.width >= 0 &&
    rect.height >= 0
}

private func mt6SafeInset(_ rect: CGRect, _ amount: CGFloat) -> CGRect {
    guard mt6RectFinite(rect) else { return .zero }
    let dx = min(max(0, amount), max(0, rect.width / 2 - 0.05))
    let dy = min(max(0, amount), max(0, rect.height / 2 - 0.05))
    let result = rect.insetBy(dx: dx, dy: dy)
    return mt6RectFinite(result) ? result : rect
}

private func mt6Ellipsize(_ text: String, maxCharacters: Int) -> String {
    guard maxCharacters > 1, text.count > maxCharacters else { return text }
    let end = text.index(text.startIndex, offsetBy: max(1, maxCharacters - 1))
    return String(text[..<end]) + "…"
}

private func mt6FileTypeLabel(_ node: MT6Node) -> String {
    let ext = (node.name as NSString).pathExtension.lowercased()
    return ext.isEmpty ? "File" : ".\(ext)"
}

private func mt6SteamGameName(forPath path: String) -> String? {
    let marker = "/steamapps/common/"
    guard let range = path.range(of: marker, options: [.caseInsensitive]) else { return nil }
    let suffix = String(path[range.upperBound...])
    guard !suffix.isEmpty else { return nil }
    return suffix.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init)
}

private func mt6DominantCategory(nodeID: Int, nodes: [MT6Node]) -> MT6Category {
    guard nodes.indices.contains(nodeID) else { return .other }
    var current = nodes[nodeID]
    var steps = 0

    if mt6Category(for: current) != .other {
        return mt6Category(for: current)
    }

    while current.isDirectory && !current.children.isEmpty && steps < 12 {
        guard let largestID = current.children.first,
              nodes.indices.contains(largestID) else { break }
        current = nodes[largestID]
        let category = mt6Category(for: current)
        if !current.isDirectory && category != .other {
            return category
        }
        steps += 1
    }

    return mt6Category(for: current)
}

private func mt6Bytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(clamping: value))
}
