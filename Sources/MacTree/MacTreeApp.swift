import SwiftUI
import AppKit
import Darwin

@main
struct MacTreeApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1320, height: 860)
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
    let modifiedAt: Date?
    var children: [Int]
}

struct ScanProgress: Sendable {
    let itemsVisited: UInt64
    let filesScanned: UInt64
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let denied: UInt64
    let currentPath: String
    let elapsed: TimeInterval
}

struct ScanSnapshot: Sendable {
    let nodes: [FileNode]
    let rootID: Int
    let filesScanned: UInt64
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let denied: UInt64
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
        let modifiedAt: Date?
        var children: [Int]
    }

    func scan(
        root: URL,
        progress: @escaping @Sendable (ScanProgress) async -> Void
    ) async throws -> ScanSnapshot {
        let start = Date()
        let fm = FileManager.default
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
                modifiedAt: nil,
                children: []
            )
        ]

        var directoryIDByRelativePath: [String: Int] = ["": 0]
        var filesScanned: UInt64 = 0
        var itemsVisited: UInt64 = 0
        var logicalBytes: UInt64 = 0
        var allocatedBytes: UInt64 = 0
        var denied: UInt64 = 0
        var publishCounter = 0
        var lastPublish = Date()
        var currentPath = rootPath

        guard let enumerator = fm.enumerator(atPath: rootPath) else {
            throw NSError(
                domain: "MacTree",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Selected location could not be scanned."]
            )
        }

        while let relative = enumerator.nextObject() as? String {
            if Task.isCancelled { break }

            let fullPath = (rootPath as NSString).appendingPathComponent(relative)
            currentPath = fullPath
            itemsVisited += 1
            publishCounter += 1

            var statInfo = stat()
            let statResult = fullPath.withCString { pointer in
                lstat(pointer, &statInfo)
            }

            if statResult != 0 {
                denied += 1
                continue
            }

            let fileType = statInfo.st_mode & mode_t(S_IFMT)
            let isDirectory = fileType == mode_t(S_IFDIR)
            let isSymlink = fileType == mode_t(S_IFLNK)

            if isSymlink {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            if shouldSkip(relativePath: relative, isDirectory: isDirectory) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            let parentRelative = (relative as NSString).deletingLastPathComponent
            let parentID = directoryIDByRelativePath[parentRelative] ?? 0
            let name = (relative as NSString).lastPathComponent

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

            let modifiedAt = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec))
            let id = builders.count

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
                    modifiedAt: modifiedAt,
                    children: []
                )
            )
            builders[parentID].children.append(id)

            if isDirectory {
                directoryIDByRelativePath[relative] = id
            }

            if publishCounter >= 5000 || Date().timeIntervalSince(lastPublish) >= 0.35 {
                await progress(
                    ScanProgress(
                        itemsVisited: itemsVisited,
                        filesScanned: filesScanned,
                        logicalBytes: logicalBytes,
                        allocatedBytes: allocatedBytes,
                        denied: denied,
                        currentPath: currentPath,
                        elapsed: Date().timeIntervalSince(start)
                    )
                )
                publishCounter = 0
                lastPublish = Date()
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
                modifiedAt: item.modifiedAt,
                children: item.children
            )
        }

        let sizeReference = nodes
        for index in nodes.indices {
            nodes[index].children = nodes[index].children.sorted { lhs, rhs in
                let left = sizeReference[lhs]
                let right = sizeReference[rhs]
                if left.allocatedSize != right.allocatedSize {
                    return left.allocatedSize > right.allocatedSize
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        await progress(
            ScanProgress(
                itemsVisited: itemsVisited,
                filesScanned: filesScanned,
                logicalBytes: logicalBytes,
                allocatedBytes: allocatedBytes,
                denied: denied,
                currentPath: currentPath,
                elapsed: elapsed
            )
        )

        return ScanSnapshot(
            nodes: nodes,
            rootID: 0,
            filesScanned: filesScanned,
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            denied: denied,
            elapsed: elapsed
        )
    }

    private func shouldSkip(relativePath: String, isDirectory: Bool) -> Bool {
        guard isDirectory else { return false }

        if relativePath == "Volumes" || relativePath.hasPrefix("Volumes/") {
            return true
        }

        if relativePath == "dev" || relativePath.hasPrefix("dev/") {
            return true
        }

        if relativePath == "System/Volumes" || relativePath.hasPrefix("System/Volumes/") {
            return true
        }

        return false
    }
}

// MARK: - Controller

@MainActor
final class ScanController: ObservableObject {
    @Published var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @Published var nodes: [FileNode] = []
    @Published var rootID: Int = 0
    @Published var filesScanned: UInt64 = 0
    @Published var itemsVisited: UInt64 = 0
    @Published var logicalBytes: UInt64 = 0
    @Published var allocatedBytes: UInt64 = 0
    @Published var denied: UInt64 = 0
    @Published var elapsed: TimeInterval = 0
    @Published var currentPath: String = ""
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var scanVersion = 0

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?

    func setHome() {
        rootURL = FileManager.default.homeDirectoryForCurrentUser
    }

    func setMacintoshHD() {
        rootURL = URL(fileURLWithPath: "/", isDirectory: true)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a disk or folder"
        panel.message = "MacTree scans only the location you choose."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
        }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func start() {
        scanTask?.cancel()
        nodes = []
        filesScanned = 0
        itemsVisited = 0
        logicalBytes = 0
        allocatedBytes = 0
        denied = 0
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
                        self.denied = update.denied
                        self.currentPath = update.currentPath
                        self.elapsed = update.elapsed
                    }
                }

                self.nodes = snapshot.nodes
                self.rootID = snapshot.rootID
                self.filesScanned = snapshot.filesScanned
                self.logicalBytes = snapshot.logicalBytes
                self.allocatedBytes = snapshot.allocatedBytes
                self.denied = snapshot.denied
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
    @StateObject private var controller = ScanController()
    @State private var searchText = ""
    @State private var selectedID: Int?
    @State private var expandedIDs: Set<Int> = []
    @State private var treemapFocusID: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summaryBar
            Divider()

            VSplitView {
                fileTree
                    .frame(minHeight: 315)

                TreemapView(
                    nodes: controller.nodes,
                    focusID: $treemapFocusID,
                    selectedID: $selectedID
                )
                .frame(minHeight: 290)
            }

            Divider()
            statusBar
        }
        .onChange(of: controller.scanVersion) { _, _ in
            selectedID = nil
            expandedIDs.removeAll()
            treemapFocusID = controller.rootID
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
        HStack(spacing: 9) {
            Menu {
                Button("Home Folder") { controller.setHome() }
                Button("Macintosh HD") { controller.setMacintoshHD() }
                Divider()
                Button("Choose Folder…") { controller.chooseFolder() }
            } label: {
                Label(locationTitle, systemImage: "internaldrive")
                    .frame(minWidth: 165, alignment: .leading)
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
                Label("Full Disk Access", systemImage: "lock.shield")
            }
            .help("During development, give Xcode Full Disk Access to avoid repeated macOS privacy prompts.")

            Spacer()

            TextField("Search files and folders", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            Label(
                controller.isScanning ? "Scanning" : "Ready",
                systemImage: controller.isScanning
                    ? "arrow.triangle.2.circlepath"
                    : "checkmark.circle.fill"
            )
            .foregroundStyle(controller.isScanning ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
    }

    private var summaryBar: some View {
        HStack(spacing: 26) {
            summaryMetric("Allocated", formatBytes(controller.allocatedBytes))
            summaryMetric("Logical", formatBytes(controller.logicalBytes))
            summaryMetric("Files", controller.filesScanned.formatted())
            summaryMetric("Items", controller.itemsVisited.formatted())

            if controller.denied > 0 {
                summaryMetric("Denied", controller.denied.formatted(), warning: true)
            }

            Spacer()

            if controller.isScanning {
                ProgressView()
                    .controlSize(.small)
            }

            Text(controller.elapsed.formatted(.number.precision(.fractionLength(1))) + " s")
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var fileTree: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                treeHeader
                Divider()

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(treeRows) { row in
                            TreeRowView(
                                node: row.node,
                                depth: row.depth,
                                totalAllocated: max(controller.allocatedBytes, 1),
                                isExpanded: expandedIDs.contains(row.node.id),
                                isSelected: selectedID == row.node.id,
                                onToggle: {
                                    toggleExpanded(row.node.id)
                                },
                                onSelect: {
                                    selectedID = row.node.id
                                },
                                onOpen: {
                                    selectedID = row.node.id
                                    if row.node.isDirectory {
                                        treemapFocusID = row.node.id
                                        expandedIDs.insert(row.node.id)
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .frame(minWidth: 1190, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private var treeHeader: some View {
        HStack(spacing: 0) {
            headerText("Name", width: 315, alignment: .leading)
            headerText("Size", width: 105, alignment: .trailing)
            headerText("Allocated", width: 105, alignment: .trailing)
            headerText("Files", width: 90, alignment: .trailing)
            headerText("% Disk", width: 145, alignment: .leading)
            headerText("Modified", width: 165, alignment: .leading)
            headerText("Path", width: 360, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.secondary)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if controller.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning")
                    .fontWeight(.semibold)
            } else {
                Text("Scanned \(controller.filesScanned.formatted()) files in \(controller.elapsed.formatted(.number.precision(.fractionLength(1)))) s")
            }

            if controller.denied > 0 {
                Text("• \(controller.denied.formatted()) inaccessible")
                    .foregroundStyle(Color.orange)
            }

            Spacer()

            if controller.isScanning {
                Text(controller.currentPath)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            } else if let selectedID, controller.nodes.indices.contains(selectedID) {
                let selected = controller.nodes[selectedID]
                Text("Selected: \(selected.path)  (\(formatBytes(selected.allocatedSize)))")
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
            return controller.nodes.dropFirst().compactMap { node in
                if node.name.localizedCaseInsensitiveContains(searchText) ||
                    node.path.localizedCaseInsensitiveContains(searchText) {
                    return TreeRow(node: node, depth: 0)
                }
                return nil
            }
            .sorted {
                if $0.node.allocatedSize != $1.node.allocatedSize {
                    return $0.node.allocatedSize > $1.node.allocatedSize
                }
                return $0.node.name.localizedStandardCompare($1.node.name) == .orderedAscending
            }
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

    private func headerText(
        _ text: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(text)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
    }

    private func summaryMetric(_ title: String, _ value: String, warning: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(title + ":")
                .foregroundStyle(Color.secondary)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(warning ? Color.orange : Color.primary)
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
                Color.clear
                    .frame(width: CGFloat(depth) * 17)

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
            .frame(width: 315, alignment: .leading)
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
                .frame(width: 360, alignment: .leading)
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
        guard let date = node.modifiedAt else { return "—" }
        return date.formatted(date: .numeric, time: .shortened)
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
        return node.id.isMultiple(of: 2)
            ? Color.clear
            : Color(nsColor: .controlBackgroundColor).opacity(0.34)
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
    let nodeID: Int
    let rect: CGRect
    let depth: Int
    var id: Int { nodeID }
}

private struct TreemapLayoutEngine {
    let nodes: [FileNode]
    let maxCells: Int
    var cells: [TreemapCell] = []

    mutating func build(rootID: Int, size: CGSize) -> [TreemapCell] {
        guard nodes.indices.contains(rootID), size.width > 2, size.height > 2 else { return [] }
        let rect = CGRect(origin: .zero, size: size)
        layoutChildren(of: rootID, in: rect, depth: 0)
        return cells
    }

    private mutating func layoutChildren(of parentID: Int, in rect: CGRect, depth: Int) {
        guard cells.count < maxCells,
              nodes.indices.contains(parentID),
              depth < 6,
              rect.width > 4,
              rect.height > 4 else { return }

        let children = nodes[parentID].children.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }

        guard !children.isEmpty else { return }
        layoutGroup(children, in: rect, depth: depth)
    }

    private mutating func layoutGroup(_ ids: [Int], in rect: CGRect, depth: Int) {
        guard !ids.isEmpty, cells.count < maxCells else { return }

        if ids.count == 1 {
            let id = ids[0]
            let node = nodes[id]
            let cell = TreemapCell(nodeID: id, rect: rect, depth: depth)
            cells.append(cell)

            let area = rect.width * rect.height
            if node.isDirectory,
               !node.children.isEmpty,
               area > 4200,
               rect.width > 38,
               rect.height > 30,
               cells.count < maxCells {
                layoutChildren(
                    of: id,
                    in: rect.insetBy(dx: 1.5, dy: 1.5),
                    depth: depth + 1
                )
            }
            return
        }

        let sorted = ids.sorted {
            if nodes[$0].allocatedSize != nodes[$1].allocatedSize {
                return nodes[$0].allocatedSize > nodes[$1].allocatedSize
            }
            return nodes[$0].name < nodes[$1].name
        }

        let total = sorted.reduce(UInt64(0)) { $0 + nodes[$1].allocatedSize }
        guard total > 0 else { return }

        let target = Double(total) / 2.0
        var running = 0.0
        var splitIndex = 1

        for index in 0..<(sorted.count - 1) {
            running += Double(nodes[sorted[index]].allocatedSize)
            splitIndex = index + 1
            if running >= target { break }
        }

        let first = Array(sorted[..<splitIndex])
        let second = Array(sorted[splitIndex...])
        let firstTotal = first.reduce(UInt64(0)) { $0 + nodes[$1].allocatedSize }
        let fraction = min(0.98, max(0.02, Double(firstTotal) / Double(total)))

        if rect.width >= rect.height {
            let firstWidth = rect.width * fraction
            let firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let secondRect = CGRect(x: rect.minX + firstWidth, y: rect.minY, width: rect.width - firstWidth, height: rect.height)
            layoutGroup(first, in: firstRect, depth: depth)
            layoutGroup(second, in: secondRect, depth: depth)
        } else {
            let firstHeight = rect.height * fraction
            let firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let secondRect = CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: rect.height - firstHeight)
            layoutGroup(first, in: firstRect, depth: depth)
            layoutGroup(second, in: secondRect, depth: depth)
        }
    }
}

private struct TreemapView: View {
    let nodes: [FileNode]
    @Binding var focusID: Int
    @Binding var selectedID: Int?

    private let palette: [Color] = [
        .blue, .green, .purple, .orange, .teal,
        .pink, .indigo, .red, .cyan, .mint
    ]

    var body: some View {
        VStack(spacing: 0) {
            treemapToolbar
            Divider()

            GeometryReader { proxy in
                let cells = makeCells(size: proxy.size)

                ZStack(alignment: .topLeading) {
                    Color(nsColor: .windowBackgroundColor)

                    ForEach(cells) { cell in
                        if nodes.indices.contains(cell.nodeID) {
                            let node = nodes[cell.nodeID]
                            TreemapTile(
                                node: node,
                                rect: cell.rect,
                                depth: cell.depth,
                                color: tileColor(nodeID: node.id, depth: cell.depth),
                                isSelected: selectedID == node.id,
                                onSelect: {
                                    selectedID = node.id
                                },
                                onOpen: {
                                    if node.isDirectory && !node.children.isEmpty {
                                        focusID = node.id
                                        selectedID = node.id
                                    }
                                }
                            )
                        }
                    }
                }
                .clipped()
            }
        }
    }

    private var treemapToolbar: some View {
        HStack(spacing: 8) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(parentOfFocus == nil)

            Image(systemName: "square.grid.3x3.fill")
                .foregroundStyle(Color.secondary)

            Text(focusTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            if nodes.indices.contains(focusID) {
                Text(formatBytes(nodes[focusID].allocatedSize))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Text("Double-click a folder to zoom")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
    }

    private var focusTitle: String {
        guard nodes.indices.contains(focusID) else { return "Treemap" }
        return nodes[focusID].path
    }

    private var parentOfFocus: Int? {
        guard nodes.indices.contains(focusID) else { return nil }
        return nodes[focusID].parentID
    }

    private func goBack() {
        if let parent = parentOfFocus {
            focusID = parent
            selectedID = parent
        }
    }

    private func makeCells(size: CGSize) -> [TreemapCell] {
        guard !nodes.isEmpty, nodes.indices.contains(focusID) else { return [] }
        var engine = TreemapLayoutEngine(nodes: nodes, maxCells: 900)
        return engine.build(rootID: focusID, size: size)
    }

    private func tileColor(nodeID: Int, depth: Int) -> Color {
        let index = abs((nodeID &* 31) &+ (depth &* 7)) % palette.count
        return palette[index]
    }
}

private struct TreemapTile: View {
    let node: FileNode
    let rect: CGRect
    let depth: Int
    let color: Color
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color.opacity(max(0.46, 0.92 - Double(depth) * 0.08)))

            Rectangle()
                .stroke(isSelected ? Color.white : Color.black.opacity(0.38), lineWidth: isSelected ? 2.4 : 0.8)

            if rect.width > 72 && rect.height > 34 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(rect.width > 150 && rect.height > 70 ? .callout.weight(.semibold) : .caption.weight(.semibold))
                        .lineLimit(1)
                    Text(formatBytes(node.allocatedSize))
                        .font(.caption2)
                        .monospacedDigit()
                }
                .foregroundStyle(Color.white)
                .shadow(radius: 1)
                .padding(5)
            }
        }
        .frame(width: max(1, rect.width), height: max(1, rect.height))
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .help("\(node.name)\n\(formatBytes(node.allocatedSize))\n\(node.path)")
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
