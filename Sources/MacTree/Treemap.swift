import SwiftUI
import AppKit

private enum MTCellKind { case file, aggregate }

private struct MTCell: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let depth: Int
    let kind: MTCellKind
    let label: String
    let representedAllocated: UInt64
    let representedFiles: UInt64
    let category: MTCategory
}

private struct MTFrame: Identifiable {
    let id: Int
    let nodeID: Int
    let rect: CGRect
    let headerRect: CGRect?
    let depth: Int
}

private struct MTRenderModel {
    let cells: [MTCell]
    let frames: [MTFrame]
    let buckets: [[Int]]
    let cols: Int
    let rows: Int
    let size: CGSize

    static func empty(_ size: CGSize = .zero) -> MTRenderModel {
        MTRenderModel(cells: [], frames: [], buckets: [], cols: 0, rows: 0, size: size)
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

    func headerHitTest(_ point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        for index in frames.indices.reversed() {
            guard let header = frames[index].headerRect, mtRectFinite(header) else { continue }
            if header.contains(point) { return index }
        }
        return nil
    }
}

private struct MTWeightedEntry {
    let token: Int
    let weight: UInt64
}

private struct MTWeightedLayout {
    func layout(_ entries: [MTWeightedEntry], in rect: CGRect) -> [(Int, CGRect)] {
        let rect = rect.standardized
        guard mtRectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return [] }
        let valid = entries.filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }
        guard !valid.isEmpty else { return [] }
        var output: [(Int, CGRect)] = []
        split(valid, rect, &output)
        return output
    }

    private func split(_ entries: [MTWeightedEntry], _ rect: CGRect, _ output: inout [(Int, CGRect)]) {
        guard !entries.isEmpty, mtRectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }
        if entries.count == 1 {
            output.append((entries[0].token, rect))
            return
        }

        let total = entries.reduce(UInt64(0)) { mtSafeAdd($0, $1.weight) }
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
        let leftTotal = left.reduce(UInt64(0)) { mtSafeAdd($0, $1.weight) }
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

private struct MTTreemapBuilder {
    let nodes: [MTNode]
    private let maxCells = 1800
    private let maxDepth = 12
    private let minExpandArea: CGFloat = 180
    private let minExpandSide: CGFloat = 10
    private let maxChildrenPerFolder = 54

    func build(rootID: Int, size: CGSize) -> MTRenderModel {
        guard nodes.indices.contains(rootID), size.width.isFinite, size.height.isFinite,
              size.width > 4, size.height > 4 else { return .empty(size) }

        let children = nodes[rootID].children.filter { nodes.indices.contains($0) && nodes[$0].allocatedSize > 0 }
        guard !children.isEmpty else { return .empty(size) }
        let total = children.reduce(UInt64(0)) { mtSafeAdd($0, nodes[$1].allocatedSize) }
        guard total > 0 else { return .empty(size) }

        let layout = MTWeightedLayout()
        let rootRects = layout.layout(children.map { MTWeightedEntry(token: $0, weight: nodes[$0].allocatedSize) },
                                      in: CGRect(origin: .zero, size: size))
        var cells: [MTCell] = []
        var frames: [MTFrame] = []
        cells.reserveCapacity(maxCells)
        frames.reserveCapacity(600)

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
                        layout: MTWeightedLayout, cells: inout [MTCell], frames: inout [MTFrame]) {
        let rect = rect.standardized
        guard nodes.indices.contains(id), mtRectFinite(rect), rect.width > 0.5, rect.height > 0.5 else { return }
        let node = nodes[id]
        let nodeCategory = mtBestCategory(id, nodes)

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
        frames.append(MTFrame(id: frames.count, nodeID: id, rect: rect, headerRect: headerRect, depth: depth))

        let content = CGRect(x: rect.minX + 0.7, y: rect.minY + headerHeight + 0.7,
                             width: max(0, rect.width - 1.4), height: max(0, rect.height - headerHeight - 1.4))
        guard mtRectFinite(content), content.width > 2, content.height > 2 else {
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
                remainderWeight = mtSafeAdd(remainderWeight, nodes[childID].allocatedSize)
                remainderFiles = mtSafeAdd(remainderFiles, nodes[childID].fileCount)
            }
        }

        var entries = real.map { MTWeightedEntry(token: $0, weight: nodes[$0].allocatedSize) }
        let remainderToken = -1
        if remainderWeight > 0 { entries.append(MTWeightedEntry(token: remainderToken, weight: remainderWeight)) }
        guard !entries.isEmpty else {
            appendCell(node, content, depth + 1, .aggregate, node.name, node.allocatedSize, node.fileCount, nodeCategory, &cells)
            return
        }

        let rects = layout.layout(entries, in: content)
        let totalWeight = entries.reduce(UInt64(0)) { mtSafeAdd($0, $1.weight) }
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
                let countText = remainderFiles > 0 ? "\(remainderFiles.formatted()) \(mtL("items"))" : mtL("Grouped items")
                let category = mtCategoryForGroup(remainderSlice, nodes, fallback: nodeCategory)
                appendCell(node, rects[index].1, depth + 1, .aggregate, countText,
                           remainderWeight, remainderFiles, category, &cells)
            } else {
                render(id: token, rect: rects[index].1, depth: depth + 1, budget: 1 + shares[index],
                       layout: layout, cells: &cells, frames: &frames)
            }
        }
    }

    private func appendCell(_ node: MTNode, _ rect: CGRect, _ depth: Int, _ kind: MTCellKind,
                            _ label: String, _ allocated: UInt64, _ files: UInt64,
                            _ category: MTCategory, _ cells: inout [MTCell]) {
        let safe = mtSafeInset(rect, 0.32)
        guard mtRectFinite(safe), safe.width > 0.25, safe.height > 0.25 else { return }
        cells.append(MTCell(id: cells.count, nodeID: node.id, rect: safe, depth: depth, kind: kind,
                            label: label, representedAllocated: allocated, representedFiles: files,
                            category: category))
    }

    private func makeModel(_ cells: [MTCell], _ frames: [MTFrame], _ size: CGSize) -> MTRenderModel {
        let cols = max(16, min(64, Int(max(1, size.width) / 24)))
        let rows = max(10, min(42, Int(max(1, size.height) / 24)))
        var buckets = Array(repeating: [Int](), count: max(1, cols * rows))
        for (index, cell) in cells.enumerated() {
            let r = cell.rect.standardized
            guard mtRectFinite(r), r.width > 0, r.height > 0 else { continue }
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
                    let bucket = y * cols + x
                    if buckets.indices.contains(bucket) { buckets[bucket].append(index) }
                }
            }
        }
        return MTRenderModel(cells: cells, frames: frames, buckets: buckets,
                             cols: cols, rows: rows, size: size)
    }
}

private struct MTBuildKey: Hashable {
    let nodeCount: Int
    let rootID: Int
    let rootAllocated: UInt64
    let widthBucket: Int
    let heightBucket: Int
    let language: String
}

struct MTTreemap: View {
    let nodes: [MTNode]
    let rootID: Int
    let scannedAllocated: UInt64
    let volumeTotal: UInt64
    let volumeFree: UInt64
    @Binding var selectedID: Int?
    @Binding var hoveredID: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3.fill").foregroundStyle(Color.secondary)
                Text(rootPath).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if nodes.indices.contains(rootID) {
                    Text(mtBytes(nodes[rootID].allocatedSize)).font(.caption).foregroundStyle(Color.secondary).monospacedDigit()
                }
                Spacer()
                Text(mtL("Hierarchy view • folder headers select whole folders • right-click for actions"))
                    .font(.caption2).foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))

            MTDiskCapacityBar(scanned: scannedAllocated, total: volumeTotal, free: volumeFree)
            legend
            Divider()

            MTTreemapViewport(nodes: nodes, rootID: rootID,
                              selectedID: $selectedID, hoveredID: $hoveredID)

            Divider()
            selectionPathBar
        }
    }

    private var selectionPathBar: some View {
        let activeID = hoveredID ?? selectedID
        return HStack(spacing: 7) {
            if let activeID, nodes.indices.contains(activeID) {
                let node = nodes[activeID]
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : Color.secondary)
                Text(node.path)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(mtBytes(node.allocatedSize))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                Text("•")
                    .foregroundStyle(Color.secondary)
                Text("\(node.fileCount.formatted()) \(mtL("files"))")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            } else {
                Image(systemName: "scope")
                    .foregroundStyle(Color.secondary)
                Text(rootPath)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(MTCategory.allCases, id: \.self) { category in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 8, height: 8)
                        Text(mtL(category.rawValue)).font(.system(size: 9)).foregroundStyle(Color.secondary)
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 2)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52))
    }

    private var rootPath: String { nodes.indices.contains(rootID) ? nodes[rootID].path : mtL("Treemap") }
}

private struct MTTreemapViewport: View {
    let nodes: [MTNode]
    let rootID: Int
    @Binding var selectedID: Int?
    @Binding var hoveredID: Int?

    @AppStorage("mactree.language") private var language = MTLanguageChoice.english.rawValue
    @State private var model = MTRenderModel.empty()
    @State private var renderToken = 0
    @State private var builtKey: MTBuildKey?

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
            let rootAllocated = nodes.indices.contains(rootID) ? nodes[rootID].allocatedSize : 0
            let key = MTBuildKey(nodeCount: nodes.count,
                                 rootID: rootID,
                                 rootAllocated: rootAllocated,
                                 widthBucket: Int(size.width / 6),
                                 heightBucket: Int(size.height / 6),
                                 language: language)

            MTSurface(nodes: nodes, model: model, renderToken: renderToken,
                      selectedID: $selectedID, hoveredID: $hoveredID)
                .onAppear { rebuildIfNeeded(key: key, size: size) }
                .onChange(of: key) { _, newKey in
                    rebuildIfNeeded(key: newKey, size: size)
                }
        }
    }

    private func rebuildIfNeeded(key: MTBuildKey, size: CGSize) {
        guard builtKey != key else { return }
        builtKey = key
        model = MTTreemapBuilder(nodes: nodes).build(rootID: rootID, size: size)
        renderToken &+= 1
    }
}

private struct MTDiskCapacityBar: View {
    let scanned: UInt64
    let total: UInt64
    let free: UInt64

    var body: some View {
        let safeTotal = max(total, 1)
        let used = total > free ? total - free : 0
        let safeScanned = min(scanned, used)
        let otherUsed = used > safeScanned ? used - safeScanned : 0

        return GeometryReader { proxy in
            let width = proxy.size.width
            let scannedW = width * CGFloat(Double(safeScanned) / Double(safeTotal))
            let otherW = width * CGFloat(Double(otherUsed) / Double(safeTotal))
            let freeW = max(0, width - scannedW - otherW)

            HStack(spacing: 0) {
                segment(width: scannedW, color: Color.accentColor.opacity(0.78),
                        title: mtL("Scanned"), value: mtBytes(safeScanned))
                segment(width: otherW, color: Color.secondary.opacity(0.42),
                        title: mtL("Unscanned / Other Used"), value: mtBytes(otherUsed))
                segment(width: freeW, color: Color.green.opacity(0.48),
                        title: mtL("Free Space"), value: mtBytes(free))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        .help(mtL("Disk capacity: mapped selection, used-but-unmapped space, and free space"))
    }

    @ViewBuilder
    private func segment(width: CGFloat, color: Color, title: String, value: String) -> some View {
        ZStack(alignment: .leading) {
            color
            if width > 88 {
                Text("\(title)  \(value)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            } else if width > 44 {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: max(0, width))
    }
}

private struct MTBaseCanvas: View, Equatable {
    let nodes: [MTNode]
    let model: MTRenderModel
    let renderToken: Int

    static func == (lhs: MTBaseCanvas, rhs: MTBaseCanvas) -> Bool {
        lhs.renderToken == rhs.renderToken
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(nsColor: .windowBackgroundColor)))

            for cell in model.cells {
                guard nodes.indices.contains(cell.nodeID), mtRectFinite(cell.rect) else { continue }
                let base = cell.category.color
                let gradient = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [base.opacity(0.92), base.opacity(0.67)]),
                    startPoint: CGPoint(x: cell.rect.minX, y: cell.rect.minY),
                    endPoint: CGPoint(x: cell.rect.maxX, y: cell.rect.maxY))
                context.fill(Path(cell.rect), with: gradient)
                context.stroke(Path(cell.rect), with: .color(Color.black.opacity(0.38)), lineWidth: 0.45)

                if cell.rect.width > 50 && cell.rect.height > 18 {
                    let maxChars = max(4, Int(cell.rect.width / 6.2))
                    let title = Text(mtEllipsize(cell.label, maxCharacters: maxChars))
                        .font(.system(size: cell.rect.width > 110 && cell.rect.height > 38 ? 9 : 8, weight: .semibold))
                        .foregroundStyle(Color.white)
                    context.draw(title,
                                 at: CGPoint(x: cell.rect.minX + 3.5, y: cell.rect.minY + 2.5),
                                 anchor: .topLeading)
                    if cell.rect.width > 105 && cell.rect.height > 43 {
                        let sizeText = mtBytes(cell.representedAllocated)
                        let details = cell.representedFiles > 1
                            ? "\(sizeText) • \(cell.representedFiles.formatted()) \(mtL("files"))"
                            : sizeText
                        let sub = Text(details)
                            .font(.system(size: 7.5))
                            .foregroundStyle(Color.white.opacity(0.82))
                        context.draw(sub,
                                     at: CGPoint(x: cell.rect.minX + 3.5, y: cell.rect.minY + 14.5),
                                     anchor: .topLeading)
                    }
                }
            }

            for frame in model.frames {
                guard nodes.indices.contains(frame.nodeID), mtRectFinite(frame.rect) else { continue }
                if let header = frame.headerRect, mtRectFinite(header) {
                    context.fill(Path(header),
                                 with: .color(Color.black.opacity(frame.depth == 0 ? 0.48 : 0.34)))
                    let node = nodes[frame.nodeID]
                    let fullLabel = "\(node.name) (\(mtBytes(node.allocatedSize)))"
                    let maxChars = max(5, Int(header.width / 5.7))
                    let label = Text(mtEllipsize(fullLabel, maxCharacters: maxChars))
                        .font(.system(size: frame.depth <= 1 ? 8.5 : 8, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.94))
                    context.draw(label,
                                 at: CGPoint(x: header.minX + 3.5, y: header.minY + 0.5),
                                 anchor: .topLeading)
                }
                context.stroke(Path(frame.rect),
                               with: .color(Color.white.opacity(frame.depth == 0 ? 0.30 : 0.13)),
                               lineWidth: frame.depth == 0 ? 0.9 : 0.45)
            }
        }
    }
}

private struct MTSurface: View {
    let nodes: [MTNode]
    let model: MTRenderModel
    let renderToken: Int
    @Binding var selectedID: Int?
    @Binding var hoveredID: Int?

    @State private var hoveredCellIndex: Int?
    @State private var hoveredFrameIndex: Int?
    @State private var hoverAnchor: CGPoint = .zero
    @State private var localHoveredNodeID: Int?
    @State private var hoverPublishTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                MTBaseCanvas(nodes: nodes, model: model, renderToken: renderToken)
                    .equatable()

                selectionOverlay
                    .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            hoverAnchor = point
                            if let frameIndex = model.headerHitTest(point), model.frames.indices.contains(frameIndex) {
                                if hoveredFrameIndex != frameIndex || hoveredCellIndex != nil {
                                    hoveredFrameIndex = frameIndex
                                    hoveredCellIndex = nil
                                    let id = model.frames[frameIndex].nodeID
                                    localHoveredNodeID = id
                                    publishHover(id)
                                }
                            } else {
                                let hit = model.hitTest(point)
                                if hit != hoveredCellIndex || hoveredFrameIndex != nil {
                                    hoveredFrameIndex = nil
                                    hoveredCellIndex = hit
                                    let id = hit.flatMap { model.cells.indices.contains($0) ? model.cells[$0].nodeID : nil }
                                    localHoveredNodeID = id
                                    publishHover(id)
                                }
                            }
                        case .ended:
                            hoveredCellIndex = nil
                            hoveredFrameIndex = nil
                            localHoveredNodeID = nil
                            publishHover(nil)
                        }
                    }
                    .onTapGesture {
                        if let id = localHoveredNodeID { selectedID = id }
                    }
                    .contextMenu {
                        if let id = localHoveredNodeID, nodes.indices.contains(id) {
                            MTFileContextMenu(node: nodes[id])
                        }
                    }

                if let frameIndex = hoveredFrameIndex, model.frames.indices.contains(frameIndex) {
                    folderHoverCard(model.frames[frameIndex], proxy.size)
                        .allowsHitTesting(false)
                } else if let index = hoveredCellIndex, model.cells.indices.contains(index) {
                    hoverCard(model.cells[index], proxy.size)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .onDisappear {
            hoverPublishTask?.cancel()
        }
    }

    private var selectionOverlay: some View {
        Canvas { context, _ in
            if let selectedID {
                drawHighlight(id: selectedID, color: Color.white, width: 2.4, fillOpacity: 0.075, context: &context)
            }
            if let localHoveredNodeID, localHoveredNodeID != selectedID {
                drawHighlight(id: localHoveredNodeID, color: Color.accentColor, width: 1.7, fillOpacity: 0.055, context: &context)
            }
        }
    }

    private func drawHighlight(id: Int, color: Color, width: CGFloat, fillOpacity: Double,
                               context: inout GraphicsContext) {
        for frame in model.frames where frame.nodeID == id {
            context.fill(Path(frame.rect), with: .color(color.opacity(fillOpacity)))
            context.stroke(Path(frame.rect), with: .color(color), lineWidth: width)
        }
        for cell in model.cells where cell.nodeID == id {
            context.fill(Path(cell.rect), with: .color(color.opacity(fillOpacity * 0.7)))
            context.stroke(Path(cell.rect), with: .color(color), lineWidth: width)
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

    private func folderHoverCard(_ frame: MTFrame, _ size: CGSize) -> some View {
        let node = nodes[frame.nodeID]
        return infoCard(title: node.name,
                        node: node,
                        category: mtBestCategory(frame.nodeID, nodes),
                        allocated: node.allocatedSize,
                        files: node.fileCount,
                        typeLabel: mtL("Folder"),
                        size: size)
    }

    private func hoverCard(_ cell: MTCell, _ size: CGSize) -> some View {
        let node = nodes[cell.nodeID]
        return infoCard(title: cell.label,
                        node: node,
                        category: cell.category,
                        allocated: cell.representedAllocated,
                        files: cell.representedFiles,
                        typeLabel: node.isDirectory ? (cell.kind == .aggregate ? mtL("Grouped") : mtL("Folder")) : mtFileTypeLabel(node),
                        size: size)
    }

    private func infoCard(title: String, node: MTNode, category: MTCategory,
                          allocated: UInt64, files: UInt64, typeLabel: String,
                          size: CGSize) -> some View {
        let cardWidth: CGFloat = 430
        let cardHeight: CGFloat = 150
        let x = hoverAnchor.x + 18 + cardWidth <= size.width - 8
            ? hoverAnchor.x + 18
            : max(8, hoverAnchor.x - cardWidth - 18)
        let y = min(max(8, hoverAnchor.y + 14), max(8, size.height - cardHeight - 8))

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(node.isDirectory ? Color.blue : category.color)
                Text(title).font(.callout.weight(.bold)).lineLimit(1)
                Spacer()
                RoundedRectangle(cornerRadius: 2).fill(category.color).frame(width: 10, height: 10)
                Text(mtL(category.rawValue)).font(.caption.weight(.semibold))
            }
            HStack(spacing: 16) {
                info(mtL("Allocated"), mtBytes(allocated))
                info(mtL("Logical"), mtBytes(node.logicalSize))
                info(mtL("Files"), files.formatted())
                info(mtL("Type"), typeLabel)
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
