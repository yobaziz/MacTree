import SwiftUI
import AppKit

// MARK: - Preferences / localization

enum MTLanguageChoice: String, CaseIterable, Identifiable {
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }
}

enum MTAppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
func mtApplyAppearance(_ rawValue: String) {
    let choice = MTAppearanceChoice(rawValue: rawValue) ?? .system
    let target = choice.nsAppearance

    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        context.allowsImplicitAnimation = false
        NSApp.appearance = target
        for window in NSApp.windows {
            window.appearance = target
            window.contentView?.needsDisplay = true
        }
    }
}

private let mtTurkishStrings: [String: String] = [
    "Settings": "Ayarlar",
    "General": "Genel",
    "Language": "Dil",
    "Appearance": "Görünüm",
    "English": "İngilizce",
    "Turkish": "Türkçe",
    "System": "Sistem",
    "Light": "Açık",
    "Dark": "Koyu",
    "Follow macOS": "macOS ayarını kullan",
    "Changes are saved automatically.": "Değişiklikler otomatik kaydedilir.",

    "Macintosh HD — Whole Disk": "Macintosh HD — Tüm Disk",
    "Home Folder": "Ana Klasör",
    "Choose Folder…": "Klasör Seç…",
    "Stop": "Durdur",
    "Scan": "Tara",
    "Full Disk Access": "Tam Disk Erişimi",
    "Grant Full Disk Access": "Tam Disk Erişimi Ver",
    "Scanning": "Taranıyor",
    "Ready": "Hazır",
    "Disk": "Disk",
    "Free": "Boş",
    "Mapped": "Eşlenen",
    "Coverage": "Kapsama",
    "Files": "Dosyalar",
    "Items": "Öğeler",
    "Whole Disk": "Tüm Disk",
    "Folder scope": "Klasör kapsamı",
    "Scanning items": "Öğe taranıyor",
    "Scanned files in": "Taranan dosya / süre",
    "Hover": "Üzerinde",
    "Selected": "Seçili",
    "Search files and folders": "Dosya ve klasör ara",

    "Open": "Aç",
    "Show in Finder": "Finder'da Göster",
    "Open Containing Folder": "Bulunduğu Klasörü Aç",
    "Get Info": "Bilgi Ver",
    "Copy Path": "Yolu Kopyala",
    "Copy Name": "Adı Kopyala",
    "Open in Terminal": "Terminal'de Aç",
    "Open Folder in Terminal": "Klasörü Terminal'de Aç",
    "Move to Trash": "Çöp Sepetine Taşı",
    "Move to Trash?": "Çöp Sepetine taşınsın mı?",
    "Cancel": "Vazgeç",
    "This item will be moved to the Trash.": "Bu öğe Çöp Sepetine taşınacak.",
    "Could not move item to Trash": "Öğe Çöp Sepetine taşınamadı",
    "The item no longer exists at this location.": "Öğe artık bu konumda bulunmuyor.",
    "macOS protects this system location.": "macOS bu sistem konumunu koruyor.",
    "The item may be protected by macOS or require additional permission.": "Öğe macOS tarafından korunuyor veya ek izin gerektiriyor olabilir.",

    "Name": "Ad",
    "Size": "Boyut",
    "Allocated": "Ayrılan",
    "% Disk": "% Disk",
    "Modified": "Değiştirilme",
    "Path": "Yol",
    "File Types / Extensions": "Dosya Türleri / Uzantılar",
    "Indexing…": "İndeksleniyor…",
    "extensions": "uzantı",
    "Extension": "Uzantı",
    "File Type": "Dosya Türü",
    "Percent": "Yüzde",
    "selected": "seçili",
    "Clear": "Temizle",
    "No Extension": "Uzantısız",
    "File": "Dosya",
    "Dynamic Library": "Dinamik Kütüphane",
    "Framework": "Framework",
    "Metal Library": "Metal Kütüphanesi",
    "Asset Catalog": "Varlık Kataloğu",
    "Property List": "Özellik Listesi",
    "Localization": "Yerelleştirme",
    "JSON Data": "JSON Verisi",
    "XML Data": "XML Verisi",
    "Configuration": "Yapılandırma",
    "Database": "Veritabanı",
    "Log File": "Günlük Dosyası",
    "Swift Source": "Swift Kaynağı",
    "C/C++ Source": "C/C++ Kaynağı",
    "JavaScript / TS": "JavaScript / TS",
    "Python Source": "Python Kaynağı",
    "Game Archive": "Oyun Arşivi",
    "Resource Data": "Kaynak Verisi",
    "Bundle Data": "Bundle Verisi",
    "Video": "Video",
    "Image": "Görsel",
    "Audio": "Ses",
    "Archive": "Arşiv",
    "Disk Image": "Disk İmajı",
    "Installer Package": "Kurulum Paketi",
    "PDF Document": "PDF Belgesi",
    "Text Document": "Metin Belgesi",
    "Application": "Uygulama",

    "Apps": "Uygulamalar",
    "Images": "Görseller",
    "Archives": "Arşivler",
    "Docs": "Belgeler",
    "Code / Dev": "Kod / Geliştirme",
    "Cache": "Önbellek",
    "App Data": "Uygulama Verisi",
    "Game Data": "Oyun Verisi",
    "Config": "Ayarlar",
    "Logs": "Günlükler",
    "Temp": "Geçici",
    "Other": "Diğer",

    "Hierarchy view • folder headers select whole folders • right-click for actions": "Hiyerarşi görünümü • klasör başlıkları tüm klasörü seçer • işlemler için sağ tık",
    "Scanned": "Taranan",
    "Unscanned / Other Used": "Taranmayan / Diğer Kullanılan",
    "Free Space": "Boş Alan",
    "Disk capacity: mapped selection, used-but-unmapped space, and free space": "Disk kapasitesi: eşlenen alan, eşlenmeyen kullanılan alan ve boş alan",
    "Folder": "Klasör",
    "Grouped": "Gruplu",
    "Grouped items": "Gruplanmış öğeler",
    "Logical": "Mantıksal",
    "Type": "Tür",
    "files": "dosya",
    "items": "öğe",
    "Treemap": "Disk Haritası"
]

func mtL(_ key: String) -> String {
    let language = UserDefaults.standard.string(forKey: "mactree.language") ?? MTLanguageChoice.english.rawValue
    if language == MTLanguageChoice.turkish.rawValue {
        return mtTurkishStrings[key] ?? key
    }
    return key
}

@main
struct MacTreeApp: App {
    @AppStorage("mactree.language") private var language = MTLanguageChoice.english.rawValue
    @StateObject private var controller = MTFastController()

    var body: some Scene {
        WindowGroup {
            MainView(controller: controller)
                .frame(minWidth: 1220, minHeight: 720)
                .environment(\.locale, Locale(identifier: language == "tr" ? "tr_TR" : "en_US"))
        }
        .defaultSize(width: 1460, height: 880)

        Settings {
            MTSettingsView()
                .environment(\.locale, Locale(identifier: language == "tr" ? "tr_TR" : "en_US"))
        }
    }
}

struct MTSettingsView: View {
    @AppStorage("mactree.language") private var language = MTLanguageChoice.english.rawValue
    @AppStorage("mactree.appearance") private var appearance = MTAppearanceChoice.system.rawValue

    var body: some View {
        Form {
            Section(mtL("General")) {
                Picker(mtL("Language"), selection: $language) {
                    Text("English").tag(MTLanguageChoice.english.rawValue)
                    Text("Türkçe").tag(MTLanguageChoice.turkish.rawValue)
                }

                Picker(mtL("Appearance"), selection: $appearance) {
                    Label(mtL("System"), systemImage: "circle.lefthalf.filled").tag(MTAppearanceChoice.system.rawValue)
                    Label(mtL("Light"), systemImage: "sun.max.fill").tag(MTAppearanceChoice.light.rawValue)
                    Label(mtL("Dark"), systemImage: "moon.fill").tag(MTAppearanceChoice.dark.rawValue)
                }
            }

            Text(mtL("Changes are saved automatically."))
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 430, height: 220)
        .padding(8)
        .onAppear { mtApplyAppearance(appearance) }
        .onChange(of: appearance) { _, newValue in mtApplyAppearance(newValue) }
    }
}

struct MainView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("mactree.language") private var language = MTLanguageChoice.english.rawValue
    @AppStorage("mactree.appearance") private var appearance = MTAppearanceChoice.system.rawValue
    @ObservedObject var controller: MTFastController
    @State private var selectedID: Int?
    @State private var hoveredID: Int?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()

            VSplitView {
                HSplitView {
                    MTTreePane(
                        nodes: controller.nodes,
                        rootID: controller.rootID,
                        totalAllocated: controller.allocated,
                        scanVersion: controller.scanVersion,
                        searchModel: controller.search,
                        selectedID: $selectedID,
                        hoveredID: $hoveredID
                    )
                    .id("tree-\(language)-\(controller.scanVersion)")
                    .frame(minWidth: 520, idealWidth: 820, maxWidth: .infinity)
                    .clipped()

                    MTExtensionPane(
                        nodes: controller.nodes,
                        scanVersion: controller.scanVersion,
                        totalAllocated: controller.allocated
                    )
                    .id("extensions-\(language)-\(controller.scanVersion)")
                    .frame(minWidth: 360, idealWidth: 520, maxWidth: .infinity)
                    .clipped()
                }
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
                .id("treemap-\(language)-\(controller.scanVersion)")
                .frame(minHeight: 320)
            }

            Divider()
            status
        }
        .transaction { transaction in transaction.animation = nil }
        .environment(\.locale, Locale(identifier: language == "tr" ? "tr_TR" : "en_US"))
        .onAppear { mtApplyAppearance(appearance) }
        .onChange(of: appearance) { _, newValue in mtApplyAppearance(newValue) }
        .onChange(of: controller.scanVersion) { _, _ in
            selectedID = nil
            hoveredID = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
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
                Button(mtL("Macintosh HD — Whole Disk")) { controller.chooseDisk() }
                Button(mtL("Home Folder")) { controller.chooseHome() }
                Divider()
                Button(mtL("Choose Folder…")) { controller.chooseFolder() }
            } label: {
                Label(locationTitle, systemImage: "internaldrive")
                    .frame(minWidth: 190, alignment: .leading)
            }
            .menuStyle(.borderlessButton)

            if controller.isScanning {
                Button(mtL("Stop"), role: .destructive) { controller.stop() }
            } else {
                Button(mtL("Scan")) { controller.start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }

            Button { controller.openFullDiskAccess() } label: {
                Label(mtL("Full Disk Access"), systemImage: "lock.shield")
            }
            .foregroundStyle(Color.secondary)
            .help(mtL("Full Disk Access"))

            Spacer()

            preferencesMenu
            MTSearchField(model: controller.search)
            Label(controller.isScanning ? mtL("Scanning") : mtL("Ready"),
                  systemImage: controller.isScanning ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                .foregroundStyle(controller.isScanning ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var preferencesMenu: some View {
        Menu {
            Picker(mtL("Language"), selection: $language) {
                Text("English").tag(MTLanguageChoice.english.rawValue)
                Text("Türkçe").tag(MTLanguageChoice.turkish.rawValue)
            }

            Divider()

            Picker(mtL("Appearance"), selection: $appearance) {
                Label(mtL("System"), systemImage: "circle.lefthalf.filled").tag(MTAppearanceChoice.system.rawValue)
                Label(mtL("Light"), systemImage: "sun.max.fill").tag(MTAppearanceChoice.light.rawValue)
                Label(mtL("Dark"), systemImage: "moon.fill").tag(MTAppearanceChoice.dark.rawValue)
            }

            Divider()
            SettingsLink {
                Text(mtL("Settings") + "…")
            }
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .menuStyle(.borderlessButton)
        .help(mtL("Settings"))
    }

    private var summary: some View {
        let freePercent = controller.volumeTotal > 0
            ? Double(controller.volumeFree) / Double(controller.volumeTotal)
            : 0
        let used = controller.volumeTotal > controller.volumeFree
            ? controller.volumeTotal - controller.volumeFree
            : 0
        let mappedPercent = used > 0
            ? min(1, Double(controller.allocated) / Double(used))
            : 0
        let wholeDisk = controller.rootURL.path == "/"

        return HStack(spacing: 15) {
            metric(mtL("Disk"), mtBytes(controller.volumeTotal))

            HStack(spacing: 5) {
                Text(mtL("Free") + ":").foregroundStyle(Color.secondary)
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

            metric(mtL("Mapped"), mtBytes(controller.allocated))
            if wholeDisk && used > 0 {
                HStack(spacing: 4) {
                    Text(mtL("Coverage") + ":").foregroundStyle(Color.secondary)
                    Text(mappedPercent, format: .percent.precision(.fractionLength(0)))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
            metric(mtL("Files"), controller.files.formatted())
            metric(mtL("Items"), controller.items.formatted())

            Text(wholeDisk ? mtL("Whole Disk") : mtL("Folder scope"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(wholeDisk ? Color.blue : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((wholeDisk ? Color.blue : Color.secondary).opacity(0.10), in: Capsule())

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
                Text("\(mtL("Scanning")) \(controller.items.formatted()) \(mtL("items"))")
                    .fontWeight(.semibold)
                Text(controller.currentPath).foregroundStyle(Color.secondary).lineLimit(1)
            } else {
                Text("\(mtL("Scanned")) \(controller.files.formatted()) \(mtL("files")) • \(controller.elapsed.formatted(.number.precision(.fractionLength(1)))) s")
            }

            Spacer()

            let activeID = hoveredID ?? selectedID
            if let activeID, controller.nodes.indices.contains(activeID) {
                let node = controller.nodes[activeID]
                let resolvedPath = mtResolvedPath(activeID, nodes: controller.nodes)
                Text((hoveredID != nil ? mtL("Hover") : mtL("Selected")) + ": " + resolvedPath + "   " + mtBytes(node.allocatedSize))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var locationTitle: String {
        if controller.rootURL.path == "/" { return mtL("Macintosh HD — Whole Disk") }
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
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            if model.isSearching { ProgressView().controlSize(.mini) }
            TextField(mtL("Search files and folders"), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onChange(of: text) { _, value in
                    debounceTask?.cancel()
                    if value.isEmpty {
                        model.search("")
                    } else {
                        debounceTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            guard !Task.isCancelled else { return }
                            model.search(value)
                        }
                    }
                }
        }
        .onDisappear { debounceTask?.cancel() }
    }
}

extension UInt64 {
    func addingReportingOverflow(by other: UInt64) -> (partialValue: UInt64, overflow: Bool) {
        addingReportingOverflow(other)
    }
}