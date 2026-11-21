import Foundation

// Pure math for OctiMonitor: no UIKit, no Metal, so it can be compiled and tested alone.

/// A fixed-size ring of the latest samples (seconds). All storage is allocated once in
/// `init`, so adding a sample on the render path never allocates.
struct SampleRing {
    private var storage: [Float]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: Swift.max(1, capacity))
    }

    var capacity: Int { storage.count }

    mutating func append(_ value: Float) {
        storage[head] = value
        head += 1
        if head == storage.count { head = 0 }
        if count < storage.count { count += 1 }
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }

    /// Copies the samples, oldest first, into `out` and returns how many were copied.
    /// `out` only grows when it is smaller than the ring.
    func copy(into out: inout [Float]) -> Int {
        if out.count < count { out = [Float](repeating: 0, count: storage.count) }
        var index = head - count
        if index < 0 { index += storage.count }
        for i in 0..<count {
            out[i] = storage[index]
            index += 1
            if index == storage.count { index = 0 }
        }
        return count
    }
}

/// Nearest-rank percentiles of a set of durations: seconds in, milliseconds out.
struct PercentileSummary {
    private(set) var count = 0
    private(set) var p50: Double = 0
    private(set) var p95: Double = 0
    private(set) var p99: Double = 0
    private(set) var worst: Double = 0

    init() {}

    /// Sorts the first `count` values of `values` in place (no allocation) and reads the
    /// percentiles from them.
    init(sorting values: inout [Float], count: Int) {
        let n = Swift.min(count, values.count)
        guard n > 0 else { return }
        values.withUnsafeMutableBufferPointer { buffer in
            var prefix = UnsafeMutableBufferPointer(rebasing: buffer[0..<n])
            prefix.sort()
        }
        self.count = n
        p50 = Self.rank(0.50, values, n)
        p95 = Self.rank(0.95, values, n)
        p99 = Self.rank(0.99, values, n)
        worst = Double(values[n - 1]) * 1000
    }

    private static func rank(_ p: Double, _ sorted: [Float], _ n: Int) -> Double {
        let index = Swift.min(n - 1, Swift.max(0, Int((p * Double(n)).rounded(.up)) - 1))
        return Double(sorted[index]) * 1000
    }

    /// For JSON reports, rounded to 0.01 ms.
    var dictionary: [String: Any] {
        ["p50": PerfMath.round2(p50), "p95": PerfMath.round2(p95),
         "p99": PerfMath.round2(p99), "max": PerfMath.round2(worst), "n": count]
    }
}

/// Fixed-bucket histogram of durations. Unlike a percentile, histograms can be added
/// together, so the server can merge any number of windows, phones or days and read the
/// percentiles of all of those frames at once, accurate to half a bucket.
///
/// Buckets (milliseconds): 0.25 wide below 50, 2 wide from 50 to 200, 25 wide from 200 to
/// 1000. Storage is allocated once; adding a sample is one division and one increment.
/// The server mirrors these edges in `octimonitor_bucket_mid` (Backend/dashboard.sql).
struct DurationHistogram {
    static let bucketCount = 307
    private(set) var counts: [UInt32]
    private(set) var total = 0

    init() { counts = [UInt32](repeating: 0, count: Self.bucketCount) }

    static func index(ms: Double) -> Int {
        guard ms.isFinite, ms > 0 else { return 0 }
        if ms < 50 { return Int(ms / 0.25) }
        if ms < 200 { return 200 + Int((ms - 50) / 2) }
        if ms < 1000 { return 275 + Int((ms - 200) / 25) }
        return bucketCount - 1
    }

    /// Lower and upper edge of a bucket, in milliseconds.
    static func range(of index: Int) -> (lower: Double, upper: Double) {
        switch index {
        case ..<200: return (Double(index) * 0.25, Double(index + 1) * 0.25)
        case ..<275: return (50 + Double(index - 200) * 2, 50 + Double(index - 199) * 2)
        default: return (200 + Double(index - 275) * 25, 200 + Double(index - 274) * 25)
        }
    }

    mutating func add(seconds: Double) {
        counts[Self.index(ms: seconds * 1000)] &+= 1
        total += 1
    }

    mutating func removeAll() {
        guard total > 0 else { return }
        for i in counts.indices { counts[i] = 0 }
        total = 0
    }

    /// Nearest-rank percentile read at the middle of its bucket, in milliseconds.
    func percentile(_ p: Double) -> Double? {
        guard total > 0 else { return nil }
        let rank = Swift.max(1, Int((p * Double(total)).rounded(.up)))
        var seen = 0
        for (i, c) in counts.enumerated() where c > 0 {
            seen += Int(c)
            if seen >= rank { let r = Self.range(of: i); return (r.lower + r.upper) / 2 }
        }
        return nil
    }

    /// Only the buckets that have samples, as `[[bucket, count], …]` (built once per report).
    var sparse: [[Int]] {
        var out: [[Int]] = []
        for (i, c) in counts.enumerated() where c > 0 { out.append([i, Int(c)]) }
        return out
    }
}

/// How frames are judged against the display's refresh interval.
enum FramePacing {
    /// The frame missed its slot: it took more than 1.5 display intervals.
    static func isDropped(interval: Double, target: Double) -> Bool {
        interval > target * 1.5
    }

    /// How late a dropped frame was beyond its own slot (Apple's "hitch time");
    /// on-time frames add nothing, so ordinary jitter does not count.
    static func hitchTime(interval: Double, target: Double) -> Double {
        isDropped(interval: interval, target: target) ? interval - target : 0
    }
}

enum PerfMath {
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
