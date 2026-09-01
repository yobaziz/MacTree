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
    let resolvedPath: String

    var body: some View {
        Group {
            Button(mtL("Open")) { MTFileActions.open(node, path: resolvedPath) }
            Button(mtL("Show in Finder")) { MTFileActions.reveal(node, path: resolvedPath) }
            Button(mtL("Open Containing Folder")) { MTFileActions.openContainingFolder(node, path: resolvedPath) }
            Button(mtL("Get Info")) { MTNativeFileActions.showInfo(node, path: resolvedPath) }
            Divider()
            Button(mtL("Copy Path")) { MTFileActions.copyPath(node, path: resolvedPath) }
            Button(mtL("Copy Name")) { MTFileActions.copyName(node) }
            Button(node.isDirectory ? mtL("Open in Terminal") : mtL("Open Folder in Terminal")) {
                MTFileActions.openTerminal(node, path: resolvedPath)
            }
            Divider()
            Button(mtL("Move to Trash"), role: .destructive) {
                MTNativeFileActions.moveToTrash(node, path: resolvedPath)
            }
        }
    }
}

private struct MTTreeColumns: Equatable {
    let width: CGFloat
    let name: CGFloat
    let size: CGFloat
    let allocated: CGFloat
    let files: CGFloat
    let disk: CGFloat
    let modified: CGFloat
    let path: CGFloat
    let showModified: Bool
    let showPath: Bool

    init(width: CGFloat) {
        self.width = max(480, width)
        showModified = width >= 760
        showPath = width >= 980

        size = 86
        allocated = 88
        files = 68
        disk = 116
        modified = showModified ? 132 : 0
        path = showPath ? max(150, width * 0.19) : 0

        let fixed = size + allocated + files + disk + modified + path
        name = max(190, self.width - fixed)
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
        GeometryReader { geometry in
            let columns = MTTreeColumns(width: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(displayRows) { row in
                                if nodes.indices.contains(row.id) {
                                    let node = nodes[row.id]
                                    let resolvedPath = mtResolvedPath(node.id, nodes: nodes)
                                    MTTreeRow(
                                        node: node,
                                        resolvedPath: resolvedPath,
                                        depth: row.depth,
                                        total: max(totalAllocated, 1),
                                        columns: columns,
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
                            treeHeader(columns)
                        }
                    }
                    .frame(width: columns.width, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                .clipped()
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
        .clipped()
    }

    @ViewBuilder
    private func treeHeader(_ c: MTTreeColumns) -> some View {
        HStack(spacing: 0) {
            header(mtL("Name"), c.name, .leading)
            header(mtL("Size"), c.size, .trailing)
            header(mtL("Allocated"), c.allocated, .trailing)
            header(mtL("Files"), c.files, .trailing)
            header(mtL("% Disk"), c.disk, .leading)
            if c.showModified { header(mtL("Modified"), c.modified, .leading) }
            if c.showPath { header(mtL("Path"), c.path, .leading) }
        }
        .frame(width: c.width, alignment: .leading)
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.secondary)
        .padding(.vertical, 7)
        .background(.bar)
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
        Text(text)
            .padding(.horizontal, 5)
            .frame(width: width, alignment: alignment)
            .lineLimit(1)
    }
}

private struct MTTreeRow: View, Equatable {
    let node: MTNode
    let resolvedPath: String
    let depth: Int
    let total: UInt64
    let columns: MTTreeColumns
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
        lhs.resolvedPath == rhs.resolvedPath &&
        lhs.depth == rhs.depth &&
        lhs.total == rhs.total &&
        lhs.columns == rhs.columns &&
        lhs.isExpanded == rhs.isExpanded &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isHovered == rhs.isHovered
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Color.clear.frame(width: min(CGFloat(depth) * 15, max(0, columns.name * 0.45)))
                if node.isDirectory && !node.children.isEmpty {
                    Button(action: toggle) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: 13)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 13)
                }

                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : Color.secondary)
                    .frame(width: 16)

                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 5)
            .frame(width: columns.name, alignment: .leading)

            cell(mtBytes(node.logicalSize), columns.size, .trailing)
            cell(mtBytes(node.allocatedSize), columns.allocated, .trailing)
            cell(node.fileCount.formatted(), columns.files, .trailing)

            HStack(spacing: 5) {
                let ratio = Double(node.allocatedSize) / Double(max(total, 1))
                ProgressView(value: ratio)
                    .frame(maxWidth: 52)
                Text(ratio, format: .percent.precision(.fractionLength(1)))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.horizontal, 5)
            .frame(width: columns.disk, alignment: .leading)

            if columns.showModified {
                let modified = node.modifiedTime > 0
                    ? Date(timeIntervalSince1970: node.modifiedTime).formatted(date: .numeric, time: .shortened)
                    : "—"
                cell(modified, columns.modified, .leading)
            }

            if columns.showPath {
                Text(resolvedPath)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 5)
                    .frame(width: columns.path, alignment: .leading)
            }
        }
        .frame(width: columns.width, height: 29, alignment: .leading)
        .font(.callout)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: select)
        .contextMenu { MTFileContextMenu(node: node, resolvedPath: resolvedPath) }
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
            .padding(.horizontal, 5)
            .frame(width: width, alignment: alignment)
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

private struct MTExtensionBucket: Sendable {
    var logical: UInt64 = 0
    var allocated: UInt64 = 0
    var files: UInt64 = 0
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
                var buckets: [String: MTExtensionBucket] = [:]
                buckets.reserveCapacity(2200)

                for node in snapshot {
                    if Task.isCancelled { return [MTExtensionStat]() }
                    guard !node.isDirectory else { continue }
                    let key = mtFastExtensionKey(node.name)
                    var bucket = buckets[key] ?? MTExtensionBucket()
                    bucket.logical = mtSafeAdd(bucket.logical, node.logicalSize)
                    bucket.allocated = mtSafeAdd(bucket.allocated, node.allocatedSize)
                    bucket.files = mtSafeAdd(bucket.files, 1)
                    buckets[key] = bucket
                }

                return buckets.map { key, bucket in
                    MTExtensionStat(
                        extensionKey: key,
                        logicalSize: bucket.logical,
                        allocatedSize: bucket.allocated,
                        fileCount: bucket.files,
                        categoryRaw: mtExtensionCategory(key).rawValue
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

private func mtFastExtensionKey(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "(no extension)" }
    let after = name.index(after: dot)
    guard after < name.endIndex else { return "(no extension)" }
    let raw = name[after...]
    guard raw.count <= 32 else { return "(no extension)" }
    return "." + raw.lowercased()
}

private func mtExtensionDisplayName(_ key: String) -> String {
    key == "(no extension)" ? mtL("No Extension") : key
}

private func mtExtensionCategory(_ key: String) -> MTCategory {
    let ext = key.hasPrefix(".") ? String(key.dropFirst()) : ""
    switch ext {
    case "app", "appex", "xpc": return .application
    case "mp4", "mov", "mkv", "avi", "webm", "m4v", "mpeg", "mpg": return .video
    case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp", "svg", "icns": return .image
    case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso", "jar": return .archive
    case "mp3", "aac", "m4a", "wav", "flac", "ogg", "aiff", "bank": return .audio
    case "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "csv", "xls", "xlsx", "ppt", "pptx": return .document
    case "swift", "c", "cpp", "cc", "h", "hpp", "js", "ts", "py", "java", "kt", "rs", "go", "rb", "php", "css", "html", "sh": return .code
    case "db", "sqlite", "sqlite3", "realm", "mdb": return .database
    case "ini", "cfg", "conf", "plist", "yaml", "yml", "toml", "json", "xml": return .config
    case "log": return .logs
    case "pak", "vpk", "wad", "pck", "bundle", "assets", "asset", "res", "ress", "resource", "dat", "bin", "obb", "unity3d": return .gameData
    case "dylib", "so", "framework", "kext", "metallib", "car": return .system
    default: return .other
    }
}

private struct MTExtensionColumns: Equatable {
    let width: CGFloat
    let color: CGFloat = 18
    let ext: CGFloat
    let type: CGFloat
    let percent: CGFloat
    let logical: CGFloat
    let allocated: CGFloat
    let files: CGFloat
    let showType: Bool
    let showLogical: Bool

    init(width: CGFloat) {
        self.width = max(340, width)
        showType = width >= 405
        showLogical = width >= 560

        ext = 78
        percent = 65
        allocated = 90
        files = 72
        logical = showLogical ? 86 : 0

        let fixed = color + ext + percent + allocated + files + logical
        type = showType ? max(0, self.width - fixed) : 0
    }
}

struct MTExtensionPane: View {
    let nodes: [MTNode]
    let scanVersion: Int
    let totalAllocated: UInt64

    @StateObject private var model = MTExtensionIndexModel()
    @State private var selectedExtension: String?

    var body: some View {
        GeometryReader { geometry in
            let columns = MTExtensionColumns(width: geometry.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(Color.secondary)
                    Text(mtL("File Types / Extensions"))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if model.isIndexing {
                        ProgressView().controlSize(.mini)
                        Text(mtL("Indexing…"))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    } else {
                        Text("\(model.stats.count.formatted()) \(mtL("extensions"))")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.bar)

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(model.stats) { stat in
                                MTExtensionRow(
                                    stat: stat,
                                    total: max(totalAllocated, 1),
                                    columns: columns,
                                    selected: selectedExtension == stat.extensionKey
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedExtension = selectedExtension == stat.extensionKey ? nil : stat.extensionKey
                                }
                            }
                        } header: {
                            extensionHeader(columns)
                        }
                    }
                    .frame(width: columns.width, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                .clipped()

                if let selectedExtension {
                    HStack(spacing: 5) {
                        Image(systemName: "scope")
                        Text(mtExtensionDisplayName(selectedExtension)).fontWeight(.semibold)
                        Text(mtL("selected")).foregroundStyle(Color.secondary)
                        Spacer()
                        Button(mtL("Clear")) { self.selectedExtension = nil }
                            .buttonStyle(.plain)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Color.accentColor.opacity(0.10))
                }
            }
            .frame(width: columns.width)
            .clipped()
        }
        .onAppear { model.sync(nodes: nodes, version: scanVersion) }
        .onChange(of: scanVersion) { _, value in
            selectedExtension = nil
            model.sync(nodes: nodes, version: value)
        }
        .clipped()
    }

    @ViewBuilder
    private func extensionHeader(_ c: MTExtensionColumns) -> some View {
        HStack(spacing: 0) {
            extHeader("", c.color, .center)
            extHeader(mtL("Extension"), c.ext, .leading)
            if c.showType { extHeader(mtL("File Type"), c.type, .leading) }
            extHeader(mtL("Percent"), c.percent, .trailing)
            if c.showLogical { extHeader(mtL("Size"), c.logical, .trailing) }
            extHeader(mtL("Allocated"), c.allocated, .trailing)
            extHeader(mtL("Files"), c.files, .trailing)
        }
        .frame(width: c.width, alignment: .leading)
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.secondary)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func extHeader(_ text: String, _ width: CGFloat, _ alignment: Alignment) -> some View {
        Text(text)
            .padding(.horizontal, 4)
            .frame(width: width, alignment: alignment)
            .lineLimit(1)
    }
}

private struct MTExtensionRow: View {
    let stat: MTExtensionStat
    let total: UInt64
    let columns: MTExtensionColumns
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
                .frame(width: columns.color)

            extensionCell(mtExtensionDisplayName(stat.extensionKey), columns.ext, .leading, monospaced: true)
            if columns.showType {
                extensionCell(extensionTypeName(stat.extensionKey, category: category), columns.type, .leading)
            }
            extensionCell(ratio.formatted(.percent.precision(.fractionLength(1))), columns.percent, .trailing, monospaced: true)
            if columns.showLogical {
                extensionCell(mtBytes(stat.logicalSize), columns.logical, .trailing, monospaced: true)
            }
            extensionCell(mtBytes(stat.allocatedSize), columns.allocated, .trailing, monospaced: true)
            extensionCell(stat.fileCount.formatted(), columns.files, .trailing, monospaced: true)
        }
        .frame(width: columns.width, height: 27, alignment: .leading)
        .font(.callout)
        .background(selected ? Color.accentColor.opacity(0.30) : Color.clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.22) }
        .help("\(mtExtensionDisplayName(stat.extensionKey)) • \(extensionTypeName(stat.extensionKey, category: category)) • \(mtBytes(stat.allocatedSize)) \(mtL("Allocated").lowercased()) • \(stat.fileCount.formatted()) \(mtL("files"))")
    }

    private func extensionCell(_ text: String, _ width: CGFloat, _ alignment: Alignment, monospaced: Bool = false) -> some View {
        Group {
            if monospaced { Text(text).monospacedDigit() } else { Text(text) }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 4)
        .frame(width: width, alignment: alignment)
    }

    private func extensionTypeName(_ key: String, category: MTCategory) -> String {
        let ext = key.hasPrefix(".") ? String(key.dropFirst()) : ""
        switch ext {
        case "dylib": return mtL("Dynamic Library")
        case "framework": return mtL("Framework")
        case "metallib": return mtL("Metal Library")
        case "car": return mtL("Asset Catalog")
        case "plist": return mtL("Property List")
        case "strings", "stringsdict": return mtL("Localization")
        case "json": return mtL("JSON Data")
        case "xml": return mtL("XML Data")
        case "yaml", "yml", "toml", "ini", "cfg", "conf": return mtL("Configuration")
        case "db", "sqlite", "sqlite3": return mtL("Database")
        case "log": return mtL("Log File")
        case "swift": return mtL("Swift Source")
        case "c", "h", "cpp", "cc", "hpp": return mtL("C/C++ Source")
        case "js", "ts": return mtL("JavaScript / TS")
        case "py": return mtL("Python Source")
        case "pak", "vpk", "pck", "obb": return mtL("Game Archive")
        case "assets", "asset", "res", "ress", "resource": return mtL("Resource Data")
        case "bundle": return mtL("Bundle Data")
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": return mtL("Video")
        case "png", "jpg", "jpeg", "heic", "gif", "webp": return mtL("Image")
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "bank": return mtL("Audio")
        case "zip", "7z", "rar", "tar", "gz", "xz": return mtL("Archive")
        case "dmg": return mtL("Disk Image")
        case "pkg": return mtL("Installer Package")
        case "pdf": return mtL("PDF Document")
        case "txt", "md", "rtf": return mtL("Text Document")
        case "app": return mtL("Application")
        case "": return key == "(no extension)" ? mtL("No Extension") : mtL("File")
        default: return category == .other ? mtL("File") : mtL(category.rawValue)
        }
    }
}
