import DetectionCore
import Foundation
import Observation

/// The Apex assistant, answering questions about this Mac. Each question can
/// carry Apex's live readings. Who answers is the user's choice: Apex Agent,
/// a local model, Lumen AI (CyberNet Labs) or any cloud AI service with the
/// user's own key (`AIProvider`); keys stay in the Keychain.
enum Assistant {
    /// Who answers: Apex Agent (built in, on this Mac), Local AI (a model
    /// running on this Mac), Lumen AI (Apex's own cloud AI, by CyberNet Labs),
    /// or Cloud API (any provider, with the user's own named keys).
    enum Mode: String, CaseIterable, Identifiable {
        case agent, local, lumen, cloud
        var id: String { rawValue }
        var title: String {
            switch self { case .agent: "Apex Agent"; case .local: "Local AI"; case .lumen: "Lumen AI"; case .cloud: "Cloud API" }
        }
        var symbol: String {
            switch self { case .agent: "cpu"; case .local: "desktopcomputer"; case .lumen: "sparkles"; case .cloud: "key.fill" }
        }
        var detail: String {
            switch self {
            case .agent: "Instant answers to common questions, worked out on this Mac. Nothing is sent anywhere."
            case .local: "A model running on this Mac, through LM Studio or Ollama. Nothing leaves the Mac."
            case .lumen: Lumen.isLive ? "Apex’s own cloud AI, by CyberNet Labs: a monthly plan or API access."
                                      : "Apex’s own cloud AI, by CyberNet Labs. Opening soon."
            case .cloud: "Any AI service with your own API key: OpenAI, Anthropic, Google, Mistral, OpenRouter or another."
            }
        }
    }

    struct Message: Identifiable, Equatable {
        enum Role: String { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        /// Apex Agent: buttons under the answer, and whether it suggests Lumen AI.
        var actions: [ApexAgent.Action] = []
        var suggestLumen = false
        /// Short summary of the model's thinking, shown while it works.
        var thinking = ""
        /// What was actually sent (user: question + readings) or received
        /// (assistant: every content block, thinking included), replayed
        /// unchanged on later turns.
        var content: [[String: Any]] = []
        static func == (a: Message, b: Message) -> Bool { a.id == b.id && a.text == b.text && a.thinking == b.thinking }
    }

    static let version = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// What the assistant is for, and how it should answer. Kept byte-stable so it caches.
    static let instructions = """
    You are the assistant inside Apex Activity Manager, a Mac system utility. Help with this Mac: \
    performance, memory, storage, battery and energy, network and Wi-Fi, displays, apps and processes, \
    startup items, servers, and fixing problems with them. When the question comes with live readings, use \
    them and say which reading an answer rests on. Explain in plain words for someone who isn't technical, \
    keep answers short, give steps in order, and suggest the Apex page or button that helps (for example \
    Free Up Memory, Disk › Clean, Drive Doctor, Network Doctor, Shell). Never suggest deleting system files \
    or running commands that could lose data without a clear warning. Use Markdown sparingly: short \
    paragraphs, numbered steps, **bold** for the thing to click.
    """

    /// A user turn: the question, with this Mac's readings first when the user allows it.
    static func userContent(_ question: String, readings: String?) -> [[String: Any]] {
        guard let readings, !readings.isEmpty else { return [["type": "text", "text": question]] }
        return [["type": "text", "text": "Live readings from this Mac right now:\n" + readings],
                ["type": "text", "text": question]]
    }

    // MARK: Anthropic's Messages API (the one provider without the OpenAI-style API)

    /// Server-side fallback is offered for the bigger Claude models only.
    static func usesFallback(_ model: String) -> Bool { model.hasPrefix("claude-") && !model.contains("haiku") }

    /// The Messages request body. Pure: tested.
    static func body(model: String, history: [Message]) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "system": instructions,
            "cache_control": ["type": "ephemeral"],
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": "medium"],
            "messages": history.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if usesFallback(model) { b["fallbacks"] = "default" }
        return b
    }

    static func request(base: String, key: String, model: String, history: [Message]) throws -> URLRequest {
        guard let url = URL(string: base + "/messages") else { throw CloudError.message("That address doesn’t look right.") }
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(version, forHTTPHeaderField: "anthropic-version")
        if usesFallback(model) { req.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body(model: model, history: history))
        return req
    }

    /// Checks a key without spending anything, and lists the models it can use.
    static func models(base: String, key: String) async throws -> [String] {
        guard let url = URL(string: base + "/models?limit=100") else { throw CloudError.message("That address doesn’t look right.") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(version, forHTTPHeaderField: "anthropic-version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw NSError(domain: "Apex", code: code, userInfo: [NSLocalizedDescriptionKey: problem(status: code, body: data)]) }
        // Newest first, as the service lists them.
        let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return list.compactMap { $0["id"] as? String }
    }

    /// Checks any provider's key and lists its chat models. Pure apart from the network.
    static func models(for k: CloudKey, secret: String) async throws -> [String] {
        let base = TestSwitch.value("APEX_ASSISTANT_BASE") ?? k.base
        switch k.provider.api {
        case .anthropic: return try await models(base: base, key: secret)
        case .openAI: return try await OpenAIChat.models(base: base, key: secret)
        }
    }

    /// Builds the reply from the stream's events, in order.
    struct Reply {
        var blocks: [[String: Any]] = []
        var stop: String?
        var error: String?

        var text: String { blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined() }
        var thinking: String { blocks.filter { $0["type"] as? String == "thinking" }.compactMap { $0["thinking"] as? String }.joined(separator: "\n") }

        /// One `data:` line. Returns true when the reply changed. Pure: tested.
        mutating func feed(_ line: String) -> Bool {
            guard line.hasPrefix("data:"), let d = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let e = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
            switch e["type"] as? String {
            case "content_block_start":
                guard let i = e["index"] as? Int, var b = e["content_block"] as? [String: Any] else { return false }
                // A new start at an index already used means the server restarted
                // the turn on the fallback model: keep the later blocks.
                if i < blocks.count { blocks.removeSubrange(i...) }
                while blocks.count < i { blocks.append([:]) }
                if b["type"] as? String == "text" { b.removeValue(forKey: "citations") }
                blocks.append(b)
            case "content_block_delta":
                guard let i = e["index"] as? Int, i < blocks.count, let delta = e["delta"] as? [String: Any] else { return false }
                switch delta["type"] as? String {
                case "text_delta": blocks[i]["text"] = (blocks[i]["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                case "thinking_delta": blocks[i]["thinking"] = (blocks[i]["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta": blocks[i]["signature"] = (blocks[i]["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                default: return false
                }
            case "message_delta":
                stop = (e["delta"] as? [String: Any])?["stop_reason"] as? String ?? stop
            case "error":
                let err = e["error"] as? [String: Any]
                error = Assistant.problem(type: err?["type"] as? String, message: err?["message"] as? String)
            default:
                return false
            }
            return true
        }

        /// Empty placeholders (from gaps) aren't valid blocks to send back.
        var sendable: [[String: Any]] { blocks.filter { !$0.isEmpty } }
    }

    /// Streams one reply, calling `update` as it grows.
    static func ask(base: String, key: String, model: String, history: [Message],
                    update: @escaping @MainActor (Reply) -> Void) async throws -> Reply {
        let (bytes, resp) = try await URLSession.shared.bytes(for: request(base: base, key: key, model: model, history: history))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
            throw NSError(domain: "Apex", code: code, userInfo: [NSLocalizedDescriptionKey: problem(status: code, body: data)])
        }
        var reply = Reply()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if reply.feed(line) { let r = reply; await update(r) }
        }
        return reply
    }

    /// An HTTP error → plain words. Pure: tested.
    static func problem(status: Int, body: Data) -> String {
        let err = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let type = err?["type"] as? String ?? (status == 401 ? "authentication_error" : status == 429 ? "rate_limit_error" : nil)
        return problem(type: type, message: err?["message"] as? String ?? "Anthropic answered \(status).")
    }

    static func problem(type: String?, message: String?) -> String {
        switch type {
        case "authentication_error": return "Anthropic didn’t accept this API key. Check it in the assistant’s settings."
        case "permission_error": return "This API key isn’t allowed to use that model."
        case "billing_error": return "The Anthropic account needs credit. Add some at console.anthropic.com › Billing."
        case "rate_limit_error": return "Too many questions at once for this account. Wait a moment and ask again."
        case "overloaded_error": return "Anthropic is busy right now. Ask again in a moment."
        case "request_too_large": return "This chat is too long. Start a new chat."
        default: return message ?? "Something went wrong. Ask again."
        }
    }

    /// The reason a reply stopped, when it isn't a normal finish. Pure: tested.
    static func stopNote(_ stop: String?) -> String? {
        switch stop {
        case "refusal": "The model can’t help with that one. Try asking another way."
        case "max_tokens": "The answer was cut short. Ask it to continue."
        default: nil
        }
    }
}

/// The conversation, shared by the Assistant page and the Assistant window.
@MainActor @Observable
final class AssistantChat {
    static let shared = AssistantChat()
    /// Cloud API: the user's named keys, any providers.
    let keys = CloudKeyStore.shared
    /// Lumen AI: the CyberNet Labs account.
    let lumen = LumenAccount.shared

    /// Each mode keeps its own conversation.
    var threads: [Assistant.Mode: [Assistant.Message]] = [:]
    var mode: Assistant.Mode = Assistant.Mode(rawValue: UserDefaults.standard.string(forKey: "assistantMode") ?? "") ?? .agent {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "assistantMode"); problem = nil }
    }
    var messages: [Assistant.Message] {
        get { threads[mode] ?? [] }
        set { threads[mode] = newValue }
    }
    var answering: Task<Void, Never>?
    var problem: String?
    var hasKey: Bool { keys.active != nil }

    /// Checks a key with its service (nothing spent), fills in its models and
    /// saves it. `secret` nil: keep the saved one. Returns a problem, or nil.
    func save(_ k: CloudKey, secret: String?) async -> String? {
        var k = k
        let typed = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = (typed?.isEmpty == false ? typed : nil) ?? keys.secret(for: k) else { return "Paste the API key first." }
        if k.provider == .custom {
            guard let b = k.customBase?.trimmingCharacters(in: .whitespaces), let u = URL(string: b), u.scheme?.hasPrefix("http") == true, u.host != nil
            else { return "Type the service’s API address, e.g. https://example.com/v1." }
        }
        do {
            k.models = try await Assistant.models(for: k, secret: s)
        } catch let e as CloudError {
            return e.text(k.provider.shortName.capitalizedFirst)
        } catch let e as URLError {
            return e.code == .notConnectedToInternet ? "The Mac is offline. Connect to the internet and try again."
                : "Couldn’t reach \(k.provider.shortName). Check the address and the internet connection."
        } catch {
            return error.localizedDescription
        }
        if k.models.isEmpty { return "This key can’t use any chat models." }
        if !k.models.contains(k.model) { k.model = k.models[0] }
        keys.save(k, secret: typed?.isEmpty == false ? typed : nil)
        return nil
    }

    func newChat() {
        answering?.cancel(); answering = nil
        messages = []; problem = nil
    }

    func stop() { answering?.cancel() }

    // MARK: Local AI

    /// The local model server found on this Mac, and its models.
    var localServer: LocalChat.Server?
    var localModels: [String] = []
    var lookingForLocal = false
    var localModel: String = UserDefaults.standard.string(forKey: "assistantModel") ?? "" {
        didSet { UserDefaults.standard.set(localModel, forKey: "assistantModel") }
    }

    /// Looks for LM Studio or Ollama answering on this Mac.
    func findLocal() async {
        lookingForLocal = true
        if let (s, list) = await LocalChat.find() {
            localServer = s; localModels = list
            if !list.contains(localModel) { localModel = list.first ?? "" }
        } else {
            localServer = nil; localModels = []
        }
        lookingForLocal = false
    }

    private func askLocal(_ text: String, readings: Bool) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, answering == nil, let server = localServer, !localModel.isEmpty else { return }
        problem = nil
        messages.append(.init(role: .user, text: q))
        let history = messages
        messages.append(.init(role: .assistant, text: ""))
        let context = readings ? AssistantContext.current() : "(The user chose not to share this Mac's readings.)"
        let model = localModel
        answering = Task {
            do {
                try await LocalChat.ask(server, model: model, history: history, readings: context) { piece in
                    Task { @MainActor in
                        if let i = self.threads[.local]?.indices.last { self.threads[.local]?[i].text += piece }
                    }
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                problem = (error as? URLError) != nil ? "\(server.name) stopped answering. Is it still running?" : error.localizedDescription
            }
            if threads[.local]?.last?.role == .assistant, threads[.local]?.last?.text.isEmpty == true { threads[.local]?.removeLast() }
            answering = nil
        }
    }

    func send(_ text: String, readings: Bool) {
        switch mode {
        case .agent: askAgent(text)
        case .local: askLocal(text, readings: readings)
        case .lumen: askLumen(text, readings: readings)
        case .cloud: askCloud(text, readings: readings)
        }
    }

    /// Apex Agent: answers at once, written out quickly so it reads naturally.
    private func askAgent(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, answering == nil else { return }
        messages.append(.init(role: .user, text: q))
        let answer = ApexAgent.answer(q, ApexAgent.Readings.current())
        var reply = Assistant.Message(role: .assistant, text: "")
        reply.content = [["type": "text", "text": answer.text]]
        messages.append(reply)
        let words = answer.text.split(separator: " ", omittingEmptySubsequences: false)
        answering = Task {
            try? await Task.sleep(for: .milliseconds(350))
            var shown = 0
            while shown < words.count, !Task.isCancelled {
                shown = min(words.count, shown + 3)
                if let i = messages.indices.last { messages[i].text = words.prefix(shown).joined(separator: " ") }
                try? await Task.sleep(for: .milliseconds(18))
            }
            if let i = messages.indices.last {
                messages[i].text = answer.text
                messages[i].actions = answer.actions
                messages[i].suggestLumen = answer.unknown
            }
            answering = nil
        }
    }

    /// The agent reports something it did (after a button).
    func agentSays(_ text: String) {
        threads[.agent, default: []].append(.init(role: .assistant, text: text))
    }

    /// Lumen AI: CyberNet Labs' service, with the account's key.
    private func askLumen(_ text: String, readings: Bool) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, answering == nil else { return }
        guard let base = Lumen.base, let key = lumen.key else {
            problem = "Lumen AI isn’t open yet. Apex Agent can answer common questions now, or use your own key in Cloud API."
            lastUnanswered = q
            return
        }
        askOpenAIStyle(q, service: "Lumen AI", base: base, key: key, model: Lumen.model, readings: readings)
    }

    /// Asks the same question in another mode (e.g. "Try Lumen AI").
    func retry(_ question: String, in mode: Assistant.Mode, readings: Bool) {
        self.mode = mode
        send(question, readings: readings)
    }

    private func askCloud(_ text: String, readings: Bool) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, answering == nil, let k = keys.active, let secret = keys.secret(for: k) else { return }
        guard !k.model.isEmpty else { problem = "Pick a model for “\(k.title)” under Manage Keys."; return }
        let base = TestSwitch.value("APEX_ASSISTANT_BASE") ?? k.base
        let service = k.provider == .custom ? k.title : k.provider.shortName
        switch k.provider.api {
        case .openAI: askOpenAIStyle(q, service: service, base: base, key: secret, model: k.model, readings: readings)
        case .anthropic: askAnthropic(q, base: base, key: secret, model: k.model, readings: readings)
        }
    }

    /// Every OpenAI-style service (most providers, Lumen AI): streamed text.
    private func askOpenAIStyle(_ q: String, service: String, base: String, key: String, model: String, readings: Bool) {
        problem = nil
        let m = mode
        var user = Assistant.Message(role: .user, text: q)
        user.content = [["type": "text", "text": q]]
        messages.append(user)
        let history = messages
        messages.append(.init(role: .assistant, text: ""))
        let context = readings ? AssistantContext.current() : nil
        answering = Task {
            do {
                try await OpenAIChat.ask(base: base, key: key, model: model, history: history, readings: context) { piece in
                    Task { @MainActor in
                        if let i = self.threads[m]?.indices.last { self.threads[m]?[i].text += piece }
                    }
                }
                // Let the last pieces land, then keep the answer for later turns.
                await Task.yield()
                if let i = threads[m]?.indices.last, let t = threads[m]?[i].text, !t.isEmpty {
                    threads[m]?[i].content = [["type": "text", "text": t]]
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch let e as CloudError {
                problem = e.text(service.capitalizedFirst)
            } catch let e as URLError {
                problem = e.code == .notConnectedToInternet ? "The Mac is offline. Connect to the internet and ask again."
                    : "Couldn’t reach \(service). Check the internet connection."
            } catch {
                problem = error.localizedDescription
            }
            finishTurn(m)
        }
    }

    /// A turn that didn't finish isn't kept: the question goes back as unanswered
    /// and both are removed, so the history sent next time stays valid.
    private func finishTurn(_ m: Assistant.Mode) {
        if threads[m]?.last?.role == .assistant, threads[m]?.last?.content.isEmpty == true {
            let partial = threads[m]!.removeLast()
            if let q = threads[m]?.last, q.role == .user {
                threads[m]!.removeLast()
                if !partial.text.isEmpty, problem == nil { problem = "Stopped. Ask again to get the full answer." }
                lastUnanswered = q.text
            }
        }
        answering = nil
    }

    private func askAnthropic(_ q: String, base: String, key: String, model: String, readings: Bool) {
        problem = nil
        var user = Assistant.Message(role: .user, text: q)
        user.content = Assistant.userContent(q, readings: readings ? AssistantContext.current() : nil)
        messages.append(user)
        let history = messages
        messages.append(.init(role: .assistant, text: ""))
        answering = Task {
            do {
                let reply = try await Assistant.ask(base: base, key: key, model: model, history: history) { [weak self] r in
                    guard let self, let i = self.messages.indices.last else { return }
                    self.messages[i].text = r.text
                    self.messages[i].thinking = r.thinking
                }
                if let err = reply.error {
                    problem = err
                } else if reply.stop == "refusal" {
                    problem = Assistant.stopNote(reply.stop)
                } else {
                    if let i = messages.indices.last { messages[i].content = reply.sendable }
                    if let note = Assistant.stopNote(reply.stop) { problem = note }
                }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch let e as URLError {
                problem = e.code == .notConnectedToInternet ? "The Mac is offline. Connect to the internet and ask again."
                    : "Couldn’t reach Anthropic. Check the internet connection."
            } catch {
                problem = error.localizedDescription
            }
            finishTurn(.cloud)
        }
    }

    /// The question of a turn that didn't finish, so the composer can offer it again.
    var lastUnanswered: String?
}

/// Apex's live readings as short plain text for the assistant.
enum AssistantContext {
    @MainActor static func current() -> String {
        let m = AppModel.shared
        return build(m.snapshot, events: Array(EventLog.shared.events.prefix(5)),
                     battery: HardwareStore.shared.hasBattery ? HardwareStore.shared.battery : nil)
    }

    /// Pure: tested.
    static func build(_ s: Snapshot, events: [DetectionEvent], battery: BatteryInfo?) -> String {
        let sys = s.system
        var lines: [String] = []
        lines.append("Mac: \(sys.cpu.brand), \(Fmt.bytes(sys.memory.total)) memory")
        lines.append(String(format: "CPU: %.0f%% busy", sys.cpu.total))
        lines.append("Memory: \(Fmt.bytes(sys.memory.used)) used of \(Fmt.bytes(sys.memory.total)), pressure \(sys.memory.pressureLevel.title), swap \(Fmt.bytes(sys.memory.swapUsed))")
        lines.append("Startup disk: \(Fmt.diskBytes(sys.disk.available)) free of \(Fmt.diskBytes(sys.disk.capacity))")
        lines.append("Network: \(sys.network.interface.isEmpty ? "not connected" : sys.network.interface), ↓ \(Fmt.rate(sys.network.inPerSec)) ↑ \(Fmt.rate(sys.network.outPerSec))")
        if let g = sys.gpu.utilization { lines.append(String(format: "GPU: %.0f%%", g)) }
        if let b = battery {
            lines.append("Battery: \(b.percent)%, \(b.onAC ? "on power" : "on battery"), health \(Int(b.health.rounded()))%, \(b.cycleCount) cycles")
        }
        let apps = s.processes.filter(\.isRegularApp)
        let byCPU = apps.sorted { $0.cpu > $1.cpu }.prefix(5).map { String(format: "%@ %.0f%%", $0.name, $0.cpu) }
        let byMem = apps.sorted { $0.memory > $1.memory }.prefix(5).map { "\($0.name) \(Fmt.bytes($0.memory))" }
        if !byCPU.isEmpty { lines.append("Busiest apps (CPU): " + byCPU.joined(separator: ", ")) }
        if !byMem.isEmpty { lines.append("Largest apps (memory): " + byMem.joined(separator: ", ")) }
        if !events.isEmpty {
            lines.append("Recent alerts: " + events.map { "\($0.title) (\($0.date.formatted(date: .omitted, time: .shortened)))" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    /// "your service" → "Your service" (a name starting a sentence).
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
