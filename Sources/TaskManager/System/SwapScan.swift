import Foundation

/// Per-app split of memory between RAM and "compressed or swapped out".
///
/// macOS has no per-process swap counter. Apple's `footprint` tool can read,
/// for your own processes, how much of each one's memory is not resident in
/// RAM (compressed in memory or written to the swap file — macOS doesn't
/// separate the two per process). It walks the whole address space, so this
/// is an on-demand scan, never part of the regular sampling.
struct SwapEntry: Identifiable, Sendable {
    var id: String { key }
    let key: String          // bundle path, or process name for non-app processes
    var name: String
    let bundlePath: String
    var total: UInt64        // footprint, summed over the app's processes
    var swapped: UInt64      // compressed or in swap
    var processes: Int
    var inRAM: UInt64 { total > swapped ? total - swapped : 0 }
    var swappedShare: Double { total > 0 ? Double(swapped) / Double(total) * 100 : 0 }
}

enum SwapScan {
    /// Scans your processes (largest first) and groups helpers under their app.
    /// `onUpdate` receives the growing, sorted list as results arrive.
    static func run(_ procs: [ProcessInfoSample], limit: Int = 60,
                    onUpdate: @escaping @MainActor ([SwapEntry], _ done: Int, _ total: Int) -> Void) async {
        let me = getuid()
        let targets = Array(procs.filter { $0.uid == me && !$0.restricted && $0.memory > 15 << 20 }
            .sorted { $0.memory > $1.memory }
            .prefix(limit))
        // App display names for bundles (so helpers show as "Google Chrome").
        var appNames: [String: String] = [:]
        for p in procs where p.isRegularApp && !p.bundlePath.isEmpty { appNames[p.bundlePath] = p.name }
        let names = appNames

        var grouped: [String: SwapEntry] = [:]
        var done = 0
        await withTaskGroup(of: (ProcessInfoSample, (UInt64, UInt64)?).self) { group in
            var it = targets.makeIterator()
            // Three at a time: fast enough, without hogging every core.
            for _ in 0..<3 { if let p = it.next() { group.addTask { (p, scan(p.pid)) } } }
            while let (p, r) = await group.next() {
                done += 1
                if let (dirty, swapped) = r, dirty > 0 {
                    // Shared memory appears in every process that maps it, so raw
                    // per-process totals over-count when added up. Apply each
                    // process's swapped *share* to the memory it owns
                    // (phys_footprint, what the Memory column shows) instead.
                    let share = min(1, Double(swapped) / Double(dirty))
                    let total = p.memory
                    let swappedOwned = UInt64(saturating: Double(total) * share)
                    let key = p.appKey
                    var e = grouped[key] ?? SwapEntry(
                        key: key,
                        name: names[p.bundlePath] ?? (p.bundlePath.isEmpty ? p.name
                            : ((p.bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension),
                        bundlePath: p.bundlePath, total: 0, swapped: 0, processes: 0)
                    e.total += total; e.swapped += swappedOwned; e.processes += 1
                    grouped[key] = e
                }
                let snapshot = grouped.values.sorted { $0.swapped > $1.swapped }
                let d = done, t = targets.count
                await onUpdate(snapshot, d, t)
                if let next = it.next() { group.addTask { (next, scan(next.pid)) } }
            }
        }
    }

    /// (dirty, swapped) bytes for one process.
    private static func scan(_ pid: pid_t) -> (UInt64, UInt64)? {
        guard let out = Shell.capture("/usr/bin/footprint", ["--swapped", "-f", "bytes", String(pid)], allowFailure: true) else { return nil }
        return parseFootprint(out)
    }

    /// First "TOTAL" row: "<dirty> B  <swapped> B  <clean> B  <reclaimable> B  <regions>  TOTAL"
    static func parseFootprint(_ out: String) -> (UInt64, UInt64)? {
        for line in out.split(separator: "\n") where line.hasSuffix("TOTAL") {
            let nums = line.split(separator: " ").compactMap { UInt64($0) }
            guard nums.count >= 2 else { return nil }
            return (nums[0], nums[1])
        }
        return nil
    }
}
