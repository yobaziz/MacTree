import SwiftUI
import AppKit
import Darwin

@main
struct MacTreeApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 860)
    }
}

// MARK: - Model

struct FileNode: Identifiable, Hashable, Sendable {
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

struct ScanProgress: Sendable {
    let itemsVisited: UInt64
    let filesScanned: UInt64
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let currentPath: String
    let elapsed: TimeInterval
}

struct ScanSnapshot: Sendable {
    let nodes: [FileNode]
    let rootID: Int
    let filesScanned: UInt64
    let itemsVisited: UInt64
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let elapsed: TimeInterval
}

// MARK: - Scanner

actor DiskScanner {
    private struct NodeBuilder {
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
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> ScanSnapshot {
        let start = CFAbsoluteTimeGetCurrent()
        let rootPath = root.standardizedFileURL.path
        let rootName = root.lastPathComponent.isEmpty ? "Macintosh HD" : root.lastPathComponent

        var builders: [NodeBuilder] = [
            NodeBuilder(
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

        var directoryIDByRelativePath: [String: Int] = ["": 0]
        directoryIDByRelativePath.reserveCapacity(48_000)
        builders.reserveCapacity(350_000)

        var filesScanned: UInt64 = 0
        var itemsVisited: UInt64 = 0
        var logicalBytes: UInt64 = 0
        var allocatedBytes: UInt64 = 0
        var currentPath = rootPath
        var publishCounter = 0

        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else {
            throw NSError(
                domain: "MacTree",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Selected location could not be scanned."]
            )
        }

        while let relative = enumerator.nextObject() as? String {
            if Task.isCancelled { break }

            itemsVisited += 1
            publishCounter += 1

            let fullPath = rootPath == "/" ? "/" + relative : rootPath + "/" + relative
            currentPath = fullPath

            var statInfo = stat()
            let statResult = fullPath.withCString { pointer in
                lstat(pointer, &statInfo)
            }

            if statResult != 0 { continue }

            let fileType = statInfo.st_mode & mode_t(S_IFMT)
            let isDirectory = fileType == mode_t(S_IFDIR)
            let isSymlink = fileType == mode_t(S_IFLNK)

            if isSymlink { continue }

            if isDirectory && shouldSkipDirectory(relativePath: relative) {
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

            guard let parentID = directoryIDByRelativePath[parentRelative] else {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            let logical: UInt64
            let allocated: UInt64
            let fileCount: UInt64

            if isDirectory {
                logical = 0
                allocated = 0
                fileCount = 0
            } else {
                logical = statInfo.st_size > 0 ? UInt64(statInfo.st_size) : 0
                allocated = statInfo.st_blocks > 0 ? UInt64(statInfo.st_blocks) * 512 : logical
                fileCount = 1
                filesScanned += 1
                logicalBytes += logical
                allocatedBytes += allocated
            }

            let id = builders.count
            let modified = TimeInterval(statInfo.st_mtimespec.tv_sec)

            builders.append(
                NodeBuilder(
                    id: id,
                    parentID: parentID,
                    name: name,
                    path: fullPath,
                    isDirectory: isDirectory,
                    logicalSize: logical,
                    allocatedSize: allocated,
                    fileCount: fileCount,
                    modifiedTime: modified,
                    children: []
                )
            )
            builders[parentID].children.append(id)

            if isDirectory {
                directoryIDByRelativePath[relative] = id
            }

            if publishCounter >= 20_000 {
                await progress(
                    ScanProgress(
                        itemsVisited: itemsVisited,
                        filesScanned: filesScanned,
                        logicalBytes: logicalBytes,
                        allocatedBytes: allocatedBytes,
                        currentPath: currentPath,
                        elapsed: CFAbsoluteTimeGetCurrent() - start
                    )
                )
                publishCounter = 0
            }
        }

        if builders.count > 1 {
            for index in stride(from: builders.count - 1, through: 1, by: -1) {
                guard let parentID = builders[index].parentID else { continue }
                builders[parentID].logicalSize += builders[index].logicalSize
                builders[parentID].allocatedSize += builders[index].allocatedSize
                builders[parentID].fileCount += builders[index].fileCount
            }
        }

        var nodes = builders.map { item in
            FileNode(
                id: item.id,
                parentID: item.parentID,
                name: item.name,
                path: item.path,
                isDirectory: item.isDirectory,
                logicalSize: item.logicalSize,
                allocatedSize: item.allocatedSize,
                fileCount: item.fileCount,
                modifiedTime: item.modifiedTime,
                children: item.children
            )
        }

        let sizeReference = nodes
        for index in nodes.indices where !nodes[index].children.isEmpty {
            nodes[index].children.sort { lhs, rhs in
                let left = sizeReference[lhs]
                let right = sizeReference[rhs]
                if left.allocatedSize != right.allocatedSize {
                    return left.allocatedSize > right.allocatedSize
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        await progress(
            ScanProgress(
                itemsVisited: itemsVisited,
                filesScanned: filesScanned,
                logicalBytes: logicalBytes,
                allocatedBytes: allocatedBytes,
                currentPath: currentPath,
                elapsed: elapsed
            )
        )

        return ScanSnapshot(
            nodes: nodes,
            rootID: 0,
            filesScanned: filesScanned,
            itemsVisited: itemsVisited,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            elapsed: elapsed
        )
    }

    private func shouldSkipDirectory(relativePath: String) -> Bool {
        if relativePath == "Volumes" || relativePath.hasPrefix("Volumes/") { return true }
        if relativePath == "dev" || relativePath.hasPrefix("dev/") { return true }
        if relativePath == "System/Volumes" || relativePath.hasPrefix("System/Volumes/") { return true }

        let marker = "/" + relativePath
        if marker.contains("/Library/CloudStorage") { return true }
        if marker.contains("/Library/Mobile Documents") { return true }
        if marker.contains("/Library/Application Support/CloudDocs") { return true }

        return false
    }
}

// MARK: - Controller

@MainActor
final class ScanController: ObservableObject {
    @Published var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @Published var nodes: [FileNode] = []
    @Published var rootID = 0
    @Published var filesScanned: UInt64 = 0
    @Published var itemsVisited: UInt64 = 0
    @Published var logicalBytes: UInt64 = 0
    @Published var allocatedBytes: UInt64 = 0
    @Published var elapsed: TimeInterval = 0
    @Published var currentPath = ""
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var scanVersion = 0
    @Published var fullDiskAccessGranted = false

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?

    init() {
        refreshFullDiskAccessStatus()
    }

    func setHome() {
        rootURL = FileManager.default.homeDirectoryForCurrentUser
    }

    func setMacintoshHD() {
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

    func refreshFullDiskAccessStatus() {
        let protectedPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        fullDiskAccessGranted = access(protectedPath, R_OK) == 0
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        scanTask?.cancel()
        nodes = []
        filesScanned = 0
        itemsVisited = 0
        logicalBytes = 0
        allocatedBytes = 0
        elapsed = 0
        currentPath = rootURL.path
        errorMessage = nil
        isScanning = true

        let selectedRoot = rootURL

        scanTask = Task { [weak self] in
            guard let self else { return }

            do {
                let snapshot = try await scanner.scan(root: selectedRoot) { update in
                    await MainActor.run {
                        self.itemsVisited = update.itemsVisited
                        self.filesScanned = update.filesScanned
                        self.logicalBytes = update.logicalBytes
                        self.allocatedBytes = update.allocatedBytes
                        self.currentPath = update.currentPath
                        self.elapsed = update.elapsed
                    }
                }

                self.nodes = snapshot.nodes
                self.rootID = snapshot.rootID
                self.filesScanned = snapshot.filesScanned
                self.itemsVisited = snapshot.itemsVisited
                self.logicalBytes = snapshot.logicalBytes
                self.allocatedBytes = snapshot.allocatedBytes
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
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
}

// MARK: - Main UI

struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = ScanController()
    @State private var searchText = ""
    @State private var selectedID: Int?
    @State private var expandedIDs: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summaryBar
            Divider()

            VSplitView {
                fileTree
                    .frame(minHeight: 300)

                TreemapView(
                    nodes: controller.nodes,
                    rootID: controller.rootID,
                    selectedID: $selectedID
                )
                .frame(minHeight: 310)
            }

            Divider()
            statusBar
        }
        .onChange(of: controller.scanVersion) { _, _ in
            selectedID = nil
            expandedIDs.removeAll()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                controller.refreshFullDiskAccessStatus()
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
                Button("Home Folder") { controller.setHome() }
                Button("Macintosh HD") { controller.setMacintoshHD() }
                Divider()
                Button("Choose Folder…") { controller.chooseFolder() }
            } label: {
                Label(locationTitle, systemImage: "internaldrive")
                    .frame(minWidth: 160, alignment: .leading)
            }
            .menuStyle(.borderlessButton)

            if controller.isScanning {
                Button("Stop", role: .destructive) {
                    controller.stop()
                }
            } else {
                Button("Scan") {
                    controller.start()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }

            Button {
                controller.openFullDiskAccessSettings()
            } label: {
                Label(
                    controller.fullDiskAccessGranted ? "Full Disk Access" : "Grant Full Disk Access",
                    systemImage: controller.fullDiskAccessGranted ? "lock.open.fill" : "lock.shield"
                )
            }
            .foregroundStyle(controller.fullDiskAccessGranted ? Color.green : Color.secondary)

            Spacer()

            TextField("Search files and folders", text: $searchText)
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

    private var summaryBar: some View {
        HStack(spacing: 24) {
            summaryMetric("Allocated", formatBytes(controller.allocatedBytes))
            summaryMetric("Logical", formatBytes(controller.logicalBytes))
            summaryMetric("Files", controller.filesScanned.formatted())
            summaryMetric("Items", controller.itemsVisited.formatted())

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

    private var fileTree: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(treeRows) { row in
                        TreeRowView(
                            node: row.node,
                            depth: row.depth,
                            totalAllocated: max(controller.allocatedBytes, 1),
                            isExpanded: expandedIDs.contains(row.node.id),
                            isSelected: selectedID == row.node.id,
                            onToggle: { toggleExpanded(row.node.id) },
                            onSelect: { selectedID = row.node.id },
                            onOpen: {
                                selectedID = row.node.id
                                if row.node.isDirectory && !row.node.children.isEmpty {
                                    toggleExpanded(row.node.id)
                                }
                            }
                        )
                    }
                } header: {
                    treeHeader
                }
            }
            .frame(minWidth: 1280, alignment: .topLeading)
        }
        .id(controller.scanVersion)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private var treeHeader: some View {
        HStack(spacing: 0) {
            headerText("Name", width: 330, alignment: .leading)
            headerText("Size", width: 105, alignment: .trailing)
            headerText("Allocated", width: 105, alignment: .trailing)
            headerText("Files", width: 90, alignment: .trailing)
            headerText("% Disk", width: 145, alignment: .leading)
            headerText("Modified", width: 165, alignment: .leading)
            headerText("Path", width: 390, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.secondary)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if controller.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning \(controller.itemsVisited.formatted()) items")
                    .fontWeight(.semibold)
                Text(controller.currentPath)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            } else {
                Text("Scanned \(controller.filesScanned.formatted()) files in \(controller.elapsed.formatted(.number.precision(.fractionLength(1)))) s")
            }

            Spacer()

            if let selectedID, controller.nodes.indices.contains(selectedID) {
                let selected = controller.nodes[selectedID]
                Text("Selected: \(selected.path)   \(formatBytes(selected.allocatedSize))")
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

    private struct TreeRow: Identifiable {
        let node: FileNode
        let depth: Int
        var id: Int { node.id }
    }

    private var treeRows: [TreeRow] {
        guard !controller.nodes.isEmpty else { return [] }

        if !searchText.isEmpty {
            var matches: [TreeRow] = []
            matches.reserveCapacity(300)

            for node in controller.nodes.dropFirst() {
                if node.name.localizedCaseInsensitiveContains(searchText) || node.path.localizedCaseInsensitiveContains(searchText) {
                    matches.append(TreeRow(node: node, depth: 0))
                    if matches.count >= 2_000 { break }
                }
            }

            matches.sort {
                if $0.node.allocatedSize != $1.node.allocatedSize {
                    return $0.node.allocatedSize > $1.node.allocatedSize
                }
                return $0.node.name.localizedStandardCompare($1.node.name) == .orderedAscending
            }
            return matches
        }

        var result: [TreeRow] = []

        func appendChildren(of parentID: Int, depth: Int) {
            guard controller.nodes.indices.contains(parentID) else { return }
            for childID in controller.nodes[parentID].children {
                guard controller.nodes.indices.contains(childID) else { continue }
                let child = controller.nodes[childID]
                result.append(TreeRow(node: child, depth: depth))

                if child.isDirectory && expandedIDs.contains(child.id) {
                    appendChildren(of: child.id, depth: depth + 1)
                }
            }
        }

        appendChildren(of: controller.rootID, depth: 0)
        return result
    }

    private func toggleExpanded(_ id: Int) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    private func headerText(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
    }

    private func summaryMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title + ":")
                .foregroundStyle(Color.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }
}

// MARK: - Tree Row

private struct TreeRowView: View {
    let node: FileNode
    let depth: Int
    let totalAllocated: UInt64
    let isExpanded: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(depth) * 17)

                if node.isDirectory && !node.children.isEmpty {
                    Button(action: onToggle) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14)
                }

                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 17)

                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 330, alignment: .leading)
            .padding(.horizontal, 6)

            cellText(formatBytes(node.logicalSize), width: 105, alignment: .trailing)
            cellText(formatBytes(node.allocatedSize), width: 105, alignment: .trailing)
            cellText(node.fileCount.formatted(), width: 90, alignment: .trailing)

            HStack(spacing: 7) {
                ProgressView(value: ratio)
                    .frame(width: 66)
                Text(ratio, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
            .frame(width: 145, alignment: .leading)
            .padding(.horizontal, 6)

            cellText(modifiedText, width: 165, alignment: .leading)

            Text(node.path)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 390, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .font(.callout)
        .frame(height: 29)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
    }

    private var ratio: Double {
        Double(node.allocatedSize) / Double(max(totalAllocated, 1))
    }

    private var modifiedText: String {
        guard node.modifiedTime > 0 else { return "—" }
        return Date(timeIntervalSince1970: node.modifiedTime)
            .formatted(date: .numeric, time: .shortened)
    }

    private var iconName: String {
        if node.isDirectory {
            if node.name.hasSuffix(".app") { return "app.fill" }
            return "folder.fill"
        }

        let ext = (node.name as NSString).pathExtension.lowercased()
        if ["mp4", "mov", "mkv", "avi"].contains(ext) { return "film.fill" }
        if ["jpg", "jpeg", "png", "heic", "gif"].contains(ext) { return "photo.fill" }
        if ["zip", "7z", "rar", "dmg", "pkg"].contains(ext) { return "archivebox.fill" }
        return "doc.fill"
    }

    private var iconColor: Color {
        if node.isDirectory { return node.name.hasSuffix(".app") ? .green : .blue }
        return .secondary
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.28) }
        return node.id.isMultiple(of: 2) ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.28)
    }

    private func cellText(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
    }
}

// MARK: - Treemap

private struct TreemapCell: Identifiable {
    enum Kind {
        case directory
        case file
    }

    let nodeID: Int
    let rect: CGRect
    let depth: Int
    let kind: Kind

    var id: String { "\(nodeID)-\(depth)" }
}

private struct SquarifiedTreemapLayout {
    struct WeightedItem {
        let nodeID: Int
        let area: CGFloat
    }

    let nodes: [FileNode]

    func build(ids: [Int], in bounds: CGRect) -> [TreemapCell] {
        layout(ids: ids, in: bounds).map {
            TreemapCell(nodeID: $0.nodeID, rect: $0.rect, depth: 0, kind: nodes[$0.nodeID].isDirectory ? .directory : .file)
        }
    }

    private struct BasicCell {
        let nodeID: Int
        let rect: CGRect
    }

    private func layout(ids: [Int], in bounds: CGRect) -> [BasicCell] {
        guard bounds.width > 1, bounds.height > 1 else { return [] }

        let valid = ids.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }
        guard !valid.isEmpty else { return [] }

        let total = valid.reduce(UInt64(0)) { $0 + nodes[$1].allocatedSize }
        guard total > 0 else { return [] }

        let totalArea = bounds.width * bounds.height
        var items = valid.map {
            WeightedItem(
                nodeID: $0,
                area: totalArea * CGFloat(Double(nodes[$0].allocatedSize) / Double(total))
            )
        }
        items.sort { $0.area > $1.area }

        var output: [BasicCell] = []
        var remaining = bounds
        var row: [WeightedItem] = []

        while !items.isEmpty {
            let candidate = items[0]
            let side = max(1, min(remaining.width, remaining.height))

            if row.isEmpty || worst(row + [candidate], side: side) <= worst(row, side: side) {
                row.append(candidate)
                items.removeFirst()
            } else {
                layoutRow(row, in: &remaining, output: &output)
                row.removeAll(keepingCapacity: true)
            }
        }

        if !row.isEmpty {
            layoutRow(row, in: &remaining, output: &output)
        }

        return output
    }

    private func worst(_ row: [WeightedItem], side: CGFloat) -> CGFloat {
        guard !row.isEmpty else { return .greatestFiniteMagnitude }

        let sum = row.reduce(CGFloat(0)) { $0 + $1.area }
        let maxArea = row.map(\.area).max() ?? 0
        let minArea = max(row.map(\.area).min() ?? 0, 0.0001)
        let sideSquared = side * side
        let sumSquared = sum * sum

        return max(
            sideSquared * maxArea / max(sumSquared, 0.0001),
            sumSquared / max(sideSquared * minArea, 0.0001)
        )
    }

    private func layoutRow(
        _ row: [WeightedItem],
        in remaining: inout CGRect,
        output: inout [BasicCell]
    ) {
        guard !row.isEmpty else { return }
        let rowArea = row.reduce(CGFloat(0)) { $0 + $1.area }

        if remaining.width >= remaining.height {
            let stripWidth = remaining.height > 0 ? rowArea / remaining.height : 0
            var y = remaining.minY

            for (index, item) in row.enumerated() {
                let height: CGFloat
                if index == row.count - 1 {
                    height = remaining.maxY - y
                } else {
                    height = stripWidth > 0 ? item.area / stripWidth : 0
                }

                output.append(
                    BasicCell(
                        nodeID: item.nodeID,
                        rect: CGRect(
                            x: remaining.minX,
                            y: y,
                            width: max(0, stripWidth),
                            height: max(0, height)
                        )
                    )
                )
                y += height
            }

            remaining = CGRect(
                x: remaining.minX + stripWidth,
                y: remaining.minY,
                width: max(0, remaining.width - stripWidth),
                height: remaining.height
            )
        } else {
            let stripHeight = remaining.width > 0 ? rowArea / remaining.width : 0
            var x = remaining.minX

            for (index, item) in row.enumerated() {
                let width: CGFloat
                if index == row.count - 1 {
                    width = remaining.maxX - x
                } else {
                    width = stripHeight > 0 ? item.area / stripHeight : 0
                }

                output.append(
                    BasicCell(
                        nodeID: item.nodeID,
                        rect: CGRect(
                            x: x,
                            y: remaining.minY,
                            width: max(0, width),
                            height: max(0, stripHeight)
                        )
                    )
                )
                x += width
            }

            remaining = CGRect(
                x: remaining.minX,
                y: remaining.minY + stripHeight,
                width: remaining.width,
                height: max(0, remaining.height - stripHeight)
            )
        }
    }
}

private struct HierarchicalTreemapLayout {
    let nodes: [FileNode]
    let maxDepth: Int = 9
    let maxCells: Int = 5500
    let minRecursiveArea: CGFloat = 120

    private let topLevelInset: CGFloat = 1
    private let childInset: CGFloat = 1

    func build(rootID: Int, in bounds: CGRect) -> [TreemapCell] {
        guard nodes.indices.contains(rootID), bounds.width > 2, bounds.height > 2 else { return [] }

        let rootChildren = nodes[rootID].children.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }
        guard !rootChildren.isEmpty else { return [] }

        let basic = SquarifiedTreemapLayout(nodes: nodes)
        let top = basic.build(ids: rootChildren, in: bounds.insetBy(dx: topLevelInset, dy: topLevelInset))

        var result: [TreemapCell] = []
        result.reserveCapacity(min(maxCells, 2500))

        for cell in top {
            appendNode(cell.nodeID, rect: cell.rect, depth: 0, result: &result)
            if result.count >= maxCells { break }
        }

        return result
    }

    private func appendNode(
        _ nodeID: Int,
        rect: CGRect,
        depth: Int,
        result: inout [TreemapCell]
    ) {
        guard result.count < maxCells,
              nodes.indices.contains(nodeID),
              rect.width > 0.8,
              rect.height > 0.8 else { return }

        let node = nodes[nodeID]
        let kind: TreemapCell.Kind = node.isDirectory ? .directory : .file
        result.append(TreemapCell(nodeID: nodeID, rect: rect, depth: depth, kind: kind))

        guard node.isDirectory,
              depth < maxDepth,
              !node.children.isEmpty,
              rect.width * rect.height >= minRecursiveArea,
              rect.width > 7,
              rect.height > 7,
              result.count < maxCells else { return }

        let headerHeight: CGFloat
        if rect.width > 85 && rect.height > 34 {
            headerHeight = min(16, max(10, rect.height * 0.08))
        } else {
            headerHeight = 2
        }

        let contentRect = CGRect(
            x: rect.minX + childInset,
            y: rect.minY + headerHeight,
            width: max(0, rect.width - childInset * 2),
            height: max(0, rect.height - headerHeight - childInset)
        )

        guard contentRect.width > 3, contentRect.height > 3 else { return }

        let children = node.children.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }
        guard !children.isEmpty else { return }

        let engine = SquarifiedTreemapLayout(nodes: nodes)
        let childCells = engine.build(ids: children, in: contentRect)

        for childCell in childCells {
            appendNode(
                childCell.nodeID,
                rect: childCell.rect.insetBy(dx: 0.35, dy: 0.35),
                depth: depth + 1,
                result: &result
            )
            if result.count >= maxCells { break }
        }
    }
}

private struct HoverState {
    let nodeID: Int
    let point: CGPoint
    let depth: Int
}

private struct TreemapView: View {
    let nodes: [FileNode]
    let rootID: Int
    @Binding var selectedID: Int?
    @State private var hoverState: HoverState?

    private let extensionPalette: [Color] = [
        .blue, .green, .purple, .orange, .teal,
        .pink, .indigo, .red, .cyan, .mint,
        .yellow, .brown
    ]

    var body: some View {
        VStack(spacing: 0) {
            treemapToolbar
            Divider()

            GeometryReader { proxy in
                let canvasSize = CGSize(
                    width: max(1, proxy.size.width),
                    height: max(1, proxy.size.height)
                )
                let cells = makeCells(size: canvasSize)

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        let drawingBounds = CGRect(origin: .zero, size: size)
                        context.fill(
                            Path(drawingBounds),
                            with: .color(Color(nsColor: .windowBackgroundColor))
                        )

                        for cell in cells {
                            guard nodes.indices.contains(cell.nodeID) else { continue }
                            let node = nodes[cell.nodeID]
                            let rect = cell.rect
                            guard rect.width > 0.55, rect.height > 0.55 else { continue }

                            if node.isDirectory {
                                drawDirectory(
                                    context: &context,
                                    node: node,
                                    cell: cell,
                                    selected: selectedID == node.id
                                )
                            } else {
                                drawFile(
                                    context: &context,
                                    node: node,
                                    cell: cell,
                                    selected: selectedID == node.id
                                )
                            }
                        }
                    }
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            updateHover(point: point, cells: cells)
                        case .ended:
                            hoverState = nil
                        }
                    }
                    .onTapGesture {
                        if let id = hoverState?.nodeID {
                            selectedID = id
                        }
                    }

                    if let hoverState,
                       nodes.indices.contains(hoverState.nodeID) {
                        hoverCard(
                            node: nodes[hoverState.nodeID],
                            depth: hoverState.depth,
                            point: hoverState.point,
                            containerSize: canvasSize
                        )
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var treemapToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3.fill")
                .foregroundStyle(Color.secondary)

            Text(rootTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if nodes.indices.contains(rootID) {
                Text(formatBytes(nodes[rootID].allocatedSize))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Text("WizTree view • all folders expanded visually • hover for details")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
    }

    private var rootTitle: String {
        guard nodes.indices.contains(rootID) else { return "Treemap" }
        return nodes[rootID].path
    }

    private func makeCells(size: CGSize) -> [TreemapCell] {
        let engine = HierarchicalTreemapLayout(nodes: nodes)
        return engine.build(
            rootID: rootID,
            in: CGRect(x: 0, y: 0, width: size.width, height: size.height)
        )
    }

    private func updateHover(point: CGPoint, cells: [TreemapCell]) {
        var best: TreemapCell?

        for cell in cells where cell.rect.contains(point) {
            if best == nil || cell.depth >= best!.depth {
                best = cell
            }
        }

        if let best {
            hoverState = HoverState(nodeID: best.nodeID, point: point, depth: best.depth)
        } else {
            hoverState = nil
        }
    }

    private func drawDirectory(
        context: inout GraphicsContext,
        node: FileNode,
        cell: TreemapCell,
        selected: Bool
    ) {
        let rect = cell.rect
        let depthShade = min(0.19, Double(cell.depth) * 0.018)

        context.fill(
            Path(rect),
            with: .color(Color.black.opacity(0.17 + depthShade))
        )

        let border = selected
            ? Color.white
            : Color.white.opacity(cell.depth == 0 ? 0.46 : 0.22)
        context.stroke(
            Path(rect),
            with: .color(border),
            lineWidth: selected ? 2.2 : (cell.depth == 0 ? 1.5 : 0.75)
        )

        if rect.width > 86 && rect.height > 33 {
            let title = Text(node.name)
                .font(cell.depth == 0 ? .caption.weight(.bold) : .caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.94))

            context.draw(
                title,
                at: CGPoint(x: rect.minX + 5, y: rect.minY + 2),
                anchor: .topLeading
            )
        }
    }

    private func drawFile(
        context: inout GraphicsContext,
        node: FileNode,
        cell: TreemapCell,
        selected: Bool
    ) {
        let rect = cell.rect
        let base = fileColor(node)

        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [base.opacity(0.97), base.opacity(0.67)]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY),
            endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        context.fill(Path(rect), with: shading)

        let border = selected ? Color.white : Color.black.opacity(0.45)
        context.stroke(
            Path(rect),
            with: .color(border),
            lineWidth: selected ? 2.1 : 0.55
        )

        if rect.width > 62 && rect.height > 28 {
            let title = Text(node.name)
                .font(rect.width > 135 && rect.height > 55 ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                .foregroundStyle(Color.white)
            context.draw(
                title,
                at: CGPoint(x: rect.minX + 4, y: rect.minY + 3),
                anchor: .topLeading
            )

            if rect.width > 90 && rect.height > 48 {
                let size = Text(formatBytes(node.allocatedSize))
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.9))
                context.draw(
                    size,
                    at: CGPoint(x: rect.minX + 4, y: rect.minY + 19),
                    anchor: .topLeading
                )
            }
        }
    }

    private func fileColor(_ node: FileNode) -> Color {
        let ext = (node.name as NSString).pathExtension.lowercased()

        switch ext {
        case "app", "dylib", "so": return .green
        case "mp4", "mov", "mkv", "avi", "webm": return .purple
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff": return .pink
        case "zip", "7z", "rar", "tar", "gz", "dmg", "pkg", "iso": return .orange
        case "mp3", "aac", "m4a", "wav", "flac", "ogg": return .cyan
        case "pdf", "doc", "docx", "pages", "txt", "rtf": return .blue
        case "swift", "c", "cpp", "h", "hpp", "js", "ts", "py", "json", "xml": return .teal
        default:
            var hash = 5381
            for byte in ext.utf8 {
                hash = ((hash << 5) &+ hash) &+ Int(byte)
            }
            return extensionPalette[abs(hash) % extensionPalette.count]
        }
    }

    @ViewBuilder
    private func hoverCard(
        node: FileNode,
        depth: Int,
        point: CGPoint,
        containerSize: CGSize
    ) -> some View {
        let cardWidth: CGFloat = 330
        let cardHeight: CGFloat = 92
        let xCandidate = point.x + cardWidth / 2 + 16
        let x = min(
            max(xCandidate, cardWidth / 2 + 8),
            max(cardWidth / 2 + 8, containerSize.width - cardWidth / 2 - 8)
        )

        let yCandidate = point.y - cardHeight / 2 - 14
        let y = min(
            max(yCandidate, cardHeight / 2 + 8),
            max(cardHeight / 2 + 8, containerSize.height - cardHeight / 2 - 8)
        )

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : fileColor(node))
                Text(node.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(formatBytes(node.allocatedSize))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }

            Text(node.path)
                .font(.caption2)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Text(node.isDirectory ? "\(node.fileCount.formatted()) files" : "File")
                Text("Depth \(depth)")
                if !node.isDirectory {
                    let ext = (node.name as NSString).pathExtension
                    if !ext.isEmpty { Text(".\(ext)") }
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.secondary)
        }
        .padding(9)
        .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(radius: 8)
        .position(x: x, y: y)
        .allowsHitTesting(false)
    }
}

// MARK: - Formatting

private func formatBytes(_ value: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(clamping: value))
}
