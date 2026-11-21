# OctiMonitor

Real-user performance monitoring for iOS Metal apps, as a Swift package with no third-party dependencies. A Unity (C#) package that sends the same report format is planned.

It answers one question: how does the app actually run on real people's phones, frame by frame, split by whatever the app cares about (a material, a tool, a screen)?

- **Frame pacing from the screen:** intervals between the moments frames were actually shown (`MTLDrawable.presentedTime`), with draw-call intervals as a fallback. p50 / p95 / p99, dropped frames, hitch time (ms of lateness per second, the metric Apple uses in Instruments and MetricKit).
- **Mergeable histograms** of frame and GPU times in every report, so percentiles over any range are computed from all frames, accurate to half a bucket (0.125 ms below 50 ms).
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
    let target = min(view.preferredFramesPerSecond, view.window?.screen.maximumFramesPerSecond ?? 60)
    commandBuffer.addCompletedHandler { b in
        OctiMonitor.recordGPU(start: b.gpuStartTime, end: b.gpuEndTime, scene: scene)
    }
    // … encode …
    drawable.addPresentedHandler { d in      // before present()
        OctiMonitor.recordPresented(time: d.presentedTime, scene: scene, targetFPS: target)
    }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    OctiMonitor.recordFrame(interval: start - lastFrame, cpu: CACurrentMediaTime() - start,
                            scene: scene, targetFPS: target, degraded: qualityReduced)
    lastFrame = start
}
```

`recordPresented` and `recordGPU` are optional. Without the presented handler, pacing is measured from draw calls; without GPU timing, reports send `gpu_ms: null` (never zero) and the dashboard says GPU time isn't reported.

Without an endpoint the package never touches the network, but the HUD still works.

## Overhead

On the render path each frame costs one lock, one dictionary lookup, a few writes into rings and two histogram increments, all allocated up front: **no heap allocation** once a scene has been seen. `testCostPerFrame` records 200,000 frames (draw call, presentation and GPU time) on every CI run and prints the cost: about 1.3 to 1.7 µs per frame on the CI simulator (about 0.01% of a 16.7 ms frame); it fails above 20 µs. Memory and thermal state are sampled once a second. Window percentiles are computed only on demand: 4× a second while the HUD is open, and once per report. To measure on a specific phone, compare Time Profiler and Allocations in Instruments with and without `OctiMonitor.start()`.

## HUD

- Debug and TestFlight builds show a small gauge button in the top-left corner; tap it to open or close the panel. App Store builds have no button.
- In any build, the launch argument `-octiMonitor.hud YES` opens the panel.

The panel shows the scene, thermal state, FPS against the target, frame p95/p99, GPU p50/p95, hitch ms/s, memory, and a graph of recent frames with missed frames marked in red. It takes no touches.

## Backend (Supabase)

New project: run [`Backend/schema.sql`](Backend/schema.sql), [`Backend/hardening.sql`](Backend/hardening.sql) and [`Backend/dashboard.sql`](Backend/dashboard.sql) in the Supabase SQL Editor. A project created with the first version: run [`Backend/migrations/002_accuracy_and_rules.sql`](Backend/migrations/002_accuracy_and_rules.sql) once (it contains the other two and is safe to re-run). It keeps every app that has already sent reports allowed; add apps that haven't reported yet to `octimonitor_apps`.

- `schema.sql`: the table; the app key can only insert.
- `hardening.sql`: only apps listed in `octimonitor_apps` can report (`insert into public.octimonitor_apps values ('com.example.app');`), reports must have the SDK's shape (numbers where numbers belong, in plausible ranges, valid histograms), at most 40 per session and 2,000 per app per minute (over that the API answers 429 and the SDK retries later), and no sequence rights for the public role.
- `dashboard.sql`: one read-only function for a public dashboard. Percentiles from merged histograms, GPU over measured frames only, a frame budget per group from the reported target rates, and per-build, per-phone data so builds can be compared on the same phones. Every field is read defensively, so a malformed row stored before the rules existed can't break it.

Dashboard: [`Dashboard/`](Dashboard/) is a ready-made copy of the live dashboard for your own backend: set your project URL and key in one place and publish the folder anywhere static. Setup in [`Dashboard/README.md`](Dashboard/README.md). Live example: https://evamariadreams.com/octimonitor/, with a page on how every number is measured: https://evamariadreams.com/octimonitor/docs/

Info.plist:

| Key | Value |
|---|---|
| `OctiMonitorEndpoint` | `https://<project>.supabase.co/rest/v1/perf_reports` |
| `OctiMonitorKey` | the project's publishable key (`sb_publishable_…`) or legacy anon key; insert-only under the policy above |

Or configure it in code: `OctiMonitor.start(.init(endpoint: url, apiKey: key, reportInterval: 30))`.

A `perf` row (schema 2). The histograms list only non-empty buckets as `[bucket, count]` and add up to `frames` and `gpu_samples`:

```json
{
  "app": "com.example.app", "kind": "perf", "session": "…", "device": "iPhone15,2",
  "os": "iOS 18.1.0", "app_version": "1.0 (12)", "build": "release",
  "payload": {
    "schema": 2, "window_s": 30.01, "target_fps": 60, "pacing": "screen",
    "ended_at": "2026-11-21T10:15:30.120Z", "reports_dropped": 0,
    "session_active_start_s": 90.02, "session_active_s": 119.93,
    "thermal_now": "fair", "thermal_worst": "fair", "memory_mb_peak": 212.4,
    "scenes": [{
      "scene": "Slime", "target_fps": 60, "frames": 1790, "seconds": 29.91, "fps": 59.85,
      "frame_ms": {"p50": 16.67, "p95": 16.71, "p99": 16.98, "max": 50.1, "n": 1790},
      "frame_hist": [[66, 1720], [67, 66], [133, 3], [200, 1]],
      "gpu_ms": {"p50": 6.1, "p95": 8.9, "p99": 8.98, "max": 8.99, "n": 1790},
      "gpu_samples": 1790, "gpu_hist": [[24, 900], [25, 610], [35, 280]],
      "dropped_frames": 4, "hitch_ms": 84.5, "hitch_ms_per_s": 2.83,
      "draw_calls": 1792, "cpu_ms_avg": 2.3, "degraded_share": 0
    }]
  }
}
```

`frame_ms` and `gpu_ms` are exact for the window (its latest 4,096 frames, which covers 30 s at 120 Hz); the histograms cover every frame. `gpu_ms` is `null` and `gpu_hist` absent when GPU time wasn't recorded. `pacing` says whether intervals came from the screen (`recordPresented`) or from draw calls.

## Privacy

Reports contain no user, device or advertising identifiers. `session` is a random UUID created at launch and never stored. The package ships its own `PrivacyInfo.xcprivacy` declaring Performance Data and Crash Data as not linked to the user and not used for tracking. If reporting is enabled in an App Store build, declare the same in App Store Connect.

## Definitions

- **Dropped frame:** an interval longer than 1.5 display intervals (more than 25 ms at 60 Hz).
- **Hitch time:** for dropped frames only, `interval − display interval`, summed and divided by the time in use. Under 5 ms/s is good, 5–10 ms/s is noticeable, over 10 ms/s is bad.
- **Percentiles:** nearest rank. Exact within a report window; over longer ranges, read from the sum of histograms at the middle of the bucket (buckets 0.25 ms wide below 50 ms, 2 ms to 200 ms, 25 ms to 1 s).
- Gaps longer than 1 s are treated as pauses, not frames.

## Tests

- `Tests/OctiMonitorTests`: XCTest on the iOS Simulator, including histogram merging, screen timing, missing GPU and cost per frame.
- `Backend/tests`: the SQL against a real Postgres. `check_dashboard.py` simulates phones frame by frame and compares the dashboard function's percentiles, fps, hitch time and heat shares with values computed from every frame; `check_rules.sql` checks the ingestion rules as the public role.
- GitHub Actions runs all of it on every push (`.github/workflows/ci.yml`), plus the upgrade path from the first schema.
- `Smoke/main.swift`: pure-math check that needs only `swiftc`:
  `swiftc Sources/OctiMonitor/PerfStats.swift Smoke/main.swift -o /tmp/s && /tmp/s`

## Known limits

- Up to 20 unsent reports wait in memory. When the app goes to the background they are saved to disk, together with a batch still on its way, and the file stays until the server confirms them, including across launches; so closing the app while offline doesn't lose them, and a delivered batch is never sent twice. A crash while offline before the app was ever backgrounded can lose them. Saved reports whose window ended more than a day ago are discarded, and each report counts the ones lost before it.
- Reports are retried when the device is offline, the request times out, or the server answers 408, 429 or 5xx (the rate limits answer 429). Any other 4xx means the server rejected the rows themselves, so they are dropped rather than holding up newer reports. A batch is accepted or rejected as a whole.
- Rows over 200 KB are not sent (the table refuses payloads over 256 KB, and one refused row would fail its whole batch); in practice only very large MetricKit diagnostics come near this.
- MetricKit crash stacks arrive unsymbolicated: match the addresses against the build's dSYM.
- The publishable key can be extracted from the app, so the ingestion rules stop floods and malformed reports, not plausible fakes. Proving reports come from a genuine app needs App Attest checked by a server in front of the database.

## License

MIT. See [LICENSE](LICENSE).
