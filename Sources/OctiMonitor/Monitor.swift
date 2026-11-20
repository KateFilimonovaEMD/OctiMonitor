import Foundation
import QuartzCore
import Darwin

/// Collects the numbers behind OctiMonitor: frame pacing, CPU and GPU time per scene,
/// memory and heat.
///
/// Cost on the render path: a lock, one dictionary lookup and a few array writes per frame,
/// no allocation once a scene has been seen (rings are allocated up front). Memory and
/// thermal state are sampled once a second. Percentiles are computed only when the HUD
/// (4x a second) or a report asks.
final class Monitor {
    static let shared = Monitor()

    /// What the HUD shows. Durations in the summaries are milliseconds.
    struct Snapshot {
        var fps: Double = 0
        var targetFPS = 60
        var frame = PercentileSummary()
        var gpu = PercentileSummary()
        var hitchMsPerSecond: Double = 0
        var memoryMB: Double = 0
        var thermal: ProcessInfo.ThermalState = .nominal
        var scene = ""
        var degraded = false
        /// Frame intervals in seconds, oldest first.
        var recentFrames: [Float] = []
    }

    /// Everything measured for one scene since the last report.
    private struct Window {
        let scene: String
        var frames: SampleRing
        var gpu: SampleRing
        var frameCount = 0
        var duration: Double = 0
        var cpuTotal: Double = 0
        var hitchTime: Double = 0
        var dropped = 0
        var degradedFrames = 0

        init(scene: String, capacity: Int) {
            self.scene = scene
            frames = SampleRing(capacity: capacity)
            gpu = SampleRing(capacity: capacity)
        }

        mutating func reset() {
            frames.removeAll()
            gpu.removeAll()
            frameCount = 0
            duration = 0
            cpuTotal = 0
            hitchTime = 0
            dropped = 0
            degradedFrames = 0
        }
    }

    /// 30 s at 120 Hz fits; older frames of a longer window simply roll off.
    private static let windowCapacity = 4096
    private static let recentCapacity = 240
    /// Scenes beyond this share one "other" bucket, so a bug cannot grow memory forever.
    private static let maxScenes = 32

    private let lock = NSLock()
    private var windows: [Window] = []
    private var sceneIndex: [String: Int] = [:]
    private var recentFrames = SampleRing(capacity: Monitor.recentCapacity)
    private var recentGPU = SampleRing(capacity: Monitor.recentCapacity)
    private var scratch = [Float](repeating: 0, count: Monitor.windowCapacity)
    private var scene = ""
    private var targetFPS = 60
    private var degraded = false
    private var windowStart = CACurrentMediaTime()
    private var lastSystemSample: CFTimeInterval = 0
    private var memoryBytes: UInt64 = 0
    private var peakMemoryBytes: UInt64 = 0
    private var thermal: ProcessInfo.ThermalState = .nominal
    private var worstThermal: ProcessInfo.ThermalState = .nominal

    private init() {}

    // MARK: - Recording (render path)

    func recordFrame(interval: Double, cpu: Double, scene name: String, targetFPS fps: Int, degraded isDegraded: Bool) {
        // Longer gaps are pauses (app in background, drawing stopped), not slow frames.
        guard interval > 0, interval < 1 else { return }
        let target = 1.0 / Double(Swift.max(1, fps))
        let now = CACurrentMediaTime()
        let sampleSystem = now - lastSystemSample >= 1
        let footprint = sampleSystem ? Self.footprintBytes() : 0
        let heat = sampleSystem ? ProcessInfo.processInfo.thermalState : .nominal

        lock.lock()
        defer { lock.unlock() }
        scene = name
        targetFPS = fps
        degraded = isDegraded
        recentFrames.append(Float(interval))

        let i = index(of: name)
        windows[i].frames.append(Float(interval))
        windows[i].frameCount += 1
        windows[i].duration += interval
        windows[i].cpuTotal += cpu
        if FramePacing.isDropped(interval: interval, target: target) {
            windows[i].dropped += 1
            windows[i].hitchTime += FramePacing.hitchTime(interval: interval, target: target)
        }
        if isDegraded { windows[i].degradedFrames += 1 }

        if sampleSystem {
            lastSystemSample = now
            memoryBytes = footprint
            peakMemoryBytes = Swift.max(peakMemoryBytes, footprint)
            thermal = heat
            if heat.rawValue > worstThermal.rawValue { worstThermal = heat }
        }
    }

    func recordGPU(start: CFTimeInterval, end: CFTimeInterval, scene name: String) {
        let seconds = end - start
        guard start > 0, seconds > 0, seconds < 1 else { return }
        lock.lock()
        defer { lock.unlock() }
        recentGPU.append(Float(seconds))
        windows[index(of: name)].gpu.append(Float(seconds))
    }

    /// Caller holds the lock. Allocates only the first time a scene appears.
    private func index(of name: String) -> Int {
        if let i = sceneIndex[name] { return i }
        let key = windows.count < Self.maxScenes ? name : "other"
        if let i = sceneIndex[key] { return i }
        windows.append(Window(scene: key, capacity: Self.windowCapacity))
        sceneIndex[key] = windows.count - 1
        return windows.count - 1
    }

    // MARK: - Reading

    /// The last ~2–4 seconds, for the HUD.
    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var result = Snapshot()
        result.targetFPS = targetFPS
        result.scene = scene
        result.degraded = degraded
        result.thermal = thermal
        result.memoryMB = Double(memoryBytes) / 1_048_576

        let n = recentFrames.copy(into: &scratch)
        result.recentFrames = Array(scratch[0..<n])
        let target = 1.0 / Double(Swift.max(1, targetFPS))
        var total = 0.0
        var hitch = 0.0
        for value in result.recentFrames {
            let interval = Double(value)
            total += interval
            hitch += FramePacing.hitchTime(interval: interval, target: target)
        }
        result.fps = total > 0 ? Double(n) / total : 0
        result.hitchMsPerSecond = total > 0 ? hitch * 1000 / total : 0
        result.frame = PercentileSummary(sorting: &scratch, count: n)

        let g = recentGPU.copy(into: &scratch)
        result.gpu = PercentileSummary(sorting: &scratch, count: g)
        return result
    }

    /// Everything since the previous call, JSON-ready, and starts a new window.
    /// Nil when nothing was drawn.
    func drainReport() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let seconds = now - windowStart
        windowStart = now

        var scenes: [[String: Any]] = []
        for i in windows.indices {
            guard windows[i].frameCount > 0 else {
                windows[i].reset()
                continue
            }
            let frameN = windows[i].frames.copy(into: &scratch)
            let frame = PercentileSummary(sorting: &scratch, count: frameN)
            let gpuN = windows[i].gpu.copy(into: &scratch)
            let gpu = PercentileSummary(sorting: &scratch, count: gpuN)
            let w = windows[i]
            scenes.append([
                "scene": w.scene,
                "frames": w.frameCount,
                "seconds": PerfMath.round2(w.duration),
                "fps": PerfMath.round2(w.duration > 0 ? Double(w.frameCount) / w.duration : 0),
                "frame_ms": frame.dictionary,
                "gpu_ms": gpu.dictionary,
                "cpu_ms_avg": PerfMath.round2(w.cpuTotal * 1000 / Double(w.frameCount)),
                "dropped_frames": w.dropped,
                "hitch_ms_per_s": PerfMath.round2(w.duration > 0 ? w.hitchTime * 1000 / w.duration : 0),
                "degraded_share": PerfMath.round2(Double(w.degradedFrames) / Double(w.frameCount)),
            ])
            windows[i].reset()
        }

        let report: [String: Any] = [
            "window_s": PerfMath.round2(seconds),
            "target_fps": targetFPS,
            "thermal_now": Self.name(thermal),
            "thermal_worst": Self.name(worstThermal),
            "memory_mb_peak": PerfMath.round2(Double(peakMemoryBytes) / 1_048_576),
            "scenes": scenes,
        ]
        worstThermal = thermal
        peakMemoryBytes = memoryBytes
        return scenes.isEmpty ? nil : report
    }

    // MARK: - System readings

    /// The number iOS uses for memory limits and jetsam: physical footprint.
    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
