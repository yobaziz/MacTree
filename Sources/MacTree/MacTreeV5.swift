import SwiftUI
import AppKit
import Darwin

@main
struct MacTreeV5App: App {
    var body: some Scene {
        WindowGroup {
            MainViewV5()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 860)
    }
}

// MARK: - Model

struct MT5Node: Identifiable, Hashable, Sendable {
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

struct MT5Progress: Sendable {
    let items: UInt64
    let files: UInt64
    let logical: UInt64
    let allocated: UInt64
    let currentPath: String
    let elapsed: TimeInterval
}

struct MT5Snapshot: Sendable {
    let nodes: [MT5Node]
    let rootID: Int
    let items: UInt64
    let files: UInt64
    let logical: UInt64
    let allocated: UInt64
    let elapsed: TimeInterval
}

// MARK: - Scanner

actor MT5Scanner {
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
        progress: @escaping @Sendable (MT5Progress) async -> Void
    ) async throws -> MT5Snapshot {
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

            let type = info.st_mode & mode_t(S_IFMT)
            let isDirectory = type == mode_t(S_IFDIR)
            let isSymlink = type == mode_t(S_IFLNK)
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
                    MT5Progress(
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
            MT5Node(
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
            MT5Progress(
                items: items,
                files: files,
                logical: logical,
                allocated: allocated,
                currentPath: currentPath,
                elapsed: elapsed
            )
        )

        return MT5Snapshot(
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
final class MT5Controller: ObservableObject {
    @Published var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @Published var nodes: [MT5Node] = []
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

    private let scanner = MT5Scanner()
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

struct MainViewV5: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MT5Controller()
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

                MT5Treemap(
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
            metric("Allocated", mt5Bytes(controller.allocated))
            metric("Logical", mt5Bytes(controller.logical))
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
                        MT5TreeRow(
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
                Text("Selected: \(node.path)   \(mt5Bytes(node.allocatedSize))")
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private struct Row: Identifiable {
        let node: MT5Node
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

private struct MT5TreeRow: View {
    let node: MT5Node
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

            cell(mt5Bytes(node.logicalSize), 105, .trailing)
            cell(mt5Bytes(node.allocatedSize), 105, .trailing)
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

// MARK: - Treemap model

private enum MT5CellKind {
    case file
    case aggregate
}

private struct MT5Cell: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let depth: Int
    let kind: MT5CellKind
    let labelOverride: String?
}

private struct MT5Frame: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let headerRect: CGRect?
    let depth: Int
}

private struct MT5RenderModel {
    let cells: [MT5Cell]
    let frames: [MT5Frame]
    let buckets: [[Int]]
    let cols: Int
    let rows: Int
    let size: CGSize

    static func empty(size: CGSize = .zero) -> MT5RenderModel {
        MT5RenderModel(cells: [], frames: [], buckets: [], cols: 0, rows: 0, size: size)
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
                return cells[index].nodeID
            }
        }
        return nil
    }
}

private struct MT5WeightedEntry {
    let token: Int
    let weight: UInt64
}

private struct MT5WeightedLayout {
    func layout(_ entries: [MT5WeightedEntry], in rect: CGRect) -> [(Int, CGRect)] {
        let safeRect = rect.standardized
        guard mt5RectFinite(safeRect), safeRect.width > 0.5, safeRect.height > 0.5 else { return [] }

        let valid = entries.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard !valid.isEmpty else { return [] }

        var output: [(Int, CGRect)] = []
        output.reserveCapacity(valid.count)
        split(valid, in: safeRect, output: &output)
        return output
    }

    private func split(
        _ entries: [MT5WeightedEntry],
        in rect: CGRect,
        output: inout [(Int, CGRect)]
    ) {
        guard !entries.isEmpty, mt5RectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }

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

// MARK: - Coverage-preserving treemap builder

private struct MT5TreemapBuilder {
    let nodes: [MT5Node]

    private let maxLeafCells = 1700
    private let maxDepth = 10
    private let minExpandArea: CGFloat = 260
    private let minExpandSide: CGFloat = 13
    private let maxChildrenPerFolder = 42

    func build(rootID: Int, size: CGSize) -> MT5RenderModel {
        guard nodes.indices.contains(rootID),
              size.width.isFinite, size.height.isFinite,
              size.width > 4, size.height > 4 else {
            return .empty(size: size)
        }

        let rootChildren = nodes[rootID].children.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }
        guard !rootChildren.isEmpty else {
            return .empty(size: size)
        }

        let rootTotal = rootChildren.reduce(UInt64(0)) { partial, id in
            let (value, overflow) = partial.addingReportingOverflow(nodes[id].allocatedSize)
            return overflow ? UInt64.max : value
        }
        guard rootTotal > 0 else {
            return .empty(size: size)
        }

        let rootEntries = rootChildren.map {
            MT5WeightedEntry(token: $0, weight: nodes[$0].allocatedSize)
        }
        let layout = MT5WeightedLayout()
        let rootRects = layout.layout(rootEntries, in: CGRect(origin: .zero, size: size))

        var cells: [MT5Cell] = []
        var frames: [MT5Frame] = []
        cells.reserveCapacity(maxLeafCells)
        frames.reserveCapacity(260)

        var remainingBudget = maxLeafCells

        for (index, pair) in rootRects.enumerated() {
            let id = pair.0
            let rect = pair.1
            let weight = nodes[id].allocatedSize
            let share = max(1, Int((Double(maxLeafCells) * Double(weight) / Double(rootTotal)).rounded(.down)))
            let siblingsLeft = rootRects.count - index
            let safeShare = max(1, min(remainingBudget - max(0, siblingsLeft - 1), share))

            renderNode(
                id: id,
                rect: rect,
                depth: 0,
                budget: safeShare,
                layout: layout,
                cells: &cells,
                frames: &frames
            )
            remainingBudget = max(0, maxLeafCells - cells.count)

            if remainingBudget <= 0 { break }
        }

        // A final root-level safety pass guarantees no top-level region can disappear
        // even if a pathological folder consumes more detail than expected.
        if cells.count < rootRects.count {
            cells.removeAll(keepingCapacity: true)
            frames.removeAll(keepingCapacity: true)
            for (id, rect) in rootRects {
                let node = nodes[id]
                cells.append(
                    MT5Cell(
                        id: cells.count,
                        nodeID: id,
                        rect: mt5SafeInset(rect, 0.5),
                        depth: 0,
                        kind: node.isDirectory ? .aggregate : .file,
                        labelOverride: nil
                    )
                )
            }
        }

        return makeRenderModel(cells: cells, frames: frames, size: size)
    }

    private func renderNode(
        id: Int,
        rect: CGRect,
        depth: Int,
        budget: Int,
        layout: MT5WeightedLayout,
        cells: inout [MT5Cell],
        frames: inout [MT5Frame]
    ) {
        let rect = rect.standardized
        guard nodes.indices.contains(id), mt5RectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }

        let node = nodes[id]
        if !node.isDirectory {
            cells.append(
                MT5Cell(
                    id: cells.count,
                    nodeID: id,
                    rect: mt5SafeInset(rect, 0.38),
                    depth: depth,
                    kind: .file,
                    labelOverride: nil
                )
            )
            return
        }

        let area = rect.width * rect.height
        let children = node.children.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }

        let canExpand = budget > 1 &&
            depth < maxDepth &&
            area.isFinite && area >= minExpandArea &&
            rect.width >= minExpandSide && rect.height >= minExpandSide &&
            !children.isEmpty

        guard canExpand else {
            cells.append(
                MT5Cell(
                    id: cells.count,
                    nodeID: id,
                    rect: mt5SafeInset(rect, 0.38),
                    depth: depth,
                    kind: .aggregate,
                    labelOverride: nil
                )
            )
            return
        }

        let headerHeight: CGFloat = shouldUseHeader(depth: depth, rect: rect) ? 17 : 0
        let content = CGRect(
            x: rect.minX + 1,
            y: rect.minY + headerHeight + 1,
            width: max(0, rect.width - 2),
            height: max(0, rect.height - headerHeight - 2)
        )

        guard mt5RectFinite(content), content.width > 2, content.height > 2 else {
            cells.append(
                MT5Cell(
                    id: cells.count,
                    nodeID: id,
                    rect: mt5SafeInset(rect, 0.38),
                    depth: depth,
                    kind: .aggregate,
                    labelOverride: nil
                )
            )
            return
        }

        frames.append(
            MT5Frame(
                id: frames.count,
                nodeID: id,
                rect: rect,
                headerRect: headerHeight > 0
                    ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
                    : nil,
                depth: depth
            )
        )

        let allowedEntries = max(1, min(maxChildrenPerFolder, budget))
        let keepCount = min(children.count, allowedEntries)
        var realChildren = Array(children.prefix(keepCount))
        var remainderWeight: UInt64 = 0

        if children.count > keepCount {
            realChildren = Array(children.prefix(max(1, keepCount - 1)))
            for childID in children.dropFirst(realChildren.count) {
                let (value, overflow) = remainderWeight.addingReportingOverflow(nodes[childID].allocatedSize)
                remainderWeight = overflow ? UInt64.max : value
            }
        }

        var entries = realChildren.map {
            MT5WeightedEntry(token: $0, weight: nodes[$0].allocatedSize)
        }
        let remainderToken = -1
        if remainderWeight > 0 {
            entries.append(MT5WeightedEntry(token: remainderToken, weight: remainderWeight))
        }

        guard !entries.isEmpty else {
            cells.append(
                MT5Cell(
                    id: cells.count,
                    nodeID: id,
                    rect: mt5SafeInset(content, 0.3),
                    depth: depth + 1,
                    kind: .aggregate,
                    labelOverride: nil
                )
            )
            return
        }

        let rects = layout.layout(entries, in: content)
        let totalWeight = entries.reduce(UInt64(0)) { partial, entry in
            let (value, overflow) = partial.addingReportingOverflow(entry.weight)
            return overflow ? UInt64.max : value
        }
        let entryCount = rects.count
        let extraBudget = max(0, budget - entryCount)

        var extraShares = Array(repeating: 0, count: entryCount)
        if extraBudget > 0 && totalWeight > 0 {
            var assigned = 0
            for index in rects.indices {
                let token = rects[index].0
                let weight = token == remainderToken
                    ? remainderWeight
                    : (nodes.indices.contains(token) ? nodes[token].allocatedSize : 0)
                let share = Int((Double(extraBudget) * Double(weight) / Double(totalWeight)).rounded(.down))
                extraShares[index] = max(0, share)
                assigned += extraShares[index]
            }
            var remaining = max(0, extraBudget - assigned)
            var index = 0
            while remaining > 0 && !extraShares.isEmpty {
                extraShares[index % extraShares.count] += 1
                remaining -= 1
                index += 1
            }
        }

        for index in rects.indices {
            let token = rects[index].0
            let childRect = rects[index].1
            if token == remainderToken {
                cells.append(
                    MT5Cell(
                        id: cells.count,
                        nodeID: id,
                        rect: mt5SafeInset(childRect, 0.38),
                        depth: depth + 1,
                        kind: .aggregate,
                        labelOverride: "Other items"
                    )
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

    private func shouldUseHeader(depth: Int, rect: CGRect) -> Bool {
        depth <= 2 && rect.width >= 105 && rect.height >= 58
    }

    private func makeRenderModel(
        cells: [MT5Cell],
        frames: [MT5Frame],
        size: CGSize
    ) -> MT5RenderModel {
        let cols = max(14, min(52, Int(max(1, size.width) / 30)))
        let rows = max(9, min(34, Int(max(1, size.height) / 30)))
        var buckets = Array(repeating: [Int](), count: max(1, cols * rows))

        for (index, cell) in cells.enumerated() {
            let rect = cell.rect.standardized
            guard mt5RectFinite(rect), rect.width > 0, rect.height > 0 else { continue }

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

        return MT5RenderModel(
            cells: cells,
            frames: frames,
            buckets: buckets,
            cols: cols,
            rows: rows,
            size: size
        )
    }
}

// MARK: - Treemap views

private struct MT5Treemap: View {
    let nodes: [MT5Node]
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
                    Text(mt5Bytes(nodes[rootID].allocatedSize))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }

                Spacer()

                Text("Adaptive detail • file-type colors • hover for details")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))

            Divider()

            GeometryReader { proxy in
                let size = CGSize(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
                let model = MT5TreemapBuilder(nodes: nodes).build(rootID: rootID, size: size)

                MT5TreemapSurface(
                    nodes: nodes,
                    model: model,
                    selectedID: $selectedID
                )
            }
        }
    }

    private var rootPath: String {
        nodes.indices.contains(rootID) ? nodes[rootID].path : "Treemap"
    }
}

private struct MT5TreemapSurface: View {
    let nodes: [MT5Node]
    let model: MT5RenderModel
    @Binding var selectedID: Int?
    @State private var hoveredID: Int?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(nsColor: .windowBackgroundColor))
                )

                for cell in model.cells {
                    guard nodes.indices.contains(cell.nodeID), mt5RectFinite(cell.rect) else { continue }
                    let node = nodes[cell.nodeID]
                    let color = cell.kind == .file ? mt5FileColor(node) : mt5AggregateColor(node, nodes: nodes)
                    let gradient = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [color.opacity(0.94), color.opacity(0.68)]),
                        startPoint: CGPoint(x: cell.rect.minX, y: cell.rect.minY),
                        endPoint: CGPoint(x: cell.rect.maxX, y: cell.rect.maxY)
                    )

                    context.fill(Path(cell.rect), with: gradient)
                    context.stroke(
                        Path(cell.rect),
                        with: .color(selectedID == node.id ? Color.white : Color.black.opacity(0.43)),
                        lineWidth: selectedID == node.id ? 2.2 : 0.55
                    )

                    if cell.rect.width > 92 && cell.rect.height > 44 {
                        let label = cell.labelOverride ?? node.name
                        let maxChars = max(5, Int(cell.rect.width / 7.2))
                        let title = Text(mt5Ellipsize(label, maxCharacters: maxChars))
                            .font(cell.rect.width > 175 && cell.rect.height > 74 ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                            .foregroundStyle(Color.white)
                        context.draw(
                            title,
                            at: CGPoint(x: cell.rect.minX + 5, y: cell.rect.minY + 4),
                            anchor: .topLeading
                        )

                        if cell.rect.width > 125 && cell.rect.height > 64 {
                            let subtitle = Text(mt5Bytes(node.allocatedSize))
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.88))
                            context.draw(
                                subtitle,
                                at: CGPoint(x: cell.rect.minX + 5, y: cell.rect.minY + 21),
                                anchor: .topLeading
                            )
                        }
                    }
                }

                for frame in model.frames {
                    guard nodes.indices.contains(frame.nodeID), mt5RectFinite(frame.rect) else { continue }

                    if let header = frame.headerRect, mt5RectFinite(header) {
                        context.fill(
                            Path(header),
                            with: .color(Color.black.opacity(frame.depth == 0 ? 0.56 : 0.42))
                        )
                        let maxChars = max(6, Int(header.width / 7.2))
                        let label = Text(mt5Ellipsize(nodes[frame.nodeID].name, maxCharacters: maxChars))
                            .font(frame.depth == 0 ? .caption.weight(.bold) : .caption2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.96))
                        context.draw(
                            label,
                            at: CGPoint(x: header.minX + 5, y: header.minY + 2),
                            anchor: .topLeading
                        )
                    }

                    context.stroke(
                        Path(frame.rect),
                        with: .color(Color.white.opacity(frame.depth == 0 ? 0.42 : 0.20)),
                        lineWidth: frame.depth == 0 ? 1.4 : 0.75
                    )
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let id = model.hitTest(point)
                    if id != hoveredID {
                        hoveredID = id
                    }
                case .ended:
                    if hoveredID != nil {
                        hoveredID = nil
                    }
                }
            }
            .onTapGesture {
                if let hoveredID {
                    selectedID = hoveredID
                }
            }

            if let hoveredID, nodes.indices.contains(hoveredID) {
                hoverCard(nodes[hoveredID])
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private func hoverCard(_ node: MT5Node) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : mt5FileColor(node))

                Text(node.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                Text(mt5Bytes(node.allocatedSize))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }

            Text(node.path)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(node.isDirectory ? "\(node.fileCount.formatted()) files" : mt5FileTypeLabel(node))
                .font(.caption2)
                .foregroundStyle(Color.secondary)
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
        .shadow(radius: 8)
    }
}

// MARK: - Treemap helpers

private func mt5RectFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite &&
    rect.origin.y.isFinite &&
    rect.size.width.isFinite &&
    rect.size.height.isFinite &&
    rect.width >= 0 &&
    rect.height >= 0
}

private func mt5SafeInset(_ rect: CGRect, _ amount: CGFloat) -> CGRect {
    guard mt5RectFinite(rect) else { return .zero }
    let dx = min(max(0, amount), max(0, rect.width / 2 - 0.05))
    let dy = min(max(0, amount), max(0, rect.height / 2 - 0.05))
    let result = rect.insetBy(dx: dx, dy: dy)
    return mt5RectFinite(result) ? result : rect
}

private func mt5Ellipsize(_ text: String, maxCharacters: Int) -> String {
    guard maxCharacters > 1, text.count > maxCharacters else { return text }
    let end = text.index(text.startIndex, offsetBy: max(1, maxCharacters - 1))
    return String(text[..<end]) + "…"
}

private func mt5FileTypeLabel(_ node: MT5Node) -> String {
    let ext = (node.name as NSString).pathExtension
    return ext.isEmpty ? "File" : ".\(ext.lowercased()) file"
}

private func mt5AggregateColor(_ node: MT5Node, nodes: [MT5Node]) -> Color {
    var current = node
    var steps = 0

    while current.isDirectory && !current.children.isEmpty && steps < 10 {
        guard let largestID = current.children.first,
              nodes.indices.contains(largestID) else { break }
        current = nodes[largestID]
        steps += 1
    }

    if !current.isDirectory {
        return mt5FileColor(current)
    }

    return Color(nsColor: .systemGray)
}

private func mt5FileColor(_ node: MT5Node) -> Color {
    let ext = (node.name as NSString).pathExtension.lowercased()

    switch ext {
    case "app", "dylib", "so", "exe":
        return .green
    case "mp4", "mov", "mkv", "avi", "webm", "m4v":
        return .purple
    case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff":
        return .pink
    case "zip", "7z", "rar", "tar", "gz", "dmg", "pkg", "iso":
        return .orange
    case "mp3", "aac", "m4a", "wav", "flac", "ogg":
        return .cyan
    case "pdf", "doc", "docx", "pages", "txt", "rtf":
        return .blue
    case "swift", "c", "cpp", "h", "hpp", "js", "ts", "py", "json", "xml", "plist":
        return .teal
    case "db", "sqlite", "sqlite3":
        return .indigo
    case "ttf", "otf", "woff", "woff2":
        return .brown
    default:
        var hash = 2166136261
        for byte in ext.utf8 {
            hash = (hash ^ Int(byte)) &* 16777619
        }
        let palette: [Color] = [.red, .mint, .yellow, .indigo, .brown, .blue, .green, .purple]
        return palette[abs(hash) % palette.count]
    }
}

private func mt5Bytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(clamping: value))
}
