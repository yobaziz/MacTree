import SwiftUI
import AppKit

@main
struct MacTreeApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1050, minHeight: 700)
        }
        .defaultSize(width: 1250, height: 820)
    }
}

struct FileNode: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let logicalSize: UInt64
    let allocatedSize: UInt64
    let fileCount: UInt64
    let modifiedAt: Date?
}

struct ScanSnapshot: Sendable {
    let items: [FileNode]
    let filesScanned: UInt64
    let logicalBytes: UInt64
    let allocatedBytes: UInt64
    let denied: UInt64
    let elapsed: TimeInterval
}

actor DiskScanner {
    private struct Aggregate {
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var files: UInt64 = 0
        var modifiedAt: Date?
        var isDirectory = true
    }

    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .contentModificationDateKey
    ]

    func scan(root: URL, progress: @escaping @Sendable (ScanSnapshot) async -> Void) async throws -> ScanSnapshot {
        let start = Date()
        let fm = FileManager.default
        var topLevel: [URL: Aggregate] = [:]
        var filesScanned: UInt64 = 0
        var logicalBytes: UInt64 = 0
        var allocatedBytes: UInt64 = 0
        var denied: UInt64 = 0
        var publishCounter = 0
        var lastPublish = Date()

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw NSError(domain: "MacTree", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected location could not be scanned."])
        }

        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for case let url as URL in enumerator {
            if Task.isCancelled { break }

            do {
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { continue }

                let relative = url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")
                guard let first = relative.split(separator: "/").first, !first.isEmpty else { continue }
                let topURL = root.appendingPathComponent(String(first))
                var agg = topLevel[topURL, default: Aggregate()]

                let isDirectory = values.isDirectory == true
                if relative == String(first) {
                    agg.isDirectory = isDirectory
                    agg.modifiedAt = values.contentModificationDate
                }

                if !isDirectory {
                    let logical = UInt64(max(0, values.fileSize ?? 0))
                    let allocated = UInt64(max(0, values.fileAllocatedSize ?? values.fileSize ?? 0))
                    agg.logical += logical
                    agg.allocated += allocated
                    agg.files += 1
                    filesScanned += 1
                    logicalBytes += logical
                    allocatedBytes += allocated
                }

                topLevel[topURL] = agg
            } catch {
                denied += 1
            }

            publishCounter += 1
            if publishCounter >= 2500 || Date().timeIntervalSince(lastPublish) >= 0.25 {
                let snapshot = makeSnapshot(topLevel: topLevel, files: filesScanned, logical: logicalBytes, allocated: allocatedBytes, denied: denied, start: start)
                await progress(snapshot)
                publishCounter = 0
                lastPublish = Date()
            }
        }

        let final = makeSnapshot(topLevel: topLevel, files: filesScanned, logical: logicalBytes, allocated: allocatedBytes, denied: denied, start: start)
        await progress(final)
        return final
    }

    private func makeSnapshot(topLevel: [URL: Aggregate], files: UInt64, logical: UInt64, allocated: UInt64, denied: UInt64, start: Date) -> ScanSnapshot {
        let items = topLevel.map { url, agg in
            FileNode(
                url: url,
                name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
                isDirectory: agg.isDirectory,
                logicalSize: agg.logical,
                allocatedSize: agg.allocated,
                fileCount: agg.files,
                modifiedAt: agg.modifiedAt
            )
        }
        .sorted {
            if $0.allocatedSize != $1.allocatedSize { return $0.allocatedSize > $1.allocatedSize }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return ScanSnapshot(items: items, filesScanned: files, logicalBytes: logical, allocatedBytes: allocated, denied: denied, elapsed: Date().timeIntervalSince(start))
    }
}

@MainActor
final class ScanController: ObservableObject {
    @Published var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @Published var items: [FileNode] = []
    @Published var filesScanned: UInt64 = 0
    @Published var logicalBytes: UInt64 = 0
    @Published var allocatedBytes: UInt64 = 0
    @Published var denied: UInt64 = 0
    @Published var elapsed: TimeInterval = 0
    @Published var isScanning = false
    @Published var errorMessage: String?

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a disk or folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { rootURL = url }
    }

    func start() {
        scanTask?.cancel()
        items = []
        filesScanned = 0
        logicalBytes = 0
        allocatedBytes = 0
        denied = 0
        elapsed = 0
        errorMessage = nil
        isScanning = true
        let selectedRoot = rootURL

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await scanner.scan(root: selectedRoot) { snapshot in
                    await MainActor.run {
                        self.items = snapshot.items
                        self.filesScanned = snapshot.filesScanned
                        self.logicalBytes = snapshot.logicalBytes
                        self.allocatedBytes = snapshot.allocatedBytes
                        self.denied = snapshot.denied
                        self.elapsed = snapshot.elapsed
                    }
                }
            } catch {
                if !Task.isCancelled { self.errorMessage = error.localizedDescription }
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

struct MainView: View {
    @StateObject private var controller = ScanController()
    @State private var searchText = ""
    @State private var selectedID: FileNode.ID?

    private var visibleItems: [FileNode] {
        guard !searchText.isEmpty else { return controller.items }
        return controller.items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.url.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()

            VSplitView {
                Table(visibleItems, selection: $selectedID) {
                    TableColumn("Name") { node in
                        HStack(spacing: 6) {
                            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundStyle(node.isDirectory ? .blue : .secondary)
                            Text(node.name).lineLimit(1)
                        }
                    }.width(min: 180, ideal: 250)

                    TableColumn("Size") { node in Text(formatBytes(node.logicalSize)).monospacedDigit() }
                        .width(min: 90, ideal: 110)
                    TableColumn("Allocated") { node in Text(formatBytes(node.allocatedSize)).monospacedDigit() }
                        .width(min: 90, ideal: 110)
                    TableColumn("Files") { node in Text(node.fileCount.formatted()).monospacedDigit() }
                        .width(min: 70, ideal: 90)
                    TableColumn("% Disk") { node in
                        let ratio = Double(node.allocatedSize) / Double(max(controller.allocatedBytes, 1))
                        HStack(spacing: 5) {
                            ProgressView(value: ratio).frame(width: 50)
                            Text(ratio, format: .percent.precision(.fractionLength(1))).monospacedDigit()
                        }
                    }.width(min: 105, ideal: 125)
                    TableColumn("Path") { node in Text(node.url.path).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 250, ideal: 400)
                }
                .frame(minHeight: 300)

                TreemapPrototype(items: visibleItems)
                    .frame(minHeight: 260)
            }

            Divider()
            status
        }
        .alert("MacTree", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: controller.chooseFolder) {
                Label(controller.rootURL.lastPathComponent.isEmpty ? controller.rootURL.path : controller.rootURL.lastPathComponent, systemImage: "internaldrive")
                    .frame(minWidth: 150, alignment: .leading)
            }

            if controller.isScanning {
                Button("Stop", role: .destructive, action: controller.stop)
            } else {
                Button("Scan", action: controller.start).buttonStyle(.borderedProminent)
            }

            Spacer()
            TextField("Search", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 250)
            Label(controller.isScanning ? "Scanning…" : "Ready", systemImage: controller.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .foregroundStyle(controller.isScanning ? .secondary : .green)
        }
        .padding(10)
    }

    private var summary: some View {
        HStack(spacing: 28) {
            metric("Scanned", formatBytes(controller.allocatedBytes))
            metric("Logical", formatBytes(controller.logicalBytes))
            metric("Files", controller.filesScanned.formatted())
            metric("Denied", controller.denied.formatted())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(title):").foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }.font(.callout)
    }

    private var status: some View {
        HStack {
            if controller.isScanning { ProgressView().controlSize(.small) }
            Text(controller.isScanning
                 ? "Scanning \(controller.filesScanned.formatted()) files…"
                 : "Scanned \(controller.filesScanned.formatted()) files in \(controller.elapsed.formatted(.number.precision(.fractionLength(1)))) s")
            Spacer()
            if let selectedID, let selected = controller.items.first(where: { $0.id == selectedID }) {
                Text("Selected: \(selected.url.path)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct TreemapPrototype: View {
    let items: [FileNode]

    var body: some View {
        GeometryReader { proxy in
            let top = Array(items.prefix(10))
            let total = max(top.reduce(UInt64(0)) { $0 + $1.allocatedSize }, 1)
            HStack(spacing: 2) {
                ForEach(Array(top.enumerated()), id: \.element.id) { index, node in
                    let ratio = Double(node.allocatedSize) / Double(total)
                    ZStack {
                        Rectangle().fill(colors[index % colors.count].gradient)
                        VStack(spacing: 2) {
                            Text(node.name).font(.headline).lineLimit(1)
                            Text(formatBytes(node.allocatedSize)).font(.caption).monospacedDigit()
                            Text(ratio, format: .percent.precision(.fractionLength(1))).font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .padding(5)
                    }
                    .frame(width: max(2, proxy.size.width * ratio))
                    .clipped()
                }
            }
            .background(.black.opacity(0.08))
        }
        .overlay(alignment: .topLeading) {
            Text("Treemap prototype")
                .font(.caption)
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
        }
    }

    private let colors: [Color] = [.blue, .green, .purple, .red, .orange, .teal, .pink, .indigo, .mint, .cyan]
}

private func formatBytes(_ value: UInt64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return f.string(fromByteCount: Int64(clamping: value))
}
