import AppKit
import Security

/// What macOS itself lists in System Settings › General › Login Items.
/// Apps that open at login come from System Events (no password). The rest
/// is in macOS's Background Task Management database (`sfltool dumpbtm`),
/// which since macOS 15.7 needs the administrator password, so it's read only
/// when asked (Startup › Show Background Items), about 4 s:
///  * apps that **open at login**,
///  * login items, agents and daemons apps registered to run **in the
///    background** (often from inside the app bundle, so they have no plist
///    in a LaunchAgents folder).
/// Older plist agents and daemons are already listed from their folders, so
/// they're skipped here.
struct BTMRecord: Hashable, Sendable {
    enum Kind: String, Sendable { case app, loginItem, agent, daemon, legacy, other }
    var name: String
    var developer: String
    var kind: Kind
    var enabled: Bool
    var url: String             // file:///… for apps; a path inside the parent bundle for embedded items
    var identifier: String      // "2.com.vendor.app"
    var bundleID: String
    var parent: String          // parent's identifier, for embedded items
}

enum BackgroundItems {
    static func read() -> [BTMRecord] {
        guard let out = Shell.capture("/usr/bin/sfltool", ["dumpbtm"]) else { return [] }
        return parse(out, uid: getuid())
    }

    /// Records for this user (and the system), from `sfltool dumpbtm` text.
    static func parse(_ text: String, uid: uid_t) -> [BTMRecord] {
        var out: [BTMRecord] = []
        var inScope = false
        var cur: [String: String] = [:]
        func flush() {
            defer { cur = [:] }
            guard inScope, let type = cur["Type"], let disp = cur["Disposition"] else { return }
            let kind: BTMRecord.Kind
            if type.hasPrefix("legacy") { kind = .legacy }
            else if type.hasPrefix("app") { kind = .app }
            else if type.hasPrefix("login item") { kind = .loginItem }
            else if type.hasPrefix("agent") { kind = .agent }
            else if type.hasPrefix("daemon") { kind = .daemon }
            else { kind = .other }
            func v(_ k: String) -> String { let x = cur[k] ?? ""; return x == "(null)" ? "" : x }
            out.append(BTMRecord(name: v("Name"), developer: v("Developer Name"), kind: kind,
                                 enabled: disp.hasPrefix("[enabled"), url: v("URL"), identifier: v("Identifier"),
                                 bundleID: v("Bundle Identifier"), parent: v("Parent Identifier")))
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                flush()
                let id = line.dropFirst("Records for UID ".count).prefix { $0 != " " }
                inScope = id == "\(uid)" || id == "0"
            } else if line.hasPrefix("#"), line.hasSuffix(":"), line.dropFirst().dropLast().allSatisfy(\.isNumber) {
                flush()
            } else if let colon = line.firstIndex(of: ":"), cur.isEmpty || !line.hasPrefix("#") {
                let key = String(line[..<colon]), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if cur[key] == nil { cur[key] = value }
            }
        }
        flush()
        // The same item can appear in the user's and the system's records.
        var seen = Set<String>()
        return out.filter { seen.insert($0.identifier + $0.url).inserted }
    }

    /// The background items (open-at-login apps come from System Events).
    static func startupItems(_ records: [BTMRecord], runningApps: [String: pid_t]) -> [StartupItem] {
        let byID = Dictionary(records.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
        return records.compactMap { r in
            switch r.kind {
            case .loginItem, .agent, .daemon:
                let parent = byID[r.parent]
                let parentPath = parent.flatMap { URL(string: $0.url)?.path } ?? ""
                let appName = parent?.name ?? ""
                let shortName = r.name.split(separator: ".").last.map(String.init) ?? r.name
                return StartupItem(label: r.bundleID.isEmpty ? r.name : r.bundleID, plistPath: "btm:" + r.identifier,
                                   scope: .background, enabled: r.enabled, running: false, pid: nil,
                                   displayName: appName.isEmpty ? shortName : "\(appName) (\(LabelDecoder.words(shortName)))",
                                   vendor: r.developer.isEmpty ? (parent?.developer ?? "") : r.developer,
                                   program: parentPath.isEmpty ? r.url : parentPath + "/" + r.url, iconPath: parentPath)
            default:
                return nil
            }
        }
    }

    enum LoginApps: Sendable { case items([StartupItem]), refused(String) }

    /// Apps that open at login, from System Events (macOS asks once for
    /// permission to control it). Vendors come from each app's signature.
    static func loginApps(runningApps: [String: pid_t]) -> LoginApps {
        let script = """
        tell application "System Events"
        set out to ""
        repeat with i in every login item
        set out to out & (name of i) & tab & (path of i) & linefeed
        end repeat
        end tell
        return out
        """
        let r = Shell.run("/usr/bin/osascript", ["-e", script])
        if r.status != 0 {
            if r.stderr.contains("-1743") { return .refused("To list apps that open at login, allow Apex to control System Events: System Settings › Privacy & Security › Automation.") }
            return .refused(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).ifEmptyMessage("macOS didn’t give the list of login items."))
        }
        return .items(parseLoginApps(r.stdout).map { name, given in
            let path = given ?? appPath(named: name) ?? ""
            let bundleID = path.isEmpty ? "" : (Bundle(path: path)?.bundleIdentifier ?? "")
            let label = bundleID.isEmpty ? name : bundleID
            return StartupItem(label: label, plistPath: "login:" + label, scope: .openAtLogin, enabled: true,
                               running: runningApps[bundleID] != nil, pid: runningApps[bundleID], displayName: name,
                               vendor: vendor(appPath: path, bundleID: bundleID), program: path, iconPath: path)
        })
    }

    /// "Name<TAB>/path" lines; "missing value" when macOS has no path. Pure: tested.
    static func parseLoginApps(_ text: String) -> [(name: String, path: String?)] {
        var out: [(String, String?)] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = f.first, !name.isEmpty, seen.insert(name).inserted else { continue }
            let p = f.count > 1 ? f[1] : ""
            out.append((name, p.hasPrefix("/") ? p : nil))
        }
        return out
    }

    /// An app by name in the usual folders (for login items macOS gives no path for).
    static func appPath(named name: String) -> String? {
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications", "/Applications/Setapp", "/System/Applications"]
        return dirs.map { "\($0)/\(name).app" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Who made it: the organization in its signing certificate, else Apex's
    /// own vendor for CyberNet Labs apps, else the maker in its bundle ID.
    static func vendor(appPath: String, bundleID: String) -> String {
        if !appPath.isEmpty, let org = signingOrganization(appPath) { return org }
        return bundleID.isEmpty ? "" : LabelDecoder.decode(bundleID).vendor
    }

    /// "Developer ID Application: SuperUltra, Inc. (ABCDE12345)" → "SuperUltra, Inc.". Pure: tested.
    static func organization(fromCertificateSummary s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        var org = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if org.hasSuffix(")"), let open = org.lastIndex(of: "(") { org = org[..<open].trimmingCharacters(in: .whitespaces) }
        return org.isEmpty ? nil : org
    }

    private static func signingOrganization(_ path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first, let summary = SecCertificateCopySubjectSummary(leaf) as String?,
              summary.hasPrefix("Developer ID") || summary.hasPrefix("Apple Distribution") || summary.hasPrefix("3rd Party Mac Developer") else { return nil }
        if summary == "Software Signing" { return "Apple" }
        return organization(fromCertificateSummary: summary)
    }

    /// Open at Login on/off for an app, through System Events (macOS asks
    /// once for permission to control it). nil on success.
    static func setOpenAtLogin(_ on: Bool, name: String, path: String) -> String? {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = on
            ? "tell application \"System Events\" to make login item at end with properties {path:\"\(esc(path))\", hidden:false}"
            : "tell application \"System Events\" to delete login item \"\(esc(name))\""
        let r = Shell.run("/usr/bin/osascript", ["-e", script])
        if r.status == 0 { return nil }
        if r.stderr.contains("-1743") { return "Apex needs permission to control System Events: System Settings › Privacy & Security › Automation." }
        return r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).ifEmptyMessage("macOS refused the change.")
    }
}

private extension String {
    func ifEmptyMessage(_ s: String) -> String { isEmpty ? s : self }
}
