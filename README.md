# OctiMonitor

Real-user performance monitoring for iOS Metal apps, as a Swift package with no third-party dependencies. A Unity (C#) package that sends the same report format is planned.

It answers one question: how does the app actually run on real people's phones, frame by frame, split by whatever the app cares about (a material, a tool, a screen)?

- **Frame pacing:** interval p50 / p95 / p99, dropped frames, hitch time (ms of lateness per second, the metric Apple uses in Instruments and MetricKit).
- **CPU and GPU time per frame.** GPU time comes from `MTLCommandBuffer.gpuStartTime`/`gpuEndTime`.
- **Memory** (`phys_footprint`, the figure iOS uses for jetsam) and **thermal state**.
- **Live HUD** overlay for Debug and TestFlight builds.
- **Reports:** anonymous JSON every 30 s and on background, batched into one HTTPS request (Supabase/PostgREST or any endpoint that accepts a JSON array).
- **MetricKit:** Apple's daily field metrics and crash/hang diagnostics, sent the same way.

## Integration

1. Xcode → File → Add Package Dependencies… → `https://github.com/KateFilimonovaEMD/OctiMonitor` (branch `main` until the first version tag), and link the `OctiMonitor` product to the app target.
2. Start it at launch:

```swift
import OctiMonitor

@main struct MyApp: App {
    init() { OctiMonitor.start() }   // reads OctiMonitorEndpoint / OctiMonitorKey from Info.plist
    var body: some Scene {
        WindowGroup { ZStack { ContentView(); OctiMonitorHUD() } }
    }
}
```

3. Record each frame in the `MTKViewDelegate`:

```swift
func draw(in view: MTKView) {
    let start = CACurrentMediaTime()
    let scene = "Slime"                     // stable string literal
    commandBuffer.addCompletedHandler { b in
        OctiMonitor.recordGPU(start: b.gpuStartTime, end: b.gpuEndTime, scene: scene)
    }
    // … encode, present, commit …
    OctiMonitor.recordFrame(interval: start - lastFrame, cpu: CACurrentMediaTime() - start,
                            scene: scene,
                            targetFPS: min(view.preferredFramesPerSecond,
                                           view.window?.screen.maximumFramesPerSecond ?? 60),
                            degraded: qualityReduced)
    lastFrame = start
}
```

`recordGPU` is optional: an app that has no Metal command buffer of its own can send frame timing alone. Its GPU fields stay 0, and the dashboard says that GPU time isn't reported instead of drawing empty bars.

Without an endpoint the package never touches the network, but the HUD still works.

## Overhead

On the render path each frame costs one lock, one dictionary lookup and a few writes into rings allocated up front, with **no heap allocation** once a scene has been seen. Memory and thermal state are sampled once a second. Percentiles are computed only on demand: 4× a second while the HUD is open, and once per report.

## HUD

- Debug and TestFlight builds show a small gauge button in the top-left corner; tap it to open or close the panel. App Store builds have no button.
- In any build, the launch argument `-octiMonitor.hud YES` opens the panel.

The panel shows the scene, thermal state, FPS against the target, frame p95/p99, GPU p50/p95, hitch ms/s, memory, and a graph of recent frames with missed frames marked in red. It takes no touches.

## Backend (Supabase)

The table and its access rule live in [`Backend/schema.sql`](Backend/schema.sql). [`Backend/dashboard.sql`](Backend/dashboard.sql) adds one read-only function that returns aggregates for a public dashboard (live example: https://evamariadreams.com/octimonitor/, with a page on how every number is measured: https://evamariadreams.com/octimonitor/docs/). Run both once in the Supabase SQL Editor.

Info.plist:

| Key | Value |
|---|---|
| `OctiMonitorEndpoint` | `https://<project>.supabase.co/rest/v1/perf_reports` |
| `OctiMonitorKey` | the project's publishable key (`sb_publishable_…`) or legacy anon key; insert-only under the policy above |

Or configure it in code: `OctiMonitor.start(.init(endpoint: url, apiKey: key, reportInterval: 30))`.

A `perf` row:

```json
{
  "app": "com.example.app", "kind": "perf", "session": "…", "device": "iPhone15,2",
  "os": "iOS 18.1.0", "app_version": "1.0 (12)", "build": "release",
  "payload": {
    "window_s": 30.01, "target_fps": 60, "thermal_now": "fair", "thermal_worst": "fair",
    "memory_mb_peak": 212.4,
    "scenes": [{
      "scene": "Slime", "frames": 1790, "seconds": 29.9, "fps": 59.87,
      "frame_ms": {"p50": 16.67, "p95": 17.4, "p99": 33.3, "max": 50.1, "n": 1790},
      "gpu_ms":   {"p50": 6.1, "p95": 8.9, "p99": 11.2, "max": 14.0, "n": 1790},
      "cpu_ms_avg": 2.3, "dropped_frames": 4, "hitch_ms_per_s": 2.1, "degraded_share": 0
    }]
  }
}
```

## Privacy

Reports contain no user, device or advertising identifiers. `session` is a random UUID created at launch and never stored. The package ships its own `PrivacyInfo.xcprivacy` declaring Performance Data and Crash Data as not linked to the user and not used for tracking. If reporting is enabled in an App Store build, declare the same in App Store Connect.

## Definitions

- **Dropped frame:** an interval longer than 1.5 display intervals (more than 25 ms at 60 Hz).
- **Hitch time:** for dropped frames only, `interval − display interval`, summed and divided by the time played. Under 5 ms/s is good, 5–10 ms/s is noticeable, over 10 ms/s is bad.
- Gaps longer than 1 s are treated as pauses, not frames.

## Tests

- `Tests/OctiMonitorTests`: XCTest, run in Xcode on a simulator. GitHub Actions runs them on every push (`.github/workflows/ci.yml`), together with the smoke test below.
- `Smoke/main.swift`: pure-math check that needs only `swiftc`:
  `swiftc Sources/OctiMonitor/PerfStats.swift Smoke/main.swift -o /tmp/s && /tmp/s`

## Known limits

- The report queue lives in memory (up to 20 reports), so reports that haven't been sent are lost if the app is killed while offline.
- Reports are retried when the device is offline, the request times out, or the server answers 408, 429 or 5xx. Any other 4xx means the server rejected the rows themselves, so they are dropped rather than holding up newer reports.
- MetricKit crash stacks arrive unsymbolicated: match the addresses against the build's dSYM.
