import Foundation

// Runs without Xcode or a simulator (the file is main.swift so swiftc accepts its top-level code):
// swiftc Sources/OctiMonitor/PerfStats.swift Smoke/main.swift -o /tmp/perf-smoke && /tmp/perf-smoke

func check(_ condition: Bool, _ message: String) {
    if !condition {
        print("FAIL: \(message)")
        exit(1)
    }
}

// Ring keeps the newest samples in order after wrapping around.
var ring = SampleRing(capacity: 4)
for value in 1...6 { ring.append(Float(value)) }
var out = [Float](repeating: 0, count: 4)
let n = ring.copy(into: &out)
check(n == 4 && Array(out[0..<n]) == [3, 4, 5, 6], "ring order after wrap: \(out)")
ring.removeAll()
check(ring.copy(into: &out) == 0, "ring empty after removeAll")

// Nearest-rank percentiles on 1...100 ms.
var samples = (1...100).reversed().map { Float($0) / 1000 }
let summary = PercentileSummary(sorting: &samples, count: samples.count)
check(abs(summary.p50 - 50) < 0.001, "p50 \(summary.p50)")
check(abs(summary.p95 - 95) < 0.001, "p95 \(summary.p95)")
check(abs(summary.p99 - 99) < 0.001, "p99 \(summary.p99)")
check(abs(summary.worst - 100) < 0.001, "max \(summary.worst)")
check(PercentileSummary(sorting: &samples, count: 0).count == 0, "empty summary")

// Pacing at 60 Hz: on-time and jittery frames are fine, a missed slot is a hitch.
let target = 1.0 / 60
check(!FramePacing.isDropped(interval: 0.020, target: target), "20 ms is jitter, not a drop")
check(FramePacing.isDropped(interval: 0.034, target: target), "34 ms missed a slot")
check(FramePacing.hitchTime(interval: 0.020, target: target) == 0, "no hitch time for jitter")
check(abs(FramePacing.hitchTime(interval: 0.050, target: target) - (0.050 - target)) < 1e-9, "hitch time")

// Histogram: buckets cover 0–1000 ms without gaps and merge by adding counts.
check(DurationHistogram.index(ms: 16.67) == 66, "16.67 ms bucket")
check(DurationHistogram.index(ms: 50) == 200 && DurationHistogram.index(ms: 200) == 275, "bucket boundaries")
var h = DurationHistogram()
for ms in 1...100 { h.add(seconds: Double(ms) / 1000) }
check(abs((h.percentile(0.95) ?? 0) - 95) < 0.001, "histogram p95 \(h.percentile(0.95) ?? -1)")
check(h.sparse.reduce(0) { $0 + $1[1] } == 100, "sparse counts add up")

print("PASS: PerfStatsSmoke")
