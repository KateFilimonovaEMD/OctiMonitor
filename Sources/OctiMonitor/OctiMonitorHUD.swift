import SwiftUI
import StoreKit

/// Live OctiMonitor numbers over the app. Put it on top of the content in a ZStack.
///
/// Debug and TestFlight builds: a small gauge button in the top-left corner opens and closes it.
/// Any build: the launch argument `-octiMonitor.hud YES` opens it.
/// App Store builds have no button. The panel itself takes no touches.
public struct OctiMonitorHUD: View {
    @AppStorage("octiMonitor.hud") private var visible = false
    @State private var testBuild = false

    public init() {}

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if visible {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    PerfPanel(snapshot: Monitor.shared.snapshot())
                }
                .padding(.top, 58)
                .padding(.leading, 10)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
            if testBuild {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { visible.toggle() }
                } label: {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(visible ? 0.95 : 0.6))
                        .frame(width: 34, height: 34)
                        .background(.black.opacity(visible ? 0.62 : 0.35), in: Circle())
                        .frame(width: 60, height: 60)   // easy to hit, the circle stays small
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(visible ? "Hide performance panel" : "Show performance panel")
            }
        }
        .task { testBuild = await Self.isTestBuild() }
    }

    /// Debug, or installed from TestFlight (StoreKit reports the sandbox environment).
    private static func isTestBuild() async -> Bool {
        #if DEBUG
        return true
        #else
        guard let result = try? await AppTransaction.shared else { return false }
        switch result {
        case .verified(let transaction), .unverified(let transaction, _):
            return transaction.environment != .production
        }
        #endif
    }
}

private struct PerfPanel: View {
    let snapshot: Monitor.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(snapshot.scene.isEmpty ? "—" : snapshot.scene)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                thermalChip
            }
            row("FPS", "\(Int(snapshot.fps.rounded())) / \(snapshot.targetFPS)")
            row("Frame p95", ms(snapshot.frame.p95))
            row("Frame p99", ms(snapshot.frame.p99))
            row("GPU p50", ms(snapshot.gpu.p50))
            row("GPU p95", ms(snapshot.gpu.p95))
            row("Hitches", String(format: "%.1f ms/s", snapshot.hitchMsPerSecond))
            row("Memory", String(format: "%.0f MB", snapshot.memoryMB))
            if snapshot.degraded {
                Text("Reduced quality").foregroundStyle(.orange)
            }
            FrameGraph(frames: snapshot.recentFrames,
                       target: 1 / Double(max(1, snapshot.targetFPS)))
                .frame(height: 34)
                .padding(.top, 2)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .frame(width: 172)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: 4)
            Text(value)
        }
    }

    private func ms(_ value: Double) -> String { String(format: "%.1f ms", value) }

    private var thermalChip: some View {
        let style: (String, Color)
        switch snapshot.thermal {
        case .nominal: style = ("cool", .green)
        case .fair: style = ("warm", .yellow)
        case .serious: style = ("hot", .orange)
        case .critical: style = ("critical", .red)
        @unknown default: style = ("?", .gray)
        }
        return HStack(spacing: 3) {
            Circle().fill(style.1).frame(width: 6, height: 6)
            Text(style.0)
        }
    }
}

/// Frame intervals, newest on the right. The dashed line is the frame budget; frames that
/// missed their slot get a red tick. The graph tops out at three budgets.
private struct FrameGraph: View {
    let frames: [Float]
    let target: Double

    var body: some View {
        Canvas { context, size in
            guard frames.count > 1 else { return }
            let ceiling = target * 3
            let step = size.width / CGFloat(frames.count - 1)
            func y(_ seconds: Double) -> CGFloat {
                size.height * (1 - CGFloat(min(seconds / ceiling, 1)))
            }

            var budget = Path()
            budget.move(to: CGPoint(x: 0, y: y(target)))
            budget.addLine(to: CGPoint(x: size.width, y: y(target)))
            context.stroke(budget, with: .color(.white.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            var line = Path()
            var misses = Path()
            for (index, value) in frames.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: y(Double(value)))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                if FramePacing.isDropped(interval: Double(value), target: target) {
                    misses.move(to: CGPoint(x: point.x, y: size.height))
                    misses.addLine(to: point)
                }
            }
            context.stroke(misses, with: .color(.red.opacity(0.8)), lineWidth: 1)
            context.stroke(line, with: .color(.mint), lineWidth: 1)
        }
    }
}
