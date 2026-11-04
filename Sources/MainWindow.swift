import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// Small observable holder used instead of @State (the @State macro plugin ships only with full Xcode).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

struct MainView: View {
    @ObservedObject var history: HistoryStore
    let controller: Controller
    @StateObject private var tab: Box<Int>

    init(history: HistoryStore, controller: Controller, tab: Int) {
        self.history = history
        self.controller = controller
        _tab = StateObject(wrappedValue: Box(tab))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab.value) {
                Text("History").tag(0)
                Text("Settings").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.vertical, 12)
            Divider()
            if tab.value == 0 {
                HistoryView(history: history)
            } else {
                SettingsView(controller: controller)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}

// MARK: History

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @AppStorage(Settings.Key.keepHistory) private var keepHistory = true
    @StateObject private var search = Box("")
    @StateObject private var confirmClear = Box(false)

    private var filtered: [HistoryEntry] {
        let q = search.value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.lowercased().contains(q) || $0.original.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search", text: $search.value).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Toggle("Save history", isOn: $keepHistory).toggleStyle(.switch).controlSize(.small)
                Button("Clear all", role: .destructive) { confirmClear.value = true }
                    .disabled(history.entries.isEmpty)
            }
            .padding(12)
            if filtered.isEmpty {
                Spacer()
                Text(history.entries.isEmpty ? "Nothing yet. Hold Fn and start talking." : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { entry in
                    HistoryRow(entry: entry, onDelete: { history.delete(entry.id) })
                }
                .listStyle(.inset)
            }
        }
        .alert("Clear all history?", isPresented: $confirmClear.value) {
            Button("Clear all", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every saved dictation and polish. It can't be undone.")
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @StateObject private var showOriginal = Box(false)
    @StateObject private var copied = Box(false)

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.dateFormat.string(from: entry.date))
                if entry.kind == "polish" { tag("Polish") }
                if let app = entry.app { Text("· \(app)") }
                tag(entry.engine == "raw" ? "Raw" : entry.engine.capitalized)
                Spacer()
                Button(copied.value ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    copied.value = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied.value = false }
                }
                .controlSize(.small)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .controlSize(.small)
                    .help("Delete")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(entry.text).textSelection(.enabled)
            if entry.original != entry.text {
                Button {
                    showOriginal.value.toggle()
                } label: {
                    Label(entry.kind == "polish" ? "Original text" : "What you actually said",
                          systemImage: showOriginal.value ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.link)
                .font(.caption)
                if showOriginal.value {
                    Text(entry.original).textSelection(.enabled).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func tag(_ s: String) -> some View {
        Text(s).padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
    }
}

// MARK: Settings

struct SettingsView: View {
    let controller: Controller
    @AppStorage(Settings.Key.cleanupEngine) private var cleanup = CleanupEngine.apple.rawValue
    @AppStorage(Settings.Key.polishEngine) private var polish = PolishEngine.apple.rawValue
    @AppStorage(Settings.Key.customWords) private var customWords = Settings.defaultWords
    @AppStorage(Settings.Key.playSounds) private var playSounds = true
    @AppStorage(Settings.Key.muteWhileRecording) private var muteWhileRecording = true
    @StateObject private var launchAtLogin = Box(SMAppService.mainApp.status == .enabled)
    @StateObject private var refresh = Box(0)
    @StateObject private var claudeTest = Box<String?>(nil)
    @StateObject private var helperFound = Box<Bool?>(nil)

    var body: some View {
        Form {
            Section("How to use") {
                Text("Hold **Fn** and talk. Let go to paste.\nHands-free: hold **Fn**, tap **Space**, let go of both. Tap **Fn** to finish.\n**Esc** cancels. Nothing selected? The text goes to your clipboard.\nPolish: highlight text anywhere, right-click, **Services → Polish with Prosperity Voice**.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Cleanup") {
                Picker("Clean up dictation with", selection: $cleanup) {
                    ForEach(CleanupEngine.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Polish selected text with", selection: $polish) {
                    ForEach(PolishEngine.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Claude, ChatGPT, and Grok run on your own subscriptions through their command-line tools, in a locked-down empty folder. If one fails, the app falls back to Apple.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Test cleanup AI") {
                        let provider = CleanupEngine(rawValue: cleanup)?.provider ?? .apple
                        claudeTest.value = "Testing \(provider.name)…"
                        Task {
                            let start = Date()
                            do {
                                let out = try await Cleaner.run("so um this is uh a test of the the cleanup", mode: .dictation,
                                                                provider: provider, words: [])
                                claudeTest.value = String(format: "\(provider.name) works (%.1fs): \(out)", Date().timeIntervalSince(start))
                            } catch {
                                claudeTest.value = error.localizedDescription
                            }
                        }
                    }
                    if let text = claudeTest.value { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            Section {
                TextEditor(text: $customWords)
                    .font(.body)
                    .frame(height: 70)
            } header: {
                Text("Words to spell right")
            } footer: {
                Text("Names, brands, and jargon, one per line or separated by commas. To always fix something it mishears, add a line like: Clawed => Claude")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Play start and stop sounds", isOn: $playSounds)
                Toggle("Mute other sound while recording", isOn: $muteWhileRecording)
                Toggle("Open at login", isOn: $launchAtLogin.value)
                    .onChange(of: launchAtLogin.value) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin.value = SMAppService.mainApp.status == .enabled
                    }
                Button("Retry last recording") { controller.retryLast() }
            }
            Section("Permissions and status") {
                status("Microphone", ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                       fix: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { refresh.value += 1 } }
                }
                status("Accessibility (Fn key + auto-paste)", ok: Inserter.hasAccessibility,
                       fix: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(opts)
                }
                status("Fn key set to \"Do Nothing\"", ok: fnKeyFree,
                       fix: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension", ask: nil)
                LabeledContent("Apple Intelligence (on-device backup)", value: Cleaner.appleStatus)
                LabeledContent("Apple Private Cloud helper shortcut", value: helperFound.value.map { $0 ? "Installed" : "Missing (using on-device)" } ?? "Checking…")
                    .task { helperFound.value = await Cleaner.helperInstalled() }
                LabeledContent("Claude (claude tool)", value: Cleaner.isAvailable(.claude) ? "Found" : "Not found")
                LabeledContent("ChatGPT (codex tool)", value: Cleaner.isAvailable(.chatgpt) ? "Found" : "Not found")
                LabeledContent("Grok (grok tool)", value: Cleaner.isAvailable(.grok) ? "Found" : "Not found")
                Button("Refresh") { refresh.value += 1 }
            }
            .id(refresh.value)
        }
        .formStyle(.grouped)
    }

    private var fnKeyFree: Bool {
        (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int ?? 0) == 0
    }

    private func status(_ name: String, ok: Bool, fix: String, ask: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(name)
            Spacer()
            if !ok {
                if let ask { Button("Ask") { ask() } }
                Button("Open Settings") { NSWorkspace.shared.open(URL(string: fix)!) }
            }
        }
    }
}
