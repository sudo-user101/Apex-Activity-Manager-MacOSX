import AppKit
import IOKit.ps

/// Energy › Stay Awake: keep the Mac awake on chosen days (lid open), and keep
/// chosen apps running with the lid closed: always on power, on battery only
/// if allowed and for at most an hour. Lid-closed staying awake is done by the
/// helper (root), which Apex renews every 30 s; it lapses on its own within
/// 3 minutes if Apex stops.
@MainActor @Observable
final class LidAwake {
    static let shared = LidAwake()
    static let renewEvery: TimeInterval = 30
    static let holdFor: TimeInterval = 180
    static let batteryChoices = [15, 30, 45, 60]

    // Settings (saved).
    var lidEnabled = UserDefaults.standard.bool(forKey: "lidAwake") { didSet { save(); evaluate() } }
    var apps: [String] = UserDefaults.standard.stringArray(forKey: "lidAwakeApps") ?? [] { didSet { save(); evaluate() } }
    var allowOnBattery = UserDefaults.standard.bool(forKey: "lidAwakeBattery") { didSet { save(); evaluate() } }
    /// Limited to an hour by `decide`. Don't set it inside its own didSet: in an
    /// @Observable class that calls didSet again, until the stack runs out.
    var batteryMinutes = UserDefaults.standard.object(forKey: "lidAwakeBatteryMinutes") as? Int ?? 60 { didSet { save(); evaluate() } }
    /// Weekdays (1 = Sunday … 7 = Saturday) to stay awake all day, lid open.
    var awakeDays: Set<Int> = Set(UserDefaults.standard.array(forKey: "awakeDays") as? [Int] ?? []) { didSet { save(); evaluate() } }

    // State.
    private(set) var active = false
    private(set) var reason = ""
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var onBatterySince: Date?
    @ObservationIgnored private var scheduledAwake = false

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.renewEvery, repeats: true) { _ in
            MainActor.assumeIsolated { LidAwake.shared.evaluate() }
        }
        evaluate()
    }

    /// Decides lid-closed staying awake. Pure: tested.
    static func decide(enabled: Bool, appRunning: Bool, onAC: Bool, allowOnBattery: Bool,
                       onBatterySince: Date?, batteryMinutes: Int, now: Date) -> Bool {
        guard enabled, appRunning else { return false }
        if onAC { return true }
        guard allowOnBattery, let since = onBatterySince else { return false }
        return now.timeIntervalSince(since) < Double(min(60, batteryMinutes)) * 60
    }

    func evaluate(now: Date = Date()) {
        // Days to stay awake (lid open): a plain power assertion, no helper needed.
        let today = Calendar.current.component(.weekday, from: now)
        if awakeDays.contains(today) {
            if !KeepAwake.shared.isOn { KeepAwake.shared.start(for: nil, keepDisplayOn: false); scheduledAwake = true }
        } else if scheduledAwake {
            KeepAwake.shared.stop(); scheduledAwake = false
        }

        let ac = Self.onAC()
        if ac { onBatterySince = nil } else if onBatterySince == nil { onBatterySince = now }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let mine = apps.filter(running.contains)
        let want = Self.decide(enabled: lidEnabled, appRunning: !mine.isEmpty, onAC: ac, allowOnBattery: allowOnBattery,
                               onBatterySince: onBatterySince, batteryMinutes: batteryMinutes, now: now)
        let helper = FanController.shared
        if want && !helper.installed {
            active = false
            reason = "Needs the Apex helper: install it from the battery icon first."
            return
        }
        helper.setStayAwake(until: want ? now.addingTimeInterval(Self.holdFor) : nil)
        active = want
        if want {
            reason = "Staying awake with the lid closed for " + mine.map(Self.name).joined(separator: ", ")
                + (ac ? "" : " (on battery, up to \(batteryMinutes) min)")
        } else if !lidEnabled {
            reason = ""
        } else if mine.isEmpty {
            reason = apps.isEmpty ? "Pick the apps to keep running." : "Waiting: none of the chosen apps are open."
        } else if !ac && !allowOnBattery {
            reason = "On battery: the Mac sleeps as usual when the lid closes."
        } else {
            reason = "On battery: the \(batteryMinutes)-minute allowance is used up."
        }
    }

    static func onAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    static func name(_ bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let n = app.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }

    private func save() {
        let u = UserDefaults.standard
        u.set(lidEnabled, forKey: "lidAwake")
        u.set(apps, forKey: "lidAwakeApps")
        u.set(allowOnBattery, forKey: "lidAwakeBattery")
        u.set(batteryMinutes, forKey: "lidAwakeBatteryMinutes")
        u.set(Array(awakeDays).sorted(), forKey: "awakeDays")
    }
}
