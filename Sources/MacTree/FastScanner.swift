import Foundation
import AppKit
import Darwin

// Fast APFS/macOS scanner. Uses getattrlistbulk() so one syscall can return
// metadata for many directory entries. Individual directories transparently
// fall back to lstat when a filesystem does not support the bulk API.
actor MTFastScanner {
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

    private struct BulkEntry {
        let name: String
        let objectType: UInt32
        let logicalSize: UInt64
        let allocatedSize: UInt64
        let modifiedTime: TimeInterval
    }

    private let bulkBufferSize = 512 * 1024

    func scan(root: URL, progress: @escaping @Sendable (MTProgress) async -> Void) async throws -> MTSnapshot {
        let started = CFAbsoluteTimeGetCurrent()
        let rootPath = root.standardizedFileURL.path
        let rootName = root.lastPathComponent.isEmpty ? "Macintosh HD" : root.lastPathComponent

        let volumeTotal: UInt64 = {
            let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey])
            return values?.volumeTotalCapacity.map { UInt64(max(0, $0)) } ?? 0
        }()
        let maxReasonableAllocated = max(mtSafeMultiply(volumeTotal, 4), 4 * 1024 * 1024 * 1024 * 1024)
        let maxReasonableLogical = max(mtSafeMultiply(volumeTotal, 128), 32 * 1024 * 1024 * 1024 * 1024)

        var builders: [Builder] = [
            Builder(id: 0, parentID: nil, name: rootName, path: rootPath, isDirectory: true,
                    logicalSize: 0, allocatedSize: 0, fileCount: 0, modifiedTime: 0, children: [])
        ]
        builders.reserveCapacity(rootPath == "/" ? 1_250_000 : 450_000)

        // Queue node IDs only. Paths already live in Builder, avoiding a second huge path dictionary.
        var directoryQueue: [Int] = [0]
        directoryQueue.reserveCapacity(rootPath == "/" ? 150_000 : 60_000)
        var queueIndex = 0

        var items: UInt64 = 0
        var files: UInt64 = 0
        var logical: UInt64 = 0
        var allocated: UInt64 = 0
        var sincePublish = 0
        var currentPath = rootPath
        var bulkBuffer = [UInt8](repeating: 0, count: bulkBufferSize)

        while queueIndex < directoryQueue.count {
            if Task.isCancelled { throw CancellationError() }

            let parentID = directoryQueue[queueIndex]
            queueIndex += 1
            guard builders.indices.contains(parentID) else { continue }

            let directoryPath = builders[parentID].path
            currentPath = directoryPath

            let usedBulk = enumerateBulk(path: directoryPath, buffer: &bulkBuffer) { entry in
                if Task.isCancelled { return false }
                guard entry.name != ".", entry.name != ".." else { return true }

                let isDirectory = entry.objectType == UInt32(VDIR)
                let isRegular = entry.objectType == UInt32(VREG)
                let isLink = entry.objectType == UInt32(VLNK)
                if isLink || (!isDirectory && !isRegular) { return true }

                let fullPath = join(directoryPath, entry.name)
                if isDirectory && shouldSkip(path: fullPath, rootPath: rootPath) { return true }

                items = mtSafeAdd(items, 1)
                sincePublish += 1

                var nodeLogical: UInt64 = isDirectory ? 0 : entry.logicalSize
                var nodeAllocated: UInt64 = isDirectory ? 0 : entry.allocatedSize
                var nodeModified = entry.modifiedTime
                let nodeFiles: UInt64 = isDirectory ? 0 : 1

                // A corrupt/shifted metadata record must never poison the whole tree.
                // Only suspicious outliers pay for a single lstat verification.
                if !isDirectory && (nodeAllocated > maxReasonableAllocated || nodeLogical > maxReasonableLogical) {
                    var info = stat()
                    if fullPath.withCString({ lstat($0, &info) }) == 0 {
                        nodeLogical = info.st_size > 0 ? UInt64(info.st_size) : 0
                        nodeAllocated = info.st_blocks > 0 ? UInt64(info.st_blocks) * 512 : nodeLogical
                        nodeModified = TimeInterval(info.st_mtimespec.tv_sec)
                    } else {
                        nodeLogical = 0
                        nodeAllocated = 0
                    }
                }

                if !isDirectory {
                    if nodeAllocated == 0 && nodeLogical > 0 { nodeAllocated = nodeLogical }
                    files = mtSafeAdd(files, 1)
                    logical = mtSafeAdd(logical, nodeLogical)
                    allocated = mtSafeAdd(allocated, nodeAllocated)
                }

                let id = builders.count
                builders.append(
                    Builder(id: id, parentID: parentID, name: entry.name, path: fullPath,
                            isDirectory: isDirectory, logicalSize: nodeLogical,
                            allocatedSize: nodeAllocated, fileCount: nodeFiles,
                            modifiedTime: nodeModified, children: [])
                )
                builders[parentID].children.append(id)
                if isDirectory { directoryQueue.append(id) }
                return true
            }

            if !usedBulk {
                // External/legacy filesystems can reject getattrlistbulk. Fall back only for this directory.
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryPath)) ?? []
                for name in names {
                    if Task.isCancelled { throw CancellationError() }
                    guard name != ".", name != ".." else { continue }

                    let fullPath = join(directoryPath, name)
                    var info = stat()
                    if fullPath.withCString({ lstat($0, &info) }) != 0 { continue }

                    let kind = info.st_mode & mode_t(S_IFMT)
                    if kind == mode_t(S_IFLNK) { continue }
                    let isDirectory = kind == mode_t(S_IFDIR)
                    guard isDirectory || kind == mode_t(S_IFREG) else { continue }
                    if isDirectory && shouldSkip(path: fullPath, rootPath: rootPath) { continue }

                    items = mtSafeAdd(items, 1)
                    sincePublish += 1

                    let nodeLogical = isDirectory ? 0 : (info.st_size > 0 ? UInt64(info.st_size) : 0)
                    let nodeAllocated = isDirectory ? 0 : (info.st_blocks > 0 ? UInt64(info.st_blocks) * 512 : nodeLogical)
                    let nodeFiles: UInt64 = isDirectory ? 0 : 1

                    if !isDirectory {
                        files = mtSafeAdd(files, 1)
                        logical = mtSafeAdd(logical, nodeLogical)
                        allocated = mtSafeAdd(allocated, nodeAllocated)
                    }

                    let id = builders.count
                    builders.append(
                        Builder(id: id, parentID: parentID, name: name, path: fullPath,
                                isDirectory: isDirectory, logicalSize: nodeLogical,
                                allocatedSize: nodeAllocated, fileCount: nodeFiles,
                                modifiedTime: TimeInterval(info.st_mtimespec.tv_sec), children: [])
                    )
                    builders[parentID].children.append(id)
                    if isDirectory { directoryQueue.append(id) }
                }
            }

            if sincePublish >= 50_000 {
                await progress(
                    MTProgress(items: items, files: files, logical: logical, allocated: allocated,
                               currentPath: currentPath, elapsed: CFAbsoluteTimeGetCurrent() - started)
                )
                sincePublish = 0
            }
        }

        if builders.count > 1 {
            // Parents are always created before descendants, so reverse order aggregates in one pass.
            for index in stride(from: builders.count - 1, through: 1, by: -1) {
                guard let parent = builders[index].parentID else { continue }
                builders[parent].logicalSize = mtSafeAdd(builders[parent].logicalSize, builders[index].logicalSize)
                builders[parent].allocatedSize = mtSafeAdd(builders[parent].allocatedSize, builders[index].allocatedSize)
                builders[parent].fileCount = mtSafeAdd(builders[parent].fileCount, builders[index].fileCount)
            }
        }

        var nodes = builders.map {
            MTNode(id: $0.id, parentID: $0.parentID, name: $0.name, path: $0.path,
                   isDirectory: $0.isDirectory, logicalSize: $0.logicalSize,
                   allocatedSize: $0.allocatedSize, fileCount: $0.fileCount,
                   modifiedTime: $0.modifiedTime, children: $0.children)
        }

        let sizeReference = nodes
        for index in nodes.indices where !nodes[index].children.isEmpty {
            nodes[index].children.sort {
                let lhs = sizeReference[$0]
                let rhs = sizeReference[$1]
                if lhs.allocatedSize != rhs.allocatedSize { return lhs.allocatedSize > rhs.allocatedSize }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        await progress(
            MTProgress(items: items, files: files, logical: logical, allocated: allocated,
                       currentPath: currentPath, elapsed: elapsed)
        )
        return MTSnapshot(nodes: nodes, rootID: 0, items: items, files: files,
                          logical: logical, allocated: allocated, elapsed: elapsed)
    }

    // Returns false only when the directory cannot use the bulk API at all.
    private func enumerateBulk(path: String, buffer: inout [UInt8], consume: (BulkEntry) -> Bool) -> Bool {
        let fd = path.withCString { Darwin.open($0, O_RDONLY) }
        guard fd >= 0 else { return true } // Permission denied: keep scan moving.
        defer { Darwin.close(fd) }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.reserved = 0
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) |
                                attrgroup_t(ATTR_CMN_NAME) |
                                attrgroup_t(ATTR_CMN_OBJTYPE) |
                                attrgroup_t(ATTR_CMN_MODTIME)
        attributes.volattr = 0
        attributes.dirattr = 0
        attributes.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        attributes.forkattr = 0

        var gotAnyBatch = false
        while true {
            let count: Int32 = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return getattrlistbulk(fd, &attributes, base, raw.count, 0)
            }

            if count == 0 { return true }
            if count < 0 {
                // Use legacy enumeration only when bulk was rejected before yielding anything.
                return gotAnyBatch
            }
            gotAnyBatch = true

            let shouldContinue = buffer.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var entryStart = base
                let bufferEnd = base.advanced(by: raw.count)

                for _ in 0..<Int(count) {
                    guard entryStart.distance(to: bufferEnd) >= MemoryLayout<UInt32>.size else { return false }
                    let entryLength = Int(entryStart.loadUnaligned(as: UInt32.self))
                    guard entryLength >= 24, entryLength <= entryStart.distance(to: bufferEnd) else { return false }

                    let entryEnd = entryStart.advanced(by: entryLength)
                    var field = entryStart.advanced(by: MemoryLayout<UInt32>.size)

                    guard let returned: attribute_set_t = read4(&field, base: entryStart, end: entryEnd) else {
                        entryStart = entryEnd
                        continue
                    }

                    var name: String?
                    if (returned.commonattr & attrgroup_t(ATTR_CMN_NAME)) != 0 {
                        field = align4(field, base: entryStart)
                        guard field.distance(to: entryEnd) >= MemoryLayout<attrreference_t>.size else {
                            entryStart = entryEnd
                            continue
                        }

                        let referenceStart = field
                        let reference = field.loadUnaligned(as: attrreference_t.self)
                        field = field.advanced(by: MemoryLayout<attrreference_t>.size)

                        let offset = Int(reference.attr_dataoffset)
                        let length = Int(reference.attr_length)
                        if offset >= 0, length > 0 {
                            let namePointer = referenceStart.advanced(by: offset)
                            let nameEnd = namePointer.advanced(by: length)
                            if Int(bitPattern: namePointer) >= Int(bitPattern: entryStart),
                               Int(bitPattern: nameEnd) <= Int(bitPattern: entryEnd) {
                                name = String(validatingUTF8: namePointer.assumingMemoryBound(to: CChar.self))
                            }
                        }
                    }

                    var objectType: UInt32 = 0
                    if (returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE)) != 0,
                       let value: fsobj_type_t = read4(&field, base: entryStart, end: entryEnd) {
                        objectType = UInt32(value)
                    }

                    var modified: TimeInterval = 0
                    if (returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME)) != 0,
                       let value: timespec = read4(&field, base: entryStart, end: entryEnd) {
                        modified = TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
                    }

                    var logical: UInt64 = 0
                    var allocated: UInt64 = 0
                    if (returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE)) != 0,
                       let value: off_t = read4(&field, base: entryStart, end: entryEnd), value > 0 {
                        logical = UInt64(value)
                    }
                    if (returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE)) != 0,
                       let value: off_t = read4(&field, base: entryStart, end: entryEnd), value > 0 {
                        allocated = UInt64(value)
                    }
                    if allocated == 0 && logical > 0 { allocated = logical }

                    if let name, !name.isEmpty {
                        if !consume(
                            BulkEntry(name: name, objectType: objectType,
                                      logicalSize: logical, allocatedSize: allocated,
                                      modifiedTime: modified)
                        ) {
                            return false
                        }
                    }
                    entryStart = entryEnd
                }
                return true
            }

            if !shouldContinue { return true }
        }
    }

    // Darwin's getattrlist/getattrlistbulk ABI packs every attribute on a
    // 4-byte boundary, including 64-bit values. Natural Swift alignment (8)
    // is therefore wrong for timespec/off_t and shifts all following fields.
    private func read4<T>(_ field: inout UnsafeRawPointer,
                          base: UnsafeRawPointer,
                          end: UnsafeRawPointer) -> T? {
        field = align4(field, base: base)
        guard field.distance(to: end) >= MemoryLayout<T>.size else { return nil }
        let value = field.loadUnaligned(as: T.self)
        field = field.advanced(by: MemoryLayout<T>.size)
        return value
    }

    private func align4(_ pointer: UnsafeRawPointer, base: UnsafeRawPointer) -> UnsafeRawPointer {
        let offset = base.distance(to: pointer)
        let alignedOffset = (offset + 3) & ~3
        return base.advanced(by: alignedOffset)
    }

    private func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    private func shouldSkip(path: String, rootPath: String) -> Bool {
        if rootPath == "/" {
            if path == "/Volumes" || path.hasPrefix("/Volumes/") { return true }
            if path == "/dev" || path.hasPrefix("/dev/") { return true }
            if path == "/System/Volumes" || path.hasPrefix("/System/Volumes/") { return true }
        }
        if path.contains("/Library/CloudStorage") { return true }
        if path.contains("/Library/Mobile Documents") { return true }
        if path.contains("/Library/Application Support/CloudDocs") { return true }
        return false
    }
}

@MainActor
final class MTFastController: ObservableObject {
    @Published var rootURL = URL(fileURLWithPath: "/", isDirectory: true)
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
    @Published var volumeTotal: UInt64 = 0
    @Published var volumeFree: UInt64 = 0

    let search = MTSearchModel()
    private let scanner = MTFastScanner()
    private var task: Task<Void, Never>?

    init() {
        refreshFullDiskAccess()
        refreshVolumeSpace()
    }

    func chooseHome() {
        rootURL = FileManager.default.homeDirectoryForCurrentUser
        refreshVolumeSpace()
    }

    func chooseDisk() {
        rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        refreshVolumeSpace()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = mtL("Choose Folder…")
        panel.message = "iCloud and File Provider folders are skipped automatically."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            refreshVolumeSpace()
        }
    }

    func refreshFullDiskAccess() {
        fullDiskAccess = access("/Library/Application Support/com.apple.TCC/TCC.db", R_OK) == 0
    }

    func refreshVolumeSpace() {
        do {
            let values = try rootURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            volumeTotal = values.volumeTotalCapacity.map { UInt64(max(0, $0)) } ?? 0
            volumeFree = values.volumeAvailableCapacity.map { UInt64(max(0, $0)) } ?? 0
        } catch {
            volumeTotal = 0
            volumeFree = 0
        }
    }

    func openFullDiskAccess() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func start() {
        task?.cancel()
        refreshVolumeSpace()
        nodes = []
        search.setNodes([])
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

                guard !Task.isCancelled else {
                    self.isScanning = false
                    return
                }

                self.nodes = snapshot.nodes
                self.rootID = snapshot.rootID
                self.items = snapshot.items
                self.files = snapshot.files
                self.logical = snapshot.logical
                self.allocated = snapshot.allocated
                self.elapsed = snapshot.elapsed
                self.search.setNodes(snapshot.nodes)
                self.refreshVolumeSpace()
                self.scanVersion += 1
            } catch is CancellationError {
                // Normal stop action.
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
