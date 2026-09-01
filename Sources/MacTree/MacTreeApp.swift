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

            let fullPath: String
            if rootPath == "/" {
                fullPath = "/" + relative
            } else {
                fullPath = rootPath + "/" + relative
            }
            currentPath = fullPath

            var statInfo = stat()
            let statResult = fullPath.withCString { pointer in
                lstat(pointer, &statInfo)
            }

            if statResult != 0 {
                continue
            }

            let fileType = statInfo.st_mode & mode_t(S_IFMT)
            let isDirectory = fileType == mode_t(S_IFDIR)
            let isSymlink = fileType == mode_t(S_IFLNK)

            if isSymlink {
                continue
            }

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

            // Publishing too often costs a surprising amount on large trees.
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

        // Roll file sizes up into every ancestor directory.
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

        // Sort only once, after the scan is complete.
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
        // Never traverse other mounted volumes or synthetic system trees.
        if relativePath == "Volumes" || relativePath.hasPrefix("Volumes/") {
            return true
        }
        if relativePath == "dev" || relativePath.hasPrefix("dev/") {
            return true
        }
        if relativePath == "System/Volumes" || relativePath.hasPrefix("System/Volumes/") {
            return true
        }

        // iCloud / File Provider storage is intentionally excluded. Apart from being
        // noisy in a disk-usage tool, walking these folders can trigger provider work.
        let marker = "/" + relativePath
        if marker.contains("/Library/CloudStorage") {
            return true
        }
        if marker.contains("/Library/Mobile Documents") {
            return true
        }
        if marker.contains("/Library/Application Support/CloudDocs") {
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
        // macOS never allows an app to grant itself Full Disk Access. Reveal the exact
        // debug app so the user can add it, then open the correct Settings pane.
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
    @State private var treemapFocusID = 0

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
                    focusID: $treemapFocusID,
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
            treemapFocusID = controller.rootID
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
            .help("macOS requires Full Disk Access to be granted manually. MacTree will reveal the exact app and open System Settings.")

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
                                    treemapFocusID = row.node.id
                                    expandedIDs.insert(row.node.id)
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
                ProgressView()
                    .controlSize(.small)
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
    let nodeID: Int
    let rect: CGRect
    var id: Int { nodeID }
}

private struct StableTreemapLayout {
    let nodes: [FileNode]
    var cells: [TreemapCell] = []

    mutating func build(ids: [Int], in rect: CGRect) -> [TreemapCell] {
        layout(ids: ids, in: rect)
        return cells
    }

    private mutating func layout(ids: [Int], in rect: CGRect) {
        guard !ids.isEmpty, rect.width > 1, rect.height > 1 else { return }

        if ids.count == 1 {
            cells.append(TreemapCell(nodeID: ids[0], rect: rect.insetBy(dx: 0.5, dy: 0.5)))
            return
        }

        let sorted = ids.sorted { nodes[$0].allocatedSize > nodes[$1].allocatedSize }
        let total = sorted.reduce(UInt64(0)) { $0 + nodes[$1].allocatedSize }
        guard total > 0 else { return }

        let half = Double(total) / 2
        var running = 0.0
        var splitIndex = 1

        for index in 0..<(sorted.count - 1) {
            running += Double(nodes[sorted[index]].allocatedSize)
            splitIndex = index + 1
            if running >= half { break }
        }

        let first = Array(sorted[..<splitIndex])
        let second = Array(sorted[splitIndex...])
        let firstTotal = first.reduce(UInt64(0)) { $0 + nodes[$1].allocatedSize }
        let fraction = min(0.985, max(0.015, Double(firstTotal) / Double(total)))

        if rect.width >= rect.height {
            let firstWidth = rect.width * fraction
            layout(ids: first, in: CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height))
            layout(ids: second, in: CGRect(x: rect.minX + firstWidth, y: rect.minY, width: rect.width - firstWidth, height: rect.height))
        } else {
            let firstHeight = rect.height * fraction
            layout(ids: first, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight))
            layout(ids: second, in: CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: rect.height - firstHeight))
        }
    }
}

private struct HoverState {
    let nodeID: Int
    let point: CGPoint
}

private struct TreemapView: View {
    let nodes: [FileNode]
    @Binding var focusID: Int
    @Binding var selectedID: Int?
    @State private var hoverState: HoverState?

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
                                color: tileColor(node: node),
                                isSelected: selectedID == node.id,
                                onSelect: { selectedID = node.id },
                                onOpen: {
                                    if node.isDirectory && !node.children.isEmpty {
                                        focusID = node.id
                                        selectedID = node.id
                                        hoverState = nil
                                    }
                                },
                                onHover: { localPoint in
                                    hoverState = HoverState(
                                        nodeID: node.id,
                                        point: CGPoint(
                                            x: cell.rect.minX + localPoint.x,
                                            y: cell.rect.minY + localPoint.y
                                        )
                                    )
                                },
                                onHoverEnded: {
                                    if hoverState?.nodeID == node.id {
                                        hoverState = nil
                                    }
                                }
                            )
                        }
                    }

                    if let hoverState,
                       nodes.indices.contains(hoverState.nodeID) {
                        hoverCard(
                            node: nodes[hoverState.nodeID],
                            point: hoverState.point,
                            containerSize: proxy.size
                        )
                    }
                }
                .clipped()
            }
        }
    }

    private var treemapToolbar: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(parentOfFocus == nil)

            Image(systemName: "square.grid.3x3.fill")
                .foregroundStyle(Color.secondary)

            Text(focusTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if nodes.indices.contains(focusID) {
                Text(formatBytes(nodes[focusID].allocatedSize))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Text("Hover for details • double-click a folder to open")
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
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
            hoverState = nil
        }
    }

    private func makeCells(size: CGSize) -> [TreemapCell] {
        guard nodes.indices.contains(focusID), size.width > 2, size.height > 2 else { return [] }

        let ids = nodes[focusID].children.filter {
            nodes.indices.contains($0) && nodes[$0].allocatedSize > 0
        }
        guard !ids.isEmpty else { return [] }

        var engine = StableTreemapLayout(nodes: nodes)
        return engine.build(ids: ids, in: CGRect(origin: .zero, size: size))
    }

    private func tileColor(node: FileNode) -> Color {
        if !node.isDirectory {
            let ext = (node.name as NSString).pathExtension.lowercased()
            if ["mp4", "mov", "mkv", "avi"].contains(ext) { return .purple }
            if ["jpg", "jpeg", "png", "heic", "gif"].contains(ext) { return .pink }
            if ["zip", "7z", "rar", "dmg", "pkg"].contains(ext) { return .orange }
        }

        if node.name.hasSuffix(".app") { return .green }
        return palette[abs(node.id &* 31) % palette.count]
    }

    @ViewBuilder
    private func hoverCard(node: FileNode, point: CGPoint, containerSize: CGSize) -> some View {
        let cardWidth: CGFloat = 310
        let cardHeight: CGFloat = 78
        let x = min(max(point.x + cardWidth / 2 + 14, cardWidth / 2 + 8), containerSize.width - cardWidth / 2 - 8)
        let yCandidate = point.y - cardHeight / 2 - 14
        let y = min(max(yCandidate, cardHeight / 2 + 8), containerSize.height - cardHeight / 2 - 8)

        VStack(alignment: .leading, spacing: 3) {
            HStack {
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

            if node.isDirectory {
                Text("\(node.fileCount.formatted()) files")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
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

private struct TreemapTile: View {
    let node: FileNode
    let rect: CGRect
    let color: Color
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onHover: (CGPoint) -> Void
    let onHoverEnded: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color.opacity(0.82))

            Rectangle()
                .stroke(isSelected ? Color.white : Color.black.opacity(0.38), lineWidth: isSelected ? 2.5 : 0.8)

            if rect.width > 70 && rect.height > 34 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(rect.width > 160 && rect.height > 70 ? .callout.weight(.semibold) : .caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                onHover(location)
            case .ended:
                onHoverEnded()
            }
        }
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
