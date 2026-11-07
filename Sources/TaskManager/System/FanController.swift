import AppKit
import CryptoKit
import Foundation
import FanControlCore

/// App side of fan control: installs/removes the privileged helper (one
/// administrator prompt each), writes the settings file it reads, and keeps
/// the heartbeat fresh while Apex runs. Quitting Apex (or the heartbeat going
/// stale) returns every fan to automatic.
@MainActor
@Observable
final class FanController {
    static let shared = FanController()

    private(set) var installed = FileManager.default.fileExists(atPath: FanControl.daemonPlist)
    var settings: [FanControl.FanSetting] = []
    private(set) var lastError: String?
    /// Battery charge limit (nil = off) and "charge to 100% now" override.
    private(set) var chargeLimit: Int?
    private(set) var chargeOverrideUntil: Date?
    private(set) var chargeSchedules: [FanControl.ChargeSchedule] = []
    private(set) var nightCharging: FanControl.NightCharging?
    /// Firmware that can only "hold" (disconnect the adapter): may the limit run the Mac on battery?
    private(set) var holdOnBattery = false
    /// Lid-closed mode, renewed by `LidAwake` (nil = off).
    private(set) var stayAwakeUntil: Date?
    /// What the helper actually did (read back from its status file).
    private(set) var status: FanControl.Status?

    init() {
        if let data = FileManager.default.contents(atPath: FanControl.configPath), let c = FanControl.decode(data) {
            chargeLimit = c.chargeLimit
            chargeOverrideUntil = c.chargeOverrideUntil
            chargeSchedules = c.chargeSchedules ?? []
            nightCharging = c.nightCharging
            holdOnBattery = c.holdOnBattery ?? false
        }
        refreshStatus()
        // Night charging keeps the battery full until the Mac is opened: tell the helper when that happens.
        screenWake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FanController.shared.markOpened() }
        }
    }

    /// Setup checks shown before charge control is trusted.
    /// Helper status is fresh (it writes every 10 s) → macOS lets it run in the background.
    var helperRunning: Bool { status.map { Date().timeIntervalSince($0.updated) < 30 } ?? false }
    /// The installed helper is as new as this Apex's (by `FanControl.helperVersion`,
    /// not by its bytes: every build changes those, and asking for the password
    /// after every build was the problem).
    var helperUpToDate: Bool {
        !FanControl.helperNeedsUpdate(running: status?.helperVersion, statusKnown: helperRunning)
    }
    /// Apex can write the settings file the helper reads.
    private(set) var settingsWritable = true

    func refreshStatus() {
        installed = FileManager.default.fileExists(atPath: FanControl.daemonPlist)
        if installed {
            settingsWritable = FileManager.default.isWritableFile(atPath: FanControl.configPath)
        }
        guard let d = FileManager.default.contents(atPath: FanControl.statusPath) else { status = nil; return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        status = try? dec.decode(FanControl.Status.self, from: d)
    }

    func setChargeLimit(_ limit: Int?) {
        chargeLimit = limit.map { min(max($0, FanControl.chargeLimitRange.lowerBound), FanControl.chargeLimitRange.upperBound) }
        chargeOverrideUntil = nil
        save()
    }

    /// Lets the battery charge to 100% once (for the next 24h or until full).
    func chargeToFullNow(_ on: Bool) {
        chargeOverrideUntil = on ? Date().addingTimeInterval(24 * 3600) : nil
        save()
    }
    func setSchedule(_ s: FanControl.ChargeSchedule) {
        if let i = chargeSchedules.firstIndex(where: { $0.id == s.id }) { chargeSchedules[i] = s } else { chargeSchedules.append(s) }
        save()
    }

    func removeSchedule(_ id: UUID) { chargeSchedules.removeAll { $0.id == id }; save() }

    func setNightCharging(_ n: FanControl.NightCharging?) { nightCharging = n; save() }

    func setHoldOnBattery(_ on: Bool) { holdOnBattery = on; save() }

    @ObservationIgnored private var screenWake: NSObjectProtocol?
    private func markOpened() {
        guard var n = nightCharging, n.enabled else { return }
        if case .keepFull = FanControl.nightPlan(n, now: Date()).phase {
            n.openedAt = Date(); nightCharging = n; save()
        }
    }

    /// What the helper is applying now (same rule it uses).
    var effectiveCharge: (limit: Int?, source: FanControl.LimitSource) {
        let cfg = FanControl.Config(chargeLimit: chargeLimit, chargeOverrideUntil: chargeOverrideUntil, chargeSchedules: chargeSchedules,
                                    nightCharging: nightCharging)
        return FanControl.effectiveLimit(cfg, overrideActive: (chargeOverrideUntil ?? .distantPast) > Date())
    }
    @ObservationIgnored private var heartbeat: Timer?

    func ensureSettings(for fans: [FanReading]) {
        for f in fans where !settings.contains(where: { $0.index == f.index }) {
            settings.append(FanControl.FanSetting(index: f.index, rpm: f.minRPM > 0 ? f.minRPM : 2000))
        }
        if let data = FileManager.default.contents(atPath: FanControl.configPath),
           let saved = FanControl.decode(data), settings.allSatisfy({ $0.mode == .auto }) {
            for s in saved.fans { if let i = settings.firstIndex(where: { $0.index == s.index }) { settings[i] = s } }
        }
    }

    func update(_ s: FanControl.FanSetting) {
        if let i = settings.firstIndex(where: { $0.index == s.index }) { settings[i] = s } else { settings.append(s) }
        save()
    }

    func applyToAll(_ change: (inout FanControl.FanSetting) -> Void) {
        for i in settings.indices { change(&settings[i]) }
        save()
    }

    /// Writes the settings with a fresh heartbeat; keeps refreshing it while
    /// any fan is under manual control.
    func save() {
        guard installed else { return }
        let cfg = FanControl.Config(heartbeat: Date(), fans: settings, chargeLimit: chargeLimit, chargeOverrideUntil: chargeOverrideUntil,
                                    chargeSchedules: chargeSchedules.isEmpty ? nil : chargeSchedules, nightCharging: nightCharging,
                                    stayAwakeUntil: stayAwakeUntil, holdOnBattery: holdOnBattery ? true : nil)
        write(cfg)
        heartbeat?.invalidate()
        heartbeat = nil
        if !cfg.allAutomatic {
            heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { FanController.shared.save() }
            }
        }
    }

    /// On quit: hand the fans straight back to macOS.
    func restoreAutomatic() {
        guard installed else { return }
        // Fans back to macOS; the charge limit, schedules and night charging
        // deliberately stay on (the helper runs them while Apex is closed).
        // Lid-closed mode ends: Apex isn't there to watch the apps.
        stayAwakeUntil = nil
        let cfg = FanControl.Config(heartbeat: Date(), fans: settings.map { var s = $0; s.mode = .auto; return s },
                                    chargeLimit: chargeLimit, chargeOverrideUntil: chargeOverrideUntil,
                                    chargeSchedules: chargeSchedules.isEmpty ? nil : chargeSchedules, nightCharging: nightCharging,
                                    holdOnBattery: holdOnBattery ? true : nil)
        write(cfg)
    }

    /// Lid-closed mode: keep the Mac awake until this time (nil = off).
    func setStayAwake(until: Date?) {
        guard until != stayAwakeUntil else { return }
        stayAwakeUntil = until
        save()
    }

    /// The settings folder belongs to root, so the file (owned by you) is
    /// rewritten in place; the helper ignores a half-written read.
    private func write(_ cfg: FanControl.Config) {
        guard let data = FanControl.encode(cfg) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: FanControl.configPath))
            lastError = nil; settingsWritable = true
        } catch {
            settingsWritable = false
            lastError = "Couldn’t save settings for the helper. Use Repair to fix its permissions."
        }
    }

    /// Copies the helper into place and starts it as a LaunchDaemon (admin prompt).
    func install() async {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "apex-fanhelper")?.path else {
            lastError = "The fan helper is missing from the app bundle."; return
        }
        guard let requirement = Self.helperRequirement else {
            lastError = "This copy of Apex isn’t signed, so it can’t check the helper before installing it."; return
        }
        let script = Self.installScript(helper: helper, user: NSUserName(), requirement: requirement)
        let r = await Task.detached {
            Shell.runAsAdmin(script, prompt: "Apex Activity Manager wants to install its hardware helper, which controls battery charging and fan speed. It runs in the background and can be removed at any time from Apex.")
        }.value
        if r.status == 0 { installed = true; lastError = nil; save(); refreshStatus() }
        else if !Shell.isUserCancelled(r) { lastError = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The helper must carry the same signing certificate as the Apex that's
    /// running. Taken from the running code, which another program can't change,
    /// so a helper swapped on disk doesn't pass. Nil for an unsigned copy.
    nonisolated static var helperRequirement: String? {
        var me: SecCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let leaf = ((info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return nil }
        let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(FanControl.daemonLabel)\" and certificate leaf = H\"\(sha1)\""
    }

    /// Runs as root after the password. Nothing is read from a place the user
    /// can change after the check: the helper is copied into a root-only folder
    /// and checked there, and the LaunchDaemon file is written by root itself.
    /// (A file in the user's temp folder could be swapped while the password
    /// box is open, and launchd would start whatever it named, as root.) Pure: tested.
    nonisolated static func installScript(helper: String, user: String, requirement: String) -> String {
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
            + "<plist version=\"1.0\"><dict><key>Label</key><string>\(FanControl.daemonLabel)</string>"
            + "<key>ProgramArguments</key><array><string>\(FanControl.helperPath)</string></array>"
            + "<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string></dict></plist>\n"
        let staged = FanControl.helperPath + ".new"
        let dir = (FanControl.configPath as NSString).deletingLastPathComponent
        return [
            "mkdir -p /Library/PrivilegedHelperTools \(Shell.quote(dir))",
            "rm -f \(staged)",
            "install -m 755 -o root -g wheel \(Shell.quote(helper)) \(staged)",
            "{ /usr/bin/codesign --verify --strict -R=\(Shell.quote(requirement)) \(staged) || { rm -f \(staged); echo 'The helper in this Apex has been changed, so it wasn’t installed. Reinstall Apex.' >&2; false; }; }",
            "mv -f \(staged) \(FanControl.helperPath)",
            "printf '%s' \(Shell.quote(plist)) > \(FanControl.daemonPlist)",
            "chown root:wheel \(FanControl.daemonPlist)", "chmod 644 \(FanControl.daemonPlist)",
            "touch \(Shell.quote(FanControl.configPath))",
            "chown \(Shell.quote(user)) \(Shell.quote(FanControl.configPath))", "chmod 644 \(Shell.quote(FanControl.configPath))",
            "launchctl bootout system/\(FanControl.daemonLabel) 2>/dev/null; launchctl bootstrap system \(FanControl.daemonPlist)",
        ].joined(separator: " && ")
    }

    /// Stops the helper (fans return to automatic, charging back to normal) and deletes it.
    func uninstall() async {
        chargeLimit = nil
        restoreAutomatic()
        // The settings file goes first: a helper that sees it gone hands charging back as it stops
        // (with it still there, it would leave a paused charge paused, as at shutdown).
        let script = [
            "rm -f \(Shell.quote(FanControl.configPath))",
            "launchctl bootout system/\(FanControl.daemonLabel) 2>/dev/null; true",
            "rm -f \(FanControl.daemonPlist) \(FanControl.helperPath) \(Shell.quote(FanControl.statusPath)) \(Shell.quote(FanControl.offRecordPath))",
        ].joined(separator: " && ")
        let r = await Task.detached {
            Shell.runAsAdmin(script, prompt: "Apex Activity Manager wants to remove its hardware helper. Charging and fans go back to normal.")
        }.value
        if r.status == 0 { installed = false; status = nil; heartbeat?.invalidate(); heartbeat = nil }
        else if !Shell.isUserCancelled(r) { lastError = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
