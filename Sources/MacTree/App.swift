import SwiftUI
import AppKit

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

struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = MTController()
    @State private var selectedID: Int?
    @State private var hoveredID: Int?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()

            VSplitView {
                MTTreePane(
                    nodes: controller.nodes,
                    rootID: controller.rootID,
                    totalAllocated: controller.allocated,
                    scanVersion: controller.scanVersion,
                    searchModel: controller.search,
                    selectedID: $selectedID,
                    hoveredID: $hoveredID
                )
                .frame(minHeight: 290)

                MTTreemap(
                    nodes: controller.nodes,
                    rootID: controller.rootID,
                    scannedAllocated: controller.allocated,
                    volumeTotal: controller.volumeTotal,
                    volumeFree: controller.volumeFree,
                    selectedID: $selectedID,
                    hoveredID: $hoveredID
                )
                .frame(minHeight: 320)
            }

            Divider()
            status
        }
        .onChange(of: controller.scanVersion) { _, _ in
            selectedID = nil
            hoveredID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controller.refreshFullDiskAccess()
                controller.refreshVolumeSpace()
            }
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
                Label(controller.fullDiskAccess ? "Full Disk Access" : "Grant Full Disk Access",
                      systemImage: controller.fullDiskAccess ? "lock.open.fill" : "lock.shield")
            }
            .foregroundStyle(controller.fullDiskAccess ? Color.green : Color.secondary)

            Spacer()
            MTSearchField(model: controller.search)
            Label(controller.isScanning ? "Scanning" : "Ready",
                  systemImage: controller.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .foregroundStyle(controller.isScanning ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var summary: some View {
        let freePercent = controller.volumeTotal > 0
            ? Double(controller.volumeFree) / Double(controller.volumeTotal)
            : 0

        return HStack(spacing: 17) {
            metric("Disk", mtBytes(controller.volumeTotal))

            HStack(spacing: 5) {
                Text("Free:").foregroundStyle(Color.secondary)
                Text(mtBytes(controller.volumeFree))
                    .fontWeight(.bold)
                    .foregroundStyle(Color.green)
                    .monospacedDigit()
                if controller.volumeTotal > 0 {
                    Text(freePercent, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
            }
            .layoutPriority(2)

            metric("Scanned", mtBytes(controller.allocated))
            metric("Logical", mtBytes(controller.logical))
            metric("Files", controller.files.formatted())
            metric("Items", controller.items.formatted())

            Text("iCloud skipped")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.1), in: Capsule())

            Spacer(minLength: 8)
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

            let activeID = hoveredID ?? selectedID
            if let activeID, controller.nodes.indices.contains(activeID) {
                let node = controller.nodes[activeID]
                Text((hoveredID != nil ? "Hover: " : "Selected: ") + node.path + "   " + mtBytes(node.allocatedSize))
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

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title + ":").foregroundStyle(Color.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }
}

private struct MTSearchField: View {
    @ObservedObject var model: MTSearchModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            if model.isSearching { ProgressView().controlSize(.mini) }
            TextField("Search files and folders", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onChange(of: text) { _, value in model.search(value) }
        }
    }
}

extension UInt64 {
    func addingReportingOverflow(by other: UInt64) -> (partialValue: UInt64, overflow: Bool) {
        addingReportingOverflow(other)
    }
}
