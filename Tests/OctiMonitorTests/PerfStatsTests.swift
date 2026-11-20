import XCTest
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
        _ = monitor.drainReport()
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
}
