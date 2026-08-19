import Foundation

struct SavedState: Codable {
    var peripheralID: UUID?
    var serialHex: String?
    var name: String?
    var brightness: Int = 100
    var isOn: Bool = false
}

enum StateStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/YCOnion", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("state.json") }

    static func load() -> SavedState {
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else {
            return SavedState()
        }
        return state
    }

    static func save(_ state: SavedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(state)
        try data.write(to: file, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
