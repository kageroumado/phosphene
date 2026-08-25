import Darwin
import Foundation
import IOKit

// Samples CPU, memory, and energy for Phosphene's process family plus GPU
// utilization, using the delta discipline from Refrax's ProcessMemoryMonitor
// (first sample yields no rate; recycled PIDs are discarded, never negative).
//
//   swiftc -O perfprobe.swift -o /tmp/perfprobe
//   /tmp/perfprobe [seconds] [interval]
//
// CPU time and energy come from proc_pid_rusage (RUSAGE_INFO_V4): same-uid
// processes only, so WindowServer reads as n/a — watch it with
// `top -s 1 -pid <ws pid>` alongside. GPU is IOAccelerator
// "PerformanceStatistics" (whole-GPU, not per-process).

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 30 : 30
let interval = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 1 : 1

var timebaseInfo = mach_timebase_info_data_t()
mach_timebase_info(&timebaseInfo)
let machToNanos = Double(timebaseInfo.numer) / Double(timebaseInfo.denom)

struct Usage {
    var cpuTimeNanos: Double
    var footprint: UInt64
    var energyNanojoules: UInt64
    var sampledAt: Date
}

func readUsage(pid: pid_t) -> Usage? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard result == 0 else { return nil }
    let cpuNanos = Double(info.ri_user_time &+ info.ri_system_time) * machToNanos
    return Usage(
        cpuTimeNanos: cpuNanos,
        footprint: info.ri_phys_footprint,
        energyNanojoules: info.ri_billed_energy,
        sampledAt: Date(),
    )
}

func gpuUtilization() -> (device: Int, renderer: Int)? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
    var entry = IOIteratorNext(iterator)
    while entry != 0 {
        defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
        guard let props = IORegistryEntryCreateCFProperty(
            entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0,
        )?.takeRetainedValue() as? [String: Any] else { continue }
        let device = props["Device Utilization %"] as? Int
        let renderer = props["Renderer Utilization %"] as? Int
        if device != nil || renderer != nil {
            return (device ?? -1, renderer ?? -1)
        }
    }
    return nil
}

func processName(pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
    return (String(cString: buffer) as NSString).lastPathComponent
}

func discoverTargets() -> [(pid: pid_t, label: String)] {
    var targets = [(pid_t, String)]()
    let patterns: [(String, String)] = [
        ("PhospheneExtension", "appex"),
        ("Phosphene.app/Contents/MacOS/Phosphene", "app"),
        ("VTDecoderXPCService", "decoder"),
        ("WallpaperAgent", "agent"),
        ("WindowServer -daemon", "windowserver"),
    ]
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-Ao", "pid,command"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    for line in output.split(separator: "\n").dropFirst() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " "),
              let pid = pid_t(trimmed[..<space]) else { continue }
        let command = String(trimmed[trimmed.index(after: space)...])
        for (pattern, label) in patterns where command.contains(pattern) {
            targets.append((pid, "\(label)-\(pid)"))
            break
        }
    }
    return targets
}

let targets = discoverTargets()
guard !targets.isEmpty else {
    print("No Phosphene processes found")
    exit(1)
}

var previous = [pid_t: Usage]()
var cpuSums = [pid_t: Double]()
var cpuCounts = [pid_t: Int]()
var energyStart = [pid_t: UInt64]()
var energyEnd = [pid_t: UInt64]()
var gpuDeviceSum = 0, gpuRendererSum = 0, gpuCount = 0

let header = (["time"] + targets.map(\.label) + ["gpu-dev%", "gpu-rend%"]).joined(separator: "\t")
print(header)

let start = Date()
var tick = 0
while Date().timeIntervalSince(start) < duration {
    Thread.sleep(forTimeInterval: interval)
    tick += 1
    var columns = [String(format: "%5.1fs", Date().timeIntervalSince(start))]
    for (pid, _) in targets {
        guard let usage = readUsage(pid: pid) else {
            columns.append("n/a")
            continue
        }
        defer { previous[pid] = usage }
        if energyStart[pid] == nil { energyStart[pid] = usage.energyNanojoules }
        energyEnd[pid] = usage.energyNanojoules
        guard let prev = previous[pid] else {
            columns.append("…")
            continue
        }
        let wall = usage.sampledAt.timeIntervalSince(prev.sampledAt)
        guard wall > 0.5, usage.cpuTimeNanos >= prev.cpuTimeNanos else {
            columns.append("…")
            continue
        }
        let percent = (usage.cpuTimeNanos - prev.cpuTimeNanos) / (wall * 1e9) * 100
        cpuSums[pid, default: 0] += percent
        cpuCounts[pid, default: 0] += 1
        columns.append(String(format: "%.1f%% %dM", percent, usage.footprint / 1_048_576))
    }
    if let gpu = gpuUtilization() {
        columns.append("\(gpu.device)")
        columns.append("\(gpu.renderer)")
        gpuDeviceSum += gpu.device; gpuRendererSum += gpu.renderer; gpuCount += 1
    } else {
        columns.append("n/a"); columns.append("n/a")
    }
    print(columns.joined(separator: "\t"))
}

print("\n== averages over \(Int(duration))s ==")
for (pid, label) in targets {
    guard let count = cpuCounts[pid], count > 0 else {
        print("\(label): n/a (not sampleable — different uid?)")
        continue
    }
    let avgCPU = cpuSums[pid]! / Double(count)
    var energyLine = ""
    if let first = energyStart[pid], let last = energyEnd[pid], last > first {
        let joules = Double(last - first) / 1e9
        energyLine = String(format: " · %.2f J (%.0f mW avg)", joules, joules / duration * 1000)
    }
    print(String(format: "%@ (%@): %.2f%% CPU%@", label, processName(pid: pid), avgCPU, energyLine))
}
if gpuCount > 0 {
    print(String(format: "GPU: device %.1f%%, renderer %.1f%% (whole-system)",
                 Double(gpuDeviceSum) / Double(gpuCount), Double(gpuRendererSum) / Double(gpuCount)))
}
