import SwiftUI
import AppKit
import Darwin

@main
struct MacTreeV9App: App {
    var body: some Scene {
        WindowGroup {
            MainViewV9()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 860)
    }
}

// MARK: - Data

struct MT9Node: Identifiable, Hashable, Sendable {
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

struct MT9Progress: Sendable {
    let items: UInt64
    let files: UInt64
    let logical: UInt64
    let allocated: UInt64
    let currentPath: String
    let elapsed: TimeInterval
}

struct MT9Snapshot: Sendable {
    let nodes: [MT9Node]
    let rootID: Int
    let items: UInt64
    let files: UInt64
    let logical: UInt64
    let allocated: UInt64
    let elapsed: TimeInterval
}

// MARK: - Scanner

actor MT9Scanner {
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

    func scan(root: URL, progress: @escaping @Sendable (MT9Progress) async -> Void) async throws -> MT9Snapshot {
        let started = CFAbsoluteTimeGetCurrent()
        let rootPath = root.standardizedFileURL.path
        let rootName = root.lastPathComponent.isEmpty ? "Macintosh HD" : root.lastPathComponent

        var builders: [Builder] = [
            Builder(id: 0, parentID: nil, name: rootName, path: rootPath, isDirectory: true,
                    logicalSize: 0, allocatedSize: 0, fileCount: 0, modifiedTime: 0, children: [])
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
                logical = mt9SafeAdd(logical, logicalSize)
                allocated = mt9SafeAdd(allocated, allocatedSize)
            }

            let id = builders.count
            builders.append(
                Builder(id: id, parentID: parentID, name: name, path: fullPath, isDirectory: isDirectory,
                        logicalSize: logicalSize, allocatedSize: allocatedSize, fileCount: fileCount,
                        modifiedTime: TimeInterval(info.st_mtimespec.tv_sec), children: [])
            )
            builders[parentID].children.append(id)
            if isDirectory { directoryIDs[relative] = id }

            if publishCounter >= 35_000 {
                await progress(MT9Progress(items: items, files: files, logical: logical, allocated: allocated,
                                           currentPath: currentPath, elapsed: CFAbsoluteTimeGetCurrent() - started))
                publishCounter = 0
            }
        }

        if builders.count > 1 {
            for index in stride(from: builders.count - 1, through: 1, by: -1) {
                guard let parent = builders[index].parentID else { continue }
                builders[parent].logicalSize = mt9SafeAdd(builders[parent].logicalSize, builders[index].logicalSize)
                builders[parent].allocatedSize = mt9SafeAdd(builders[parent].allocatedSize, builders[index].allocatedSize)
                builders[parent].fileCount = mt9SafeAdd(builders[parent].fileCount, builders[index].fileCount)
            }
        }

        var nodes = builders.map {
            MT9Node(id: $0.id, parentID: $0.parentID, name: $0.name, path: $0.path,
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
        await progress(MT9Progress(items: items, files: files, logical: logical, allocated: allocated,
                                   currentPath: currentPath, elapsed: elapsed))
        return MT9Snapshot(nodes: nodes, rootID: 0, items: items, files: files,
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

// MARK: - Search

@MainActor
final class MT9SearchModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var resultIDs: [Int] = []
    @Published private(set) var isSearching = false

    private var nodes: [MT9Node] = []
    private var task: Task<Void, Never>?

    func setNodes(_ newNodes: [MT9Node]) {
        task?.cancel()
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
            return
        }

        let snapshot = nodes
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            let lowered = needle.lowercased()
            let ids = await Task.detached(priority: .userInitiated) {
                var hits: [(Int, UInt64)] = []
                hits.reserveCapacity(1000)
                for node in snapshot.dropFirst() {
                    if Task.isCancelled { return [Int]() }
                    if node.name.lowercased().contains(lowered) || node.path.lowercased().contains(lowered) {
                        hits.append((node.id, node.allocatedSize))
                        if hits.count >= 5000 { break }
                    }
                }
                hits.sort { $0.1 > $1.1 }
                return Array(hits.prefix(2000).map { $0.0 })
            }.value
            guard !Task.isCancelled, let self else { return }
            self.resultIDs = ids
            self.isSearching = false
        }
    }
}

// MARK: - Controller

@MainActor
final class MT9Controller: ObservableObject {
    @Published var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @Published var nodes: [MT9Node] = []
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

    let search = MT9SearchModel()
    private let scanner = MT9Scanner()
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
        var fs = statfs()
        let path = rootURL.path
        guard path.withCString({ Darwin.statfs($0, &fs) }) == 0 else {
            volumeTotal = 0
            volumeFree = 0
            return
        }
        let blockSize = UInt64(fs.f_bsize)
        volumeTotal = mt9SafeMultiply(UInt64(fs.f_blocks), blockSize)
        volumeFree = mt9SafeMultiply(UInt64(fs.f_bavail), blockSize)
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
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
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isScanning = false
    }
}

// MARK: - Main UI

struct MainViewV9: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MT9Controller()
    @State private var expanded: Set<Int> = []
    @State private var selectedID: Int?
    @State private var hoveredID: Int?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()
            VSplitView {
                MT9TreePane(nodes: controller.nodes,
                            rootID: controller.rootID,
                            totalAllocated: controller.allocated,
                            scanVersion: controller.scanVersion,
                            searchModel: controller.search,
                            expanded: $expanded,
                            selectedID: $selectedID,
                            hoveredID: $hoveredID)
                    .frame(minHeight: 290)

                MT9Treemap(nodes: controller.nodes,
                           rootID: controller.rootID,
                           selectedID: $selectedID,
                           hoveredID: $hoveredID)
                    .frame(minHeight: 320)
            }
            Divider()
            status
        }
        .onChange(of: controller.scanVersion) { _, _ in
            expanded.removeAll()
            selectedID = nil
            hoveredID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.refreshFullDiskAccess()
                controller.refreshVolumeSpace()
            }
        }
        .alert("MacTree", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )) {
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
                Label(controller.fullDiskAccess ? "Full Disk Access" : "Grant Full Disk Access",
                      systemImage: controller.fullDiskAccess ? "lock.open.fill" : "lock.shield")
            }
            .foregroundStyle(controller.fullDiskAccess ? Color.green : Color.secondary)

            Spacer()
            MT9SearchField(model: controller.search)
            Label(controller.isScanning ? "Scanning" : "Ready",
                  systemImage: controller.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .foregroundStyle(controller.isScanning ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var summary: some View {
        let freePercent = controller.volumeTotal > 0
            ? Double(controller.volumeFree) / Double(controller.volumeTotal)
            : 0
        return HStack(spacing: 18) {
            metric("Allocated", mt9Bytes(controller.allocated))
            metric("Logical", mt9Bytes(controller.logical))
            metric("Disk", mt9Bytes(controller.volumeTotal))
            HStack(spacing: 5) {
                Text("Free:").foregroundStyle(Color.secondary)
                Text(mt9Bytes(controller.volumeFree)).fontWeight(.semibold).monospacedDigit()
                if controller.volumeTotal > 0 {
                    Text(freePercent, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
            }
            metric("Files", controller.files.formatted())
            metric("Items", controller.items.formatted())
            Text("iCloud skipped")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1), in: Capsule())
            Spacer(minLength: 8)
            if controller.isScanning { ProgressView().controlSize(.small) }
            Text(controller.elapsed.formatted(.number.precision(.fractionLength(1))) + " s")
                .foregroundStyle(Color.secondary).monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
    }

    private var status: some View {
        HStack(spacing: 10) {
            if controller.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning \(controller.items.formatted()) items").fontWeight(.semibold)
                Text(controller.currentPath).foregroundStyle(Color.secondary).lineLimit(1)
            } else {
                Text("Scanned \(controller.files.formatted()) files in \(controller.elapsed.formatted(.number.precision(.fractionLength(1)))) s")
            }
            Spacer()
            let activeID = hoveredID ?? selectedID
            if let activeID, controller.nodes.indices.contains(activeID) {
                let node = controller.nodes[activeID]
                Text((hoveredID != nil ? "Hover: " : "Selected: ") + node.path + "   " + mt9Bytes(node.allocatedSize))
                    .foregroundStyle(Color.secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var locationTitle: String {
        if controller.rootURL.path == "/" { return "Macintosh HD" }
        let name = controller.rootURL.lastPathComponent
        return name.isEmpty ? controller.rootURL.path : name
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title + ":").foregroundStyle(Color.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }
}

private struct MT9SearchField: View {
    @ObservedObject var model: MT9SearchModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            if model.isSearching { ProgressView().controlSize(.mini) }
            TextField("Search files and folders", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onChange(of: text) { _, value in model.search(value) }
        }
    }
}

// MARK: - Tree pane

private struct MT9TreePane: View {
    let nodes: [MT9Node]
    let rootID: Int
    let totalAllocated: UInt64
    let scanVersion: Int
    @ObservedObject var searchModel: MT9SearchModel
    @Binding var expanded: Set<Int>
    @Binding var selectedID: Int?
    @Binding var hoveredID: Int?

    private struct Row: Identifiable {
        let node: MT9Node
        let depth: Int
        var id: Int { node.id }
    }

    var body: some View {
        let currentRows = rows
        let visibleHoverID = nearestVisibleHoverID(in: currentRows)

        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(currentRows) { row in
                        MT9TreeRow(node: row.node,
                                   depth: row.depth,
                                   total: max(totalAllocated, 1),
                                   isExpanded: expanded.contains(row.node.id),
                                   isSelected: selectedID == row.node.id,
                                   isHovered: visibleHoverID == row.node.id,
                                   toggle: { toggle(row.node.id) },
                                   select: { selectedID = row.node.id },
                                   hover: { inside in
                                       if inside {
                                           hoveredID = row.node.id
                                       } else if hoveredID == row.node.id {
                                           hoveredID = nil
                                       }
                                   },
                                   open: {
                                       selectedID = row.node.id
                                       if row.node.isDirectory && !row.node.children.isEmpty { toggle(row.node.id) }
                                   })
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
        .id(scanVersion)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private var rows: [Row] {
        guard !nodes.isEmpty else { return [] }
        if !searchModel.query.isEmpty {
            return searchModel.resultIDs.compactMap { id in
                guard nodes.indices.contains(id) else { return nil }
                return Row(node: nodes[id], depth: 0)
            }
        }

        var result: [Row] = []
        func appendChildren(_ parent: Int, depth: Int) {
            guard nodes.indices.contains(parent) else { return }
            for childID in nodes[parent].children {
                guard nodes.indices.contains(childID) else { continue }
                let child = nodes[childID]
                result.append(Row(node: child, depth: depth))
                if child.isDirectory && expanded.contains(child.id) {
                    appendChildren(child.id, depth: depth + 1)
                }
            }
        }
        appendChildren(rootID, depth: 0)
        return result
    }

    private func nearestVisibleHoverID(in rows: [Row]) -> Int? {
        guard var id = hoveredID else { return nil }
        let visible = Set(rows.map(\.id))
        while nodes.indices.contains(id) {
            if visible.contains(id) { return id }
            guard let parent = nodes[id].parentID else { break }
            id = parent
        }
        return nil
    }

    private func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func header(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text).frame(width: width, alignment: alignment).padding(.horizontal, 6)
    }
}

private struct MT9TreeRow: View {
    let node: MT9Node
    let depth: Int
    let total: UInt64
    let isExpanded: Bool
    let isSelected: Bool
    let isHovered: Bool
    let toggle: () -> Void
    let select: () -> Void
    let hover: (Bool) -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(depth) * 17)
                if node.isDirectory && !node.children.isEmpty {
                    Button(action: toggle) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold)).frame(width: 14)
                    }.buttonStyle(.plain)
                } else { Color.clear.frame(width: 14) }
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : Color.secondary).frame(width: 17)
                Text(node.name).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 330, alignment: .leading).padding(.horizontal, 6)
            cell(mt9Bytes(node.logicalSize), 105, .trailing)
            cell(mt9Bytes(node.allocatedSize), 105, .trailing)
            cell(node.fileCount.formatted(), 90, .trailing)
            HStack(spacing: 7) {
                let ratio = Double(node.allocatedSize) / Double(max(total, 1))
                ProgressView(value: ratio).frame(width: 66)
                Text(ratio, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit().frame(width: 58, alignment: .trailing)
            }
            .frame(width: 145, alignment: .leading).padding(.horizontal, 6)
            let modified = node.modifiedTime > 0
                ? Date(timeIntervalSince1970: node.modifiedTime).formatted(date: .numeric, time: .shortened)
                : "—"
            cell(modified, 165, .leading)
            Text(node.path).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                .frame(width: 390, alignment: .leading).padding(.horizontal, 6)
        }
        .font(.callout).frame(height: 29)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.30) }
        if isHovered { return Color.accentColor.opacity(0.15) }
        return node.id.isMultiple(of: 2) ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.28)
    }

    private func cell(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text).monospacedDigit().lineLimit(1).frame(width: width, alignment: alignment).padding(.horizontal, 6)
    }
}

// MARK: - Categories

private enum MT9Category: String, CaseIterable {
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
        case .application: return .green
        case .video: return .purple
        case .image: return .pink
        case .archive: return .orange
        case .audio: return .cyan
        case .document: return .blue
        case .code: return .teal
        case .database: return .indigo
        case .cache: return .yellow
        case .appData: return .mint
        case .gameData: return .red
        case .config: return .brown
        case .logs: return Color(nsColor: .systemGray)
        case .temp: return Color(nsColor: .systemOrange)
        case .system: return Color(nsColor: .systemGreen)
        case .other: return Color(nsColor: .darkGray)
        }
    }
}

private func mt9DirectCategory(_ node: MT9Node) -> MT9Category {
    let name = node.name.lowercased()
    let path = node.path.lowercased()

    if path.contains("/library/caches/") || name == "cache" || name == "caches" || name == "cacheddata" ||
        name == "code cache" || name == "gpucache" || name.hasSuffix(".cache") { return .cache }
    if path.contains("/library/logs/") || name == "log" || name == "logs" || name.hasSuffix(".log") { return .logs }
    if path.contains("/library/preferences/") || name == "preferences" || name == "config" || name == "configs" ||
        name == ".config" || name == "settings" { return .config }
    if name == "tmp" || name == "temp" || name == "temporary" || path.contains("/tmp/") { return .temp }
    if path.contains("/steamapps/common/") || path.contains("/games/") || name == "gamedata" || name == "game data" { return .gameData }
    if path.contains(".app/contents/") || name.hasSuffix(".app") { return .application }
    if path.contains("/library/application support/") || path.contains("/library/containers/") ||
        path.contains("/library/group containers/") || name == "application support" || name == "containers" ||
        name == "group containers" || name == "saved application state" { return .appData }
    if path.contains("/developer/") || path.contains("/deriveddata/") || path.contains("/sourcepackages/") ||
        name == "developer" || name == "deriveddata" || name == "sourcepackages" || name == "node_modules" ||
        name == ".gradle" || name == ".swiftpm" || name == ".npm" || name == ".cargo" { return .code }
    if path.contains("/system/") || path.contains("/library/frameworks/") || name.hasSuffix(".framework") || name == "coreservices" { return .system }

    if node.isDirectory {
        if ["movies", "videos", "video"].contains(name) { return .video }
        if ["pictures", "images", "image", "photos"].contains(name) { return .image }
        if ["music", "audio", "sounds", "sound"].contains(name) { return .audio }
        if ["documents", "docs"].contains(name) { return .document }
        if ["database", "databases"].contains(name) { return .database }
        return .other
    }

    let ext = (node.name as NSString).pathExtension.lowercased()
    switch ext {
    case "app", "exe": return .application
    case "mp4", "mov", "mkv", "avi", "webm", "m4v", "mpeg", "mpg": return .video
    case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp", "svg": return .image
    case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso", "jar": return .archive
    case "mp3", "aac", "m4a", "wav", "flac", "ogg", "aiff", "bank": return .audio
    case "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "csv", "xls", "xlsx", "ppt", "pptx": return .document
    case "swift", "c", "cpp", "cc", "h", "hpp", "js", "ts", "py", "java", "kt", "rs", "go", "rb", "php", "css", "html": return .code
    case "db", "sqlite", "sqlite3", "realm", "mdb": return .database
    case "ini", "cfg", "conf", "plist", "yaml", "yml", "toml": return .config
    case "log": return .logs
    case "pak", "vpk", "wad", "pck", "bundle", "assets", "asset", "res", "resource", "dat", "bin", "obb", "unity3d": return .gameData
    case "dylib", "so", "framework", "kext": return .system
    default: return .other
    }
}

private func mt9BestCategory(_ nodeID: Int, _ nodes: [MT9Node]) -> MT9Category {
    guard nodes.indices.contains(nodeID) else { return .other }
    let node = nodes[nodeID]
    let direct = mt9DirectCategory(node)
    if direct != .other { return direct }
    guard node.isDirectory && !node.children.isEmpty else { return .other }

    var weights: [MT9Category: UInt64] = [:]
    for childID in node.children.prefix(40) {
        guard nodes.indices.contains(childID) else { continue }
        let child = nodes[childID]
        let category = mt9DirectCategory(child)
        if category == .other && child.isDirectory {
            for grandID in child.children.prefix(10) {
                guard nodes.indices.contains(grandID) else { continue }
                let grand = nodes[grandID]
                let grandCategory = mt9DirectCategory(grand)
                if grandCategory != .other {
                    weights[grandCategory, default: 0] = mt9SafeAdd(weights[grandCategory, default: 0], grand.allocatedSize)
                }
            }
        } else if category != .other {
            weights[category, default: 0] = mt9SafeAdd(weights[category, default: 0], child.allocatedSize)
        }
    }
    return weights.max(by: { $0.value < $1.value })?.key ?? .other
}

private func mt9CategoryForGroup(_ ids: ArraySlice<Int>, _ nodes: [MT9Node], fallback: MT9Category) -> MT9Category {
    var weights: [MT9Category: UInt64] = [:]
    for id in ids.prefix(80) {
        guard nodes.indices.contains(id) else { continue }
        let category = mt9BestCategory(id, nodes)
        if category != .other {
            weights[category, default: 0] = mt9SafeAdd(weights[category, default: 0], nodes[id].allocatedSize)
        }
    }
    return weights.max(by: { $0.value < $1.value })?.key ?? fallback
}

// MARK: - Treemap model

private enum MT9CellKind { case file, aggregate }

private struct MT9Cell: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let depth: Int
    let kind: MT9CellKind
    let label: String
    let representedAllocated: UInt64
    let representedFiles: UInt64
    let category: MT9Category
}

private struct MT9Frame: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let headerRect: CGRect?
    let depth: Int
}

private struct MT9RenderModel {
    let cells: [MT9Cell]
    let frames: [MT9Frame]
    let buckets: [[Int]]
    let cols: Int
    let rows: Int
    let size: CGSize

    static func empty(_ size: CGSize = .zero) -> MT9RenderModel {
        MT9RenderModel(cells: [], frames: [], buckets: [], cols: 0, rows: 0, size: size)
    }

    func hitTest(_ point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < size.width, point.y < size.height, cols > 0, rows > 0 else { return nil }
        let nx = max(0, min(0.999999, point.x / max(1, size.width)))
        let ny = max(0, min(0.999999, point.y / max(1, size.height)))
        guard nx.isFinite, ny.isFinite else { return nil }
        let gx = min(cols - 1, max(0, Int(nx * CGFloat(cols))))
        let gy = min(rows - 1, max(0, Int(ny * CGFloat(rows))))
        let bucket = gy * cols + gx
        guard buckets.indices.contains(bucket) else { return nil }
        for cellIndex in buckets[bucket].reversed() {
            guard cells.indices.contains(cellIndex) else { continue }
            if cells[cellIndex].rect.contains(point) { return cellIndex }
        }
        return nil
    }
}

private struct MT9WeightedEntry {
    let token: Int
    let weight: UInt64
}

private struct MT9WeightedLayout {
    func layout(_ entries: [MT9WeightedEntry], in rect: CGRect) -> [(Int, CGRect)] {
        let rect = rect.standardized
        guard mt9RectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return [] }
        let valid = entries.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard !valid.isEmpty else { return [] }
        var output: [(Int, CGRect)] = []
        split(valid, rect, &output)
        return output
    }

    private func split(_ entries: [MT9WeightedEntry], _ rect: CGRect, _ output: inout [(Int, CGRect)]) {
        guard !entries.isEmpty, mt9RectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }
        if entries.count == 1 {
            output.append((entries[0].token, rect))
            return
        }
        let total = entries.reduce(UInt64(0)) { mt9SafeAdd($0, $1.weight) }
        guard total > 0 else { return }
        let target = Double(total) / 2
        var running = 0.0
        var splitIndex = 1
        for i in 0..<(entries.count - 1) {
            running += Double(entries[i].weight)
            splitIndex = i + 1
            if running >= target { break }
        }
        splitIndex = max(1, min(entries.count - 1, splitIndex))
        let left = Array(entries[..<splitIndex])
        let right = Array(entries[splitIndex...])
        let leftTotal = left.reduce(UInt64(0)) { mt9SafeAdd($0, $1.weight) }
        var fraction = Double(leftTotal) / Double(total)
        if !fraction.isFinite { fraction = 0.5 }
        fraction = max(0.001, min(0.999, fraction))

        if rect.width >= rect.height {
            let width = rect.width * CGFloat(fraction)
            guard width.isFinite else { return }
            split(left, CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), &output)
            split(right, CGRect(x: rect.minX + width, y: rect.minY,
                                width: max(0, rect.width - width), height: rect.height), &output)
        } else {
            let height = rect.height * CGFloat(fraction)
            guard height.isFinite else { return }
            split(left, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height), &output)
            split(right, CGRect(x: rect.minX, y: rect.minY + height,
                                width: rect.width, height: max(0, rect.height - height)), &output)
        }
    }
}

private struct MT9TreemapBuilder {
    let nodes: [MT9Node]
    private let maxCells = 2200
    private let maxDepth = 12
    private let minExpandArea: CGFloat = 170
    private let minExpandSide: CGFloat = 10
    private let maxChildrenPerFolder = 58

    func build(rootID: Int, size: CGSize) -> MT9RenderModel {
        guard nodes.indices.contains(rootID), size.width.isFinite, size.height.isFinite,
              size.width > 4, size.height > 4 else { return .empty(size) }

        let children = nodes[rootID].children.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }
        guard !children.isEmpty else { return .empty(size) }
        let total = children.reduce(UInt64(0)) { mt9SafeAdd($0, nodes[$1].allocatedSize) }
        guard total > 0 else { return .empty(size) }

        let layout = MT9WeightedLayout()
        let rootRects = layout.layout(children.map { MT9WeightedEntry(token: $0, weight: nodes[$0].allocatedSize) },
                                      in: CGRect(origin: .zero, size: size))
        var cells: [MT9Cell] = []
        var frames: [MT9Frame] = []
        cells.reserveCapacity(maxCells)
        frames.reserveCapacity(650)

        var remainingBudget = maxCells
        for (i, pair) in rootRects.enumerated() {
            let id = pair.0
            let proportional = max(1, Int((Double(maxCells) * Double(nodes[id].allocatedSize) / Double(total)).rounded(.down)))
            let siblingsLeft = rootRects.count - i
            let budget = max(1, min(max(1, remainingBudget - max(0, siblingsLeft - 1)), proportional))
            render(id: id, rect: pair.1, depth: 0, budget: budget, layout: layout,
                   cells: &cells, frames: &frames)
            remainingBudget = max(0, maxCells - cells.count)
        }
        return makeModel(cells, frames, size)
    }

    private func render(id: Int, rect: CGRect, depth: Int, budget: Int,
                        layout: MT9WeightedLayout, cells: inout [MT9Cell], frames: inout [MT9Frame]) {
        let rect = rect.standardized
        guard nodes.indices.contains(id), mt9RectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }
        let node = nodes[id]
        let nodeCategory = mt9BestCategory(id, nodes)

        if !node.isDirectory {
            appendCell(node, rect, depth, .file, node.name, node.allocatedSize, 1, nodeCategory, &cells)
            return
        }

        let children = node.children.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }
        let area = rect.width * rect.height
        let canExpand = budget > 1 && depth < maxDepth && area.isFinite && area >= minExpandArea &&
            rect.width >= minExpandSide && rect.height >= minExpandSide && !children.isEmpty

        guard canExpand else {
            appendCell(node, rect, depth, .aggregate, node.name, node.allocatedSize, node.fileCount, nodeCategory, &cells)
            return
        }

        let showHeader = depth <= 7 && rect.width >= 74 && rect.height >= 32
        let headerHeight: CGFloat = showHeader ? 11 : 0
        let headerRect = showHeader
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
            : nil
        frames.append(MT9Frame(id: frames.count, nodeID: id, rect: rect, headerRect: headerRect, depth: depth))

        let content = CGRect(x: rect.minX + 0.7, y: rect.minY + headerHeight + 0.7,
                             width: max(0, rect.width - 1.4), height: max(0, rect.height - headerHeight - 1.4))
        guard mt9RectFinite(content), content.width > 2, content.height > 2 else {
            appendCell(node, rect, depth, .aggregate, node.name, node.allocatedSize, node.fileCount, nodeCategory, &cells)
            return
        }

        let allowed = max(1, min(maxChildrenPerFolder, budget))
        let keepCount = min(children.count, allowed)
        var real = Array(children.prefix(keepCount))
        var remainderWeight: UInt64 = 0
        var remainderFiles: UInt64 = 0
        var remainderSlice: ArraySlice<Int> = []

        if children.count > keepCount {
            real = Array(children.prefix(max(1, keepCount - 1)))
            remainderSlice = children.dropFirst(real.count)
            for childID in remainderSlice {
                remainderWeight = mt9SafeAdd(remainderWeight, nodes[childID].allocatedSize)
                remainderFiles = mt9SafeAdd(remainderFiles, nodes[childID].fileCount)
            }
        }

        var entries = real.map { MT9WeightedEntry(token: $0, weight: nodes[$0].allocatedSize) }
        let remainderToken = -1
        if remainderWeight > 0 { entries.append(MT9WeightedEntry(token: remainderToken, weight: remainderWeight)) }
        guard !entries.isEmpty else {
            appendCell(node, content, depth + 1, .aggregate, node.name, node.allocatedSize, node.fileCount, nodeCategory, &cells)
            return
        }

        let rects = layout.layout(entries, in: content)
        let totalWeight = entries.reduce(UInt64(0)) { mt9SafeAdd($0, $1.weight) }
        let extraBudget = max(0, budget - rects.count)
        var shares = Array(repeating: 0, count: rects.count)
        if extraBudget > 0 && totalWeight > 0 {
            var assigned = 0
            for index in rects.indices {
                let token = rects[index].0
                let weight = token == remainderToken ? remainderWeight : (nodes.indices.contains(token) ? nodes[token].allocatedSize : 0)
                shares[index] = max(0, Int((Double(extraBudget) * Double(weight) / Double(totalWeight)).rounded(.down)))
                assigned += shares[index]
            }
            var left = max(0, extraBudget - assigned)
            var cursor = 0
            while left > 0 && !shares.isEmpty {
                shares[cursor % shares.count] += 1
                cursor += 1
                left -= 1
            }
        }

        for index in rects.indices {
            let token = rects[index].0
            if token == remainderToken {
                let countText = remainderFiles > 0 ? "\(remainderFiles.formatted()) items" : "Grouped items"
                let category = mt9CategoryForGroup(remainderSlice, nodes, fallback: nodeCategory)
                appendCell(node, rects[index].1, depth + 1, .aggregate, countText,
                           remainderWeight, remainderFiles, category, &cells)
            } else {
                render(id: token, rect: rects[index].1, depth: depth + 1, budget: 1 + shares[index],
                       layout: layout, cells: &cells, frames: &frames)
            }
        }
    }

    private func appendCell(_ node: MT9Node, _ rect: CGRect, _ depth: Int, _ kind: MT9CellKind,
                            _ label: String, _ allocated: UInt64, _ files: UInt64,
                            _ category: MT9Category, _ cells: inout [MT9Cell]) {
        let safe = mt9SafeInset(rect, 0.32)
        guard mt9RectFinite(safe), safe.width > 0.25, safe.height > 0.25 else { return }
        cells.append(MT9Cell(id: cells.count, nodeID: node.id, rect: safe, depth: depth, kind: kind,
                             label: label, representedAllocated: allocated, representedFiles: files,
                             category: category))
    }

    private func makeModel(_ cells: [MT9Cell], _ frames: [MT9Frame], _ size: CGSize) -> MT9RenderModel {
        let cols = max(14, min(56, Int(max(1, size.width) / 26)))
        let rows = max(9, min(38, Int(max(1, size.height) / 26)))
        var buckets = Array(repeating: [Int](), count: max(1, cols * rows))
        for (index, cell) in cells.enumerated() {
            let r = cell.rect.standardized
            guard mt9RectFinite(r), r.width > 0, r.height > 0 else { continue }
            let minNX = max(0, min(0.999999, r.minX / max(1, size.width)))
            let maxNX = max(0, min(0.999999, max(r.minX, r.maxX - 0.01) / max(1, size.width)))
            let minNY = max(0, min(0.999999, r.minY / max(1, size.height)))
            let maxNY = max(0, min(0.999999, max(r.minY, r.maxY - 0.01) / max(1, size.height)))
            guard minNX.isFinite, maxNX.isFinite, minNY.isFinite, maxNY.isFinite else { continue }
            let minX = min(cols - 1, max(0, Int(minNX * CGFloat(cols))))
            let maxX = min(cols - 1, max(0, Int(maxNX * CGFloat(cols))))
            let minY = min(rows - 1, max(0, Int(minNY * CGFloat(rows))))
            let maxY = min(rows - 1, max(0, Int(maxNY * CGFloat(rows))))
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    let b = y * cols + x
                    if buckets.indices.contains(b) { buckets[b].append(index) }
                }
            }
        }
        return MT9RenderModel(cells: cells, frames: frames, buckets: buckets,
                              cols: cols, rows: rows, size: size)
    }
}

// MARK: - Treemap views

private struct MT9Treemap: View {
    let nodes: [MT9Node]
    let rootID: Int
    @Binding var selectedID: Int?
    @Binding var hoveredID: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill").foregroundStyle(Color.secondary)
                Text(rootPath).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if nodes.indices.contains(rootID) {
                    Text(mt9Bytes(nodes[rootID].allocatedSize)).font(.caption).foregroundStyle(Color.secondary).monospacedDigit()
                }
                Spacer()
                Text("Linked selection • hover for details")
                    .font(.caption2).foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            legend
            Divider()
            GeometryReader { proxy in
                let size = CGSize(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
                let model = MT9TreemapBuilder(nodes: nodes).build(rootID: rootID, size: size)
                MT9Surface(nodes: nodes, model: model, selectedID: $selectedID, hoveredID: $hoveredID)
            }
        }
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(MT9Category.allCases, id: \.self) { category in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 8, height: 8)
                        Text(category.rawValue).font(.system(size: 9)).foregroundStyle(Color.secondary)
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 2)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
    }

    private var rootPath: String { nodes.indices.contains(rootID) ? nodes[rootID].path : "Treemap" }
}

private struct MT9Surface: View {
    let nodes: [MT9Node]
    let model: MT9RenderModel
    @Binding var selectedID: Int?
    @Binding var hoveredID: Int?
    @State private var hoveredCellIndex: Int?
    @State private var hoverAnchor: CGPoint = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)),
                                 with: .color(Color(nsColor: .windowBackgroundColor)))

                    for cell in model.cells {
                        guard nodes.indices.contains(cell.nodeID), mt9RectFinite(cell.rect) else { continue }
                        let base = cell.category.color
                        let gradient = GraphicsContext.Shading.linearGradient(
                            Gradient(colors: [base.opacity(0.92), base.opacity(0.67)]),
                            startPoint: CGPoint(x: cell.rect.minX, y: cell.rect.minY),
                            endPoint: CGPoint(x: cell.rect.maxX, y: cell.rect.maxY))
                        context.fill(Path(cell.rect), with: gradient)

                        let selected = selectedID == cell.nodeID
                        let hovered = hoveredID == cell.nodeID
                        context.stroke(Path(cell.rect),
                                       with: .color(selected ? Color.white : (hovered ? Color.accentColor : Color.black.opacity(0.38))),
                                       lineWidth: selected ? 2.1 : (hovered ? 1.5 : 0.45))

                        if cell.rect.width > 50 && cell.rect.height > 18 {
                            let maxChars = max(4, Int(cell.rect.width / 6.2))
                            let title = Text(mt9Ellipsize(cell.label, maxCharacters: maxChars))
                                .font(.system(size: cell.rect.width > 110 && cell.rect.height > 38 ? 9 : 8, weight: .semibold))
                                .foregroundStyle(Color.white)
                            context.draw(title,
                                         at: CGPoint(x: cell.rect.minX + 3.5, y: cell.rect.minY + 2.5),
                                         anchor: .topLeading)
                            if cell.rect.width > 105 && cell.rect.height > 43 {
                                let sub = Text(mt9Bytes(cell.representedAllocated))
                                    .font(.system(size: 7.5))
                                    .foregroundStyle(Color.white.opacity(0.82))
                                context.draw(sub,
                                             at: CGPoint(x: cell.rect.minX + 3.5, y: cell.rect.minY + 14.5),
                                             anchor: .topLeading)
                            }
                        }
                    }

                    for frame in model.frames {
                        guard nodes.indices.contains(frame.nodeID), mt9RectFinite(frame.rect) else { continue }
                        if let header = frame.headerRect, mt9RectFinite(header) {
                            context.fill(Path(header),
                                         with: .color(Color.black.opacity(frame.depth == 0 ? 0.48 : 0.34)))
                            let maxChars = max(5, Int(header.width / 6.0))
                            let label = Text(mt9Ellipsize(nodes[frame.nodeID].name, maxCharacters: maxChars))
                                .font(.system(size: frame.depth <= 1 ? 8.5 : 8, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.94))
                            context.draw(label,
                                         at: CGPoint(x: header.minX + 3.5, y: header.minY + 0.5),
                                         anchor: .topLeading)
                        }

                        let selected = selectedID == frame.nodeID
                        let hovered = hoveredID == frame.nodeID
                        context.stroke(Path(frame.rect),
                                       with: .color(selected ? Color.white : (hovered ? Color.accentColor : Color.white.opacity(frame.depth == 0 ? 0.30 : 0.13))),
                                       lineWidth: selected ? 2.2 : (hovered ? 1.5 : (frame.depth == 0 ? 0.9 : 0.45)))
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
                            if let hit, model.cells.indices.contains(hit) {
                                hoveredID = model.cells[hit].nodeID
                            } else {
                                hoveredID = nil
                            }
                        }
                    case .ended:
                        hoveredCellIndex = nil
                        hoveredID = nil
                    }
                }
                .onTapGesture {
                    if let index = hoveredCellIndex, model.cells.indices.contains(index) {
                        selectedID = model.cells[index].nodeID
                    }
                }

                if let index = hoveredCellIndex, model.cells.indices.contains(index) {
                    hoverCard(model.cells[index], proxy.size).allowsHitTesting(false)
                }
            }
            .clipped()
        }
    }

    private func hoverCard(_ cell: MT9Cell, _ size: CGSize) -> some View {
        let node = nodes[cell.nodeID]
        let cardWidth: CGFloat = 430
        let cardHeight: CGFloat = 150
        let x = hoverAnchor.x + 18 + cardWidth <= size.width - 8
            ? hoverAnchor.x + 18
            : max(8, hoverAnchor.x - cardWidth - 18)
        let y = min(max(8, hoverAnchor.y + 14), max(8, size.height - cardHeight - 8))

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : cell.category.color)
                Text(cell.label).font(.callout.weight(.bold)).lineLimit(1)
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(cell.category.color).frame(width: 10, height: 10)
                Text(cell.category.rawValue).font(.caption.weight(.semibold))
            }
            HStack(spacing: 16) {
                info("Allocated", mt9Bytes(cell.representedAllocated))
                info("Logical", mt9Bytes(node.logicalSize))
                info("Files", cell.representedFiles.formatted())
                info("Type", node.isDirectory ? (cell.label.contains("items") ? "Grouped" : "Folder") : mt9FileTypeLabel(node))
            }
            .font(.caption2)
            Text(node.path)
                .font(.caption2).foregroundStyle(Color.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
        .padding(11)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(radius: 8)
        .offset(x: x, y: y)
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).foregroundStyle(Color.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }
}

// MARK: - Helpers

private func mt9RectFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite &&
    rect.width >= 0 && rect.height >= 0
}

private func mt9SafeInset(_ rect: CGRect, _ amount: CGFloat) -> CGRect {
    guard mt9RectFinite(rect) else { return .zero }
    let dx = min(max(0, amount), max(0, rect.width / 2 - 0.05))
    let dy = min(max(0, amount), max(0, rect.height / 2 - 0.05))
    let result = rect.insetBy(dx: dx, dy: dy)
    return mt9RectFinite(result) ? result : rect
}

private func mt9SafeAdd(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (value, overflow) = a.addingReportingOverflow(b)
    return overflow ? UInt64.max : value
}

private func mt9SafeMultiply(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (value, overflow) = a.multipliedReportingOverflow(by: b)
    return overflow ? UInt64.max : value
}

private func mt9Ellipsize(_ text: String, maxCharacters: Int) -> String {
    guard maxCharacters > 1, text.count > maxCharacters else { return text }
    let end = text.index(text.startIndex, offsetBy: max(1, maxCharacters - 1))
    return String(text[..<end]) + "…"
}

private func mt9FileTypeLabel(_ node: MT9Node) -> String {
    let ext = (node.name as NSString).pathExtension.lowercased()
    return ext.isEmpty ? "File" : ".\(ext)"
}

private func mt9Bytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(clamping: value))
}
