import Foundation
import QuartzCore
import Darwin

/// Collects the numbers behind OctiMonitor: frame pacing, CPU and GPU time per scene,
/// memory and heat.
///
/// Frame pacing is measured from the moments frames actually reach the screen
/// (`MTLDrawable.presentedTime`, via `recordPresented`) when the app reports them, and from
/// draw-call intervals otherwise. Presentation times are what people see, and what Apple's
/// hitch metrics are based on.
///
/// Cost on the render path: a lock, one dictionary lookup, a few array writes and two
/// histogram increments per frame, with no allocation once a scene has been seen (rings and
/// histograms are allocated up front). Memory and thermal state are sampled once a second.
/// Percentiles are computed only when the HUD (4x a second) or a report asks.
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
        var pacingFromScreen = false
        /// Frame intervals in seconds, oldest first.
        var recentFrames: [Float] = []
    }

    /// Everything measured for one scene since the last report.
    private struct Window {
        let scene: String
        var frames: SampleRing
        var gpu: SampleRing
        var frameHistogram = DurationHistogram()
        var gpuHistogram = DurationHistogram()
        /// Frames counted by the pacing source (screen or draw calls).
        var frameCount = 0
        var duration: Double = 0
        var hitchTime: Double = 0
        var dropped = 0
        /// Draw calls, for CPU time and the reduced-quality share.
        var drawCount = 0
        var cpuTotal: Double = 0
        var degradedFrames = 0
        var targetFPS = 0

        init(scene: String, capacity: Int) {
            self.scene = scene
            frames = SampleRing(capacity: capacity)
            gpu = SampleRing(capacity: capacity)
        }

        mutating func reset() {
            frames.removeAll()
            gpu.removeAll()
            frameHistogram.removeAll()
            gpuHistogram.removeAll()
            frameCount = 0
            duration = 0
            hitchTime = 0
            dropped = 0
            drawCount = 0
            cpuTotal = 0
            degradedFrames = 0
            targetFPS = 0
        }
    }

    /// 30 s at 120 Hz fits; older frames of a longer window simply roll off. The histograms
    /// keep every frame regardless.
    private static let windowCapacity = 4096
    private static let recentCapacity = 240
    /// Scenes beyond this share one "other" bucket, so a bug cannot grow memory forever.
    private static let maxScenes = 32
    /// Without a presented frame for this long, pacing falls back to draw-call intervals.
    private static let screenTimeout: CFTimeInterval = 1

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
    /// Last presentation time from the display, and when the app last reported one.
    private var lastPresented: CFTimeInterval = 0
    private var lastPresentedReport: CFTimeInterval = 0
    /// Seconds of drawing so far in this session (pauses excluded), and at the window start.
    private var activeSeconds: Double = 0
    private var windowActiveStart: Double = 0

    private init() {}

    /// Tests only: forget presentation timing and start a fresh window.
    func resetForTesting() {
        lock.lock()
        lastPresented = 0
        lastPresentedReport = 0
        lock.unlock()
        _ = drainReport()
    }

    private var pacingFromScreen: Bool { CACurrentMediaTime() - lastPresentedReport < Self.screenTimeout }

    // MARK: - Recording (render path)

    func recordFrame(interval: Double, cpu: Double, scene name: String, targetFPS fps: Int, degraded isDegraded: Bool) {
        let now = CACurrentMediaTime()
        let sampleSystem = now - lastSystemSample >= 1
        let footprint = sampleSystem ? Self.footprintBytes() : 0
        let heat = sampleSystem ? ProcessInfo.processInfo.thermalState : .nominal

        lock.lock()
        defer { lock.unlock() }
        scene = name
        targetFPS = fps
        degraded = isDegraded

        let i = index(of: name)
        windows[i].drawCount += 1
        windows[i].cpuTotal += Swift.max(0, cpu)
        windows[i].targetFPS = Swift.max(windows[i].targetFPS, fps)
        if isDegraded { windows[i].degradedFrames += 1 }
        // Pacing from draw calls only while the screen isn't reporting presentation times.
        if now - lastPresentedReport >= Self.screenTimeout {
            addPacing(interval: interval, window: i, targetFPS: fps)
        }

        if sampleSystem {
            lastSystemSample = now
            memoryBytes = footprint
            peakMemoryBytes = Swift.max(peakMemoryBytes, footprint)
            thermal = heat
            if heat.rawValue > worstThermal.rawValue { worstThermal = heat }
        }
    }

    /// The moment a frame reached the screen (`MTLDrawable.presentedTime`), from the
    /// drawable's presented handler (any thread). Zero means the frame was never shown;
    /// it's skipped, and the gap correctly counts toward the next frame's interval.
    func recordPresented(time: CFTimeInterval, scene name: String, targetFPS fps: Int) {
        guard time > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let previous = lastPresented
        lastPresented = time
        lastPresentedReport = CACurrentMediaTime()
        guard previous > 0, time > previous else { return }
        addPacing(interval: time - previous, window: index(of: name), targetFPS: fps)
    }

    /// Caller holds the lock.
    private func addPacing(interval: Double, window i: Int, targetFPS fps: Int) {
        // Longer gaps are pauses (app in background, drawing stopped), not slow frames.
        guard interval > 0, interval < 1 else { return }
        let target = 1.0 / Double(Swift.max(1, fps))
        recentFrames.append(Float(interval))
        windows[i].frames.append(Float(interval))
        windows[i].frameHistogram.add(seconds: interval)
        windows[i].frameCount += 1
        windows[i].duration += interval
        windows[i].targetFPS = Swift.max(windows[i].targetFPS, fps)
        activeSeconds += interval
        if FramePacing.isDropped(interval: interval, target: target) {
            windows[i].dropped += 1
            windows[i].hitchTime += FramePacing.hitchTime(interval: interval, target: target)
        }
    }

    func recordGPU(start: CFTimeInterval, end: CFTimeInterval, scene name: String) {
        let seconds = end - start
        guard start > 0, seconds > 0, seconds < 1 else { return }
        lock.lock()
        defer { lock.unlock() }
        recentGPU.append(Float(seconds))
        let i = index(of: name)
        windows[i].gpu.append(Float(seconds))
        windows[i].gpuHistogram.add(seconds: seconds)
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
        result.pacingFromScreen = pacingFromScreen

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
        let pacingSource = pacingFromScreen ? "screen" : "draw"

        var scenes: [[String: Any]] = []
        for i in windows.indices {
            guard windows[i].frameCount > 0 || windows[i].drawCount > 0 else {
                windows[i].reset()
                continue
            }
            let frameN = windows[i].frames.copy(into: &scratch)
            let frame = PercentileSummary(sorting: &scratch, count: frameN)
            let gpuN = windows[i].gpu.copy(into: &scratch)
            let gpu = PercentileSummary(sorting: &scratch, count: gpuN)
            let w = windows[i]
            var row: [String: Any] = [
                "scene": w.scene,
                "target_fps": w.targetFPS > 0 ? w.targetFPS : targetFPS,
                "frames": w.frameCount,
                "seconds": PerfMath.round2(w.duration),
                "fps": PerfMath.round2(w.duration > 0 ? Double(w.frameCount) / w.duration : 0),
                "frame_ms": frame.dictionary,
                "frame_hist": w.frameHistogram.sparse,
                // No GPU samples means "not measured", never zero.
                "gpu_ms": gpuN > 0 ? gpu.dictionary : NSNull(),
                "gpu_samples": w.gpuHistogram.total,
                "dropped_frames": w.dropped,
                "hitch_ms_per_s": PerfMath.round2(w.duration > 0 ? w.hitchTime * 1000 / w.duration : 0),
                "hitch_ms": PerfMath.round2(w.hitchTime * 1000),
                "draw_calls": w.drawCount,
                "cpu_ms_avg": w.drawCount > 0 ? PerfMath.round2(w.cpuTotal * 1000 / Double(w.drawCount)) : NSNull(),
                "degraded_share": w.drawCount > 0 ? PerfMath.round2(Double(w.degradedFrames) / Double(w.drawCount)) : 0,
            ]
            if w.gpuHistogram.total > 0 { row["gpu_hist"] = w.gpuHistogram.sparse }
            scenes.append(row)
            windows[i].reset()
        }

        let report: [String: Any] = [
            "schema": 2,
            "window_s": PerfMath.round2(seconds),
            "target_fps": targetFPS,
            "pacing": pacingSource,
            "session_active_start_s": PerfMath.round2(windowActiveStart),
            "session_active_s": PerfMath.round2(activeSeconds),
            "thermal_now": Self.name(thermal),
            "thermal_worst": Self.name(worstThermal),
            "memory_mb_peak": PerfMath.round2(Double(peakMemoryBytes) / 1_048_576),
            "scenes": scenes,
        ]
        windowActiveStart = activeSeconds
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
