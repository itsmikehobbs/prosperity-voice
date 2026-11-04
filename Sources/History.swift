import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    /// "dictation" or "polish"
    var kind: String
    /// What was heard (dictation) or the original selection (polish).
    var original: String
    /// What was pasted / returned.
    var text: String
    var engine: String
    var app: String?
    var seconds: Double?
    var pasted: Bool = false
}

/// Saved dictations and polishes, newest first, in one JSON file.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    let url: URL

    init(url: URL = Paths.history) {
        self.url = url
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else { entries = []; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = list
        } else {
            // Keep a damaged file aside instead of overwriting it.
            let backup = url.deletingPathExtension().appendingPathExtension("damaged-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            entries = []
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    func update(_ id: UUID, _ change: (inout HistoryEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
