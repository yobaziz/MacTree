import SwiftUI
import AppKit
import Darwin

@main
struct MacTreeV4App: App {
    var body: some Scene {
        WindowGroup {
            MainViewV4()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 860)
    }
}

// MARK: - Data

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

// MARK: - Scanner

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

    func scan(
        root: URL,
        progress: @escaping @Sendable (MTProgress) async -> Void
    ) async throws -> MTSnapshot {
        let start = CFAbsoluteTimeGetCurrent()
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
        builders.reserveCapacity(350_000)

        var directoryIDs: [String: Int] = ["": 0]
        directoryIDs.reserveCapacity(55_000)

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

            if isDirectory { directoryIDs[relative] = id }

            if publishCounter >= 30_000 {
                await progress(
                    MTProgress(
                        items: items,
                        files: files,
                        logical: logical,
                        allocated: allocated,
                        currentPath: currentPath,
                        elapsed: CFAbsoluteTimeGetCurrent() - start
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
            MTNode(
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

        let sizeRef = nodes
        for index in nodes.indices where !nodes[index].children.isEmpty {
            nodes[index].children.sort {
                let a = sizeRef[$0]
                let b = sizeRef[$1]
                if a.allocatedSize != b.allocatedSize { return a.allocatedSize > b.allocatedSize }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        await progress(
            MTProgress(
                items: items,
                files: files,
                logical: logical,
                allocated: allocated,
                currentPath: currentPath,
                elapsed: elapsed
            )
        )

        return MTSnapshot(
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
final class MTController: ObservableObject {
    @Published var rootURL = FileManager.default.homeDirectoryForCurrentUser
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

    private let scanner = MTScanner()
    private var task: Task<Void, Never>?

    init() { refreshFullDiskAccess() }

    func chooseHome() { rootURL = FileManager.default.homeDirectoryForCurrentUser }
    func chooseDisk() { rootURL = URL(fileURLWithPath: "/", isDirectory: true) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a disk or folder"
        panel.message = "iCloud and File Provider folders are skipped automatically."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url { rootURL = url }
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

// MARK: - Main view

struct MainViewV4: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MTController()
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
                tree.frame(minHeight: 290)
                StableTreemap(nodes: controller.nodes, rootID: controller.rootID, selectedID: $selectedID)
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
            if phase == .active { controller.refreshFullDiskAccess() }
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

            Label(controller.isScanning ? "Scanning" : "Ready", systemImage: controller.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .foregroundStyle(controller.isScanning ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            metric("Allocated", mtBytes(controller.allocated))
            metric("Logical", mtBytes(controller.logical))
            metric("Files", controller.files.formatted())
            metric("Items", controller.items.formatted())

            Text("iCloud skipped")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1), in: Capsule())

            Spacer()
            if controller.isScanning { ProgressView().controlSize(.small) }
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
                        TreeRowV4(
                            node: row.node,
                            depth: row.depth,
                            total: max(controller.allocated, 1),
                            expanded: expanded.contains(row.node.id),
                            selected: selectedID == row.node.id,
                            toggle: { toggle(row.node.id) },
                            select: { selectedID = row.node.id },
                            open: {
                                selectedID = row.node.id
                                if row.node.isDirectory && !row.node.children.isEmpty { toggle(row.node.id) }
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
                Text("Scanning \(controller.items.formatted()) items").fontWeight(.semibold)
                Text(controller.currentPath).foregroundStyle(Color.secondary).lineLimit(1)
            } else {
                Text("Scanned \(controller.files.formatted()) files in \(controller.elapsed.formatted(.number.precision(.fractionLength(1)))) s")
            }
            Spacer()
            if let selectedID, controller.nodes.indices.contains(selectedID) {
                let node = controller.nodes[selectedID]
                Text("Selected: \(node.path)   \(mtBytes(node.allocatedSize))")
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var locationTitle: String {
        if controller.rootURL.path == "/" { return "Macintosh HD" }
        let name = controller.rootURL.lastPathComponent
        return name.isEmpty ? controller.rootURL.path : name
    }

    private struct Row: Identifiable {
        let node: MTNode
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
                    if matches.count >= 2000 { break }
                }
            }
            matches.sort { $0.node.allocatedSize > $1.node.allocatedSize }
            return matches
        }

        var out: [Row] = []
        func append(_ parent: Int, _ depth: Int) {
            guard controller.nodes.indices.contains(parent) else { return }
            for childID in controller.nodes[parent].children {
                guard controller.nodes.indices.contains(childID) else { continue }
                let child = controller.nodes[childID]
                out.append(Row(node: child, depth: depth))
                if child.isDirectory && expanded.contains(child.id) { append(child.id, depth + 1) }
            }
        }
        append(controller.rootID, 0)
        return out
    }

    private func toggle(_ id: Int) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
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

private struct TreeRowV4: View {
    let node: MTNode
    let depth: Int
    let total: UInt64
    let expanded: Bool
    let selected: Bool
    let toggle: () -> Void
    let select: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(depth) * 17)
                if node.isDirectory && !node.children.isEmpty {
                    Button(action: toggle) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold)).frame(width: 14)
                    }.buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14)
                }

                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : Color.secondary)
                    .frame(width: 17)
                Text(node.name).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 330, alignment: .leading).padding(.horizontal, 6)

            cell(mtBytes(node.logicalSize), 105, .trailing)
            cell(mtBytes(node.allocatedSize), 105, .trailing)
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

            Text(node.path)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 390, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .font(.callout)
        .frame(height: 29)
        .background(selected ? Color.accentColor.opacity(0.28) : (node.id.isMultiple(of: 2) ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.28)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
    }

    private func cell(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text).monospacedDigit().lineLimit(1).frame(width: width, alignment: alignment).padding(.horizontal, 6)
    }
}

// MARK: - Stable treemap

private struct MTDrawCell: Identifiable {
    enum Kind { case file, aggregate }
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let kind: Kind
}

private struct MTFolderFrame: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let depth: Int
}

private struct MTRenderModel {
    let cells: [MTDrawCell]
    let frames: [MTFolderFrame]
    let buckets: [[Int]]
    let cols: Int
    let rows: Int
    let size: CGSize

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
            if cells[index].rect.contains(point) { return cells[index].nodeID }
        }
        return nil
    }
}

private struct MTBinaryLayout {
    let nodes: [MTNode]

    func layout(ids: [Int], in rect: CGRect) -> [(Int, CGRect)] {
        let safeRect = rect.standardized
        guard rectIsFinite(safeRect), safeRect.width > 0.5, safeRect.height > 0.5 else { return [] }

        let valid = ids.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }.sorted {
            nodes[$0].allocatedSize > nodes[$1].allocatedSize
        }
        guard !valid.isEmpty else { return [] }

        var result: [(Int, CGRect)] = []
        result.reserveCapacity(valid.count)
        split(valid, rect: safeRect, output: &result)
        return result
    }

    private func split(_ ids: [Int], rect: CGRect, output: inout [(Int, CGRect)]) {
        guard !ids.isEmpty, rectIsFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }

        if ids.count == 1 {
            output.append((ids[0], rect))
            return
        }

        let total = ids.reduce(UInt64(0)) { $0 &+ nodes[$1].allocatedSize }
        guard total > 0 else { return }

        let target = Double(total) / 2.0
        var running = 0.0
        var splitIndex = 1

        for i in 0..<(ids.count - 1) {
            running += Double(nodes[ids[i]].allocatedSize)
            splitIndex = i + 1
            if running >= target { break }
        }

        splitIndex = max(1, min(ids.count - 1, splitIndex))
        let left = Array(ids[..<splitIndex])
        let right = Array(ids[splitIndex...])

        let leftTotal = left.reduce(UInt64(0)) { $0 &+ nodes[$1].allocatedSize }
        var fraction = Double(leftTotal) / Double(total)
        if !fraction.isFinite { fraction = 0.5 }
        fraction = max(0.001, min(0.999, fraction))

        if rect.width >= rect.height {
            let firstWidth = rect.width * CGFloat(fraction)
            guard firstWidth.isFinite else { return }
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let r2 = CGRect(x: rect.minX + firstWidth, y: rect.minY, width: max(0, rect.width - firstWidth), height: rect.height)
            split(left, rect: r1, output: &output)
            split(right, rect: r2, output: &output)
        } else {
            let firstHeight = rect.height * CGFloat(fraction)
            guard firstHeight.isFinite else { return }
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let r2 = CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: max(0, rect.height - firstHeight))
            split(left, rect: r1, output: &output)
            split(right, rect: r2, output: &output)
        }
    }
}

private struct MTStableBuilder {
    let nodes: [MTNode]
    let maxCells = 1500
    let maxDepth = 8
    let minRecursiveArea: CGFloat = 420
    let minRecursiveSide: CGFloat = 16

    func build(rootID: Int, size: CGSize) -> MTRenderModel {
        guard nodes.indices.contains(rootID),
              size.width.isFinite, size.height.isFinite,
              size.width > 4, size.height > 4 else {
            return MTRenderModel(cells: [], frames: [], buckets: [], cols: 0, rows: 0, size: size)
        }

        var cells: [MTDrawCell] = []
        var frames: [MTFolderFrame] = []
        cells.reserveCapacity(1200)
        frames.reserveCapacity(120)

        let layout = MTBinaryLayout(nodes: nodes)
        let rootRect = CGRect(origin: .zero, size: size)
        let children = nodes[rootID].children.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }

        for (id, rect) in layout.layout(ids: children, in: rootRect) {
            append(id: id, rect: rect, depth: 0, layout: layout, cells: &cells, frames: &frames)
            if cells.count >= maxCells { break }
        }

        let cols = max(12, min(42, Int(max(1, size.width) / 34)))
        let rows = max(8, min(28, Int(max(1, size.height) / 34)))
        var buckets = Array(repeating: [Int](), count: max(1, cols * rows))

        for (index, cell) in cells.enumerated() {
            let r = cell.rect.standardized
            guard rectIsFinite(r), r.width > 0, r.height > 0 else { continue }

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
            for gy in minY...maxY {
                for gx in minX...maxX {
                    let bucketIndex = gy * cols + gx
                    if buckets.indices.contains(bucketIndex) { buckets[bucketIndex].append(index) }
                }
            }
        }

        return MTRenderModel(cells: cells, frames: frames, buckets: buckets, cols: cols, rows: rows, size: size)
    }

    private func append(
        id: Int,
        rect: CGRect,
        depth: Int,
        layout: MTBinaryLayout,
        cells: inout [MTDrawCell],
        frames: inout [MTFolderFrame]
    ) {
        let rect = rect.standardized
        guard nodes.indices.contains(id), rectIsFinite(rect), rect.width > 0.5, rect.height > 0.5, cells.count < maxCells else { return }
        let node = nodes[id]

        if !node.isDirectory {
            let cellRect = safeInset(rect, amount: 0.35)
            if rectIsFinite(cellRect) {
                cells.append(MTDrawCell(id: cells.count, nodeID: id, rect: cellRect, kind: .file))
            }
            return
        }

        if depth <= 2 && rect.width > 135 && rect.height > 75 {
            let frameRect = safeInset(rect, amount: 0.2)
            if rectIsFinite(frameRect) {
                frames.append(MTFolderFrame(id: frames.count, nodeID: id, rect: frameRect, depth: depth))
            }
        }

        let area = rect.width * rect.height
        let children = node.children.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }
        let canRecurse = depth < maxDepth && area.isFinite && area >= minRecursiveArea && rect.width >= minRecursiveSide && rect.height >= minRecursiveSide && !children.isEmpty && cells.count < maxCells - 12

        if !canRecurse {
            let cellRect = safeInset(rect, amount: 0.35)
            if rectIsFinite(cellRect) {
                cells.append(MTDrawCell(id: cells.count, nodeID: id, rect: cellRect, kind: .aggregate))
            }
            return
        }

        let inset: CGFloat = depth <= 1 ? 1.2 : 0.65
        let inner = safeInset(rect, amount: inset)
        guard rectIsFinite(inner), inner.width > 2, inner.height > 2 else {
            cells.append(MTDrawCell(id: cells.count, nodeID: id, rect: rect, kind: .aggregate))
            return
        }

        let childRects = layout.layout(ids: children, in: inner)
        if childRects.isEmpty {
            cells.append(MTDrawCell(id: cells.count, nodeID: id, rect: rect, kind: .aggregate))
            return
        }

        for (childID, childRect) in childRects {
            append(id: childID, rect: childRect, depth: depth + 1, layout: layout, cells: &cells, frames: &frames)
            if cells.count >= maxCells { break }
        }
    }
}

private struct StableTreemap: View {
    let nodes: [MTNode]
    let rootID: Int
    @Binding var selectedID: Int?
    @State private var hoveredID: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill").foregroundStyle(Color.secondary)
                Text(rootPath).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if nodes.indices.contains(rootID) {
                    Text(mtBytes(nodes[rootID].allocatedSize)).font(.caption).foregroundStyle(Color.secondary).monospacedDigit()
                }
                Spacer()
                Text("Files colored by type • small folders grouped • hover for details")
                    .font(.caption).foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))

            Divider()

            GeometryReader { proxy in
                let size = CGSize(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
                let model = MTStableBuilder(nodes: nodes).build(rootID: rootID, size: size)

                ZStack(alignment: .topTrailing) {
                    Canvas { context, canvasSize in
                        context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(Color(nsColor: .windowBackgroundColor)))

                        for cell in model.cells {
                            guard nodes.indices.contains(cell.nodeID), rectIsFinite(cell.rect) else { continue }
                            let node = nodes[cell.nodeID]
                            let color = cell.kind == .file ? fileColor(node) : aggregateColor(node)
                            let gradient = GraphicsContext.Shading.linearGradient(
                                Gradient(colors: [color.opacity(0.92), color.opacity(0.66)]),
                                startPoint: CGPoint(x: cell.rect.minX, y: cell.rect.minY),
                                endPoint: CGPoint(x: cell.rect.maxX, y: cell.rect.maxY)
                            )
                            context.fill(Path(cell.rect), with: gradient)
                            context.stroke(Path(cell.rect), with: .color(selectedID == node.id ? Color.white : Color.black.opacity(0.40)), lineWidth: selectedID == node.id ? 2.2 : 0.6)

                            if cell.rect.width > 115 && cell.rect.height > 56 {
                                let title = Text(node.name)
                                    .font(cell.rect.width > 190 && cell.rect.height > 84 ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                                    .foregroundStyle(Color.white)
                                context.draw(title, at: CGPoint(x: cell.rect.minX + 6, y: cell.rect.minY + 5), anchor: .topLeading)

                                if cell.rect.width > 145 && cell.rect.height > 78 {
                                    let subtitle = Text(mtBytes(node.allocatedSize)).font(.caption2).foregroundStyle(Color.white.opacity(0.88))
                                    context.draw(subtitle, at: CGPoint(x: cell.rect.minX + 6, y: cell.rect.minY + 23), anchor: .topLeading)
                                }
                            }
                        }

                        for frame in model.frames {
                            guard nodes.indices.contains(frame.nodeID), rectIsFinite(frame.rect) else { continue }
                            context.stroke(Path(frame.rect), with: .color(Color.white.opacity(frame.depth == 0 ? 0.34 : 0.16)), lineWidth: frame.depth == 0 ? 1.4 : 0.8)

                            if frame.depth == 0 && frame.rect.width > 190 && frame.rect.height > 100 {
                                let label = Text(nodes[frame.nodeID].name)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.white.opacity(0.90))
                                context.draw(label, at: CGPoint(x: frame.rect.minX + 7, y: frame.rect.minY + 6), anchor: .topLeading)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let id = model.hitTest(point)
                            if id != hoveredID { hoveredID = id }
                        case .ended:
                            if hoveredID != nil { hoveredID = nil }
                        }
                    }
                    .onTapGesture {
                        if let hoveredID { selectedID = hoveredID }
                    }

                    if let hoveredID, nodes.indices.contains(hoveredID) {
                        hoverCard(nodes[hoveredID]).padding(10).allowsHitTesting(false)
                    }
                }
                .clipped()
            }
        }
    }

    private var rootPath: String {
        nodes.indices.contains(rootID) ? nodes[rootID].path : "Treemap"
    }

    private func hoverCard(_ node: MTNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : fileColor(node))
                Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(mtBytes(node.allocatedSize)).font(.caption.weight(.semibold)).monospacedDigit()
            }
            Text(node.path).font(.caption2).foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
            Text(node.isDirectory ? "\(node.fileCount.formatted()) files" : fileTypeLabel(node))
                .font(.caption2).foregroundStyle(Color.secondary)
        }
        .padding(10)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.13), lineWidth: 1))
        .shadow(radius: 8)
    }

    private func fileTypeLabel(_ node: MTNode) -> String {
        let ext = (node.name as NSString).pathExtension
        return ext.isEmpty ? "File" : ".\(ext.lowercased()) file"
    }
}

private func aggregateColor(_ node: MTNode) -> Color {
    let lower = node.name.lowercased()
    if lower.contains("steam") || lower.contains("game") { return Color.indigo }
    if lower.contains("cache") { return Color.gray }
    if lower.contains("application") { return Color.teal }
    return Color(nsColor: .systemGray)
}

private func fileColor(_ node: MTNode) -> Color {
    let ext = (node.name as NSString).pathExtension.lowercased()
    switch ext {
    case "app", "dylib", "so", "exe": return .green
    case "mp4", "mov", "mkv", "avi", "webm", "m4v": return .purple
    case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff": return .pink
    case "zip", "7z", "rar", "tar", "gz", "dmg", "pkg", "iso": return .orange
    case "mp3", "aac", "m4a", "wav", "flac", "ogg": return .cyan
    case "pdf", "doc", "docx", "pages", "txt", "rtf": return .blue
    case "swift", "c", "cpp", "h", "hpp", "js", "ts", "py", "json", "xml", "plist": return .teal
    case "db", "sqlite", "sqlite3": return .indigo
    case "ttf", "otf", "woff", "woff2": return .brown
    default:
        var hash = 2166136261
        for byte in ext.utf8 { hash = (hash ^ Int(byte)) &* 16777619 }
        let palette: [Color] = [.red, .mint, .yellow, .indigo, .brown, .blue, .green, .purple]
        return palette[abs(hash) % palette.count]
    }
}

private func rectIsFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
}

private func safeInset(_ rect: CGRect, amount: CGFloat) -> CGRect {
    guard rectIsFinite(rect) else { return .zero }
    let maxInset = max(0, min(amount, min(rect.width, rect.height) / 2 - 0.01))
    guard maxInset.isFinite else { return rect }
    return rect.insetBy(dx: maxInset, dy: maxInset)
}

private func mtBytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(clamping: value))
}
