import Foundation
import Observation

/// Lumen AI: Apex's own cloud AI, run by CyberNet Labs. Two ways in: a
/// monthly plan with CyberNet Labs, or API access bought from CyberNet Labs.
/// Either way the account gives a Lumen key, kept in the Keychain; questions
/// go to the Lumen API (OpenAI-style chat: `/models`, `/chat/completions`).
enum Lumen {
    // CyberNet Labs' addresses, in one place. Until the service is live these
    // stay nil: the Lumen screen then says it's opening soon and its buttons
    // wait. `APEX_LUMEN_BASE` points at a stand-in server for testing.
    static let liveBase: String? = nil
    static let plansPage: URL? = nil
    static let apiPage: URL? = nil
    static let accountPage: URL? = nil

    static var base: String? { TestSwitch.value("APEX_LUMEN_BASE") ?? liveBase }
    static var isLive: Bool { base != nil }

    /// How the user pays CyberNet Labs.
    enum Access: String, CaseIterable, Identifiable, Codable, Sendable {
        case plan, api
        var id: String { rawValue }
        var title: String { self == .plan ? "Monthly Plan" : "API Access" }
        var symbol: String { self == .plan ? "calendar" : "key.fill" }
        var detail: String {
            self == .plan ? "One monthly price from CyberNet Labs. Ask as much as your plan allows."
                          : "Buy API credit from CyberNet Labs and pay only for what you ask."
        }
        var page: URL? { self == .plan ? Lumen.plansPage : Lumen.apiPage }
    }

    /// The model Lumen answers with (the service picks its best one).
    static let model = "lumen"
}

/// The Lumen key and how it was bought.
@MainActor @Observable
final class LumenAccount {
    static let shared = LumenAccount()
    private static let account = "lumen-api-key"

    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var hasKey: Bool
    var access: Lumen.Access? {
        didSet { defaults.set(access?.rawValue, forKey: "lumenAccess") }
    }

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainSecrets()) {
        self.defaults = defaults
        self.secrets = secrets
        hasKey = TestSwitch.value("APEX_LUMEN_KEY") != nil || secrets.get(Self.account) != nil
        access = defaults.string(forKey: "lumenAccess").flatMap(Lumen.Access.init)
    }

    var key: String? { TestSwitch.value("APEX_LUMEN_KEY") ?? secrets.get(Self.account) }

    /// Checks the key with the Lumen service, then keeps it. Returns a problem, or nil.
    func connect(key: String, access: Lumen.Access, check: Bool = true) async -> String? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return "Paste your Lumen key first." }
        guard let base = Lumen.base else { return "Lumen AI isn’t open yet. CyberNet Labs will open it soon." }
        if check {
            do { _ = try await OpenAIChat.models(base: base, key: k) }
            catch let e as CloudError { return e.text("Lumen AI") }
            catch { return "Couldn’t reach Lumen AI. Check the internet connection." }
        }
        secrets.set(k, Self.account)
        self.access = access
        hasKey = true
        return nil
    }

    func signOut() {
        secrets.remove(Self.account)
        hasKey = false
        access = nil
    }
}
