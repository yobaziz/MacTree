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

            if isDirectory {
                directoryIDs[relative] = id
            }

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
                tree
                    .frame(minHeight: 290)

                FastTreemap(
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

// MARK: - Fast readable treemap

private struct DrawCell: Identifiable {
    enum Kind { case file, aggregate }
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let kind: Kind
}

private struct FolderFrame: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let depth: Int
}

private struct RenderModel {
    let cells: [DrawCell]
    let frames: [FolderFrame]
    let buckets: [[Int]]
    let gridColumns: Int
    let gridRows: Int
    let size: CGSize

    func hitTest(_ point: CGPoint) -> Int? {
        guard point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height,
              gridColumns > 0, gridRows > 0 else { return nil }

        let gx = min(gridColumns - 1, max(0, Int(point.x / max(1, size.width) * CGFloat(gridColumns))))
        let gy = min(gridRows - 1, max(0, Int(point.y / max(1, size.height) * CGFloat(gridRows))))
        let bucket = buckets[gy * gridColumns + gx]
        for index in bucket.reversed() {
            guard cells.indices.contains(index) else { continue }
            if cells[index].rect.contains(point) { return cells[index].nodeID }
        }
        return nil
    }
}

private struct BasicTreemap {
    struct Weighted {
        let id: Int
        let area: CGFloat
    }

    let nodes: [MTNode]

    func layout(ids: [Int], rect: CGRect) -> [(Int, CGRect)] {
        let valid = ids.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }
        guard !valid.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        if valid.count == 1 { return [(valid[0], rect)] }

        let total = valid.reduce(UInt64(0)) { $0 + nodes[$1].allocatedSize }
        guard total > 0 else { return [] }

        var weighted = valid.map {
            Weighted(id: $0, area: rect.width * rect.height * CGFloat(Double(nodes[$0].allocatedSize) / Double(total)))
        }
        weighted.sort { $0.area > $1.area }

        var output: [(Int, CGRect)] = []
        var remaining = rect
        var row: [Weighted] = []

        while !weighted.isEmpty {
            let item = weighted[0]
            let side = max(1, min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [item], side) <= worst(row, side) {
                row.append(item)
                weighted.removeFirst()
            } else {
                place(row, &remaining, &output)
                row.removeAll(keepingCapacity: true)
            }
        }
        if !row.isEmpty { place(row, &remaining, &output) }
        return output
    }

    private func worst(_ row: [Weighted], _ side: CGFloat) -> CGFloat {
        guard !row.isEmpty else { return .greatestFiniteMagnitude }
        let sum = row.reduce(CGFloat(0)) { $0 + $1.area }
        let maxArea = row.map(\.area).max() ?? 0
        let minArea = max(row.map(\.area).min() ?? 0, 0.0001)
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * maxArea / max(sum2, 0.0001), sum2 / max(side2 * minArea, 0.0001))
    }

    private func place(_ row: [Weighted], _ remaining: inout CGRect, _ output: inout [(Int, CGRect)]) {
        guard !row.isEmpty else { return }
        let area = row.reduce(CGFloat(0)) { $0 + $1.area }

        if remaining.width >= remaining.height {
            let strip = remaining.height > 0 ? area / remaining.height : 0
            var y = remaining.minY
            for (i, item) in row.enumerated() {
                let h = i == row.count - 1 ? remaining.maxY - y : (strip > 0 ? item.area / strip : 0)
                output.append((item.id, CGRect(x: remaining.minX, y: y, width: strip, height: max(0, h))))
                y += h
            }
            remaining = CGRect(x: remaining.minX + strip, y: remaining.minY, width: max(0, remaining.width - strip), height: remaining.height)
        } else {
            let strip = remaining.width > 0 ? area / remaining.width : 0
            var x = remaining.minX
            for (i, item) in row.enumerated() {
                let w = i == row.count - 1 ? remaining.maxX - x : (strip > 0 ? item.area / strip : 0)
                output.append((item.id, CGRect(x: x, y: remaining.minY, width: max(0, w), height: strip)))
                x += w
            }
            remaining = CGRect(x: remaining.minX, y: remaining.minY + strip, width: remaining.width, height: max(0, remaining.height - strip))
        }
    }
}

private struct TreemapBuilder {
    let nodes: [MTNode]
    let maxCells = 2200
    let minRecurseArea: CGFloat = 90
    let minSide: CGFloat = 4
    let maxDepth = 12

    func build(rootID: Int, size: CGSize) -> RenderModel {
        guard nodes.indices.contains(rootID), size.width > 4, size.height > 4 else {
            return RenderModel(cells: [], frames: [], buckets: [], gridColumns: 0, gridRows: 0, size: size)
        }

        var cells: [DrawCell] = []
        var frames: [FolderFrame] = []
        cells.reserveCapacity(1600)
        frames.reserveCapacity(300)

        let layout = BasicTreemap(nodes: nodes)
        let rootRect = CGRect(origin: .zero, size: size)
        let children = nodes[rootID].children.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }

        for (id, rect) in layout.layout(ids: children, rect: rootRect) {
            append(id: id, rect: rect, depth: 0, layout: layout, cells: &cells, frames: &frames)
            if cells.count >= maxCells { break }
        }

        let cols = max(12, min(48, Int(size.width / 28)))
        let rows = max(8, min(32, Int(size.height / 28)))
        var buckets = Array(repeating: [Int](), count: cols * rows)

        for (index, cell) in cells.enumerated() {
            let minX = max(0, min(cols - 1, Int(cell.rect.minX / max(1, size.width) * CGFloat(cols))))
            let maxX = max(0, min(cols - 1, Int(max(cell.rect.minX, cell.rect.maxX - 0.01) / max(1, size.width) * CGFloat(cols))))
            let minY = max(0, min(rows - 1, Int(cell.rect.minY / max(1, size.height) * CGFloat(rows))))
            let maxY = max(0, min(rows - 1, Int(max(cell.rect.minY, cell.rect.maxY - 0.01) / max(1, size.height) * CGFloat(rows))))
            for gy in minY...maxY {
                for gx in minX...maxX {
                    buckets[gy * cols + gx].append(index)
                }
            }
        }

        return RenderModel(cells: cells, frames: frames, buckets: buckets, gridColumns: cols, gridRows: rows, size: size)
    }

    private func append(
        id: Int,
        rect: CGRect,
        depth: Int,
        layout: BasicTreemap,
        cells: inout [DrawCell],
        frames: inout [FolderFrame]
    ) {
        guard nodes.indices.contains(id), rect.width > 0.5, rect.height > 0.5, cells.count < maxCells else { return }
        let node = nodes[id]

        if !node.isDirectory {
            cells.append(DrawCell(id: cells.count, nodeID: id, rect: rect.insetBy(dx: 0.35, dy: 0.35), kind: .file))
            return
        }

        if depth <= 3 && rect.width > 65 && rect.height > 35 {
            frames.append(FolderFrame(id: frames.count, nodeID: id, rect: rect.insetBy(dx: 0.2, dy: 0.2), depth: depth))
        }

        let area = rect.width * rect.height
        let children = node.children.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }
        let canRecurse = depth < maxDepth && area >= minRecurseArea && rect.width >= minSide && rect.height >= minSide && !children.isEmpty && cells.count < maxCells - 8

        if !canRecurse {
            cells.append(DrawCell(id: cells.count, nodeID: id, rect: rect.insetBy(dx: 0.35, dy: 0.35), kind: .aggregate))
            return
        }

        let inner = rect.insetBy(dx: depth <= 2 ? 1.0 : 0.45, dy: depth <= 2 ? 1.0 : 0.45)
        guard inner.width > 1, inner.height > 1 else {
            cells.append(DrawCell(id: cells.count, nodeID: id, rect: rect, kind: .aggregate))
            return
        }

        let childRects = layout.layout(ids: children, rect: inner)
        if childRects.isEmpty {
            cells.append(DrawCell(id: cells.count, nodeID: id, rect: rect, kind: .aggregate))
            return
        }

        for (childID, childRect) in childRects {
            append(id: childID, rect: childRect, depth: depth + 1, layout: layout, cells: &cells, frames: &frames)
            if cells.count >= maxCells { break }
        }
    }
}

private struct FastTreemap: View {
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
                Text("Files colored by type • hover for details")
                    .font(.caption).foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))

            Divider()

            GeometryReader { proxy in
                let size = CGSize(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
                let model = TreemapBuilder(nodes: nodes).build(rootID: rootID, size: size)

                ZStack(alignment: .topTrailing) {
                    Canvas { context, canvasSize in
                        context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(Color(nsColor: .windowBackgroundColor)))

                        for cell in model.cells {
                            guard nodes.indices.contains(cell.nodeID) else { continue }
                            let node = nodes[cell.nodeID]
                            let color = cell.kind == .file ? fileColor(node) : Color.gray
                            let gradient = GraphicsContext.Shading.linearGradient(
                                Gradient(colors: [color.opacity(0.93), color.opacity(0.64)]),
                                startPoint: CGPoint(x: cell.rect.minX, y: cell.rect.minY),
                                endPoint: CGPoint(x: cell.rect.maxX, y: cell.rect.maxY)
                            )
                            context.fill(Path(cell.rect), with: gradient)
                            context.stroke(Path(cell.rect), with: .color(selectedID == node.id ? Color.white : Color.black.opacity(0.42)), lineWidth: selectedID == node.id ? 2.2 : 0.55)

                            if cell.rect.width > 92 && cell.rect.height > 44 {
                                let title = Text(node.name)
                                    .font(cell.rect.width > 170 && cell.rect.height > 72 ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                                    .foregroundStyle(Color.white)
                                context.draw(title, at: CGPoint(x: cell.rect.minX + 5, y: cell.rect.minY + 4), anchor: .topLeading)

                                if cell.rect.width > 120 && cell.rect.height > 64 {
                                    let subtitle = Text(mtBytes(node.allocatedSize)).font(.caption2).foregroundStyle(Color.white.opacity(0.9))
                                    context.draw(subtitle, at: CGPoint(x: cell.rect.minX + 5, y: cell.rect.minY + 21), anchor: .topLeading)
                                }
                            }
                        }

                        for frame in model.frames {
                            guard nodes.indices.contains(frame.nodeID) else { continue }
                            context.stroke(
                                Path(frame.rect),
                                with: .color(Color.white.opacity(frame.depth == 0 ? 0.48 : 0.24)),
                                lineWidth: frame.depth == 0 ? 1.5 : 0.8
                            )

                            if frame.depth <= 1 && frame.rect.width > 150 && frame.rect.height > 70 {
                                let label = Text(nodes[frame.nodeID].name)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.white.opacity(0.92))
                                context.draw(label, at: CGPoint(x: frame.rect.minX + 6, y: frame.rect.minY + 5), anchor: .topLeading)
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
                        hoverCard(nodes[hoveredID])
                            .padding(10)
                            .allowsHitTesting(false)
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

private func mtBytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(clamping: value))
}
