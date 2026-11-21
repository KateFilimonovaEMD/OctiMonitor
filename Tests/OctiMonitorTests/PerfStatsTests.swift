import XCTest
import QuartzCore
@testable import OctiMonitor

final class PerfStatsTests: XCTestCase {
    func testRingKeepsNewestInOrder() {
        var ring = SampleRing(capacity: 4)
        for value in 1...6 { ring.append(Float(value)) }
        var out = [Float](repeating: 0, count: 4)
        let n = ring.copy(into: &out)
        XCTAssertEqual(Array(out[0..<n]), [3, 4, 5, 6])
        ring.removeAll()
        XCTAssertEqual(ring.copy(into: &out), 0)
    }

    func testNearestRankPercentiles() {
        var samples = (1...100).reversed().map { Float($0) / 1000 }
        let summary = PercentileSummary(sorting: &samples, count: samples.count)
        XCTAssertEqual(summary.p50, 50, accuracy: 0.001)
        XCTAssertEqual(summary.p95, 95, accuracy: 0.001)
        XCTAssertEqual(summary.p99, 99, accuracy: 0.001)
        XCTAssertEqual(summary.worst, 100, accuracy: 0.001)
        XCTAssertEqual(PercentileSummary(sorting: &samples, count: 0).count, 0)
    }

    func testPacingAt60Hz() {
        let target = 1.0 / 60
        XCTAssertFalse(FramePacing.isDropped(interval: 0.020, target: target), "jitter is not a drop")
        XCTAssertTrue(FramePacing.isDropped(interval: 0.034, target: target), "missed one slot")
        XCTAssertEqual(FramePacing.hitchTime(interval: 0.020, target: target), 0)
        XCTAssertEqual(FramePacing.hitchTime(interval: 0.050, target: target), 0.050 - target, accuracy: 1e-9)
    }

    func testReportSplitsScenes() {
        let monitor = Monitor.shared
        monitor.resetForTesting()
        for _ in 0..<120 {
            monitor.recordFrame(interval: 1.0 / 60, cpu: 0.002, scene: "A", targetFPS: 60, degraded: false)
        }
        monitor.recordFrame(interval: 0.1, cpu: 0.002, scene: "B", targetFPS: 60, degraded: true)
        let report = monitor.drainReport()
        let scenes = report?["scenes"] as? [[String: Any]] ?? []
        XCTAssertEqual(scenes.count, 2)
        let b = scenes.first { $0["scene"] as? String == "B" }
        XCTAssertEqual(b?["dropped_frames"] as? Int, 1)
        XCTAssertEqual(b?["degraded_share"] as? Double, 1)
        XCTAssertNil(monitor.drainReport(), "nothing drawn since the last report")
    }

    func testRetryOnlyWhatCanSucceedLater() {
        XCTAssertTrue(SessionReporter.isWorthRetrying(status: 0), "offline")
        XCTAssertTrue(SessionReporter.isWorthRetrying(status: 503))
        XCTAssertTrue(SessionReporter.isWorthRetrying(status: 429))
        XCTAssertFalse(SessionReporter.isWorthRetrying(status: 400), "rejected rows stay rejected")
        XCTAssertFalse(SessionReporter.isWorthRetrying(status: 401))
    }

    // MARK: - Histograms

    func testHistogramBucketEdges() {
        XCTAssertEqual(DurationHistogram.index(ms: 0), 0)
        XCTAssertEqual(DurationHistogram.index(ms: 16.67), 66)
        XCTAssertEqual(DurationHistogram.index(ms: 49.99), 199)
        XCTAssertEqual(DurationHistogram.index(ms: 50), 200)
        XCTAssertEqual(DurationHistogram.index(ms: 199.9), 274)
        XCTAssertEqual(DurationHistogram.index(ms: 200), 275)
        XCTAssertEqual(DurationHistogram.index(ms: 999), 306)
        XCTAssertEqual(DurationHistogram.index(ms: 5000), DurationHistogram.bucketCount - 1)
        for i in 0..<DurationHistogram.bucketCount {
            let r = DurationHistogram.range(of: i)
            XCTAssertEqual(DurationHistogram.index(ms: (r.lower + r.upper) / 2), i, "bucket \(i) round-trips")
            if i > 0 { XCTAssertEqual(DurationHistogram.range(of: i - 1).upper, r.lower, accuracy: 1e-9, "no gaps") }
        }
    }

    func testHistogramPercentileMatchesExactWithinHalfABucket() {
        var rng = SystemRandomNumberGenerator()
        var values: [Float] = []
        var histogram = DurationHistogram()
        for _ in 0..<20_000 {
            // Mostly on-time frames with a long tail of hitches.
            let ms = Double.random(in: 0..<1, using: &rng) < 0.9
                ? Double.random(in: 15...18, using: &rng) : Double.random(in: 25...120, using: &rng)
            values.append(Float(ms / 1000))
            histogram.add(seconds: ms / 1000)
        }
        let exact = PercentileSummary(sorting: &values, count: values.count)
        for (p, truth) in [(0.50, exact.p50), (0.95, exact.p95), (0.99, exact.p99)] {
            let estimate = histogram.percentile(p) ?? -1
            let bucket = DurationHistogram.range(of: DurationHistogram.index(ms: truth))
            XCTAssertLessThanOrEqual(abs(estimate - truth), (bucket.upper - bucket.lower) / 2 + 1e-6, "p\(Int(p * 100))")
        }
    }

    func testHistogramsAddUpAcrossWindows() {
        var a = DurationHistogram(), b = DurationHistogram(), all = DurationHistogram()
        for ms in stride(from: 1.0, through: 60, by: 0.7) { a.add(seconds: ms / 1000); all.add(seconds: ms / 1000) }
        for ms in stride(from: 10.0, through: 300, by: 3.1) { b.add(seconds: ms / 1000); all.add(seconds: ms / 1000) }
        let merged = zip(a.counts, b.counts).map { $0 + $1 }
        XCTAssertEqual(merged, all.counts, "merging is just adding counts")
        XCTAssertEqual(all.sparse.reduce(0) { $0 + $1[1] }, all.total)
    }

    // MARK: - Screen timing and missing GPU

    func testPresentedTimesDrivePacingAndGPUIsNullWhenMissing() {
        let monitor = Monitor.shared
        monitor.resetForTesting()
        var t: CFTimeInterval = 1000
        for i in 0..<60 {
            // Draw-call intervals look perfect; the screen shows one frame two slots late.
            t += i == 30 ? 3.0 / 60 : 1.0 / 60
            monitor.recordPresented(time: t, scene: "S", targetFPS: 60)
            monitor.recordFrame(interval: 1.0 / 60, cpu: 0.002, scene: "S", targetFPS: 60, degraded: false)
        }
        monitor.recordPresented(time: 0, scene: "S", targetFPS: 60)   // never shown: ignored
        let report = monitor.drainReport()
        XCTAssertEqual(report?["pacing"] as? String, "screen")
        let s = (report?["scenes"] as? [[String: Any]])?.first
        XCTAssertEqual(s?["frames"] as? Int, 59, "60 presentations give 59 intervals")
        XCTAssertEqual(s?["draw_calls"] as? Int, 60)
        XCTAssertEqual(s?["dropped_frames"] as? Int, 1, "the late frame comes from the screen, not the draw calls")
        XCTAssertEqual(s?["target_fps"] as? Int, 60)
        XCTAssertTrue(s?["gpu_ms"] is NSNull, "no GPU samples is 'not measured', never zero")
        XCTAssertEqual(s?["gpu_samples"] as? Int, 0)
        XCTAssertNil(s?["gpu_hist"])
        let hist = s?["frame_hist"] as? [[Int]] ?? []
        XCTAssertEqual(hist.reduce(0) { $0 + $1[1] }, 59)
        monitor.resetForTesting()
    }

    // MARK: - Cost on the render path

    /// What one frame costs the app: recordFrame + recordPresented + recordGPU, as an app
    /// calls them every frame. Prints nanoseconds per frame; fails only if it is absurdly slow.
    func testCostPerFrame() {
        let monitor = Monitor.shared
        monitor.resetForTesting()
        let frames = 200_000
        var t: CFTimeInterval = 5000
        let start = CACurrentMediaTime()
        for i in 0..<frames {
            let scene = i % 3 == 0 ? "A" : "B"
            monitor.recordFrame(interval: 1.0 / 60, cpu: 0.002, scene: scene, targetFPS: 60, degraded: false)
            t += 1.0 / 60
            monitor.recordPresented(time: t, scene: scene, targetFPS: 60)
            monitor.recordGPU(start: t, end: t + 0.008, scene: scene)
        }
        let perFrame = (CACurrentMediaTime() - start) / Double(frames)
        print(String(format: "OctiMonitor cost per frame: %.0f ns (%.4f%% of a 16.7 ms frame)", perFrame * 1e9, perFrame / (1.0 / 60) * 100))
        XCTAssertLessThan(perFrame, 20e-6, "recording a frame should take microseconds, not milliseconds")
        monitor.resetForTesting()
    }
}
