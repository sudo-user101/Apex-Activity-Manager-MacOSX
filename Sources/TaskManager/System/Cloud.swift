import Foundation
import Security

/// A cloud service Apex shows on Performance › Cloud: a folder macOS syncs
/// (iCloud Drive, ~/Library/CloudStorage: OneDrive, Google Drive, Dropbox,
/// Nextcloud…), or one the user added: any folder, or a WebDAV server
/// (Nextcloud, ownCloud, a NAS…) for its online quota.
struct CloudService: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case system, folder, webdav, web }
    var id: String
    var name: String
    var account: String = ""
    var kind: Kind
    var path: String = ""            // local folder, if any
    var url: String = ""             // WebDAV address
    var username: String = ""
    /// Web sign-in: the provider's storage page and this service's own browser data.
    var webPage: String? = nil
    var webStore: String? = nil

    var symbol: String {
        switch name {
        case "iCloud Drive": return "icloud"
        case "OneDrive", "Google Drive", "Dropbox", "Box", "Nextcloud": return "externaldrive.connected.to.line.below"
        default: return kind == .webdav ? "server.rack" : kind == .web ? "globe" : "folder"
        }
    }
}

/// What a scan found in a local cloud folder.
struct CloudUsage: Sendable, Equatable {
    var files = 0
    var onlineOnly = 0
    var totalBytes: UInt64 = 0        // everything, including online-only files
    var onMacBytes: UInt64 = 0        // what's actually stored on this Mac
    var largest: [CloudFile] = []     // biggest files stored on this Mac
    /// Files macOS says aren't in the cloud yet, and why the ones that are stuck are.
    var notUploaded = 0
    var notUploadedBytes: UInt64 = 0
    var uploadIssues: [String: Int] = [:]
    /// Stored on this Mac, already in the cloud, not opened for `Cloud.untouchedDays`:
    /// safe to make online-only. Biggest first, at most 500.
    var untouched: [CloudFile] = []
    var untouchedBytes: UInt64 = 0
    /// What's stored on this Mac, by kind of file ("Videos", "Photos"…).
    var kinds: [String: UInt64] = [:]
    /// Files whose upload state was read (changed in the last `Cloud.uploadCheckDays`),
    /// and whether there were more than `Cloud.uploadCheckLimit` of them.
    /// Folders whose contents aren't on this Mac (not listed: that would ask
    /// the server); what's in them isn't counted.
    var unlistedFolders = 0
    var uploadChecked = 0
    var uploadCheckLimited = false
    /// What fills the online storage, and what could go to free some.
    var space: CloudSpace?
    var partial = false
    var scanned = Date()
}

struct CloudFile: Identifiable, Sendable, Hashable {
    var id: String { path }
    let path: String
    let bytes: UInt64
    var uploading = false          // not in the cloud yet: can't be made online-only until it is
    var name: String { (path as NSString).lastPathComponent }
}

struct CloudQuota: Sendable, Equatable {
    var used: UInt64
    var available: UInt64?
    var total: UInt64? { available.map { used + $0 } }
}

enum Cloud {
    /// Services macOS syncs for this user.
    static func detected(home: String = NSHomeDirectory()) -> [CloudService] {
        var out: [CloudService] = []
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) {
            out.append(CloudService(id: "icloud", name: "iCloud Drive", kind: .system, path: icloud))
        }
        let base = home + "/Library/CloudStorage"
        for dir in ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted() where !dir.hasPrefix(".") {
            let (name, account) = providerName(dir)
            out.append(CloudService(id: "cs:" + dir, name: name, account: account, kind: .system, path: base + "/" + dir))
        }
        return out
    }

    /// "OneDrive-Personal" → ("OneDrive", "Personal"); "GoogleDrive-me@x.com" →
    /// ("Google Drive", "me@x.com"); "Nextcloud-host-user" → ("Nextcloud", "host-user"). Pure: tested.
    static func providerName(_ dir: String) -> (String, String) {
        let parts = dir.split(separator: "-", maxSplits: 1).map(String.init)
        let raw = parts[0], account = parts.count > 1 ? parts[1] : ""
        let known = ["OneDrive": "OneDrive", "GoogleDrive": "Google Drive", "Dropbox": "Dropbox", "Box": "Box",
                     "Nextcloud": "Nextcloud", "ownCloud": "ownCloud", "pCloud": "pCloud", "ProtonDrive": "Proton Drive",
                     "SynologyDrive": "Synology Drive", "MEGA": "MEGA"]
        let name = known[raw] ?? raw
        return (name, account == name ? "" : account)
    }

    /// Walks a folder: how much is stored on this Mac vs online only. Reading
    /// metadata never downloads anything. Blocking: call off the main thread.
    static func scan(_ path: String, cancelled: () -> Bool = { false }, now: Date = Date()) -> CloudUsage {
        var u = CloudUsage()
        // Upload state costs ~2 ms a file (macOS asks the service's sync
        // extension), sizes and dates ~0.03 ms: the walk reads only the cheap
        // ones, and upload state is read afterwards for the files it matters for.
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                      .contentAccessDateKey, .contentModificationDateKey]
        let root = URL(fileURLWithPath: path)
        let synced = (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        let cutoff = now.addingTimeInterval(-Double(untouchedDays) * 86400)
        let recentSince = now.addingTimeInterval(-Double(uploadCheckDays) * 86400)
        var untouched: [CloudFile] = []
        var recent: [(path: String, bytes: UInt64, changed: Date)] = []
        var space = CloudSpace.Builder(root: path, realRoot: SafeTrash.realPath(path), now: now)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else { return u }
        var biggest: [CloudFile] = []
        for case let url as URL in e {
            if cancelled() { u.partial = true; break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true, Dataless.folder(url.path) { e.skipDescendants(); u.unlistedFolders += 1; continue }
            guard v.isRegularFile == true else { continue }
            let logical = UInt64(v.fileSize ?? 0)
            let onMac = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            u.files += 1
            u.totalBytes += logical
            u.onMacBytes += onMac
            if logical > 0 && onMac == 0 { u.onlineOnly += 1 }
            if onMac > 0 { u.kinds[kind(of: url.pathExtension), default: 0] += onMac }
            let used = [v.contentAccessDate, v.contentModificationDate].compactMap { $0 }.max()
            space.add(CloudEntry(path: url.path, bytes: logical, onMac: onMac, lastUsed: used))
            if synced, let changed = v.contentModificationDate, changed > recentSince {
                recent.append((url.path, logical, changed))
                if recent.count > 2 * uploadCheckLimit {
                    recent.sort { $0.changed > $1.changed }; recent.removeLast(recent.count - uploadCheckLimit)
                    u.uploadCheckLimited = true
                }
            }
            if synced, onMac > 1_000_000, let used, used < cutoff {
                untouched.append(CloudFile(path: url.path, bytes: onMac))
                if untouched.count > 2000 { untouched.sort { $0.bytes > $1.bytes }; untouched.removeLast(1000) }
            }
            if onMac > 1_000_000 {
                biggest.append(CloudFile(path: url.path, bytes: onMac))
                if biggest.count > 200 { biggest.sort { $0.bytes > $1.bytes }; biggest.removeLast(100) }
            }
        }
        biggest = Array(biggest.sorted { $0.bytes > $1.bytes }.prefix(40))
        if synced {
            // Not uploaded yet: files changed lately (a file is uploaded after it changes), newest first.
            recent.sort { $0.changed > $1.changed }
            if recent.count > uploadCheckLimit { recent.removeLast(recent.count - uploadCheckLimit); u.uploadCheckLimited = true }
            for r in recent {
                if cancelled() { u.partial = true; break }
                let st = uploadState(r.path)
                guard st.uploaded == false else { continue }
                u.notUploaded += 1
                u.notUploadedBytes += r.bytes
                if let e = st.error as NSError? {
                    u.uploadIssues[uploadReason(domain: e.domain, code: e.code, text: e.localizedDescription), default: 0] += 1
                }
            }
            u.uploadChecked = recent.count
            for i in biggest.indices { biggest[i].uploading = uploadState(biggest[i].path).uploaded == false }
            // Safe to make online-only only once uploaded.
            for f in untouched.sorted(by: { $0.bytes > $1.bytes }) where u.untouched.count < 500 {
                if cancelled() { break }
                guard uploadState(f.path).uploaded == true else { continue }
                u.untouched.append(f)
                u.untouchedBytes += f.bytes
            }
        }
        u.largest = biggest
        let compare = CloudSpace.Comparer()
        u.space = space.finish(sameContent: { compare($0, $1) })
        u.scanned = Date()
        return u
    }

    /// Upload state is read for files changed in this many days, the newest
    /// `uploadCheckLimit` of them at most (about 10 s).
    static let uploadCheckDays = 30
    static let uploadCheckLimit = 5000

    /// One file's upload state, read fresh. Blocking (~2 ms).
    static func uploadState(_ path: String) -> (uploaded: Bool?, error: Error?) {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
        return (v?.ubiquitousItemIsUploaded, v?.ubiquitousItemUploadingError)
    }

    /// Files not opened for this many days count as "not used lately".
    static let untouchedDays = 90

    /// A stuck upload's error in a few plain words, for counting. Pure: tested.
    static func uploadReason(domain: String, code: Int, text: String) -> String {
        switch CloudUpload.problem(domain: domain, code: code, text: text) {
        case .blocked(let why), .failed(let why): return why
        case .signedOut: return "The app needs you to sign in again."
        default: return text
        }
    }

    /// Kind of file from its extension, for "what takes the space". Pure: tested.
    static func kind(of ext: String) -> String {
        switch ext.lowercased() {
        case "mov", "mp4", "m4v", "avi", "mkv", "webm", "mts", "3gp": return "Videos"
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw", "dng", "webp", "psd": return "Photos"
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac", "ogg": return "Music and audio"
        case "pdf", "doc", "docx", "pages", "txt", "rtf", "md", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "odt", "ods": return "Documents"
        case "zip", "rar", "7z", "gz", "tgz", "tar", "dmg", "iso", "pkg", "xz", "bz2": return "Archives and installers"
        default: return "Other"
        }
    }

    /// Desktop and Documents: are they inside a folder a cloud service
    /// syncs (iCloud's Desktop & Documents, or a provider's folder)? Pure
    /// apart from resolving the two links: tested with a fake home.
    static func personalFolders(home: String = NSHomeDirectory(), clouds: [CloudService]) -> [(name: String, inCloud: String?)] {
        func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        func inside(_ p: String, _ folder: String) -> Bool { p == folder || p.hasPrefix(folder + "/") }
        let icloudDocs = resolved(home + "/Library/Mobile Documents/com~apple~CloudDocs")
        return ["Desktop", "Documents"].map { name in
            let real = resolved(home + "/" + name)
            if inside(real, icloudDocs) { return (name, "iCloud Drive") }
            let owner = clouds.first { !$0.path.isEmpty && $0.kind == .system && inside(real, resolved($0.path)) }
            return (name, owner?.name)
        }
    }

    // MARK: Move to the Trash (cloud space suggestions)

    /// Finder's own Move to Trash for each file. A file the service won't
    /// let go to the Trash is left as it is (moving it by hand could download it).
    static func trash(_ items: [CloudEntry]) -> (moved: Int, freed: UInt64, failed: [String]) {
        var moved = 0, freed: UInt64 = 0, failed: [String] = []
        for f in items {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: f.path), resultingItemURL: nil); moved += 1; freed += f.bytes }
            catch { failed.append(f.name) }
        }
        return (moved, freed, failed)
    }

    // MARK: Offload everything

    enum EvictResult: Equatable, Sendable { case done, waitingForUpload, failed(String) }

    /// Every file stored on this Mac in the folder (to offload them all).
    static func storedFiles(_ path: String, cancelled: () -> Bool = { false }) -> [CloudFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                                                     options: [], errorHandler: { _, _ in true }) else { return [] }
        var out: [CloudFile] = []
        for case let url as URL in e {
            if cancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // Nothing in it is stored here: nothing to offload.
            if v.isDirectory == true, Dataless.folder(url.path) { e.skipDescendants(); continue }
            guard v.isRegularFile == true else { continue }
            let onMac = UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if onMac > 0 { out.append(CloudFile(path: url.path, bytes: onMac)) }
        }
        return out
    }

    /// Offloads one file. A file that isn't uploaded yet can't be: macOS keeps
    /// it so nothing is lost, and Apex tries again later.
    static func evict(_ f: CloudFile) -> EvictResult {
        let url = URL(fileURLWithPath: f.path)
        do {
            try FileManager.default.evictUbiquitousItem(at: url)
            return .done
        } catch {
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
            if let e = v?.ubiquitousItemUploadingError { return .failed("Upload problem: " + e.localizedDescription) }
            if v?.ubiquitousItemIsUploaded == false { return .waitingForUpload }
            // Uploaded, yet refused: the provider keeps it here (e.g. "always keep downloaded").
            return .failed("The cloud app keeps “\(f.name)” on this Mac (it may be set to always keep it downloaded).")
        }
    }

    // MARK: WebDAV quota (RFC 4331)

    static let quotaBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:quota-used-bytes/><d:quota-available-bytes/></d:prop></d:propfind>
    """

    /// Quota from a PROPFIND reply. Pure: tested. Negative "available" means unknown or unlimited.
    static func parseQuota(_ xml: String) -> CloudQuota? {
        func value(_ tag: String) -> Int64? {
            guard let r = xml.range(of: tag + ">", options: .caseInsensitive),
                  let end = xml.range(of: "</", range: r.upperBound..<xml.endIndex) else { return nil }
            return Int64(xml[r.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let used = value("quota-used-bytes") else { return nil }
        let avail = value("quota-available-bytes")
        return CloudQuota(used: UInt64(max(0, used)), available: avail.flatMap { $0 >= 0 ? UInt64($0) : nil })
    }

    static func quota(url: String, username: String, password: String) async -> Result<CloudQuota, Error> {
        guard let u = URL(string: url), ["https", "http"].contains(u.scheme ?? "") else {
            return .failure(err("That doesn’t look like a web address (https://…)."))
        }
        // A password over plain http can be read by anyone on the network: only https carries one.
        if !username.isEmpty, u.scheme == "http" {
            return .failure(err("Use the https:// address. Over http:// your password would cross the network readable by anyone on it."))
        }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "PROPFIND"
        req.setValue("0", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(quotaBody.utf8)
        if !username.isEmpty {
            req.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return .failure(err("The server didn’t accept the user name or password.")) }
            guard code == 207 || code == 200 else { return .failure(err("The server answered \(code); check the address.")) }
            guard let q = parseQuota(String(decoding: data, as: UTF8.self)) else {
                return .failure(err("The server doesn’t report its storage quota."))
            }
            return .success(q)
        } catch {
            return .failure(error)
        }
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "Apex", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// Passwords for added servers, in the login keychain (never in settings files).
/// macOS lets only the copy of Apex that saved an item read it (by its
/// signature): another copy on this Mac (an older install, a build) is
/// refused. So when an item belongs to another copy, this copy keeps its own
/// beside it (`account` + this copy's mark), and reads look there first.
enum Keychain {
    private static let service = "Apex Activity Manager"

    /// This copy's mark: its signing team, or its path for unsigned / ad-hoc copies.
    private static let copyMark: String = {
        var code: SecCode?, info: CFDictionary?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code {
            var st: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &st) == errSecSuccess, let st,
               SecCodeCopySigningInformation(st, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String {
                return "#" + team
            }
        }
        // FNV-1a of the path: the same on every launch (hashValue isn't).
        let h = Bundle.main.bundlePath.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return "#" + String(h, radix: 36)
    }()

    /// Saves it; the status says whether it worked (errSecSuccess).
    @discardableResult
    static func set(_ password: String, account: String) -> OSStatus {
        readings.forget(account)
        var status = write(password, account)
        if status == errSecDuplicateItem || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            status = write(password, account + copyMark)      // the plain one is another copy's
        }
        return status
    }

    private static func write(_ password: String, _ account: String) -> OSStatus {
        let base = query(account)
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String? { read(account: account).value }

    /// The value, or why not (errSecItemNotFound: never saved; anything else:
    /// saved, but this copy may not read it).
    static func read(account: String) -> (value: String?, status: OSStatus) {
        readings.answer(account) { lookUp(account) }
    }

    /// Reading an item another build saved shows macOS's password box, and Apex
    /// reads a server's token for every request. So each item is read once per
    /// launch, whatever the answer: the box can't keep coming back.
    static let readings = Readings()
    final class Readings: @unchecked Sendable {
        private var known: [String: (value: String?, status: OSStatus)] = [:]
        private let lock = NSLock()

        /// Held for the whole read, so two threads can't both show the box.
        func answer(_ account: String, read: () -> (value: String?, status: OSStatus)) -> (value: String?, status: OSStatus) {
            lock.lock(); defer { lock.unlock() }
            if let k = known[account] { return k }
            let r = read()
            if r.status != errSecItemNotFound { known[account] = r }
            return r
        }
        func forget(_ account: String) { lock.lock(); known[account] = nil; lock.unlock() }
    }

    private static func lookUp(_ account: String) -> (value: String?, status: OSStatus) {
        var first = errSecItemNotFound
        for a in [account + copyMark, account] {
            var q = query(a)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            let st = SecItemCopyMatching(q as CFDictionary, &out)
            if st == errSecSuccess, let d = out as? Data, let v = String(data: d, encoding: .utf8) { return (v, st) }
            if first == errSecItemNotFound { first = st }
        }
        return (nil, first)
    }

    static func remove(account: String) {
        readings.forget(account)
        SecItemDelete(query(account + copyMark) as CFDictionary)
        SecItemDelete(query(account) as CFDictionary)
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func describe(_ status: OSStatus) -> String { SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)" }
}
