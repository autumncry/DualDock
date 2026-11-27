import Combine
import Darwin
import Foundation
import IOKit.ps

/// All displays share one sampler. These values come from this Mac.
@MainActor
final class LocalToolMetrics: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var systemResources: SystemResourceSnapshot?
    @Published private(set) var batteryPercent: Double?
    @Published private(set) var diskAvailableBytes: Int64?
    @Published private(set) var diskTotalBytes: Int64?
    @Published private(set) var focusDuration: TimeInterval
    @Published private(set) var focusRemaining: TimeInterval
    @Published private(set) var focusEndsAt: Date?

    private struct Demand: OptionSet, Sendable {
        let rawValue: Int
        static let system = Self(rawValue: 1)
        static let battery = Self(rawValue: 2)
        static let disk = Self(rawValue: 4)
    }
    private struct SavedTimer: Codable {
        let duration: TimeInterval
        let remaining: TimeInterval
        let end: Date?
    }

    private let file: URL
    private let readResources: @Sendable () -> SystemResourceSnapshot
    private let now: () -> Date
    private var displays: [String: Demand] = [:]
    private var sampler: Task<Void, Never>?
    private var completion: Task<Void, Never>?

    init(directory: URL, readResources: @escaping @Sendable () -> SystemResourceSnapshot = { .read() },
         now: @escaping () -> Date = Date.init) {
        self.readResources = readResources
        self.now = now
        file = directory.appendingPathComponent("focus-timer.json")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SavedTimer.self, from: $0) }
        let duration = min(180 * 60, max(60, saved?.duration ?? 1500))
        focusDuration = duration
        if let end = saved?.end {
            let seconds = end.timeIntervalSince(now())
            focusEndsAt = seconds > 0 ? end : nil
            focusRemaining = max(0, min(seconds, duration))
        } else {
            focusRemaining = min(duration, max(0, saved?.remaining ?? duration))
        }
        scheduleCompletion()
    }

    func setFocusDuration(minutes: Int) {
        guard focusEndsAt == nil else { return }
        focusDuration = TimeInterval(min(180, max(1, minutes)) * 60)
        resetFocus()
    }

    func toggleFocus() {
        if let end = focusEndsAt {
            focusRemaining = max(0, min(focusDuration, end.timeIntervalSince(now())))
            focusEndsAt = nil
        } else {
            if focusRemaining <= 0 { focusRemaining = focusDuration }
            focusEndsAt = now().addingTimeInterval(focusRemaining)
        }
        persistTimer()
        scheduleCompletion()
    }

    func resetFocus() {
        focusEndsAt = nil
        focusRemaining = focusDuration
        completion?.cancel()
        persistTimer()
    }

    private func persistTimer() {
        let saved = SavedTimer(duration: focusDuration, remaining: focusRemaining, end: focusEndsAt)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file, options: .atomic)
        } catch {
            NSLog("DualDock: could not save focus timer (%@)", (error as NSError).domain)
        }
    }

    private func scheduleCompletion() {
        completion?.cancel()
        guard let end = focusEndsAt else { return }
        let delay = max(0, end.timeIntervalSince(now()))
        completion = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.focusEndsAt == end else { return }
            self.focusEndsAt = nil
            self.focusRemaining = 0
            self.persistTimer()
        }
    }

    func setVisible(_ active: Bool, on display: String, system: Bool, battery: Bool, disk: Bool) {
        let previous = displays.values.reduce(Demand()) { $0.union($1) }
        var current = Demand()
        if active {
            if system { current.insert(.system) }
            if battery { current.insert(.battery) }
            if disk { current.insert(.disk) }
        }
        displays[display] = current.isEmpty ? nil : current
        let next = displays.values.reduce(Demand()) { $0.union($1) }
        guard next != previous else { return }
        sampler?.cancel()
        if !next.contains(.system) {
            if systemResources != nil { systemResources = nil }
            if cpuPercent != nil { cpuPercent = nil }
        }
        guard !next.isEmpty else { return }
        let readResources = self.readResources
        sampler = Task.detached(priority: .utility) { [weak self] in
            var previousCPU: LocalCPUTicks?
            var nextSlowRead = Date.distantPast
            while !Task.isCancelled {
                var cpu: Double?
                if next.contains(.system), let ticks = LocalCPUTicks.read() {
                    cpu = previousCPU.flatMap { ticks.utilization(since: $0) }
                    previousCPU = ticks
                }
                let resources = next.contains(.system) ? readResources() : nil
                let slow = Date() >= nextSlowRead
                let charge = slow && next.contains(.battery) ? Self.readBattery() : nil
                let storage = slow && next.contains(.disk) ? Self.readDisk() : nil
                if slow { nextSlowRead = Date().addingTimeInterval(30) }
                guard !Task.isCancelled else { return }
                await self?.apply(cpu: cpu, resources: resources, charge: charge, storage: storage, demand: next, slow: slow)
                do { try await Task.sleep(for: .seconds(next.contains(.system) ? 2 : 30)) } catch { return }
            }
        }
    }

    private func apply(cpu: Double?, resources: SystemResourceSnapshot?, charge: Double?, storage: (free: Int64, total: Int64)?,
                       demand: Demand, slow: Bool) {
        guard !Task.isCancelled else { return }
        if demand.contains(.system) {
            if cpuPercent != cpu { cpuPercent = cpu }
            if systemResources != resources { systemResources = resources }
        }
        if slow && demand.contains(.battery) && batteryPercent != charge { batteryPercent = charge }
        if slow && demand.contains(.disk) {
            if diskAvailableBytes != storage?.free { diskAvailableBytes = storage?.free }
            if diskTotalBytes != storage?.total { diskTotalBytes = storage?.total }
        }
    }

    private nonisolated static func readBattery() -> Double? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for item in sources {
            guard let unmanaged = IOPSGetPowerSourceDescription(snapshot, item),
                  let info = unmanaged.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? NSNumber,
                  let max = info[kIOPSMaxCapacityKey] as? NSNumber, max.doubleValue > 0 else { continue }
            return min(100, Swift.max(0, (100 * current.doubleValue / max.doubleValue).rounded()))
        }
        return nil
    }

    private nonisolated static func readDisk() -> (free: Int64, total: Int64)? {
        guard let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init),
              total > 0, free >= 0 else { return nil }
        return (min(free, Int64(total)), Int64(total))
    }

    func stop() {
        sampler?.cancel()
        completion?.cancel()
        displays.removeAll()
    }

    deinit { sampler?.cancel(); completion?.cancel() }
}

struct LocalCPUTicks {
    let user, sys, idle, nice: UInt32

    func utilization(since old: Self) -> Double? {
        let work = UInt64(user &- old.user) + UInt64(sys &- old.sys) + UInt64(nice &- old.nice)
        let total = work + UInt64(idle &- old.idle)
        return total > 0 ? (100 * Double(work) / Double(total)).rounded() : nil
    }

    static func read() -> Self? {
        var info = host_cpu_load_info()
        let count = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        var size = mach_msg_type_number_t(count)
        let port = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: count) {
                host_statistics(port, HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS, size == count else { return nil }
        let t = info.cpu_ticks
        return .init(user: t.0, sys: t.1, idle: t.2, nice: t.3)
    }
}

/// The amount currently in use and the corresponding physical or allocated capacity, in bytes.
struct SystemByteUsage: Equatable, Sendable {
    let used: UInt64
    let total: UInt64

    init?(used: UInt64, total: UInt64) {
        guard used <= total, total <= UInt64(Int64.max) else { return nil }
        self.used = used
        self.total = total
    }
}

struct SystemResourceSnapshot: Equatable, Sendable {
    let memory: SystemByteUsage?
    let swap: SystemByteUsage?

    static func read() -> Self {
        Self(memory: readMemory(), swap: readSwap())
    }

    // Anonymous resident pages (excluding reclaimable purgeable pages), wired pages,
    // and the physical pages occupied by the compressor. File-backed caches and the
    // larger, logical size of compressed content do not contribute to this total.
    static func memoryUsage(_ vm: vm_statistics64_data_t, pageBytes: UInt64, total: UInt64) -> SystemByteUsage? {
        guard pageBytes > 0, total > 0 else { return nil }
        let anonymous = UInt64(vm.internal_page_count) - UInt64(min(vm.purgeable_count, vm.internal_page_count))
        let pages = anonymous + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
        let (used, overflow) = pages.multipliedReportingOverflow(by: pageBytes)
        guard !overflow else { return nil }
        return SystemByteUsage(used: used, total: total)
    }

    private static func readMemory() -> SystemByteUsage? {
        var statistics = vm_statistics64_data_t()
        let capacity = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let port = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(port, HOST_VM_INFO64, $0, &count)
            }
        }
        // Newer SDKs append fields. A reply from an older kernel is valid if it
        // contains all the fields used above, including internal_page_count.
        guard result == KERN_SUCCESS,
              let offset = MemoryLayout<vm_statistics64_data_t>.offset(of: \.internal_page_count),
              Int(count) * MemoryLayout<integer_t>.size >= offset + MemoryLayout<natural_t>.size else { return nil }
        return memoryUsage(statistics, pageBytes: UInt64(vm_kernel_page_size), total: ProcessInfo.processInfo.physicalMemory)
    }

    private static func readSwap() -> SystemByteUsage? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0,
              size == MemoryLayout<xsw_usage>.size else { return nil }
        return SystemByteUsage(used: swap.xsu_used, total: swap.xsu_total)
    }
}
