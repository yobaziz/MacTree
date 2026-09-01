import SwiftUI
import AppKit

struct MTVisibleRow: Identifiable, Hashable {
    let id: Int
    let depth: Int
}

@MainActor
final class MTVisibleTreeModel: ObservableObject {
    @Published private(set) var rows: [MTVisibleRow] = []
    @Published private(set) var expanded: Set<Int> = []

    private var nodes: [MTNode] = []
    private var rootID: Int = 0
    private var version: Int = -1
    private var visibleIDs: Set<Int> = []

    func sync(nodes: [MTNode], rootID: Int, version: Int) {
        guard self.version != version else { return }
        self.version = version
        self.nodes = nodes
        self.rootID = rootID
        expanded.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)

        guard nodes.indices.contains(rootID) else {
            visibleIDs.removeAll()
            return
        }
        rows = nodes[rootID].children.compactMap { id in
            nodes.indices.contains(id) ? MTVisibleRow(id: id, depth: 0) : nil
        }
        refreshVisibleIDs()
    }

    func toggle(_ id: Int) {
        guard nodes.indices.contains(id), nodes[id].isDirectory else { return }
        if expanded.contains(id) { collapse(id) } else { expand(id) }
    }

    func reveal(_ id: Int) {
        guard nodes.indices.contains(id), !visibleIDs.contains(id) else { return }
        var chain: [Int] = []
        var current = nodes[id].parentID
        while let value = current, nodes.indices.contains(value), value != rootID {
            chain.append(value)
            current = nodes[value].parentID
        }
        for ancestor in chain.reversed() { expanded.insert(ancestor) }
        rebuild()
    }

    func nearestVisibleAncestor(_ id: Int?) -> Int? {
        guard var current = id else { return nil }
        while nodes.indices.contains(current) {
            if visibleIDs.contains(current) { return current }
            guard let parent = nodes[current].parentID else { break }
            current = parent
        }
        return nil
    }

    private func expand(_ id: Int) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == id }), nodes.indices.contains(id) else { return }
        let depth = rows[rowIndex].depth + 1
        let children = nodes[id].children.compactMap { child -> MTVisibleRow? in
            guard nodes.indices.contains(child) else { return nil }
            return MTVisibleRow(id: child, depth: depth)
        }
        guard !children.isEmpty else { return }

        expanded.insert(id)
        rows.insert(contentsOf: children, at: rowIndex + 1)
        visibleIDs.reserveCapacity(visibleIDs.count + children.count)
        for child in children { visibleIDs.insert(child.id) }
    }

    private func collapse(_ id: Int) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == id }) else { return }
        let depth = rows[rowIndex].depth
        var end = rowIndex + 1
        while end < rows.count && rows[end].depth > depth {
            expanded.remove(rows[end].id)
            visibleIDs.remove(rows[end].id)
            end += 1
        }
        expanded.remove(id)
        if end > rowIndex + 1 { rows.removeSubrange((rowIndex + 1)..<end) }
    }

    private func rebuild() {
        rows.removeAll(keepingCapacity: true)
        guard nodes.indices.contains(rootID) else {
            refreshVisibleIDs()
            return
        }

        func appendChildren(_ parent: Int, depth: Int) {
            guard nodes.indices.contains(parent) else { return }
            for child in nodes[parent].children where nodes.indices.contains(child) {
                rows.append(MTVisibleRow(id: child, depth: depth))
                if expanded.contains(child) && nodes[child].isDirectory {
                    appendChildren(child, depth: depth + 1)
                }
            }
        }
        appendChildren(rootID, depth: 0)
        refreshVisibleIDs()
    }

    private func refreshVisibleIDs() {
        visibleIDs = Set(rows.map(\.id))
    }
}

struct MTFileContextMenu: View {
    let node: MTNode

    var body: some View {
        Group {
            Button("Open") { MTFileActions.open(node) }
            Button("Show in Finder") { MTFileActions.reveal(node) }
            Button("Open Containing Folder") { MTFileActions.openContainingFolder(node) }
            Button("Get Info") { MTFileActions.getInfo(node) }
            Divider()
            Button("Copy Path") { MTFileActions.copyPath(node) }
            Button("Copy Name") { MTFileActions.copyName(node) }
            Button(node.isDirectory ? "Open in Terminal" : "Open Folder in Terminal") {
                MTFileActions.openTerminal(node)
            }
            Divider()
            Button("Move to Trash", role: .destructive) { MTFileActions.moveToTrash(node) }
        }
    }
}

struct MTTreePane: View {
    let nodes: [MTNode]
    let rootID: Int
    let totalAllocated: UInt64
    let scanVersion: Int
    @ObservedObject var searchModel: MTSearchModel
    @Binding var selectedID: Int?
    @Binding var hoveredID: Int?

    @StateObject private var model = MTVisibleTreeModel()
    @State private var localHoveredID: Int?
    @State private var hoverPublishTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(displayRows) { row in
                            if nodes.indices.contains(row.id) {
                                let node = nodes[row.id]
                                MTTreeRow(
                                    node: node,
                                    depth: row.depth,
                                    total: max(totalAllocated, 1),
                                    isExpanded: model.expanded.contains(node.id),
                                    isSelected: selectedID == node.id,
                                    isHovered: visibleHoverID == node.id,
                                    toggle: { model.toggle(node.id) },
                                    select: { selectedID = node.id },
                                    hover: { inside in handleHover(node.id, inside: inside) },
                                    open: {
                                        selectedID = node.id
                                        if node.isDirectory && !node.children.isEmpty { model.toggle(node.id) }
                                    }
                                )
                                .equatable()
                                .id(node.id)
                            }
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
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            .onAppear { model.sync(nodes: nodes, rootID: rootID, version: scanVersion) }
            .onChange(of: scanVersion) { _, value in
                model.sync(nodes: nodes, rootID: rootID, version: value)
            }
            .onChange(of: selectedID) { _, newID in
                guard searchModel.query.isEmpty, let newID else { return }
                model.reveal(newID)
                DispatchQueue.main.async { proxy.scrollTo(newID, anchor: .center) }
            }
            .onDisappear { hoverPublishTask?.cancel() }
        }
    }

    private var displayRows: [MTVisibleRow] {
        if !searchModel.query.isEmpty {
            return searchModel.resultIDs.map { MTVisibleRow(id: $0, depth: 0) }
        }
        return model.rows
    }

    private var visibleHoverID: Int? {
        let effective = localHoveredID ?? hoveredID
        if !searchModel.query.isEmpty {
            guard let effective, searchModel.resultIDs.contains(effective) else { return nil }
            return effective
        }
        return model.nearestVisibleAncestor(effective)
    }

    private func handleHover(_ id: Int, inside: Bool) {
        if inside {
            localHoveredID = id
            publishHover(id)
        } else if localHoveredID == id {
            localHoveredID = nil
            publishHover(nil)
        }
    }

    private func publishHover(_ id: Int?) {
        hoverPublishTask?.cancel()
        guard let id else {
            hoveredID = nil
            return
        }
        hoverPublishTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 35_000_000)
            guard !Task.isCancelled else { return }
            hoveredID = id
        }
    }

    private func header(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text).frame(width: width, alignment: alignment).padding(.horizontal, 6)
    }
}

private struct MTTreeRow: View, Equatable {
    let node: MTNode
    let depth: Int
    let total: UInt64
    let isExpanded: Bool
    let isSelected: Bool
    let isHovered: Bool
    let toggle: () -> Void
    let select: () -> Void
    let hover: (Bool) -> Void
    let open: () -> Void

    static func == (lhs: MTTreeRow, rhs: MTTreeRow) -> Bool {
        lhs.node.id == rhs.node.id &&
        lhs.node.name == rhs.node.name &&
        lhs.node.logicalSize == rhs.node.logicalSize &&
        lhs.node.allocatedSize == rhs.node.allocatedSize &&
        lhs.node.fileCount == rhs.node.fileCount &&
        lhs.node.modifiedTime == rhs.node.modifiedTime &&
        lhs.depth == rhs.depth &&
        lhs.total == rhs.total &&
        lhs.isExpanded == rhs.isExpanded &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isHovered == rhs.isHovered
    }

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

                Text(node.name).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 330, alignment: .leading)
            .padding(.horizontal, 6)

            cell(mtBytes(node.logicalSize), 105, .trailing)
            cell(mtBytes(node.allocatedSize), 105, .trailing)
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
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .contextMenu { MTFileContextMenu(node: node) }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.33) }
        if isHovered { return Color.accentColor.opacity(0.18) }
        return node.id.isMultiple(of: 2) ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.28)
    }

    private func cell(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .padding(.horizontal, 6)
    }
}

// MARK: - Extension analysis

struct MTExtensionStat: Identifiable, Hashable, Sendable {
    let extensionKey: String
    let logicalSize: UInt64
    let allocatedSize: UInt64
    let fileCount: UInt64
    let categoryRaw: String

    var id: String { extensionKey }
}

@MainActor
final class MTExtensionIndexModel: ObservableObject {
    @Published private(set) var stats: [MTExtensionStat] = []
    @Published private(set) var isIndexing = false

    private var version = -1
    private var task: Task<Void, Never>?

    func sync(nodes: [MTNode], version: Int) {
        guard self.version != version else { return }
        self.version = version
        task?.cancel()
        stats = []
        guard !nodes.isEmpty else {
            isIndexing = false
            return
        }

        let snapshot = nodes
        isIndexing = true
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                struct Bucket {
                    var logical: UInt64 = 0
                    var allocated: UInt64 = 0
                    var files: UInt64 = 0
                    var categoryWeights: [String: UInt64] = [:]
                }

                var buckets: [String: Bucket] = [:]
                buckets.reserveCapacity(1800)

                for node in snapshot where !node.isDirectory {
                    if Task.isCancelled { return [MTExtensionStat]() }
                    let rawExtension = (node.name as NSString).pathExtension.lowercased()
                    let key = rawExtension.isEmpty ? "(no extension)" : "." + rawExtension
                    var bucket = buckets[key] ?? Bucket()
                    bucket.logical = mtSafeAdd(bucket.logical, node.logicalSize)
                    bucket.allocated = mtSafeAdd(bucket.allocated, node.allocatedSize)
                    bucket.files = mtSafeAdd(bucket.files, 1)
                    let category = mtDirectCategory(node).rawValue
                    bucket.categoryWeights[category, default: 0] = mtSafeAdd(
                        bucket.categoryWeights[category, default: 0], node.allocatedSize
                    )
                    buckets[key] = bucket
                }

                return buckets.map { key, bucket in
                    let category = bucket.categoryWeights.max(by: { $0.value < $1.value })?.key ?? MTCategory.other.rawValue
                    return MTExtensionStat(
                        extensionKey: key,
                        logicalSize: bucket.logical,
                        allocatedSize: bucket.allocated,
                        fileCount: bucket.files,
                        categoryRaw: category
                    )
                }
                .sorted {
                    if $0.allocatedSize != $1.allocatedSize { return $0.allocatedSize > $1.allocatedSize }
                    return $0.extensionKey.localizedStandardCompare($1.extensionKey) == .orderedAscending
                }
            }.value

            guard !Task.isCancelled, let self else { return }
            self.stats = result
            self.isIndexing = false
        }
    }

    deinit { task?.cancel() }
}

struct MTExtensionPane: View {
    let nodes: [MTNode]
    let scanVersion: Int
    let totalAllocated: UInt64

    @StateObject private var model = MTExtensionIndexModel()
    @State private var selectedExtension: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(Color.secondary)
                Text("File Types / Extensions")
                    .font(.callout.weight(.semibold))
                Spacer()
                if model.isIndexing {
                    ProgressView().controlSize(.mini)
                    Text("Indexing…")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                } else {
                    Text("\(model.stats.count.formatted()) extensions")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.bar)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(model.stats) { stat in
                            MTExtensionRow(
                                stat: stat,
                                total: max(totalAllocated, 1),
                                selected: selectedExtension == stat.extensionKey
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedExtension = selectedExtension == stat.extensionKey ? nil : stat.extensionKey
                            }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            extensionHeader("", 22, .center)
                            extensionHeader("Extension", 88, .leading)
                            extensionHeader("File Type", 130, .leading)
                            extensionHeader("Percent", 82, .trailing)
                            extensionHeader("Size", 96, .trailing)
                            extensionHeader("Allocated", 100, .trailing)
                            extensionHeader("Files", 88, .trailing)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.vertical, 6)
                        .background(.bar)
                    }
                }
                .frame(minWidth: 606, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))

            if let selectedExtension {
                HStack(spacing: 5) {
                    Image(systemName: "scope")
                    Text(selectedExtension)
                        .fontWeight(.semibold)
                    Text("selected")
                        .foregroundStyle(Color.secondary)
                    Spacer()
                    Button("Clear") { self.selectedExtension = nil }
                        .buttonStyle(.plain)
                }
                .font(.caption2)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color.accentColor.opacity(0.10))
            }
        }
        .onAppear { model.sync(nodes: nodes, version: scanVersion) }
        .onChange(of: scanVersion) { _, value in
            selectedExtension = nil
            model.sync(nodes: nodes, version: value)
        }
    }

    private func extensionHeader(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text).frame(width: width, alignment: alignment).padding(.horizontal, 4)
    }
}

private struct MTExtensionRow: View {
    let stat: MTExtensionStat
    let total: UInt64
    let selected: Bool

    private var category: MTCategory {
        MTCategory(rawValue: stat.categoryRaw) ?? .other
    }

    private var ratio: Double {
        Double(stat.allocatedSize) / Double(max(total, 1))
    }

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(category.color)
                .frame(width: 8, height: 20)
                .frame(width: 22)

            extensionCell(stat.extensionKey, 88, .leading, monospaced: true)
            extensionCell(extensionTypeName(stat.extensionKey, category: category), 130, .leading)
            extensionCell(ratio.formatted(.percent.precision(.fractionLength(1))), 82, .trailing, monospaced: true)
            extensionCell(mtBytes(stat.logicalSize), 96, .trailing, monospaced: true)
            extensionCell(mtBytes(stat.allocatedSize), 100, .trailing, monospaced: true)
            extensionCell(stat.fileCount.formatted(), 88, .trailing, monospaced: true)
        }
        .font(.callout)
        .frame(height: 27)
        .background(selected ? Color.accentColor.opacity(0.30) : Color.clear)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.22)
        }
        .help("\(stat.extensionKey) • \(extensionTypeName(stat.extensionKey, category: category)) • \(mtBytes(stat.allocatedSize)) allocated • \(stat.fileCount.formatted()) files")
    }

    private func extensionCell(_ text: String, _ width: CGFloat, _ alignment: Alignment, monospaced: Bool = false) -> some View {
        Group {
            if monospaced {
                Text(text).monospacedDigit()
            } else {
                Text(text)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: width, alignment: alignment)
        .padding(.horizontal, 4)
    }

    private func extensionTypeName(_ key: String, category: MTCategory) -> String {
        let ext = key.hasPrefix(".") ? String(key.dropFirst()) : ""
        switch ext {
        case "dylib": return "Dynamic Library"
        case "framework": return "Framework"
        case "metallib": return "Metal Library"
        case "car": return "Asset Catalog"
        case "plist": return "Property List"
        case "strings", "stringsdict": return "Localization"
        case "json": return "JSON Data"
        case "xml": return "XML Data"
        case "yaml", "yml", "toml", "ini", "cfg", "conf": return "Configuration"
        case "db", "sqlite", "sqlite3": return "Database"
        case "log": return "Log File"
        case "swift": return "Swift Source"
        case "c", "h", "cpp", "cc", "hpp": return "C/C++ Source"
        case "js", "ts": return "JavaScript / TS"
        case "py": return "Python Source"
        case "pak", "vpk", "pck", "obb": return "Game Archive"
        case "assets", "asset", "res", "ress", "resource": return "Resource Data"
        case "bundle": return "Bundle Data"
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": return "Video"
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return "Image"
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "bank": return "Audio"
        case "zip", "7z", "rar", "tar", "gz", "xz": return "Archive"
        case "dmg": return "Disk Image"
        case "pkg": return "Installer Package"
        case "pdf": return "PDF Document"
        case "txt", "md", "rtf": return "Text Document"
        case "app": return "Application"
        case "": return key == "(no extension)" ? "No Extension" : "File"
        default:
            return category == .other ? "File" : category.rawValue
        }
    }
}
