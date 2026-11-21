import Foundation
import UIKit

/// Sends a short anonymous performance report every few seconds (30 by default) and when
/// the app goes to the background.
///
/// Off without an https endpoint, so such a build never touches the network. The endpoint
/// takes a JSON array of rows (Supabase/PostgREST `POST /rest/v1/<table>`); the key is sent
/// as its `apikey`. Each row carries only: the app's bundle id, a random id made at launch
/// (not stored), the device model, the OS and app version, and the numbers. No user,
/// device or advertising identifiers.
final class SessionReporter {
    static let shared = SessionReporter()
    private static let maxPending = 20
    /// The server refuses payloads over 256 KB, and one refused row fails the whole batch it
    /// travels in, so oversized rows (in practice only huge MetricKit diagnostics) are not sent.
    private static let maxRowBytes = 200_000

    private var endpoint: URL?
    private var apiKey = ""
    private let session: URLSession
    private let sessionID = UUID().uuidString.lowercased()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Encoded rows waiting to go out, and the batch currently being sent (main thread only).
    private var pending: [Data] = []
    private var inFlight: [Data] = []
    private var sending = false
    /// The queue file on disk holds rows that may still need sending.
    private var savedToDisk = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// Rows lost since the last report (queue full, or rejected by the server). Sent with the
    /// next report so the dashboard can show how complete the data is.
    private var droppedRows = 0
    /// Saved reports older than this (by the end of their window) are discarded rather than
    /// sent late: the dashboard trusts a phone's timestamp only within two days of arrival.
    private static let savedRowsLifetime: TimeInterval = 24 * 3600
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config)
    }

    var isEnabled: Bool { endpoint != nil }

    /// Main thread, once at launch; later calls are ignored.
    func start(_ configuration: OctiMonitor.Configuration) {
        guard timer == nil, let url = configuration.endpoint, url.scheme == "https" else { return }
        endpoint = url
        apiKey = configuration.apiKey
        let timer = Timer(timeInterval: configuration.reportInterval, repeats: true) { [weak self] _ in
            self?.flush(inBackground: false)
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.flush(inBackground: true)
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.saveQueue()
            })
        // Reports the app couldn't send before it was closed go out with the first report. The
        // file stays until the server confirms them, in case the app is closed again first.
        let saved = Self.loadSavedRows()
        pending = saved.rows + pending
        droppedRows += saved.expired
        savedToDisk = !saved.rows.isEmpty
        trimQueue()
    }

    /// Main thread: closes the current measurement window and sends what is queued.
    func flush(inBackground: Bool) {
        guard isEnabled else { return }
        if var report = Monitor.shared.drainReport() {
            report["ended_at"] = Self.isoFormatter.string(from: Date())
            report["reports_dropped"] = droppedRows
            droppedRows = 0
            enqueue(kind: "perf", payload: report)
        }
        send(inBackground: inBackground)
    }

    /// Any thread (MetricKit delivers on its own queue).
    func submit(kind: String, payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled else { return }
            self.enqueue(kind: kind, payload: payload)
            self.send(inBackground: false)
        }
    }

    // MARK: - Queue and upload

    private func enqueue(kind: String, payload: [String: Any]) {
        let row: [String: Any] = [
            "app": Self.appID,
            "kind": kind,
            "session": sessionID,
            "device": Self.deviceModel,
            "os": Self.osVersion,
            "app_version": Self.appVersion,
            "build": Self.buildChannel,
            "payload": payload,
        ]
        guard JSONSerialization.isValidJSONObject(row),
              let data = try? JSONSerialization.data(withJSONObject: row) else { return }
        guard data.count <= Self.maxRowBytes else {
            if kind == "perf" { droppedRows += 1 }
            return
        }
        pending.append(data)
        trimQueue()
    }

    /// Oldest rows go first when the device stays offline for a long time.
    private func trimQueue() {
        if pending.count > Self.maxPending {
            droppedRows += pending.count - Self.maxPending
            pending.removeFirst(pending.count - Self.maxPending)
        }
    }

    // MARK: - Saved rows (survive the app being closed while offline)

    private static var savedRowsURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OctiMonitor-pending.json")
    }

    /// Main thread. Writes every row not yet confirmed by the server (the batch in flight and
    /// the queue) so they aren't lost if the app is closed; rewritten after each response, so a
    /// delivered batch leaves the file and is never sent twice.
    private func saveQueue() {
        guard let url = Self.savedRowsURL else { return }
        let rows = Array((inFlight + pending).suffix(Self.maxPending))
        savedToDisk = !rows.isEmpty
        if rows.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? Self.arrayBody(rows).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Rows from the file, without the ones too old to send. Leaves the file in place.
    private static func loadSavedRows() -> (rows: [Data], expired: Int) {
        guard let url = savedRowsURL, let data = try? Data(contentsOf: url) else { return ([], 0) }
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            try? FileManager.default.removeItem(at: url)   // unreadable: start clean
            return ([], 0)
        }
        var rows: [Data] = []
        var expired = 0
        for object in objects {
            let ended = ((object["payload"] as? [String: Any])?["ended_at"] as? String).flatMap(isoFormatter.date(from:))
            if let ended, Date().timeIntervalSince(ended) > savedRowsLifetime {
                expired += 1
                continue
            }
            if let row = try? JSONSerialization.data(withJSONObject: object) { rows.append(row) }
        }
        if rows.isEmpty { try? FileManager.default.removeItem(at: url) }
        return (rows, expired)
    }

    private static func arrayBody(_ rows: [Data]) -> Data {
        var body = Data("[".utf8)
        for (index, row) in rows.enumerated() {
            if index > 0 { body.append(Data(",".utf8)) }
            body.append(row)
        }
        body.append(Data("]".utf8))
        return body
    }

    private func send(inBackground: Bool) {
        // Leaving the app: keep everything unconfirmed on disk, including a batch that is
        // already on its way from before (the request may be suspended with the app).
        defer { if inBackground { saveQueue() } }
        guard let endpoint, !sending, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        inFlight = batch
        sending = true

        // One request for every queued row: PostgREST inserts a JSON array in one go.
        let body = Self.arrayBody(batch)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "apikey")
            // Legacy anon keys are JWTs and also go in Authorization; new publishable keys
            // (sb_publishable_…) are not JWTs and must only be sent as apikey.
            if apiKey.hasPrefix("eyJ") {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        // Going to the background: ask iOS for a few seconds so the last report gets out.
        if inBackground && backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "octimonitor-report") { [weak self] in
                self?.endBackgroundTask()
            }
        }

        session.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let delivered = error == nil && (200..<300).contains(status)
            let reason = error?.localizedDescription ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                self.sending = false
                self.inFlight = []
                if !delivered {
                    // Offline, timeout, rate limit or a server error: keep the rows for the next tick,
                    // ahead of anything newer. Any other 4xx means the server rejected the rows
                    // themselves; sending them again would fail the same way and hold up every
                    // newer report behind them, so they are dropped.
                    if Self.isWorthRetrying(status: status) {
                        self.pending = batch + self.pending
                        self.trimQueue()
                    } else {
                        self.droppedRows += batch.count
                    }
                    #if DEBUG
                    print("OctiMonitor: report not delivered (status \(status)) \(reason)")
                    #endif
                }
                // The file may hold this batch (saved when the app left, even if the request
                // started earlier): rewrite it so delivered rows leave it and kept ones stay.
                if self.savedToDisk { self.saveQueue() }
                self.endBackgroundTask()
            }
        }.resume()
    }

    /// 0 is a transport error (no response at all).
    static func isWorthRetrying(status: Int) -> Bool {
        status == 0 || status == 408 || status == 429 || status >= 500
    }

    /// Main thread.
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Context

    /// Model identifier such as "iPhone15,2" (the simulator reports the model it imitates).
    static let deviceModel: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated + " (simulator)"
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    static let appID: String = Bundle.main.bundleIdentifier ?? "unknown"

    static let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()

    static let buildChannel: String = {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }()
}
