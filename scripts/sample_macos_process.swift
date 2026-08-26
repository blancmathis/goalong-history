import Darwin
import Foundation

private struct SampleError: Error, CustomStringConvertible {
    let description: String
}

private struct ProcessSnapshot {
    let userTime: UInt64
    let systemTime: UInt64
    let idleWakeups: UInt64
    let interruptWakeups: UInt64
    let diskBytesRead: UInt64
    let diskBytesWritten: UInt64
    let residentBytes: UInt64
    let physicalFootprint: UInt64
    let lifetimePeakPhysicalFootprint: UInt64
    let childCount: Int
    let continuousTime: UInt64
}

private let arguments = CommandLine.arguments
guard arguments.count == 8,
      let pid = Int32(arguments[1]), pid > 0,
      let sampleCount = Int(arguments[2]), (1 ... 86_400).contains(sampleCount)
else {
    FileHandle.standardError.write(
        Data("Usage: sample_macos_process.swift PID SAMPLE_COUNT CPU RSS CHILDREN RUSAGE_BEFORE RUSAGE_AFTER\n".utf8)
    )
    exit(64)
}

private let cpuURL = URL(fileURLWithPath: arguments[3])
private let rssURL = URL(fileURLWithPath: arguments[4])
private let childrenURL = URL(fileURLWithPath: arguments[5])
private let beforeURL = URL(fileURLWithPath: arguments[6])
private let afterURL = URL(fileURLWithPath: arguments[7])

private var timebase = mach_timebase_info_data_t()
guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
    FileHandle.standardError.write(Data("Unable to read the mach timebase.\n".utf8))
    exit(69)
}

private func nanoseconds(fromAbsoluteTicks ticks: UInt64) -> UInt64 {
    let quotient = ticks / UInt64(timebase.denom)
    let remainder = ticks % UInt64(timebase.denom)
    return quotient * UInt64(timebase.numer)
        + remainder * UInt64(timebase.numer) / UInt64(timebase.denom)
}

private func childProcessCount(of pid: pid_t) throws -> Int {
    // Goalong should have no children. Keep the observer bounded even if a
    // regression unexpectedly creates many of them.
    var children = [pid_t](repeating: 0, count: 4_096)
    let bytes = children.withUnsafeMutableBytes { buffer -> Int32 in
        guard let baseAddress = buffer.baseAddress else { return 0 }
        return proc_listchildpids(pid, baseAddress, Int32(buffer.count))
    }
    guard bytes >= 0 else {
        throw SampleError(description: "Unable to enumerate child processes for PID \(pid).")
    }
    return Int(bytes) / MemoryLayout<pid_t>.stride
}

private func processSnapshot() throws -> ProcessSnapshot {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
        }
    }
    guard result == 0 else {
        throw SampleError(description: "Process \(pid) exited or could not be sampled.")
    }

    return ProcessSnapshot(
        userTime: info.ri_user_time,
        systemTime: info.ri_system_time,
        idleWakeups: info.ri_pkg_idle_wkups,
        interruptWakeups: info.ri_interrupt_wkups,
        diskBytesRead: info.ri_diskio_bytesread,
        diskBytesWritten: info.ri_diskio_byteswritten,
        residentBytes: info.ri_resident_size,
        physicalFootprint: info.ri_phys_footprint,
        lifetimePeakPhysicalFootprint: info.ri_lifetime_max_phys_footprint,
        childCount: try childProcessCount(of: pid),
        continuousTime: mach_continuous_time()
    )
}

private func rusageLine(_ snapshot: ProcessSnapshot) -> String {
    [
        nanoseconds(fromAbsoluteTicks: snapshot.userTime),
        nanoseconds(fromAbsoluteTicks: snapshot.systemTime),
        snapshot.idleWakeups,
        snapshot.interruptWakeups,
        snapshot.diskBytesRead,
        snapshot.diskBytesWritten,
        snapshot.physicalFootprint,
        snapshot.lifetimePeakPhysicalFootprint,
    ]
    .map(String.init)
    .joined(separator: "\t") + "\n"
}

do {
    let before = try processSnapshot()
    var previous = before
    var cpuLines = ""
    var rssLines = ""
    var childLines = ""
    cpuLines.reserveCapacity(sampleCount * 10)
    rssLines.reserveCapacity(sampleCount * 10)
    childLines.reserveCapacity(sampleCount * 2)

    for _ in 0 ..< sampleCount {
        Thread.sleep(forTimeInterval: 1)
        let current = try processSnapshot()
        guard current.userTime >= previous.userTime,
              current.systemTime >= previous.systemTime,
              current.continuousTime > previous.continuousTime
        else {
            throw SampleError(description: "Non-monotonic process counters for PID \(pid).")
        }

        let cpuTicks = current.userTime - previous.userTime
            + current.systemTime - previous.systemTime
        let wallTicks = current.continuousTime - previous.continuousTime
        let cpuPercent = Double(cpuTicks) / Double(wallTicks) * 100
        cpuLines += String(format: "%.6f\n", cpuPercent)
        rssLines += "\(current.residentBytes / 1_024)\n"
        childLines += "\(current.childCount)\n"
        previous = current
    }

    try Data(cpuLines.utf8).write(to: cpuURL, options: .atomic)
    try Data(rssLines.utf8).write(to: rssURL, options: .atomic)
    try Data(childLines.utf8).write(to: childrenURL, options: .atomic)
    try Data(rusageLine(before).utf8).write(to: beforeURL, options: .atomic)
    try Data(rusageLine(previous).utf8).write(to: afterURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(69)
}
