import Foundation
import Observation

/// Assistant › Cloud API: the AI services a user can bring their own key for.
/// Every one but Anthropic speaks the OpenAI-style chat API, so "Other" covers
/// any service (or company gateway) with that API at its own address.
enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case anthropic, gemini, mistral, openai, openrouter, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .mistral: "Mistral"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .custom: "Other (OpenAI-compatible)"
        }
    }

    /// The name in sentences ("Your question goes to OpenAI").
    var shortName: String { self == .custom ? "your service" : self == .gemini ? "Google" : name }

    enum API: Sendable { case openAI, anthropic }
    var api: API { self == .anthropic ? .anthropic : .openAI }

    /// Where its API lives; "Other" uses the address the user types.
    var base: String? {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .mistral: "https://api.mistral.ai/v1"
        case .openai: "https://api.openai.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .custom: nil
        }
    }

    var keysPage: URL? {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: URL(string: "https://aistudio.google.com/app/apikey")
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
        case .custom: nil
        }
    }

    var billingPage: URL? {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/billing")
        case .gemini: URL(string: "https://aistudio.google.com/app/apikey")
        case .mistral: URL(string: "https://console.mistral.ai/billing")
        case .openai: URL(string: "https://platform.openai.com/settings/organization/billing")
        case .openrouter: URL(string: "https://openrouter.ai/settings/credits")
        case .custom: nil
        }
    }

    var privacyPage: URL? {
        switch self {
        case .anthropic: URL(string: "https://www.anthropic.com/legal/privacy")
        case .gemini: URL(string: "https://policies.google.com/privacy")
        case .mistral: URL(string: "https://mistral.ai/terms#privacy-policy")
        case .openai: URL(string: "https://openai.com/policies/privacy-policy")
        case .openrouter: URL(string: "https://openrouter.ai/privacy")
        case .custom: nil
        }
    }
}

/// One saved key: the user's own name for it ("Client X project"), an
/// optional group ("Work"), the service, and the model it answers with. The
/// key itself is in the Keychain, never in this record.
struct CloudKey: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var group: String? = nil
    var provider: AIProvider
    /// "Other" only: the service's API address (…/v1).
    var customBase: String? = nil
    var model: String = ""
    /// The models the key could use when it was last checked.
    var models: [String] = []

    var base: String { (provider.base ?? customBase ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
    /// The account name in the Keychain.
    var secretAccount: String { "cloud-key-\(id.uuidString)" }
    var title: String { name.isEmpty ? provider.name : name }
}

/// Where key secrets live: the Keychain in the app, memory in tests.
protocol SecretStore: AnyObject {
    func get(_ account: String) -> String?
    func set(_ value: String, _ account: String)
    func remove(_ account: String)
}

final class KeychainSecrets: SecretStore {
    func get(_ account: String) -> String? { Keychain.get(account: account) }
    func set(_ value: String, _ account: String) { Keychain.set(value, account: account) }
    func remove(_ account: String) { Keychain.remove(account: account) }
}

/// The saved keys (any number, any providers), grouped, and the one in use.
@MainActor @Observable
final class CloudKeyStore {
    static let shared = CloudKeyStore()

    private(set) var keys: [CloudKey] = []
    var activeID: UUID? {
        didSet { defaults.set(activeID?.uuidString, forKey: "cloudKeyActive") }
    }
    var active: CloudKey? { keys.first { $0.id == activeID } ?? keys.first }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: SecretStore

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecrets()) {
        self.defaults = defaults
        self.secrets = secrets
        if let d = defaults.data(forKey: "cloudKeys"), let k = try? JSONDecoder().decode([CloudKey].self, from: d) { keys = k }
        activeID = defaults.string(forKey: "cloudKeyActive").flatMap(UUID.init)
        migrateOldKey()
    }

    /// The single Anthropic key from before keys were named: kept, as a key called "Anthropic".
    private func migrateOldKey() {
        let old = "anthropic-api-key"
        guard let secret = secrets.get(old) else { return }
        let model = defaults.string(forKey: "assistantCloudModel") ?? ""
        let k = CloudKey(name: "Anthropic", provider: .anthropic, model: model)
        secrets.set(secret, k.secretAccount)
        secrets.remove(old)
        keys.append(k)
        if activeID == nil { activeID = k.id }
        save()
    }

    /// Group names in use, A–Z.
    var groups: [String] { Array(Set(keys.compactMap(\.group))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }

    /// Keys under their group ("" first: keys with no group), each A–Z. Pure (given the keys): tested.
    var grouped: [(group: String, keys: [CloudKey])] {
        let byGroup = Dictionary(grouping: keys) { $0.group ?? "" }
        return byGroup.keys.sorted { a, b in a.isEmpty != b.isEmpty ? a.isEmpty : a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
            .map { g in (g, byGroup[g]!.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) }
    }

    func secret(for k: CloudKey) -> String? {
        // Test switch: APEX_ASSISTANT_KEY supplies a key without the Keychain.
        TestSwitch.value("APEX_ASSISTANT_KEY") ?? secrets.get(k.secretAccount)
    }

    /// Adds or updates a key. `secret` nil keeps the one already saved.
    func save(_ k: CloudKey, secret: String?) {
        var k = k
        k.name = k.name.trimmingCharacters(in: .whitespacesAndNewlines)
        k.group = k.group?.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.group?.isEmpty == true { k.group = nil }
        if let secret { secrets.set(secret, k.secretAccount) }
        if let i = keys.firstIndex(where: { $0.id == k.id }) { keys[i] = k } else { keys.append(k) }
        if activeID == nil || keys.count == 1 { activeID = k.id }
        save()
    }

    func setModel(_ model: String, for id: UUID) {
        guard let i = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[i].model = model
        save()
    }

    func remove(_ id: UUID) {
        guard let k = keys.first(where: { $0.id == id }) else { return }
        secrets.remove(k.secretAccount)
        keys.removeAll { $0.id == id }
        if activeID == id { activeID = keys.first?.id }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(keys) { defaults.set(d, forKey: "cloudKeys") }
    }
}

/// The OpenAI-style chat API, used by every provider but Anthropic, by Lumen
/// AI and by local models.
enum OpenAIChat {
    /// `/models` with the key: checks it (nothing spent) and lists what it can use.
    static func models(base: String, key: String?, timeout: TimeInterval = 15) async throws -> [String] {
        guard let url = URL(string: base + "/models") else { throw CloudError.message("That address doesn’t look right.") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw CloudError.status(code, data) }
        return chatModels(LocalChat.parseModels(data))
    }

    /// Only models that chat: no embedding, speech, image or moderation models. Pure: tested.
    static func chatModels(_ ids: [String]) -> [String] {
        let skip = ["embed", "tts", "whisper", "dall-e", "moderation", "transcribe", "audio", "image", "realtime", "rerank"]
        return ids.filter { id in !skip.contains { id.lowercased().contains($0) } }
    }

    /// The request body: instructions and readings as the system message, then the chat. Pure: tested.
    static func body(model: String, history: [Assistant.Message], readings: String?) -> [String: Any] {
        var system = Assistant.instructions
        if let readings { system += "\n\nLive readings from this Mac right now:\n" + readings }
        var msgs: [[String: String]] = [["role": "system", "content": system]]
        msgs += history.suffix(20).map { ["role": $0.role.rawValue, "content": $0.text] }
        return ["model": model, "messages": msgs, "stream": true]
    }

    /// Streams the reply, calling `onText` with each piece.
    static func ask(base: String, key: String?, model: String, history: [Assistant.Message], readings: String?,
                    extra: [String: Any] = [:], timeout: TimeInterval = 300,
                    onText: @escaping @Sendable (String) -> Void) async throws {
        guard let url = URL(string: base + "/chat/completions") else { throw CloudError.message("That address doesn’t look right.") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body(model: model, history: history, readings: readings).merging(extra) { $1 })
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
            throw CloudError.status(code, data)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let piece = LocalChat.parseStreamLine(line) { onText(piece) }
        }
    }
}

enum CloudError: Error {
    case status(Int, Data)
    case message(String)

    /// Plain words, naming the service. Pure: tested.
    func text(_ service: String) -> String {
        switch self {
        case .message(let m): return m
        case .status(let code, let data):
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"]
            let detail = (err as? [String: Any])?["message"] as? String ?? err as? String
            switch code {
            case 401, 403: return "\(service) didn’t accept this API key. Check it under Manage Keys."
            case 402: return "The \(service) account needs credit. Add some on its billing page."
            case 404: return "\(service) doesn’t know that model or address. Pick another model under Manage Keys."
            case 429: return "Too many questions at once for this account. Wait a moment and ask again."
            case 500...599: return "\(service) is busy right now. Ask again in a moment."
            default: return detail.map { "\(service): \($0)" } ?? "\(service) answered \(code)."
            }
        }
    }
}
