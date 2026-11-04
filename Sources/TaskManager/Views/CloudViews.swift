import AppKit
import SwiftUI

/// Cloud services and what they take on this Mac. Scans run on demand (and
/// when the page opens if older than 10 minutes), never in the sampling loop.
@MainActor @Observable
final class CloudStore {
    static let shared = CloudStore()

    private(set) var services: [CloudService] = []
    private(set) var usage: [String: CloudUsage] = [:]
    private(set) var quota: [String: CloudQuota] = [:]
    private(set) var problem: [String: String] = [:]
    /// Total and free space of the disk an added folder is on.
    private(set) var disk: [String: (total: UInt64, free: UInt64)] = [:]
    /// Storage pages connected to services (detected ones included), by service id.
    @ObservationIgnored private var webLinks: [String: [String: String]] =
        UserDefaults.standard.dictionary(forKey: "cloudWebLinks") as? [String: [String: String]] ?? [:]
    @ObservationIgnored private var savedQuota: [String: [String: Double]] =
        UserDefaults.standard.dictionary(forKey: "cloudWebQuota") as? [String: [String: Double]] ?? [:]
    private(set) var scanning = Set<String>()
    /// Offload Everything, per service.
    private(set) var offload: [String: OffloadState] = [:]
    /// Live upload state of the files listed on the page, by path.
    private(set) var fileStates: [String: CloudUpload.FileState] = [:]
    /// The service's server didn't answer the last check.
    private(set) var serverDown: [String: Bool] = [:]
    /// The service's own app is signed out or not open (nothing can upload).
    private(set) var appProblem: [String: CloudUpload.AppProblem] = [:]
    /// The service's app is syncing right now (a listed file is going up, or its app is sending).
    private(set) var syncing: [String: Bool] = [:]
    @ObservationIgnored private var appBytes: [String: [String: UInt64]] = [:]
    /// About how far each file's upload has got (0–1), from the bytes the
    /// service's app sent while that file was going up; kept while paused.
    private(set) var uploadProgress: [String: Double] = [:]
    @ObservationIgnored private var sentFor: [String: Double] = [:]
    @ObservationIgnored private var lastServerCheck: [String: Date] = [:]
    @ObservationIgnored private var custom: [CloudService] = []

    struct OffloadState: Equatable {
        var total = 0, done = 0, waiting = 0, failed = 0
        /// Files that couldn't upload, by name, with why (shown in the monitor).
        var failedFiles: [String: String] = [:]
        var freed: UInt64 = 0
        var running = true
        var lastError: String?
        var started = Date()
        var finished: Date?
        // Upload monitor (while files wait for their upload to finish).
        var uploadingSince: Date?
        var uploadsFinished: Date?
        var waitingBytes: UInt64 = 0
        var sendingNow = 0                   // files the app is uploading this moment
        var rate: Double?                    // bytes/s the service's app is sending
        var rateHistory: [Double] = []       // last 3 minutes, a reading every 3 s
        var server: String?
        var latency: Double?                 // ms to open a connection; nil = can't reach
        var checkedServer = false
        var downSince: Date?
        var networkHint: String?             // why it can't be reached, when Apex can tell
        var appProblem: CloudUpload.AppProblem?   // its app is signed out or not open
        var stalled = false
        var stopped = false
        var paused = false
        var pausedAt: Date?
        /// Why it carried on by itself (connection back, the app syncing again).
        var resumeNote: String?
        /// Check Uploads: the monitor only, nothing is made online-only.
        var watchOnly = false
        var timeLeft: TimeInterval? { CloudUpload.timeLeft(bytesLeft: waitingBytes, rate: rate) }
    }
    /// Gives up when nothing has gone up for this long (connection lost, app stopped).
    static let stallLimit: TimeInterval = 15 * 60

    private init() {
        if let d = UserDefaults.standard.data(forKey: "cloudServices"),
           let c = try? JSONDecoder().decode([CloudService].self, from: d) { custom = c }
        refreshList()
    }

    func refreshList() { services = Cloud.detected() + custom }

    var onMacTotal: UInt64 { usage.values.reduce(0) { $0 + $1.onMacBytes } }

    func webLink(_ s: CloudService) -> (page: String, store: UUID)? {
        if let p = s.webPage, let id = s.webStore.flatMap(UUID.init) { return (p, id) }
        guard let l = webLinks[s.id], let p = l["page"], let id = l["store"].flatMap(UUID.init) else { return nil }
        return (p, id)
    }

    /// After signing in on the provider's page: remember the page and the numbers.
    func connectWeb(_ s: CloudService, page: String, store id: UUID, quota q: CloudQuota) {
        webLinks[s.id] = ["page": page, "store": id.uuidString]
        UserDefaults.standard.set(webLinks, forKey: "cloudWebLinks")
        remember(q, for: s.id)
    }

    private func remember(_ q: CloudQuota, for id: String, manual: Bool = false) {
        quota[id] = q; problem[id] = nil
        savedQuota[id] = ["used": Double(q.used), "available": Double(q.available ?? 0), "at": Date().timeIntervalSince1970,
                          "manual": manual ? 1 : 0]
        UserDefaults.standard.set(savedQuota, forKey: "cloudWebQuota")
    }

    /// Storage typed in by the user (from their provider's page or bill).
    func enterStorage(_ s: CloudService, used: UInt64, total: UInt64) {
        remember(CloudQuota(used: used, available: total > used ? total - used : 0), for: s.id, manual: true)
    }

    func clearStorage(_ s: CloudService) {
        quota[s.id] = nil
        savedQuota[s.id] = nil
        UserDefaults.standard.set(savedQuota, forKey: "cloudWebQuota")
    }

    /// When the storage figures were typed in by the user, the date they were.
    func enteredByUser(_ s: CloudService) -> Date? {
        guard let q = savedQuota[s.id], q["manual"] == 1, let at = q["at"] else { return nil }
        return Date(timeIntervalSince1970: at)
    }

    /// The page that shows this service's storage: the provider's own, or for
    /// a self-hosted server (Nextcloud, ownCloud…) its personal settings page.
    func storagePage(_ s: CloudService) -> String? {
        if let p = CloudCatalog.provider(for: s.name)?.storagePage { return p }
        return Self.serverStoragePage(name: s.name, server: CloudUpload.knownServer(for: s))
    }

    /// Pure: tested.
    nonisolated static func serverStoragePage(name: String, server: CloudUpload.Endpoint?) -> String? {
        guard let e = server else { return nil }
        // Servers on a home or office network often have no certificate: plain http there.
        let scheme = CloudUpload.ipv4(e.host).map(CloudUpload.isPrivate) == true ? "http" : "https"
        let path: String
        switch name {
        case "Nextcloud": path = "/index.php/settings/user"
        case "ownCloud": path = "/index.php/settings/personal"
        default: path = "/"
        }
        return "\(scheme)://\(e.host)\(path)"
    }

    /// "81,5" or "81.5" with a unit → bytes. Pure: tested.
    nonisolated static func bytes(_ text: String, unit: String) -> UInt64? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), v >= 0 else { return nil }
        return UInt64(saturating: v * CloudCatalog.multiplier(unit))
    }

    func refresh(_ s: CloudService, force: Bool = false) {
        if s.kind == .folder, let v = try? URL(fileURLWithPath: s.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            disk[s.id] = (UInt64(clamping: v.volumeTotalCapacity ?? 0), UInt64(clamping: v.volumeAvailableCapacityForImportantUsage ?? 0))
        }
        if quota[s.id] == nil, let q = savedQuota[s.id], let used = q["used"] {
            quota[s.id] = CloudQuota(used: UInt64(saturating: used), available: q["available"].map { UInt64(saturating: $0) })
        }
        if let link = webLink(s) {
            let age = Date().timeIntervalSince1970 - (savedQuota[s.id]?["at"] ?? 0)
            if force || age > 6 * 3600 {
                let id = s.id
                Task {
                    if let q = await WebQuotaReader.read(page: link.page, storeID: link.store) { remember(q, for: id) }
                    else if force { problem[id] = "Couldn’t read the storage page; sign in again with Show Total Storage." }
                }
            }
        }
        if !s.path.isEmpty, !scanning.contains(s.id), force || (usage[s.id].map { Date().timeIntervalSince($0.scanned) > 600 } ?? true) {
            scanning.insert(s.id)
            let path = s.path, id = s.id
            Task {
                let u = await Task.detached(priority: .utility) { Cloud.scan(path) }.value
                usage[id] = u
                scanning.remove(id)
            }
        }
        if s.kind == .webdav {
            let id = s.id
            Task {
                switch await Cloud.quota(url: s.url, username: s.username, password: Keychain.get(account: s.id) ?? "") {
                case .success(let q): quota[id] = q; problem[id] = nil
                case .failure(let e): problem[id] = e.localizedDescription
                }
            }
        }
    }

    func add(_ s: CloudService, password: String?) {
        if let password, !password.isEmpty { Keychain.set(password, account: s.id) }
        custom.append(s)
        save()
        refreshList()
        refresh(s, force: true)
    }

    func remove(_ s: CloudService) {
        guard s.kind != .system else { return }
        custom.removeAll { $0.id == s.id }
        Keychain.remove(account: s.id)
        usage[s.id] = nil; quota[s.id] = nil
        save()
        refreshList()
    }

    /// Makes files online-only (all stored on this Mac when `files` is nil).
    /// Files still uploading are watched every 3 s and offloaded the moment
    /// they're in the cloud, while the upload monitor follows the service's
    /// app and its server. Gives up only after 15 minutes without progress;
    /// a notification says how it went and how long it took.
    func offloadAll(_ s: CloudService, files: [CloudFile]? = nil) {
        guard !s.path.isEmpty, offload[s.id]?.running != true else { return }
        var fresh = OffloadState()
        if pausedServices.contains(s.id) { fresh.paused = true; fresh.pausedAt = Date() }
        offload[s.id] = fresh
        probeNow(s)
        let id = s.id, path = s.path, name = s.name
        Task {
            var pending: [CloudFile]
            if let files { pending = files } else { pending = await Task.detached(priority: .utility) { Cloud.storedFiles(path) }.value }
            offload[id]?.total = pending.count
            // First pass: everything that's already in the cloud.
            var next: [CloudFile] = []
            for chunk in stride(from: 0, to: pending.count, by: 50).map({ Array(pending[$0..<min($0 + 50, pending.count)]) }) {
                let results = await Task.detached(priority: .utility) { chunk.map { ($0, Cloud.evict($0)) } }.value
                for (f, r) in results { record(id, f, r, &next) }
                offload[id]?.waiting = next.count
            }
            pending = next
            if !pending.isEmpty { await watchUploads(s, pending: pending, evict: true) }
            offload[id]?.running = false
            offload[id]?.finished = Date()
            let st = offload[id] ?? OffloadState()
            let freed = Fmt.diskBytes(st.freed)
            let took = CloudUpload.duration(Date().timeIntervalSince(st.started))
            if st.waiting == 0 && st.failed == 0 {
                Alerts.shared.notify(id: "offload:" + id, title: "\(name): offloaded",
                                     body: "\(st.done) files are online-only now. \(freed) freed on this Mac in \(took).")
            } else {
                let why = st.stopped ? "you stopped it with \(st.waiting) still uploading"
                    : st.waiting > 0 ? "\(st.waiting) still haven’t uploaded (nothing went up for 15 minutes; is \(st.server ?? "the server") reachable?)"
                    : "\(st.failed) couldn’t be offloaded"
                Alerts.shared.notify(id: "offload:" + id, title: "\(name): offload incomplete",
                                     body: "\(freed) freed in \(took), but \(why)." + (st.lastError.map { " " + $0 } ?? ""))
            }
            refresh(s, force: true)
        }
    }

    private func record(_ id: String, _ f: CloudFile, _ r: Cloud.EvictResult, _ next: inout [CloudFile]) {
        switch r {
        case .done: offload[id]?.done += 1; offload[id]?.freed += f.bytes
        case .waitingForUpload: next.append(f)
        case .failed(let e): offload[id]?.failed += 1; offload[id]?.lastError = e; offload[id]?.failedFiles[f.name] = e
        }
    }

    /// Check Uploads: finds files on this Mac that aren't in the cloud yet and
    /// watches them go up (speed, server, time left) without offloading anything.
    func checkUploads(_ s: CloudService) {
        guard !s.path.isEmpty, offload[s.id]?.running != true else { return }
        var st = OffloadState(); st.watchOnly = true
        if pausedServices.contains(s.id) { st.paused = true; st.pausedAt = Date() }
        offload[s.id] = st
        probeNow(s)
        let id = s.id, path = s.path, name = s.name
        Task {
            let waiting = await Task.detached(priority: .utility) { () -> [CloudFile] in
                let files = Cloud.storedFiles(path)
                return zip(files, CloudUpload.states(files)).filter { $0.1 != .uploaded }.map(\.0)
            }.value
            offload[id]?.total = waiting.count
            offload[id]?.waiting = waiting.count
            if !waiting.isEmpty { await watchUploads(s, pending: waiting, evict: false) }
            offload[id]?.running = false
            offload[id]?.finished = Date()
            let st = offload[id] ?? OffloadState()
            if !waiting.isEmpty, st.waiting == 0, !st.stopped {
                Alerts.shared.notify(id: "uploads:" + id, title: "\(name): everything uploaded",
                                     body: "\(st.done) files went up in \(CloudUpload.duration(Date().timeIntervalSince(st.started))).")
            }
        }
    }

    /// Stops waiting for uploads (files already offloaded stay offloaded).
    func stopOffload(_ s: CloudService) { offload[s.id]?.stopped = true }

    /// Cloud space › Move to Trash: what moved, what didn't and why; then checks again.
    func trash(_ s: CloudService, _ items: [CloudEntry]) async -> String {
        let r = await Task.detached(priority: .userInitiated) { Cloud.trash(items) }.value
        refresh(s, force: true)
        var text = r.moved == 0 ? "" : "Moved \(r.moved) file\(r.moved == 1 ? "" : "s") (\(Fmt.diskBytes(r.freed))) to the Trash. \(s.name) frees the space once it has synced."
        if !r.failed.isEmpty {
            text += (text.isEmpty ? "" : " ") + "\(r.failed.count) couldn’t be moved (\(s.name) didn’t allow it): remove "
                + (r.failed.count == 1 ? "“\(r.failed[0])”" : "them") + " on \(s.name)’s website or in Finder."
        }
        return text
    }

    /// Pauses the offload / check: nothing is offloaded and the app's traffic
    /// isn't read, but Apex keeps an eye out and carries on by itself when
    /// the connection comes back or the service's app starts syncing again.
    /// Services paused and not resumed yet: checking or offloading again
    /// starts paused, until Resume or the connection / syncing comes back.
    @ObservationIgnored private var pausedServices: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "cloudPaused") ?? []) {
        didSet { UserDefaults.standard.set(Array(pausedServices), forKey: "cloudPaused") }
    }

    /// Every 5 s while the page shows them: where each listed file's upload
    /// is, and (every 30 s, while any isn't uploaded) whether the server answers.
    func refreshFileStates(_ s: CloudService, files: [CloudFile]) async {
        let list = files
        let states = await Task.detached(priority: .utility) { CloudUpload.states(list) }.value
        for (f, st) in zip(list, states) where fileStates[f.path] != st { fileStates[f.path] = st }
        // Syncing, as the service's own app sees it: a file it's sending, or its app sending data.
        let (appPids, sendingNow) = await Task.detached(priority: .utility) { () -> ([pid_t], [NetConnection]) in
            let p = CloudUpload.processes(for: s)
            return (p, CloudUpload.connections(p))
        }.value
        setAppProblem(s, CloudUpload.appProblem(hasApp: CloudUpload.hasOwnApp(s), running: !appPids.isEmpty, states: states))
        let sent = CloudUpload.sent(sendingNow, previous: appBytes[s.id])
        appBytes[s.id] = Dictionary(sendingNow.map { ($0.key, $0.bytesOut) }, uniquingKeysWith: max)
        let sendingFiles = zip(list, states).filter { $0.1 == .sending }.map(\.0)
        for f in sendingFiles where f.bytes > 0 {
            sentFor[f.path, default: 0] += Double(sent) / Double(sendingFiles.count)
            uploadProgress[f.path] = CloudUpload.estimatedProgress(sent: sentFor[f.path] ?? 0, size: f.bytes)
        }
        for (f, st) in zip(list, states) where st == .uploaded { uploadProgress[f.path] = nil; sentFor[f.path] = nil }
        let isSyncing = states.contains(.sending) || sent > 10_000
        if syncing[s.id] != isSyncing { syncing[s.id] = isSyncing }
        if isSyncing { serverDown[s.id] = false }
        guard states.contains(where: { $0 != .uploaded }) else { serverDown[s.id] = false; return }
        if let st = offload[s.id], st.running, st.checkedServer {
            serverDown[s.id] = st.latency == nil            // the monitor already knows
        } else if Date().timeIntervalSince(lastServerCheck[s.id] ?? .distantPast) >= 30, let e = CloudUpload.knownServer(for: s) {
            lastServerCheck[s.id] = Date()
            serverDown[s.id] = await CloudUpload.probe(e) == nil
        }
    }

    private func setAppProblem(_ s: CloudService, _ p: CloudUpload.AppProblem?) {
        if appProblem[s.id] != p { appProblem[s.id] = p }
        guard offload[s.id] != nil, offload[s.id]?.appProblem != p else { return }
        let was = offload[s.id]?.appProblem
        offload[s.id]?.appProblem = p
        if p == nil, was != nil, offload[s.id]?.running == true {
            offload[s.id]?.resumeNote = was == .signedOut ? "\(s.name) is signed in again, so uploads carry on." : "\(s.name) is open again, so uploads carry on."
        }
    }

    /// Checks the server straight away, while the files are still being
    /// listed, so the card can say at once whether it can be reached.
    private func probeNow(_ s: CloudService) {
        guard let e = CloudUpload.knownServer(for: s) else { return }
        let id = s.id
        Task {
            let ms = await CloudUpload.probe(e)
            guard offload[id]?.checkedServer != true else { return }      // the monitor got there first
            offload[id]?.server = e.label; offload[id]?.latency = ms; offload[id]?.checkedServer = true
            if ms == nil {
                offload[id]?.downSince = Date()
                offload[id]?.networkHint = CloudUpload.otherNetworkHint(host: e.host, local: CloudUpload.localIPv4())
            }
        }
    }

    func pauseOffload(_ s: CloudService) {
        pausedServices.insert(s.id)
        offload[s.id]?.paused = true
        offload[s.id]?.pausedAt = Date()
        offload[s.id]?.resumeNote = nil
        offload[s.id]?.rate = nil
    }

    func resumeOffload(_ s: CloudService, note: String? = nil) {
        pausedServices.remove(s.id)
        offload[s.id]?.paused = false
        offload[s.id]?.pausedAt = nil
        offload[s.id]?.resumeNote = note
    }

    /// The upload monitor: every 3 s, which waiting files are in the cloud now
    /// (offloaded straight away), how fast the service's app is sending and to
    /// which server; every 10 s, whether that server answers.
    private func watchUploads(_ s: CloudService, pending start: [CloudFile], evict: Bool) async {
        let id = s.id, name = s.name
        var pending = start
        offload[id]?.uploadingSince = Date()
        var pids: [pid_t] = [], pidsAt = Date.distantPast
        var lastBytes: [String: UInt64]?
        var lastTick = Date(), lastProbe = Date.distantPast, lastProgress = Date()
        var endpoint = CloudUpload.knownServer(for: s)
        var warnedLost = false
        var downWhilePaused = false
        while !pending.isEmpty, offload[id]?.stopped != true {
            try? await Task.sleep(for: .seconds(3))
            let now = Date()
            if offload[id]?.paused == true {
                // Paused: only watch for the connection or the app's own syncing to come back.
                lastProgress = now
                if offload[id]?.checkedServer == true, offload[id]?.latency == nil { downWhilePaused = true }
                let files = pending
                let states = await Task.detached(priority: .utility) { CloudUpload.states(files) }.value
                if states.contains(.uploaded) {
                    resumeOffload(s, note: "\(name) is syncing again, so Apex carried on by itself.")
                    Alerts.shared.notify(id: "offload-lost:" + id, title: "\(name) is syncing again", body: "Uploads are moving, so Apex carried on.")
                    downWhilePaused = false
                    continue
                }
                if let e = endpoint, now.timeIntervalSince(lastProbe) >= 10 {
                    lastProbe = now
                    let ms = await CloudUpload.probe(e)
                    offload[id]?.server = e.label; offload[id]?.latency = ms; offload[id]?.checkedServer = true
                    if ms == nil {
                        downWhilePaused = true
                        if offload[id]?.downSince == nil { offload[id]?.downSince = now }
                        offload[id]?.networkHint = CloudUpload.otherNetworkHint(host: e.host, local: CloudUpload.localIPv4())
                    } else if downWhilePaused {
                        offload[id]?.downSince = nil; offload[id]?.networkHint = nil
                        resumeOffload(s, note: "The connection to \(e.label) is back, so Apex carried on by itself.")
                        Alerts.shared.notify(id: "offload-lost:" + id, title: "\(name): connection back", body: "\(e.label) answers again; uploads carry on.")
                        downWhilePaused = false; warnedLost = false
                    }
                }
                continue
            }
            // Files: in the cloud now → offload them.
            let files = pending
            let states = await Task.detached(priority: .utility) { CloudUpload.states(files) }.value
            var next: [CloudFile] = [], ready: [CloudFile] = [], sending = 0
            for (f, st) in zip(files, states) {
                switch st {
                case .uploaded: ready.append(f)
                case .sending: sending += 1; next.append(f)
                case .queued: next.append(f)
                case .blocked, .signedOut: next.append(f)  // the connection, or signing in: keep waiting
                case .failed(let e): offload[id]?.failed += 1; offload[id]?.lastError = e; offload[id]?.failedFiles[f.name] = e
                }
            }
            if !ready.isEmpty {
                if evict {
                    let results = await Task.detached(priority: .utility) { ready.map { ($0, Cloud.evict($0)) } }.value
                    for (f, r) in results { record(id, f, r, &next) }
                } else {
                    offload[id]?.done += ready.count
                }
                lastProgress = now
            }
            pending = next
            offload[id]?.waiting = pending.count
            offload[id]?.sendingNow = sending
            offload[id]?.waitingBytes = pending.reduce(0) { $0 + $1.bytes }
            // The app's connections: speed and server.
            // Every 30 s, or every time while its app isn't running (to see it open).
            if now.timeIntervalSince(pidsAt) > 30 || pids.isEmpty { pids = await Task.detached(priority: .utility) { CloudUpload.processes(for: s) }.value; pidsAt = now }
            let ps = pids
            let conns = await Task.detached(priority: .utility) { CloudUpload.connections(ps) }.value
            if !pids.isEmpty {
                let bytes = CloudUpload.sent(conns, previous: lastBytes)
                let secs = max(0.5, now.timeIntervalSince(lastTick))
                if lastBytes != nil {
                    let rate = Double(bytes) / secs
                    offload[id]?.rate = rate
                    offload[id]?.rateHistory.append(rate)
                    if (offload[id]?.rateHistory.count ?? 0) > 60 { offload[id]?.rateHistory.removeFirst() }
                    if rate > 2_000 { lastProgress = now }
                }
                lastBytes = Dictionary(conns.map { ($0.key, $0.bytesOut) }, uniquingKeysWith: max)
            }
            lastTick = now
            let problem = CloudUpload.appProblem(hasApp: CloudUpload.hasOwnApp(s), running: !pids.isEmpty, states: states)
            setAppProblem(s, problem)
            if problem != nil { lastProgress = now }      // waits for you to sign in or open it, however long
            if let seen = CloudUpload.server(conns) { endpoint = seen }
            // Is the server there?
            if let e = endpoint, now.timeIntervalSince(lastProbe) >= 10 {
                lastProbe = now
                let ms = await CloudUpload.probe(e)
                offload[id]?.server = e.label
                offload[id]?.latency = ms
                offload[id]?.checkedServer = true
                offload[id]?.networkHint = ms == nil ? CloudUpload.otherNetworkHint(host: e.host, local: CloudUpload.localIPv4()) : nil
                if ms == nil {
                    if offload[id]?.downSince == nil { offload[id]?.downSince = now }
                    if let d = offload[id]?.downSince, now.timeIntervalSince(d) >= 60, !warnedLost {
                        warnedLost = true
                        Alerts.shared.notify(id: "offload-lost:" + id, title: "\(name): lost connection",
                                             body: "Can’t reach \(e.label), so uploads are paused. Apex keeps waiting and finishes the offload when it’s back.")
                    }
                } else {
                    if warnedLost {
                        Alerts.shared.notify(id: "offload-lost:" + id, title: "\(name): connection back",
                                             body: "\(e.label) answers again; uploads carry on.")
                    }
                    offload[id]?.downSince = nil
                    warnedLost = false
                }
            }
            // While the server can't be reached it waits for it, however long; it only
            // gives up when the server answers and still nothing goes up.
            if offload[id]?.downSince != nil { lastProgress = now }
            if now.timeIntervalSince(lastProgress) > Self.stallLimit { offload[id]?.stalled = true; break }
        }
        offload[id]?.uploadsFinished = Date()
        offload[id]?.rate = nil
    }

    private func save() {
        if let d = try? JSONEncoder().encode(custom) { UserDefaults.standard.set(d, forKey: "cloudServices") }
    }
}

struct CloudDetail: View {
    @AppStorage("cloudTab") private var tab = ""
    @State private var adding = false
    @State private var analyze: CloudService?
    @State private var pick = Set<String>()
    @State private var note: String?
    @State private var confirmOffload: CloudService?
    @State private var connect: (CloudService, String)?
    @State private var entering: CloudService?
    private let store = CloudStore.shared
    static let overviewTab = "overview"

    var body: some View {
        let list = store.services
        let s = list.first { $0.id == tab }
        // Overview first: it's where everyone starts (and where an unknown tab lands).
        let overview = !list.isEmpty && s == nil
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if !list.isEmpty {
                    TabStrip(tabs: [(Self.overviewTab, "Overview", "square.grid.2x2")] + list.map { ($0.id, $0.name, $0.symbol) },
                             selected: overview ? Self.overviewTab : (s?.id ?? "")) { tab = $0; pick = []; note = nil }
                }
                Spacer()
                Button { adding = true } label: { Label("Add", systemImage: "plus") }
                    .help("Add your own service: a folder on this Mac, or a server (Nextcloud, ownCloud, a NAS…)")
            }
            if overview { CloudOverviewView(onOpen: { tab = $0; pick = []; note = nil }) }
            else if let s { page(s) }
            else {
                ContentUnavailableView("No Cloud Disks", systemImage: "icloud.slash",
                                       description: Text("Turn on iCloud Drive or install OneDrive, Google Drive, Dropbox or Nextcloud, or add your own with +."))
            }
        }
        .sheet(isPresented: $adding) { AddCloudSheet() }
        .sheet(isPresented: Binding(get: { connect != nil }, set: { if !$0 { connect = nil } })) {
            if let (svc, page) = connect {
                let storeID = store.webLink(svc)?.store ?? UUID()
                WebStorageSheet(title: svc.name, page: page, storeID: storeID) { q in
                    store.connectWeb(svc, page: page, store: storeID, quota: q)
                }
            }
        }
        .sheet(item: $entering) { svc in EnterStorageSheet(service: svc) }
        .sheet(item: $analyze) { svc in
            AnalyzeView(onBack: { analyze = nil }, onDone: { analyze = nil },
                        startAt: DiskEntry(name: svc.name, path: svc.path, isDirectory: true))
                .padding(20).frame(width: 640)
        }
        .onAppear {
            store.refreshList(); store.services.forEach { store.refresh($0) }
            // Test switch: APEX_CHECK_UPLOADS=<service name> starts Check Uploads (read-only).
            if let n = ProcessInfo.processInfo.environment["APEX_CHECK_UPLOADS"], let s = store.services.first(where: { $0.name == n }) {
                tab = s.id
                store.checkUploads(s)
            }
        }
        .confirmationDialog("Offload everything in \(confirmOffload?.name ?? "")?", isPresented: Binding(get: { confirmOffload != nil }, set: { if !$0 { confirmOffload = nil } }),
                            presenting: confirmOffload) { s in
            Button("Offload All") { store.offloadAll(s) }
        } message: { _ in
            Text("Every file stays in the cloud and downloads again when you open it, which takes a moment, so avoid offloading folders you're working in right now. Files that haven't finished uploading are kept until they have. You'll get a notification when it's done.")
        }
    }

    @ViewBuilder private func page(_ s: CloudService) -> some View {
        let u = store.usage[s.id], q = store.quota[s.id]
        PageHeader(title: s.name, subtitle: [s.kind == .webdav ? s.url : (s.account.isEmpty ? "Synced folder" : s.account),
                                            u.map { "checked " + $0.scanned.formatted(.relative(presentation: .named)) } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                   accessory: AnyView(HStack(spacing: 8) {
                       if store.syncing[s.id] == true {
                           HStack(spacing: 6) {
                               UploadDot(dot: .uploading, service: s.name)
                               Text("\(s.name) is syncing").font(.callout).foregroundStyle(.green)
                           }
                           .help("\(s.name)’s app is sending files right now.")
                           .transition(.opacity)
                       }
                       if !s.path.isEmpty {
                           Button { analyze = s } label: { Image(systemName: "chart.bar.doc.horizontal") }
                               .buttonStyle(.bordered).help("Analyze: what takes the space in this folder")
                           Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)]) } label: { Image(systemName: "folder") }
                               .buttonStyle(.bordered).help("Show in Finder")
                       }
                       Button { store.refresh(s, force: true) } label: { Image(systemName: "arrow.clockwise") }
                           .buttonStyle(.bordered).help("Check again").disabled(store.scanning.contains(s.id))
                       if s.kind != .system {
                           Button { store.remove(s) } label: { Image(systemName: "minus.circle") }
                               .buttonStyle(.bordered).help("Remove from Apex (nothing is deleted)")
                       }
                   }),
                   showsRange: false)

        if store.scanning.contains(s.id) && u == nil {
            HStack { ProgressView().controlSize(.small); Text("Measuring what’s on this Mac… nothing is downloaded.").foregroundStyle(.secondary) }
        }
        if let u {
            VStack(alignment: .leading, spacing: 6) {
                Text("ON THIS MAC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                StackedBar(parts: [.init(value: Double(u.onMacBytes), color: .blue)], total: Double(max(u.totalBytes, u.onMacBytes, 1)))
                Text("\(Fmt.diskBytes(u.onMacBytes)) stored on this Mac · \(Fmt.diskBytes(u.totalBytes > u.onMacBytes ? u.totalBytes - u.onMacBytes : 0)) online only")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        if let q {
            VStack(alignment: .leading, spacing: 6) {
                Text("ONLINE STORAGE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let total = q.total {
                    StackedBar(parts: [.init(value: Double(q.used), color: .teal)], total: Double(max(total, 1)))
                    Text("\(Fmt.diskBytes(q.used)) of \(Fmt.diskBytes(total)) used · \(Fmt.diskBytes(q.available ?? 0)) free")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("\(Fmt.diskBytes(q.used)) used · no limit reported").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        statsGrid(stats(s, u, q))
        connectBanner(s, q)
        if let sp = u?.space, sp.totalBytes > 0 { CloudSpaceSection(service: s, overview: sp).id(s.id) }
        if let p = store.problem[s.id] { Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }

        // Offload everything stored here (shown while a check or offload runs, even before the folder is measured).
        if s.kind != .webdav, (u?.onMacBytes ?? 0) > 0 || store.offload[s.id]?.running == true {
            let st = store.offload[s.id]
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "icloud.and.arrow.up").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(st?.watchOnly == true && st?.running == true ? "Checking uploads" : "Offload everything").font(.headline)
                    if let st, st.running, st.paused {
                        Label(OffloadText.paused(st), systemImage: "pause.circle.fill")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            .help(OffloadText.pausedHelp)
                            .contentTransition(.opacity)
                    } else if let st, st.running, st.watchOnly {
                        if st.uploadingSince == nil {
                            Text("Looking for files that haven’t uploaded yet…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView(value: Double(st.done), total: Double(max(st.total, 1))).frame(maxWidth: 320)
                            Text("\(st.done) of \(st.total) uploaded").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else if let st, st.running {
                        ProgressView(value: Double(st.done + st.failed), total: Double(max(st.total, 1))).frame(maxWidth: 320)
                        Text("\(st.done) of \(st.total) offloaded · \(Fmt.diskBytes(st.freed)) freed")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else if let st {
                        Text(OffloadText.lastRun(st))
                            .font(.caption).foregroundStyle(st.waiting + st.failed > 0 ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Makes all \(Fmt.diskBytes(u?.onMacBytes ?? 0)) stored on this Mac online-only. Files still uploading are finished first; nothing is lost.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if st?.running == true, st?.paused == true || (st?.waiting ?? 0) > 0 {
                    if st?.paused == true {
                        Button("Stop") { store.stopOffload(s) }
                            .buttonStyle(.borderless)
                            .help(st?.watchOnly == true ? "Stop watching the uploads (they carry on in \(s.name))."
                                  : "Stop the offload. Files already offloaded stay offloaded; the rest stay on this Mac.")
                        Button("Resume") { withAnimation(.easeInOut(duration: 0.2)) { store.resumeOffload(s) } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Pause") { withAnimation(.easeInOut(duration: 0.2)) { store.pauseOffload(s) } }
                            .help("Pause until the connection is back. Apex carries on by itself when it is, or when \(s.name) starts syncing again.")
                    }
                } else {
                    Button("Check Uploads") { store.checkUploads(s) }
                        .disabled(st?.running == true)
                        .help("See what hasn’t uploaded to \(s.name) yet, how fast it’s going and whether the server can be reached. Nothing is changed.")
                    Button("Offload All") { confirmOffload = s }
                        .disabled(st?.running == true)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .animation(.easeInOut(duration: 0.25), value: st?.waiting ?? 0 > 0)
        }
        if let p = store.appProblem[s.id] {
            AppProblemBanner(problem: p, service: s)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        // Paused: the short line in the card above says it all; the monitor comes back on Resume.
        // Stays up while it runs (paused, or with files that failed), so it still says what's going on.
        if let st = store.offload[s.id], st.running, st.uploadingSince != nil, st.waiting + st.failed > 0 {
            UploadMonitor(state: st, service: s.name)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        // Free up space on this Mac: largest downloaded files → online only.
        if let u, !u.largest.isEmpty, s.kind != .webdav {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Free up space on this Mac").font(.headline)
                    Spacer()
                    let chosen = u.largest.filter { pick.contains($0.path) }
                    Text("\(Fmt.diskBytes(chosen.reduce(0) { $0 + $1.bytes })) selected").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button("Make Online-Only") { freeUp(s, chosen) }.disabled(chosen.isEmpty || store.offload[s.id]?.running == true)
                }
                Text("These files take space on this Mac. Online-only files stay in the cloud and download again when you open them.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    ForEach(u.largest.prefix(15)) { f in
                        Toggle(isOn: Binding(get: { pick.contains(f.path) }, set: { if $0 { pick.insert(f.path) } else { pick.remove(f.path) } })) {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable().frame(width: 16, height: 16)
                                Text(f.name).lineLimit(1).truncationMode(.middle)
                                if let dot = CloudUpload.dot(store.fileStates[f.path] ?? (f.uploading ? .queued : .uploaded),
                                                             paused: store.offload[s.id]?.paused == true,
                                                             serverDown: store.serverDown[s.id] == true,
                                                             app: store.appProblem[s.id]) {
                                    UploadDot(dot: dot, service: s.name, server: CloudUpload.knownServer(for: s)?.host,
                                              progress: store.uploadProgress[f.path])
                                }
                                Spacer()
                                Text(Fmt.diskBytes(f.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                Button { delete(s, f) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Move to the Trash. It’s removed from \(s.name) online too once it syncs; you can put it back from the Trash.")
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                UploadDotLegend()
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .task(id: "\(s.id)|\(u.scanned.timeIntervalSince1970)") {
                let files = Array(u.largest.prefix(15))
                while !Task.isCancelled {
                    await store.refreshFileStates(s, files: files)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func stats(_ s: CloudService, _ u: CloudUsage?, _ q: CloudQuota?) -> [(String, String)] {
        var out: [(String, String)] = [
            ("Files", u.map { "\($0.files)" + ($0.partial ? "+" : "") } ?? "—"),
            ("On this Mac", u.map { Fmt.diskBytes($0.onMacBytes) } ?? "—"),
            ("Online only", u.map { "\($0.onlineOnly) files" } ?? "—"),
            ("In the folder", u.map { Fmt.diskBytes($0.totalBytes) + ($0.unlistedFolders > 0 ? "+" : "") } ?? "—"),
        ]
        // Folders only in the cloud aren't opened (that would ask the server, and waits when it can't answer).
        if let n = u?.unlistedFolders, n > 0 { out.append(("Folders only online", "\(n) (not counted)")) }
        let online: String
        if let q, let total = q.total { online = "\(Fmt.diskBytes(q.used)) of \(Fmt.diskBytes(total))" }
        else if let q { online = Fmt.diskBytes(q.used) }
        else { online = s.kind == .webdav ? (store.problem[s.id] ?? "Checking…") : "Not connected yet" }
        out.append(("Online storage", online))
        if let d = store.disk[s.id] { out.append(("Disk it’s on", "\(Fmt.diskBytes(d.free)) free of \(Fmt.diskBytes(d.total))")) }
        return out
    }

    @ViewBuilder private func connectBanner(_ s: CloudService, _ q: CloudQuota?) -> some View {
        if q == nil, s.kind == .system || s.kind == .folder {
            let provider = CloudCatalog.provider(for: s.name)
            let page = store.storagePage(s)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "chart.pie").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("How much of your online storage is used?").font(.callout.weight(.medium))
                    Text("macOS doesn’t tell apps how big your \(s.name) plan is. Check it on \(s.name)’s site (Apex reads the “used of total” line if the page shows it), or type the numbers in."
                         + ((provider?.note ?? "").isEmpty ? "" : " " + (provider?.note ?? "")))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let page {
                    Button("Check on Website…") { connect = (s, page) }
                        .help("Opens \(page) in Apex’s browser. Sign in as usual; nothing is sent anywhere.")
                }
                Button("Enter Storage…") { entering = s }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        } else if q != nil, let when = store.enteredByUser(s) {
            HStack(spacing: 8) {
                Text("Online storage entered by you on \(when.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.caption).foregroundStyle(.tertiary)
                Button("Change…") { entering = s }.buttonStyle(.link).font(.caption)
                Button("Remove") { store.clearStorage(s) }.buttonStyle(.link).font(.caption)
            }
        } else if q != nil, store.webLink(s) != nil {
            Text("Total storage read from \(s.name)’s own page; refreshed every few hours.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// A file's trash button: to the Trash, then the folder is measured again.
    private func delete(_ s: CloudService, _ f: CloudFile) {
        pick.remove(f.path)
        Task { note = await store.trash(s, [CloudEntry(path: f.path, bytes: f.bytes, onMac: f.bytes)]) }
    }

    private func freeUp(_ s: CloudService, _ files: [CloudFile]) {
        let waiting = files.filter(\.uploading).count
        store.offloadAll(s, files: files)
        note = waiting == 0 ? "Making \(files.count) file\(files.count == 1 ? "" : "s") online-only…"
            : "\(waiting) of these \(waiting == 1 ? "is" : "are") still uploading to \(s.name). Apex makes \(waiting == 1 ? "it" : "them") online-only as soon as the upload finishes, and lets you know."
        pick = []
    }
}

/// Add a cloud disk, one step at a time: choose a provider (what each
/// offers is on its card) → connect (sign in on the web, a WebDAV server or a
/// folder, with checks next to each field) → a summary of what Apex will show.
struct AddCloudSheet: View {
    enum Method: String, CaseIterable { case web = "Sign in on the web", webdav = "WebDAV server", folder = "Folder on this Mac" }
    enum Step { case choose, connect, summary }
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.choose
    @State private var provider: CloudProvider?
    @State private var search = ""
    @State private var method = Method.web
    @State private var name = ""
    @State private var url = "https://"
    @State private var user = ""
    @State private var password = ""
    @State private var folder = ""
    @State private var testing = false
    enum Tested { case ok(String), failed(String) }
    @State private var tested: Tested?
    @State private var signIn: (page: String, store: UUID)?

    private static let other = CloudProvider(name: "Other provider", note: "Any service with a storage page or a WebDAV address.",
                                             storagePage: "https://", webdav: "https://", appFolder: nil)
    private var all: [CloudProvider] { CloudCatalog.providers + [Self.other] }

    init() {}
    /// Opened at a later step (off-screen render tests).
    init(step: Step, provider p: CloudProvider, method m: Method? = nil) {
        _step = State(initialValue: step)
        _provider = State(initialValue: p)
        _name = State(initialValue: p.name)
        let ms = (p.storagePage != nil ? [Method.web] : []) + (p.webdav != nil ? [.webdav] : []) + [.folder]
        let chosen = m ?? ms[0]
        _method = State(initialValue: chosen)
        _url = State(initialValue: chosen == .web ? (p.storagePage ?? "https://") : (p.webdav ?? "https://"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Group {
                switch step {
                case .choose: chooseStep
                case .connect: connectStep
                case .summary: summaryStep
                }
            }
            .frame(height: 360, alignment: .top)
            footer
        }
        .padding(22).frame(width: 640)
        .animation(.easeInOut(duration: 0.18), value: step)
        .sheet(isPresented: Binding(get: { signIn != nil }, set: { if !$0 { signIn = nil } })) {
            if let si = signIn {
                WebStorageSheet(title: name, page: si.page, storeID: si.store) { q in
                    let s = CloudService(id: "custom:" + UUID().uuidString, name: name, kind: .web, webPage: si.page, webStore: si.store.uuidString)
                    CloudStore.shared.add(s, password: nil)
                    CloudStore.shared.connectWeb(s, page: si.page, store: si.store, quota: q)
                    dismiss()
                }
            }
        }
    }

    // MARK: Steps

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Add a Cloud Disk").font(.title3.weight(.semibold))
                Text(["1 · Choose the service", "2 · Connect it", "3 · Check and add"][step == .choose ? 0 : step == .connect ? 1 : 2])
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search services", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { p in
                        Button { choose(p) } label: { card(p) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func card(_ p: CloudProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.name).font(.headline)
            if !p.note.isEmpty { Text(p.note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            HStack(spacing: 4) {
                if p.appFolder != nil { badge("Mac app", "app.badge.checkmark") }
                if p.storagePage != nil { badge("Web sign-in", "globe") }
                if p.webdav != nil { badge("WebDAV", "server.rack") }
            }
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(provider?.name == p.name ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(provider?.name == p.name ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption2).labelStyle(.titleAndIcon)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.07), in: Capsule())
    }

    @ViewBuilder private var connectStep: some View {
        if let p = provider {
            VStack(alignment: .leading, spacing: 12) {
                if p.appFolder != nil {
                    Label("Its Mac app adds \(p.name) here by itself once installed and signed in. Connecting here adds online storage figures.", systemImage: "app.badge.checkmark")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if methods(p).count > 1 {
                    Picker("How", selection: $method) { ForEach(methods(p), id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
                Form {
                    field { TextField("Name", text: $name) } error: { name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give it a name." : nil }
                    switch method {
                    case .web:
                        field { TextField("Storage page", text: $url) } error: { urlError }
                        Text("You sign in on the service’s own page, inside Apex. Apex reads the “used of total” line there; nothing is changed.").settingsCaption()
                    case .webdav:
                        field { TextField("WebDAV address", text: $url) } error: { urlError }
                        TextField("User name", text: $user)
                        SecureField("Password or app password", text: $password)
                        HStack {
                            Button(testing ? "Checking…" : "Test Connection") { test() }.disabled(testing || URL(string: url)?.host == nil)
                            switch tested {
                            case .ok(let t): Label(t, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                            case .failed(let t): Label(t, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                            case nil: EmptyView()
                            }
                        }
                    case .folder:
                        field { HStack { TextField("Folder", text: $folder).disabled(true); Button("Choose…") { chooseFolder() } } }
                            error: { folder.isEmpty ? "Choose the folder it syncs into." : nil }
                    }
                }
                .formStyle(.grouped).scrollDisabled(true).scrollContentBackground(.hidden).padding(.horizontal, -20)
            }
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.title2.bold())
                if let p = provider, p.name != name { Text(p.name).foregroundStyle(.secondary) }
                if method != .folder { Text(url).font(.callout).foregroundStyle(.secondary) }
            }
            Text("What Apex will show").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                switch method {
                case .web:
                    point("globe", "Online storage: used of total, read from \(host(url)) after you sign in")
                    point("lock", "Your sign-in stays in Apex’s own browser storage for this service")
                case .webdav:
                    point("server.rack", "Online storage: used of total, read live from the WebDAV server")
                    point("key", "Your password is kept in your keychain")
                case .folder:
                    point("folder", "What’s in “\((folder as NSString).lastPathComponent)” on this Mac, and what’s online-only")
                }
                point("checkmark.circle", "A tab under Cloud Disks; nothing is changed on the service")
            }
            .font(.callout)
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        GridRow {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if step != .choose { Button("Back") { step = step == .summary ? .connect : .choose } }
            switch step {
            case .choose: Button("Continue") { step = .connect }.keyboardShortcut(.defaultAction).disabled(provider == nil)
            case .connect: Button("Continue") { step = .summary }.keyboardShortcut(.defaultAction).disabled(!connectReady)
            case .summary: Button(method == .web ? "Sign In…" : "Add") { add() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Checks

    /// A field with its problem written right under it.
    private func field<F: View>(@ViewBuilder _ f: () -> F, error: () -> String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            f()
            if let e = error() { Text(e).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var urlError: String? { Self.addressProblem(url) }

    /// What's wrong with a service address, written for the field. Pure: tested.
    static func addressProblem(_ s: String) -> String? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), let scheme = u.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let h = u.host, h.contains(".") || h == "localhost" else {
            return "Enter the full address, starting with https://"
        }
        return scheme == "http" ? "This address isn’t encrypted (http). Use https:// if the service offers it." : nil
    }

    private var connectReady: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch method {
        case .folder: return !folder.isEmpty
        default: return URL(string: url)?.host != nil
        }
    }

    private func host(_ s: String) -> String { URL(string: s)?.host ?? s }

    private func methods(_ p: CloudProvider) -> [Method] {
        (p.storagePage != nil ? [.web] : []) + (p.webdav != nil ? [.webdav] : []) + [.folder]
    }

    private func choose(_ p: CloudProvider) {
        provider = p; tested = nil
        name = p.name == Self.other.name ? "" : p.name
        method = methods(p).first ?? .folder
        url = method == .web ? (p.storagePage ?? "https://") : (p.webdav ?? "https://")
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { folder = u.path; if name.isEmpty { name = u.lastPathComponent } }
    }

    private func test() {
        testing = true; tested = nil
        Task {
            switch await Cloud.quota(url: url, username: user, password: password) {
            case .success(let q): tested = .ok("Connected: \(Fmt.diskBytes(q.used)) used" + (q.total.map { " of \(Fmt.diskBytes($0))" } ?? ""))
            case .failure(let e): tested = .failed(e.localizedDescription)
            }
            testing = false
        }
    }

    private func add() {
        let id = "custom:" + UUID().uuidString
        switch method {
        case .web: signIn = (url, UUID())
        case .webdav:
            CloudStore.shared.add(CloudService(id: id, name: name, kind: .webdav, url: url, username: user), password: password)
            dismiss()
        case .folder:
            CloudStore.shared.add(CloudService(id: id, name: name, kind: .folder, path: folder), password: nil)
            dismiss()
        }
    }
}

/// The service's app is signed out or not open: say so, with a button to open it.
struct AppProblemBanner: View {
    let problem: CloudUpload.AppProblem
    let service: CloudService

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: problem == .signedOut ? "person.crop.circle.badge.exclamationmark" : "app.badge")
                .font(.title3).foregroundStyle(.orange)
            Text(CloudUpload.appMessage(problem, service: service.name)).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let url = CloudUpload.appURL(service) {
                Button("Open \(service.name)") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Words for the offload card. Pure: tested.
enum OffloadText {
    static func lastRun(_ st: CloudStore.OffloadState) -> String {
        if st.watchOnly {
            if st.total == 0 { return "Last check: everything on this Mac is in the cloud." }
            var t = "Last check: \(st.done) of \(st.total) uploaded"
            if let f = st.finished { t += " in " + CloudUpload.duration(f.timeIntervalSince(st.started)) }
            if st.waiting > 0 { t += ". \(st.waiting) still waiting" + (st.stalled ? " (nothing went up for 15 minutes)" : "") }
            return t
        }
        var t = "Last run: \(st.done) offloaded, \(Fmt.diskBytes(st.freed)) freed"
        if let f = st.finished { t += " in " + CloudUpload.duration(f.timeIntervalSince(st.started)) }
        if let a = st.uploadingSince, let b = st.uploadsFinished { t += " (waited \(CloudUpload.duration(b.timeIntervalSince(a))) for uploads)" }
        let left = st.waiting + st.failed
        if left > 0 {
            let why = st.stopped ? "you stopped waiting" : st.stalled ? "nothing went up for 15 minutes" : (st.lastError ?? "not uploaded yet")
            t += ". \(left) left on this Mac (\(why))"
        }
        return t
    }

    /// "Can't reach 10.0.0.20 for 2 min" / "Connected to 10.0.0.20 · 8 ms". Pure: tested.
    static func connection(_ st: CloudStore.OffloadState, now: Date = Date()) -> (ok: Bool?, text: String, fix: String?) {
        guard st.checkedServer, let server = st.server else { return (nil, "Checking the connection to the server…", nil) }
        if let ms = st.latency { return (true, "Connected to \(server) · \(Int(ms.rounded())) ms", nil) }
        let since = st.downSince.map { " for " + CloudUpload.duration(now.timeIntervalSince($0)) } ?? ""
        let fix = st.networkHint ?? "Check that the server is on and this Mac is online."
        return (false, "Can’t reach \(server)\(since), so uploads are paused", fix + " Apex keeps waiting and carries on by itself.")
    }

    /// The short paused line. Pure: tested.
    static func paused(_ st: CloudStore.OffloadState) -> String {
        if st.checkedServer, st.latency == nil, let server = st.server {
            return "Can’t connect to \(server) · Uploading is paused"
        }
        return st.checkedServer || !st.watchOnly ? "Uploading is paused" : "Uploading is paused · checking the connection…"
    }

    static let pausedHelp = "Apex carries on by itself when the connection is back or uploads start moving again. Or press Resume."

    static func speed(_ st: CloudStore.OffloadState) -> String {
        guard let r = st.rate else { return "Measuring upload speed…" }
        var t = "↑ " + Fmt.rate(r)
        if let left = st.timeLeft { t += " · about \(CloudUpload.duration(left)) left" }
        else if r < 1_000 { t += " · not sending right now" }
        return t
    }
}

/// While Offload waits for uploads: how long it's been going, what's left,
/// the service's upload speed over the last 3 minutes, and the server's state.
struct UploadMonitor: View {
    let state: CloudStore.OffloadState
    let service: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(state.paused ? "Uploads to \(service) · paused"
                      : state.appProblem == .signedOut ? "Uploads to \(service) · signed out"
                      : state.appProblem == .notOpen ? "Uploads to \(service) · app not open" : "Uploading to \(service)",
                      systemImage: state.paused ? "pause.circle" : state.appProblem != nil ? "exclamationmark.circle" : "arrow.up.circle").font(.headline)
                    .contentTransition(.opacity)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("for " + CloudUpload.duration(ctx.date.timeIntervalSince(state.uploadingSince ?? ctx.date)))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 18) {
                stat("Files left", "\(state.waiting)")
                if state.failed > 0 { stat("Couldn’t upload", "\(state.failed)") }
                stat("Size left", Fmt.diskBytes(state.waitingBytes))
                stat("Sending now", "\(state.sendingNow)")
                stat("Speed", state.rate.map { Fmt.rate($0) } ?? "—")
                stat("Time left", state.timeLeft.map { "~" + CloudUpload.duration($0) } ?? "—")
            }
            LineGraph(series: [GraphSeries(values: state.rateHistory, color: .accentColor)], maxValue: nil)
                .environment(\.graphUnit, .rate)
                .frame(height: 70)
            if !state.failedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn’t upload (\(state.failedFiles.count))").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    ForEach(state.failedFiles.sorted { $0.key < $1.key }.prefix(5), id: \.key) { name, why in
                        HStack(spacing: 6) {
                            UploadDot(dot: .failed(why), service: service)
                            Text(name).lineLimit(1).truncationMode(.middle)
                            Text(why).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                        .font(.caption)
                    }
                    if state.failedFiles.count > 5 { Text("and \(state.failedFiles.count - 5) more").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(state.paused ? "Paused: Apex isn’t reading the upload speed."
                 : state.appProblem != nil ? "Nothing can go up until then. Apex keeps waiting." : OffloadText.speed(state))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let note = state.resumeNote, !state.paused {
                Label(note, systemImage: "play.circle.fill").font(.caption).foregroundStyle(.green)
                    .transition(.opacity)
            }
            let c = OffloadText.connection(state)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(c.ok == nil ? Color.secondary : c.ok! ? Color.green : Color.orange).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.text).font(.callout.weight(.medium)).foregroundStyle(c.ok == false ? Color.orange : Color.primary)
                    if let fix = c.fix {
                        Text(fix).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: c.ok)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit().contentTransition(.numericText())
        }
    }
}

/// Typing in a service's online storage (from its website or bill).
private struct EnterStorageSheet: View {
    let service: CloudService
    @Environment(\.dismiss) private var dismiss
    @State private var used = ""
    @State private var usedUnit = "GB"
    @State private var total = ""
    @State private var totalUnit = "GB"
    private let units = ["MB", "GB", "TB"]

    var body: some View {
        let u = CloudStore.bytes(used, unit: usedUnit), t = CloudStore.bytes(total, unit: totalUnit)
        let valid = u != nil && t != nil && t! > 0 && u! <= t!
        VStack(alignment: .leading, spacing: 14) {
            Text("\(service.name) storage").font(.title3.weight(.semibold))
            Text("Type what \(service.name)’s website shows, e.g. “81 GB of 100 GB used”. It appears on the Cloud Disks page.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Used").gridColumnAlignment(.trailing)
                    TextField("81", text: $used).frame(width: 110).multilineTextAlignment(.trailing)
                    Picker("", selection: $usedUnit) { ForEach(units, id: \.self) { Text($0) } }.labelsHidden().fixedSize()
                }
                GridRow {
                    Text("Plan size")
                    TextField("100", text: $total).frame(width: 110).multilineTextAlignment(.trailing)
                    Picker("", selection: $totalUnit) { ForEach(units, id: \.self) { Text($0) } }.labelsHidden().fixedSize()
                }
            }
            if let u, let t, t > 0, u > t {
                Text("Used can’t be more than the plan size.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let u, let t { CloudStore.shared.enterStorage(service, used: u, total: t) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// A file's upload at a glance, as a ring: green filling up while it
/// uploads, yellow stopped where it paused (server can't be reached, or
/// paused), red with an ✕ when it can't upload. Without a figure yet the
/// green ring turns.
struct UploadDot: View {
    let dot: CloudUpload.Dot
    let service: String
    var server: String?
    /// About how far it got (0–1), when known.
    var progress: Double? = nil
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2)
            switch dot {
            case .uploading where progress == nil:
                Circle().trim(from: 0, to: 0.3).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            case .uploading, .paused:
                Circle().trim(from: 0, to: max(0.02, progress ?? 0))
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
            case .failed:
                Circle().stroke(color, lineWidth: 2)
                Image(systemName: "xmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(color)
            }
        }
        .frame(width: 13, height: 13)
        .help(help)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel(help)
    }

    private var color: Color {
        switch dot {
        case .uploading: return .green
        case .paused: return .yellow
        case .failed: return .red
        }
    }

    private var pct: String { progress.map { " About \(Int(($0 * 100).rounded()))% sent." } ?? "" }

    private var help: String {
        switch dot {
        case .uploading: return "Uploading to \(service).\(pct) If you choose it, Apex makes it online-only as soon as the upload finishes."
        case .paused: return "Upload paused: " + (server.map { "can’t connect to \($0)." } ?? "can’t connect to the server.") + pct + " It carries on when the connection is back."
        case .failed(let why): return "Can’t upload. " + why
        }
    }
}

/// What the circles mean, under the file list.
private struct UploadDotLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(.uploading, 0.65, "Uploading")
            item(.paused, 0.4, "Paused where it got to")
            item(.failed(""), nil, "Can’t upload")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func item(_ d: CloudUpload.Dot, _ p: Double?, _ text: String) -> some View {
        HStack(spacing: 5) { UploadDot(dot: d, service: "", progress: p).allowsHitTesting(false); Text(text) }
    }
}
