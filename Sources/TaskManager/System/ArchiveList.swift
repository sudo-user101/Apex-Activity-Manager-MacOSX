import Foundation

/// What's inside an archive (zip, 7z, rar, tar, gz, xz, bz2, jar, cpio, iso,
/// xar…), read with macOS's own archive library (the one behind `tar`),
/// without unpacking it. One file can be taken out to open or copy it.
enum ArchiveList {
    struct Item: Equatable, Sendable {
        var path: String        // inside the archive, "folder/file.txt" (no leading "./" or "/")
        var size: UInt64
        var isFolder: Bool
        var modified: Date?
    }

    enum Failure: Error, LocalizedError {
        case unavailable, unreadable(String), needsPassword
        var errorDescription: String? {
            switch self {
            case .unavailable: return "macOS’s archive reader isn’t available."
            case .unreadable(let why): return why.isEmpty ? "This archive couldn’t be read." : "This archive couldn’t be read: \(why)"
            case .needsPassword: return "This file is protected with a password."
            }
        }
    }

    static let extensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "xz", "txz", "bz2", "tbz", "tbz2", "lz", "lzma",
                                          "zst", "jar", "cpio", "xar", "iso", "cab", "lha", "lzh", "alfredworkflow"]

    /// An archive Apex can look inside (by name; `.tar.gz` and friends included).
    static func isArchive(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    // libarchive, loaded once from macOS. Its functions, by name.
    private typealias New = @convention(c) () -> OpaquePointer?
    private typealias OnArchive = @convention(c) (OpaquePointer?) -> Int32
    private typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    private typealias NextHeader = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias EntryText = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias EntryInt = @convention(c) (OpaquePointer?) -> Int64
    private typealias EntryMode = @convention(c) (OpaquePointer?) -> UInt16
    private typealias ErrorText = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias ReadData = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    private typealias AddPassphrase = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32

    private struct Lib: @unchecked Sendable {
        let new: New, filters: OnArchive, formats: OnArchive, open: Open, next: NextHeader, skip: OnArchive, free: OnArchive
        let pathUTF8: EntryText, path: EntryText, size: EntryInt, mtime: EntryInt, type: EntryMode, error: ErrorText, read: ReadData
        let passphrase: AddPassphrase?
    }

    private static let lib: Lib? = {
        guard let h = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW) else { return nil }
        func f<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let new = f("archive_read_new", New.self), let filters = f("archive_read_support_filter_all", OnArchive.self),
              let formats = f("archive_read_support_format_all", OnArchive.self), let open = f("archive_read_open_filename", Open.self),
              let next = f("archive_read_next_header", NextHeader.self), let skip = f("archive_read_data_skip", OnArchive.self),
              let free = f("archive_read_free", OnArchive.self), let pathUTF8 = f("archive_entry_pathname_utf8", EntryText.self),
              let path = f("archive_entry_pathname", EntryText.self), let size = f("archive_entry_size", EntryInt.self),
              let mtime = f("archive_entry_mtime", EntryInt.self), let type = f("archive_entry_filetype", EntryMode.self),
              let error = f("archive_error_string", ErrorText.self), let read = f("archive_read_data", ReadData.self) else { return nil }
        return Lib(new: new, filters: filters, formats: formats, open: open, next: next, skip: skip, free: free,
                   pathUTF8: pathUTF8, path: path, size: size, mtime: mtime, type: type, error: error, read: read,
                   passphrase: f("archive_read_add_passphrase", AddPassphrase.self))
    }()

    private static let ok: Int32 = 0, eof: Int32 = 1, warn: Int32 = -20, folderType: UInt16 = 0o040000

    /// Every item in the archive. Blocking; reads headers only (a compressed
    /// tar is still read through once). Stops after `limit` items.
    static func items(_ url: URL, limit: Int = 200_000, cancelled: () -> Bool = { false }) throws -> [Item] {
        guard let l = lib, let a = l.new() else { throw Failure.unavailable }
        defer { _ = l.free(a) }
        _ = l.filters(a); _ = l.formats(a)
        guard l.open(a, url.path, 1 << 16) == ok else { throw Failure.unreadable(l.error(a).map { String(cString: $0) } ?? "") }
        var out: [Item] = []
        var entry: OpaquePointer?
        while out.count < limit, !cancelled() {
            let r = l.next(a, &entry)
            if r == eof { break }
            guard r == ok || r == warn, let e = entry else {
                if out.isEmpty { throw Failure.unreadable(l.error(a).map { String(cString: $0) } ?? "") }
                break
            }
            let raw = (l.pathUTF8(e) ?? l.path(e)).map { String(cString: $0) } ?? ""
            let p = clean(raw)
            if !p.isEmpty {
                let m = l.mtime(e)
                // An archive can claim any size, and adding those up must not overflow.
                out.append(Item(path: p, size: UInt64(min(1 << 45, max(0, l.size(e)))), isFolder: l.type(e) == folderType || raw.hasSuffix("/"),
                                modified: m > 0 ? Date(timeIntervalSince1970: TimeInterval(m)) : nil))
            }
            _ = l.skip(a)
        }
        return out
    }

    /// Takes one file out of the archive to `destination`. Blocking.
    static func extract(_ url: URL, item path: String, to destination: URL, password: String? = nil) throws {
        guard let l = lib, let a = l.new() else { throw Failure.unavailable }
        defer { _ = l.free(a) }
        _ = l.filters(a); _ = l.formats(a)
        if let password { _ = l.passphrase?(a, password) }
        guard l.open(a, url.path, 1 << 16) == ok else { throw Failure.unreadable(l.error(a).map { String(cString: $0) } ?? "") }
        var entry: OpaquePointer?
        while true {
            let r = l.next(a, &entry)
            guard r == ok || r == warn, let e = entry else { break }
            let raw = (l.pathUTF8(e) ?? l.path(e)).map { String(cString: $0) } ?? ""
            guard clean(raw) == path else { _ = l.skip(a); continue }
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let out = try FileHandle(forWritingTo: destination)
            defer { try? out.close() }
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = buffer.withUnsafeMutableBytes { l.read(a, $0.baseAddress, $0.count) }
                if n == 0 { return }
                if n < 0 {
                    let why = l.error(a).map { String(cString: $0) } ?? ""
                    try? FileManager.default.removeItem(at: destination)
                    if why.lowercased().contains("passphrase") || why.lowercased().contains("encrypt") { throw Failure.needsPassword }
                    throw Failure.unreadable(why)
                }
                do { try out.write(contentsOf: Data(buffer[0..<n])) } catch {   // a full disk, for one
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
            }
        }
        throw Failure.unreadable("“\((path as NSString).lastPathComponent)” isn’t in it.")
    }

    /// "./a/b/" → "a/b". "..", "." and empty parts are dropped, so a name in
    /// an archive can never point outside the folder it's opened into
    /// ("../../.zshrc" → ".zshrc"). Pure: tested.
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    /// The items directly inside `folder` ("" = the top), each subfolder with
    /// the total of everything under it, including folders the archive only
    /// implies by its file paths. Pure: tested.
    static func children(of folder: String, in items: [Item]) -> [Item] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var files: [String: Item] = [:]
        var folders: [String: (size: UInt64, modified: Date?)] = [:]
        for i in items where i.path.hasPrefix(prefix) && i.path.count > prefix.count {
            let rest = String(i.path.dropFirst(prefix.count))
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[..<slash])
                var f = folders[name] ?? (0, nil)
                let sum = f.size.addingReportingOverflow(i.isFolder ? 0 : i.size)
                f.size = sum.overflow ? .max : sum.partialValue
                folders[name] = f
            } else if i.isFolder {
                var f = folders[rest] ?? (0, nil)
                f.modified = i.modified
                folders[rest] = f
            } else {
                files[rest] = i
            }
        }
        return folders.map { Item(path: prefix + $0.key, size: $0.value.size, isFolder: true, modified: $0.value.modified) }
            + files.values.map { $0 }
    }
}
