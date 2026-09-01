import SwiftUI
import AppKit

// The toolbar menu currently sends the Cocoa action `showSettingsWindow:`.
// SwiftUI's Settings scene does not always expose that selector to a custom
// toolbar action, so MacTree provides a small native bridge. This keeps the
// toolbar button reliable while the standard Settings scene remains available.
@MainActor
private final class MTOptionsWindowController {
    static let shared = MTOptionsWindowController()
    private var windowController: NSWindowController?

    func show() {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: MTOptionsWindowView())
        let window = NSWindow(contentViewController: hosting)
        window.title = mtL("Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 480, height: 390))
        window.minSize = NSSize(width: 440, height: 350)
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// Existing toolbar action in App.swift uses this selector with a nil target.
// NSApplication is the end of the responder chain, so it becomes the target.
extension NSApplication {
    @objc func showSettingsWindow(_ sender: Any?) {
        MTOptionsWindowController.shared.show()
    }
}

private struct MTOptionsWindowView: View {
    @AppStorage("mactree.language") private var language = MTLanguageChoice.english.rawValue
    @AppStorage("mactree.appearance") private var appearance = MTAppearanceChoice.system.rawValue

    private var isTurkish: Bool { language == MTLanguageChoice.turkish.rawValue }

    var body: some View {
        Form {
            Section(label("General", "Genel")) {
                Picker(label("Language", "Dil"), selection: $language) {
                    Text("English").tag(MTLanguageChoice.english.rawValue)
                    Text("Türkçe").tag(MTLanguageChoice.turkish.rawValue)
                }

                Picker(label("Appearance", "Görünüm"), selection: $appearance) {
                    Label(label("System", "Sistem"), systemImage: "circle.lefthalf.filled")
                        .tag(MTAppearanceChoice.system.rawValue)
                    Label(label("Light", "Açık"), systemImage: "sun.max.fill")
                        .tag(MTAppearanceChoice.light.rawValue)
                    Label(label("Dark", "Koyu"), systemImage: "moon.fill")
                        .tag(MTAppearanceChoice.dark.rawValue)
                }
            }

            Section(label("Access", "Erişim")) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(label("Full Disk Access", "Tam Disk Erişimi"))
                        Text(label(
                            "Allows MacTree to read protected locations that macOS permits.",
                            "MacTree'nin macOS'un izin verdiği korumalı konumları okuyabilmesini sağlar."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(label("Open Settings…", "Ayarları Aç…")) {
                        openFullDiskAccessSettings()
                    }
                }
            }

            Section(label("About", "Hakkında")) {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacTree")
                            .font(.headline)
                        Text(label("macOS disk space analyzer — Beta", "macOS disk alanı analiz aracı — Beta"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(versionText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text(label(
                "Settings are saved automatically.",
                "Ayarlar otomatik olarak kaydedilir."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(10)
        .onAppear { mtApplyAppearance(appearance) }
        .onChange(of: appearance) { _, value in mtApplyAppearance(value) }
    }

    private func label(_ english: String, _ turkish: String) -> String {
        isTurkish ? turkish : english
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Beta"
        let build = info?["CFBundleVersion"] as? String
        if let build, !build.isEmpty, build != version {
            return "v\(version) (\(build))"
        }
        return "v\(version)"
    }

    private func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
