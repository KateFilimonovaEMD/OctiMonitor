import Foundation
import MetricKit

/// Apple's own field data. About once a day iOS hands over a summary of real use (launch
/// time, hangs, animation hitches, memory, battery, thermal) and, separately, crash and hang
/// diagnostics with call stacks. Both go out through SessionReporter, next to the
/// per-frame numbers. Does nothing when reporting is off.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitCollector()
    private var started = false

    /// Main thread, once at launch.
    func start() {
        guard !started, SessionReporter.shared.isEnabled else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { forward(kind: "metrickit", json: payload.jsonRepresentation()) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { forward(kind: "diagnostic", json: payload.jsonRepresentation()) }
    }

    private func forward(kind: String, json: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return }
        SessionReporter.shared.submit(kind: kind, payload: object)
    }
}
