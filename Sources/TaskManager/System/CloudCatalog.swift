import Foundation

/// Cloud storage providers Apex knows how to connect, and how. Researched
/// list (2026); web addresses are the providers' own storage / plan pages,
/// which show "X GB of Y GB used" once signed in. Anything missing can be
/// added by address.
struct CloudProvider: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let note: String
    /// Its storage page (sign in once in Apex's browser; Apex reads the usage line).
    let storagePage: String?
    /// WebDAV address pattern, if the provider offers WebDAV (quota read live).
    let webdav: String?
    /// The name its Mac app uses in ~/Library/CloudStorage, if it has one.
    let appFolder: String?
}

enum CloudCatalog {
    static let providers: [CloudProvider] = [
        .init(name: "Google (Drive, Gmail, Photos)", note: "One storage shared by Gmail, Drive and Photos.",
              storagePage: "https://one.google.com/storage", webdav: nil, appFolder: "Google Drive"),
        .init(name: "Microsoft OneDrive", note: "Includes Outlook.com attachments.",
              storagePage: "https://onedrive.live.com/?v=managestorage", webdav: nil, appFolder: "OneDrive"),
        .init(name: "iCloud", note: "Shared by iCloud Drive, Photos, Mail and backups.",
              storagePage: "https://www.icloud.com/settings/", webdav: nil, appFolder: "iCloud Drive"),
        .init(name: "Dropbox", note: "", storagePage: "https://www.dropbox.com/account/plan", webdav: nil, appFolder: "Dropbox"),
        .init(name: "Box", note: "", storagePage: "https://app.box.com/account", webdav: nil, appFolder: "Box"),
        .init(name: "MEGA", note: "", storagePage: "https://mega.nz/fm/account", webdav: nil, appFolder: "MEGA"),
        .init(name: "pCloud", note: "", storagePage: "https://my.pcloud.com/#page=settings",
              webdav: "https://webdav.pcloud.com", appFolder: "pCloud"),
        .init(name: "Proton Drive", note: "Shared with Proton Mail.", storagePage: "https://account.proton.me/drive/dashboard",
              webdav: nil, appFolder: "Proton Drive"),
        .init(name: "Sync.com", note: "", storagePage: "https://cp.sync.com/account/info", webdav: nil, appFolder: nil),
        .init(name: "Tresorit", note: "", storagePage: "https://web.tresorit.com/settings", webdav: nil, appFolder: nil),
        .init(name: "IDrive", note: "", storagePage: "https://www.idrive.com/idrive/home", webdav: nil, appFolder: nil),
        .init(name: "Icedrive", note: "", storagePage: "https://icedrive.net/dashboard",
              webdav: "https://webdav.icedrive.io", appFolder: nil),
        .init(name: "Koofr", note: "", storagePage: "https://app.koofr.net/app/storage",
              webdav: "https://app.koofr.net/dav/Koofr", appFolder: nil),
        .init(name: "Yandex Disk", note: "", storagePage: "https://disk.yandex.com/client/disk",
              webdav: "https://webdav.yandex.com", appFolder: nil),
        .init(name: "Jottacloud", note: "", storagePage: "https://www.jottacloud.com/web/settings", webdav: nil, appFolder: nil),
        .init(name: "Filen", note: "", storagePage: "https://app.filen.io/#/settings/account", webdav: nil, appFolder: nil),
        .init(name: "TeraBox", note: "", storagePage: "https://www.terabox.com/main", webdav: nil, appFolder: nil),
        .init(name: "Nextcloud", note: "Your own or a hosted server.", storagePage: nil,
              webdav: "https://SERVER/remote.php/dav/files/USERNAME/", appFolder: "Nextcloud"),
        .init(name: "ownCloud", note: "", storagePage: nil, webdav: "https://SERVER/remote.php/webdav/", appFolder: "ownCloud"),
        .init(name: "Seafile", note: "", storagePage: nil, webdav: "https://SERVER/seafdav", appFolder: nil),
        .init(name: "Synology (NAS)", note: "WebDAV Server package on the NAS.", storagePage: nil,
              webdav: "https://NAS-ADDRESS:5006/", appFolder: "Synology Drive"),
    ]

    /// The catalogue entry for a detected service ("Google Drive", "OneDrive"…).
    static func provider(for serviceName: String) -> CloudProvider? {
        providers.first { $0.appFolder == serviceName }
    }

    /// "X GB of Y GB used" (and similar) in a storage page's text → bytes.
    /// Handles "of", "/", "out of", "von", "de"; decimal commas; KB…TB and
    /// GiB-style units. The largest "total" wins (pages also show per-app
    /// splits). Pure: tested.
    static func parseUsage(_ text: String) -> CloudQuota? {
        let unit = "(KB|MB|GB|TB|PB|KiB|MiB|GiB|TiB|Ko|Mo|Go|To)"
        let num = "([0-9]+(?:[.,][0-9]+)?)"
        let pattern = num + "\\s*" + unit + "\\s*(?:used\\s*)?(?:of|out of|/|von|de|di|van|из)\\s*" + num + "\\s*" + unit
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        var best: CloudQuota?
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func value(_ n: Int, _ u: Int) -> UInt64? {
                let raw = ns.substring(with: m.range(at: n)).replacingOccurrences(of: ",", with: ".")
                guard let v = Double(raw) else { return nil }
                return UInt64(saturating: v * multiplier(ns.substring(with: m.range(at: u))))
            }
            guard let used = value(1, 2), let total = value(3, 4), total > 0, used <= total else { continue }
            if best == nil || total > (best!.total ?? 0) { best = CloudQuota(used: used, available: total - used) }
        }
        return best
    }

    static func multiplier(_ unit: String) -> Double {
        switch unit.uppercased().prefix(1) {
        case "K": return 1e3
        case "M": return 1e6
        case "G": return 1e9
        case "T": return 1e12
        case "P": return 1e15
        default: return 1
        }
    }
}
