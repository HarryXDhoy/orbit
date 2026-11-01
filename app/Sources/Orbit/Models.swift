import AppKit
import Foundation
import Security

struct OrbitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    static let screenPermission = OrbitError("Orbit can’t see your screen yet. Turn Orbit on in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch Orbit.")
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case codex, claude, custom, ollama
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "ChatGPT"
        case .claude: return "Claude"
        case .custom: return "Custom API"
        case .ollama: return "Local model"
        }
    }
    var subtitle: String {
        switch self {
        case .codex: return "Your Codex login"
        case .claude: return "Your Claude Code login"
        case .custom: return "OpenAI-compatible endpoint"
        case .ollama: return "Ollama on your Mac"
        }
    }
    var symbol: String {
        switch self {
        case .codex: return "sparkle"
        case .claude: return "sun.max"
        case .custom: return "network"
        case .ollama: return "desktopcomputer"
        }
    }
}

struct ConnectionSettings: Codable {
    var provider: ProviderKind = .codex
    var codexPath = ExecutableLocator.find("codex") ?? ""
    var claudePath = ExecutableLocator.find("claude") ?? ""
    var codexModel = ""
    var claudeModel = ""
    var customBaseURL = "https://api.openai.com/v1"
    var customModel = ""
    var ollamaBaseURL = "http://localhost:11434"
    var ollamaModel = ""
    var speakResponses = false
    var showCompanion = true
    // Optional so settings saved by older builds still decode.
    var autoScreen: Bool?
    var pushToTalk: Bool?
    var seesScreen: Bool { get { autoScreen ?? true } set { autoScreen = newValue } }
    var talkHotkey: Bool { get { pushToTalk ?? true } set { pushToTalk = newValue } }
    var talkKeys: Shortcut?
    var clearKeys: Shortcut?
    var openKeys: Shortcut?
    var typeKeys: Shortcut?
    var drawingSeconds: Double?
    var talkShortcut: Shortcut { get { talkKeys ?? .talkDefault } set { talkKeys = newValue } }
    var clearShortcut: Shortcut { get { clearKeys ?? .clearDefault } set { clearKeys = newValue } }
    var openShortcut: Shortcut { get { openKeys ?? .openDefault } set { openKeys = newValue } }
    var typeShortcut: Shortcut { get { typeKeys ?? .typeDefault } set { typeKeys = newValue } }
    var dictationLanguages: [String]?
    var dictationLanguage: String?
    var languages: [String] { get { dictationLanguages?.isEmpty == false ? dictationLanguages! : [Dictation.systemDefault] } set { dictationLanguages = newValue } }
    /// A chosen language, or `Dictation.auto` to tell your languages apart as you talk (needs at least two).
    var language: String {
        get {
            if dictationLanguage == Dictation.auto, languages.count > 1 { return Dictation.auto }
            return dictationLanguage.flatMap { languages.contains($0) ? $0 : nil } ?? languages[0]
        }
        set { dictationLanguage = newValue }
    }
    /// The languages dictation listens in right now.
    var listening: [String] { language == Dictation.auto ? Array(languages.prefix(Dictation.autoLimit)) : [language] }
    /// Connectors Orbit may use, per provider.
    var connectorChoices: [ConnectorChoice]?
    var connectors: [ConnectorChoice] { get { connectorChoices ?? [] } set { connectorChoices = newValue } }
    /// How long drawings stay on screen; 0 keeps them until cleared.
    var keepDrawings: Double { get { drawingSeconds ?? 30 } set { drawingSeconds = newValue } }
}

struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    let role: String
    let text: String
    var date = Date()
    var hadImage = false
    var provider: String? = nil
}

struct Conversation: Codable, Identifiable {
    var id = UUID()
    var title: String
    var updated = Date()
    var messages: [ChatMessage] = []
    static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }
}

struct ScreenAttachment {
    let data: Data
    let frame: CGRect
    let image: NSImage
    /// Part of a screen the user picked, rather than the whole screen.
    var isArea = false
}

enum ExecutableLocator {
    static var directories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvm = URL(fileURLWithPath: home + "/.nvm/versions/node")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .filter { $0.hasPrefix("v") && !$0.contains("alpha") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent($0 + "/bin").path }
        return [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + versions + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }
    static func find(_ name: String) -> String? {
        directories.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum LocalStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orbit", isDirectory: true)
    }
    static func read<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum APIKeyStore {
    private static let service = "local.orbit.companion.api"
    // Bind keys to the exact configured endpoint so switching hosts cannot reuse a key silently.
    private static func query(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: endpoint]
    }
    static func read(endpoint: String) -> String {
        var request = query(endpoint)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, endpoint: String) throws {
        let request = query(endpoint)
        if value.isEmpty {
            let status = SecItemDelete(request as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw OrbitError("Could not remove the API key from Keychain (\(status)).") }
            return
        }
        let updates = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(request as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = request
            item.merge(updates) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw OrbitError("Could not save the API key in Keychain (\(status)).") }
    }
}
