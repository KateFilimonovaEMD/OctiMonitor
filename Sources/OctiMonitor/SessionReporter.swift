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

    private var endpoint: URL?
    private var apiKey = ""
    private let session: URLSession
    private let sessionID = UUID().uuidString.lowercased()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Encoded rows waiting to go out (main thread only).
    private var pending: [Data] = []
    private var sending = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

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
    }

    /// Main thread: closes the current measurement window and sends what is queued.
    func flush(inBackground: Bool) {
        guard isEnabled else { return }
        if let report = Monitor.shared.drainReport() {
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
        pending.append(data)
        trimQueue()
    }

    /// Oldest rows go first when the device stays offline for a long time.
    private func trimQueue() {
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
    }

    private func send(inBackground: Bool) {
        guard let endpoint, !sending, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        sending = true

        // One request for every queued row: PostgREST inserts a JSON array in one go.
        var body = Data("[".utf8)
        for (index, row) in batch.enumerated() {
            if index > 0 { body.append(Data(",".utf8)) }
            body.append(row)
        }
        body.append(Data("]".utf8))

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
                if !delivered {
                    // Keep the rows for the next tick, ahead of anything newer.
                    self.pending = batch + self.pending
                    self.trimQueue()
                    #if DEBUG
                    print("OctiMonitor: report not delivered (status \(status)) \(reason)")
                    #endif
                }
                self.endBackgroundTask()
            }
        }.resume()
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
