import Foundation

/// Minimal child-process helpers. Everything here is used sparingly (on demand
/// or for privileged data); routine metrics never shell out.
enum Shell {
    /// Runs a tool and returns stdout, or nil on launch failure / non-zero exit.
    static func capture(_ path: String, _ args: [String], allowFailure: Bool = false) -> String? {
        let r = run(path, args)
        guard r.launched, allowFailure || r.status == 0 else { return nil }
        return r.stdout
    }

    struct Result { var launched: Bool; var status: Int32; var stdout: String; var stderr: String }

    /// Writing to a program that has quit must fail, not stop Apex. Once, at launch.
    static func ignoreBrokenPipes() { signal(SIGPIPE, SIG_IGN) }

    /// False if the program didn't take it (it quit, usually). Its exit status says why.
    @discardableResult
    static func send(_ data: Data, to handle: FileHandle) -> Bool {
        (try? handle.write(contentsOf: data)) != nil
    }

    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(launched: false, status: -1, stdout: "", stderr: "\(error.localizedDescription)") }
        // Read both pipes before waiting so a chatty tool can't fill a pipe and deadlock.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Result(launched: true, status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Runs a shell command as root via the standard macOS admin password
    /// prompt. Blocking; call off the main thread.
    static func runAsAdmin(_ command: String, prompt: String? = nil) -> Result {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let p = prompt.map { " with prompt \"\(esc($0))\"" } ?? ""
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(esc(command))\"\(p) with administrator privileges"])
    }

    /// Single-quotes a value for safe use inside a /bin/sh command line.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isUserCancelled(_ r: Result) -> Bool {
        r.stderr.contains("-128") || r.stderr.localizedCaseInsensitiveContains("cancel")
    }
}
