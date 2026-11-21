import Foundation
import QuartzCore

/// OctiMonitor: real-user performance monitoring for Metal apps.
///
/// ```swift
/// // App launch
/// OctiMonitor.start()                       // reads OctiMonitorEndpoint / OctiMonitorKey from Info.plist
///
/// // Every frame (main thread)
/// commandBuffer.addCompletedHandler { b in
///     OctiMonitor.recordGPU(start: b.gpuStartTime, end: b.gpuEndTime, scene: "Slime")
/// }
/// drawable.addPresentedHandler { d in
///     OctiMonitor.recordPresented(time: d.presentedTime, scene: "Slime", targetFPS: 60)
/// }
/// OctiMonitor.recordFrame(interval: dt, cpu: cpuTime, scene: "Slime", targetFPS: 60)
///
/// // Overlay
/// ZStack { content; OctiMonitorHUD() }
/// ```
///
/// A *scene* is whatever the app wants numbers split by: a material, a tool, a screen.
/// Use a stable string literal (it is hashed every frame, never copied).
public enum OctiMonitor {
    public struct Configuration {
        /// Where reports go: an `https://` URL that accepts a JSON array of rows
        /// (Supabase/PostgREST `…/rest/v1/<table>`). Nil keeps reporting off.
        public var endpoint: URL?
        /// Sent as `apikey`: a Supabase publishable key (`sb_publishable_…`), or a legacy anon key,
        /// which as a JWT is also sent as the bearer token.
        public var apiKey: String
        /// Seconds between reports. A report is also sent when the app goes to the background.
        public var reportInterval: TimeInterval
        /// Forward Apple's daily MetricKit metrics and crash/hang diagnostics.
        public var collectMetricKit: Bool

        public init(endpoint: URL? = nil, apiKey: String = "", reportInterval: TimeInterval = 30,
                    collectMetricKit: Bool = true) {
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.reportInterval = max(5, reportInterval)
            self.collectMetricKit = collectMetricKit
        }

        /// `OctiMonitorEndpoint` and `OctiMonitorKey` from the app's Info.plist; an empty or
        /// non-https endpoint means no reporting (the HUD still works).
        public static func fromInfoPlist(_ bundle: Bundle = .main) -> Configuration {
            let info = bundle.infoDictionary ?? [:]
            let raw = ((info["OctiMonitorEndpoint"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ((info["OctiMonitorKey"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Configuration(endpoint: raw.hasPrefix("https://") ? URL(string: raw) : nil, apiKey: key)
        }
    }

    /// Main thread, once at launch. Safe to call again (later calls are ignored).
    public static func start(_ configuration: Configuration = .fromInfoPlist()) {
        SessionReporter.shared.start(configuration)
        if configuration.collectMetricKit { MetricKitCollector.shared.start() }
    }

    /// True when reports leave the device.
    public static var isReporting: Bool { SessionReporter.shared.isEnabled }

    /// Once per drawn frame, main thread. `interval`: seconds since the previous frame;
    /// `cpu`: seconds spent preparing this one; `targetFPS`: the rate the frame is judged
    /// against, i.e. the requested rate capped by the display
    /// (`min(view.preferredFramesPerSecond, screen.maximumFramesPerSecond)`), or a 60 Hz
    /// phone asked for 120 reports every frame as dropped; `degraded`: the app is running a
    /// reduced quality mode right now.
    public static func recordFrame(interval: Double, cpu: Double, scene: String,
                                   targetFPS: Int, degraded: Bool = false) {
        Monitor.shared.recordFrame(interval: interval, cpu: cpu, scene: scene,
                                   targetFPS: targetFPS, degraded: degraded)
    }

    /// When a frame actually reached the screen: `MTLDrawable.presentedTime`, from the
    /// drawable's presented handler (any thread). Optional but recommended: with it, frame
    /// pacing and hitches are measured from what people see rather than from draw calls.
    /// Register the handler before presenting the drawable.
    public static func recordPresented(time: CFTimeInterval, scene: String, targetFPS: Int) {
        Monitor.shared.recordPresented(time: time, scene: scene, targetFPS: targetFPS)
    }

    /// GPU time of one command buffer, from its completed handler (any thread). Optional:
    /// without it reports mark GPU time as not measured, never as zero.
    public static func recordGPU(start: CFTimeInterval, end: CFTimeInterval, scene: String) {
        Monitor.shared.recordGPU(start: start, end: end, scene: scene)
    }

    /// Sends a report now (main thread), e.g. before a deliberate quit or after a benchmark.
    public static func flush() {
        SessionReporter.shared.flush(inBackground: false)
    }
}
