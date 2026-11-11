import Darwin
import Foundation

/// The kernel's own verdict on memory, the signal behind the coloured
/// "Memory Pressure" graph in Activity Monitor.
enum MemoryPressure {
    case normal
    case warning
    case critical

    var label: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

struct SystemSnapshot {
    /// Whole-machine CPU load, 0–100.
    var cpuPercent: Double = 0
    /// Memory in use, 0–100.
    var memoryPercent: Double = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    /// Memory held by the kernel itself, which no app can be blamed for.
    var memoryWiredBytes: UInt64 = 0
    var memoryPressure: MemoryPressure = .normal
}

/// Reads whole-machine CPU and memory figures from the Mach host APIs,
/// the same counters Activity Monitor is built on.
final class SystemSampler {
    private var previousBusy: UInt64 = 0
    private var previousTotal: UInt64 = 0
    private var hasPrevious = false
    private let totalMemory = ProcessInfo.processInfo.physicalMemory
    private let pageSize = UInt64(getpagesize())

    func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpuPercent = sampleCPU()

        let memory = sampleMemory()
        let used = min(memory.used, totalMemory)
        snapshot.memoryWiredBytes = memory.wired
        snapshot.memoryTotalBytes = totalMemory
        snapshot.memoryUsedBytes = used
        snapshot.memoryPercent = totalMemory > 0 ? Double(used) / Double(totalMemory) * 100 : 0

        if let pressure = samplePressure() {
            snapshot.memoryPressure = pressure
        } else {
            // The pressure reading is unavailable: fall back to a high fixed bar.
            snapshot.memoryPressure = snapshot.memoryPercent >= 95 ? .warning : .normal
        }
        return snapshot
    }

    /// CPU load since the previous call, from cumulative tick counters.
    private func sampleCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        // cpu_ticks order: user, system, idle, nice
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        let busy = user + system + nice
        let total = busy + idle
        defer {
            previousBusy = busy
            previousTotal = total
            hasPrevious = true
        }
        guard hasPrevious, total > previousTotal, busy >= previousBusy else { return 0 }

        let percent = Double(busy - previousBusy) / Double(total - previousTotal) * 100
        return max(0, min(100, percent))
    }

    /// "Memory Used" as Activity Monitor defines it:
    /// app memory + wired + compressed.
    private func sampleMemory() -> (used: UInt64, wired: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }

        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)
        return ((appPages + wiredPages + compressedPages) * pageSize, wiredPages * pageSize)
    }

    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    private func samplePressure() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}
