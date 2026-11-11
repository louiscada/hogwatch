import Darwin
import Foundation

enum RowKind {
    /// An ordinary app or process: can be quit and force quit.
    case app
    /// Finder and the Dock: macOS relaunches them straight away.
    case restartable
    /// Part of macOS running under your account (loginwindow, Control Center…).
    /// Killing these can log you out, so they are shown but cannot be quit.
    case protected
    /// Everything that runs as the system rather than as you
    /// (kernel_task, WindowServer…), rolled into one row.
    case system
}

/// One row in the panel: an app (with all its helper processes rolled in),
/// a standalone process, or the combined system row.
struct AppUsage: Identifiable {
    /// The .app bundle path, "pid:<n>" for a process outside any bundle,
    /// or "system".
    let id: String
    let name: String
    /// File whose icon represents this row; nil for the system row.
    let iconPath: String?
    let pids: [pid_t]
    /// Summed across processes; 100 = one full core, like Activity Monitor.
    let cpuPercent: Double
    /// Summed physical footprint, the figure Activity Monitor calls "Memory".
    let memoryBytes: UInt64
    let kind: RowKind
}

/// Samples per-process CPU time and memory with libproc and groups helper
/// processes under the app they belong to.
///
/// Built to be cheap: one system call per process per sample. The name,
/// path and owner of a process are looked up once and cached for its lifetime.
final class ProcessSampler {
    private struct Identity {
        let startTime: UInt64
        let owned: Bool
        let key: String
        let name: String
        let iconPath: String
        let kind: RowKind
    }

    private struct Group {
        var key: String
        var name: String
        var iconPath: String
        var kind: RowKind
        var pids: [pid_t] = []
        var cpu: Double = 0
        var memory: UInt64 = 0
    }

    private var identities: [pid_t: Identity] = [:]
    private var previousCPU: [pid_t: UInt64] = [:]
    private var currentCPU: [pid_t: UInt64] = [:]
    private var seen = Set<pid_t>()
    private var groups: [Group] = []
    private var groupIndex: [String: Int] = [:]
    /// Recent (time, CPU time) readings for hogwatch itself, oldest first.
    private var ownHistory: [(uptime: UInt64, cpu: UInt64)] = []
    private static let ownHistoryLength = 30

    /// What hogwatch itself is using, so it can report its own cost.
    /// CPU is on the Activity Monitor scale (100 = one full core) and is
    /// averaged over the last 30 samples, one to five minutes. A single
    /// interval would mostly show the cost of opening the window that
    /// displays the figure.
    private(set) var ownCPUPercent = 0.0
    private(set) var ownMemoryBytes: UInt64 = 0
    private var pidBuffer = [pid_t](repeating: 0, count: 1024)
    private var pathBuffer = [CChar](repeating: 0, count: 4096)
    private var previousUptime: UInt64 = 0
    private var sampleCount = 0

    private let ownPID = getpid()
    private let ownUID = getuid()
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    func sample() -> [AppUsage] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = previousUptime > 0 && now > previousUptime ? now - previousUptime : 0
        previousUptime = now

        groups.removeAll(keepingCapacity: true)
        groupIndex.removeAll(keepingCapacity: true)
        currentCPU.removeAll(keepingCapacity: true)

        if let own = resourceUsage(of: ownPID) {
            let ownCPU = machTicksToNanoseconds(own.ri_user_time &+ own.ri_system_time)
            ownHistory.append((uptime: now, cpu: ownCPU))
            if ownHistory.count > Self.ownHistoryLength {
                ownHistory.removeFirst(ownHistory.count - Self.ownHistoryLength)
            }
            if let oldest = ownHistory.first, now > oldest.uptime, ownCPU >= oldest.cpu {
                ownCPUPercent = Double(ownCPU - oldest.cpu) / Double(now - oldest.uptime) * 100
            }
            ownMemoryBytes = own.ri_phys_footprint
        }
        seen.removeAll(keepingCapacity: true)

        // Processes already known to belong to someone else are skipped
        // without asking the kernel about them again. Every 15th sample
        // they are re-checked, in case a process id has been reused.
        sampleCount += 1
        let recheckOthers = sampleCount % 15 == 0

        let count = listPIDs()
        for index in 0..<count {
            let pid = pidBuffer[index]
            guard pid > 0, pid != ownPID else { continue }
            if !recheckOthers, let known = identities[pid], !known.owned {
                seen.insert(pid)
                continue
            }
            guard let usage = resourceUsage(of: pid) else {
                // No access: it belongs to the system or another user.
                identities[pid] = Identity(
                    startTime: 0, owned: false, key: "", name: "", iconPath: "", kind: .system
                )
                seen.insert(pid)
                continue
            }
            seen.insert(pid)

            let startTime = usage.ri_proc_start_abstime
            let identity: Identity
            if let cached = identities[pid], cached.startTime == startTime {
                identity = cached
            } else {
                identity = identify(pid, startTime: startTime)
                identities[pid] = identity
                previousCPU[pid] = nil
            }
            guard identity.owned else { continue }

            let cpuNanoseconds = machTicksToNanoseconds(usage.ri_user_time &+ usage.ri_system_time)
            currentCPU[pid] = cpuNanoseconds

            var cpuPercent = 0.0
            if elapsed > 0, let before = previousCPU[pid], cpuNanoseconds >= before {
                cpuPercent = Double(cpuNanoseconds - before) / Double(elapsed) * 100
            }

            // Accumulate in place: no copying of a group's process list.
            let slot: Int
            if let existing = groupIndex[identity.key] {
                slot = existing
            } else {
                slot = groups.count
                groupIndex[identity.key] = slot
                groups.append(Group(
                    key: identity.key, name: identity.name,
                    iconPath: identity.iconPath, kind: identity.kind
                ))
            }
            groups[slot].pids.append(pid)
            groups[slot].cpu += cpuPercent
            groups[slot].memory += usage.ri_phys_footprint
        }

        swap(&previousCPU, &currentCPU)
        if identities.count > seen.count {
            identities = identities.filter { seen.contains($0.key) }
        }

        var result: [AppUsage] = []
        result.reserveCapacity(groups.count)
        for group in groups {
            result.append(AppUsage(
                id: group.key,
                name: group.name,
                iconPath: group.iconPath,
                pids: group.pids,
                cpuPercent: group.cpu,
                memoryBytes: group.memory,
                kind: group.kind
            ))
        }
        return result
    }

    // MARK: - Identity (looked up once per process)

    private func identify(_ pid: pid_t, startTime: UInt64) -> Identity {
        guard isOwnedByCurrentUser(pid), let path = executablePath(of: pid) else {
            return Identity(startTime: startTime, owned: false, key: "", name: "", iconPath: "", kind: .system)
        }

        if let bundlePath = outermostAppBundle(in: path) {
            return Self.appIdentity(bundlePath: bundlePath, startTime: startTime)
        }

        // The file a process is running from can move while it runs: an app
        // that has updated itself in the background keeps running its old
        // program file from a temporary location. The path the process was
        // launched with still names the app it belongs to.
        if let launched = launchPath(of: pid),
           let bundlePath = outermostAppBundle(in: launched) {
            return Self.appIdentity(bundlePath: bundlePath, startTime: startTime)
        }

        // A system helper working on behalf of an app (a browser's web content
        // process, an app's virtual machine service…) is counted under that
        // app, the way Activity Monitor names it "… for <App>".
        if Self.kind(forLocation: path) == .protected,
           let owner = responsibleAppBundle(for: pid),
           Self.kind(forLocation: owner) == .app {
            return Self.appIdentity(bundlePath: owner, startTime: startTime)
        }

        return Identity(
            startTime: startTime, owned: true, key: "pid:\(pid)",
            name: (path as NSString).lastPathComponent,
            iconPath: path, kind: Self.kind(forLocation: path)
        )
    }

    private static func appIdentity(bundlePath: String, startTime: UInt64) -> Identity {
        let name = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return Identity(
            startTime: startTime, owned: true, key: bundlePath, name: name,
            iconPath: bundlePath, kind: kind(forLocation: bundlePath)
        )
    }

    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    /// macOS records which app each helper process is working for. The
    /// lookup has no public header, so it is resolved by name at launch and
    /// simply skipped if a future macOS no longer offers it.
    private static let responsiblePID: ResponsiblePIDFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    /// The .app bundle of the app a helper process is working for, if any.
    private func responsibleAppBundle(for pid: pid_t) -> String? {
        guard let lookup = Self.responsiblePID else { return nil }
        let owner = lookup(pid)
        guard owner > 1, owner != pid, owner != ownPID,
              isOwnedByCurrentUser(owner),
              let ownerPath = executablePath(of: owner)
        else { return nil }
        return outermostAppBundle(in: ownerPath)
    }

    /// Decides what may be done to a process from where it lives on disk.
    private static func kind(forLocation location: String) -> RowKind {
        // Apple's own apps (Mail, Notes, Safari…) are ordinary apps.
        if location.hasPrefix("/System/Applications/")
            || location.hasPrefix("/System/Cryptexes/App/System/Applications/") {
            return .app
        }
        if location == "/System/Library/CoreServices/Finder.app"
            || location == "/System/Library/CoreServices/Dock.app" {
            return .restartable
        }
        for prefix in ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]
        where location.hasPrefix(prefix) {
            return .protected
        }
        return .app
    }

    /// "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/…" → "/Applications/Foo.app"
    private func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: - libproc helpers

    /// Fills pidBuffer and returns how many entries are valid.
    private func listPIDs() -> Int {
        let estimate = Int(proc_listallpids(nil, 0))
        guard estimate > 0 else { return 0 }
        if pidBuffer.count < estimate + 64 {
            pidBuffer = [pid_t](repeating: 0, count: estimate + 256)
        }
        let filled = pidBuffer.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return max(0, min(Int(filled), pidBuffer.count))
    }

    private func isOwnedByCurrentUser(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_uid == ownUID
    }

    private func executablePath(of pid: pid_t) -> String? {
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    /// The path a process was started with, as `ps` reports it.
    private func launchPath(of pid: pid_t) -> String? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }

        // One spare byte guarantees the string is terminated.
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: a 32-bit argument count, then the program path.
        let path = buffer.withUnsafeBufferPointer { pointer -> String? in
            guard let base = pointer.baseAddress else { return nil }
            return String(cString: base + MemoryLayout<Int32>.size)
        }
        return (path?.isEmpty ?? true) ? nil : path
    }

    /// Uses the oldest, smallest report (V0). It already has everything
    /// needed here (CPU time, memory footprint, start time), and the kernel
    /// does far less work for it than for the newer ones, which also add up
    /// energy, instruction and disk counters for every thread.
    private func resourceUsage(of pid: pid_t) -> rusage_info_v0? {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        return result == 0 ? info : nil
    }

    /// proc_pid_rusage reports CPU time in Mach ticks, which are not
    /// nanoseconds on Apple silicon.
    private func machTicksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        guard timebase.denom != 0, timebase.numer != timebase.denom else { return ticks }
        return UInt64(Double(ticks) * Double(timebase.numer) / Double(timebase.denom))
    }
}
