import AppKit
import SwiftUI
import TheListCore

/// E11: a stickman each for Claude and Codex on a floor line, at the bottom of the popover. One
/// runs while its agent works, sits when it's idle (or waiting on me), and lies down when it's
/// out of usage.
///
/// Built to cost nothing when nobody's looking: a `Canvas` of a few strokes, redrawn 12 times a
/// second only while a figure is running and the popover is on screen. Sitting and lying are
/// still, so the timeline is paused and nothing is drawn after the first frame.
struct AgentScene: View {
    let claude: AgentPose
    let codex: AgentPose
    /// Saiyan mode is on: both figures get spiky gold hair.
    var saiyan = false
    /// False for `--render`, which draws a single frame.
    var live = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false

    private var animating: Bool {
        live && onScreen && !reduceMotion && (claude.isRunning || codex.isRunning)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animating)) { context in
            let t = animating ? context.date.timeIntervalSinceReferenceDate : 0.15
            HStack(spacing: 0) {
                figureColumn("Claude", claude, head: Color(cgColor: Logo.coral), t: t)
                figureColumn("Codex", codex, head: nil, t: t + 0.37)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1).padding(.horizontal, 14).padding(.bottom, 9)
        }
        .background { if live { VisibilityTracker(onScreen: $onScreen) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude \(claude.caption), Codex \(codex.caption)")
    }

    private func figureColumn(_ name: String, _ pose: AgentPose, head: Color?, t: Double) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            Canvas { ctx, size in
                Stickman.draw(in: &ctx, at: CGPoint(x: size.width / 2, y: size.height - 1), pose: pose, t: t, head: head, saiyan: saiyan)
            }
            .frame(width: 22, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(pose.caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .padding(.bottom, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .help(pose.help(name))
    }
}

extension AgentPose {
    var isRunning: Bool { if case .running = self { return true } else { return false } }

    var caption: String {
        switch self {
        case let .running(project): project.isEmpty ? "running" : "running · \(project)"
        case .sitting: "idle"
        case let .lying(resets): resets.isEmpty ? "no tokens" : "no tokens till \(resets)"
        }
    }

    func help(_ name: String) -> String {
        switch self {
        case .running: "\(name) is working."
        case .sitting: "\(name) has tokens left and nothing to do right now."
        case let .lying(resets):
            "\(name) has used up its usage limit" + (resets.isEmpty ? " for now." : ". It resets at \(resets).")
        }
    }
}

/// The figure, in points, with its feet at `at`. Drawn in the label color, so it follows
/// light and dark; `head` fills the head (Claude's coral), nil leaves it hollow.
enum Stickman {
    static func draw(in ctx: inout GraphicsContext, at origin: CGPoint, pose: AgentPose, t: Double, head: Color?, saiyan: Bool) {
        ctx.translateBy(x: origin.x, y: origin.y)
        let ink = GraphicsContext.Shading.style(.primary)
        let stroke = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        func line(_ points: [CGPoint]) {
            var path = Path()
            path.addLines(points)
            ctx.stroke(path, with: ink, style: stroke)
        }
        /// Two segments from `o`: angles from straight down, in radians.
        func limb(_ o: CGPoint, _ a1: Double, _ l1: Double, _ a2: Double, _ l2: Double) -> [CGPoint] {
            let k = CGPoint(x: o.x + sin(a1) * l1, y: o.y + cos(a1) * l1)
            return [o, k, CGPoint(x: k.x + sin(a2) * l2, y: k.y + cos(a2) * l2)]
        }

        let headCenter: CGPoint
        switch pose {
        case .running:
            let p = t * .pi * 2 * 2.2, bob = -abs(sin(p)) * 1.1
            let hip = CGPoint(x: 0, y: -8.5 + bob), neck = CGPoint(x: 1.6, y: -15 + bob)
            headCenter = CGPoint(x: 2.2, y: -18.3 + bob)
            for s in [0, Double.pi] {
                let a = 0.75 * sin(p + s)                          // thigh swing
                let knee = 0.2 + 1.1 * max(0, sin(p + s + 1.6))    // knee bends on the back swing
                line(limb(hip, a, 4.6, a - knee, 4.4))
                let b = -0.8 * sin(p + s)                          // arms swing against the legs
                line(limb(neck, b, 3.4, b + 1.3, 3.2))
            }
            line([hip, neck])
        case .sitting:
            let hip = CGPoint(x: -1, y: -1.6), neck = CGPoint(x: -1.6, y: -8.6)
            headCenter = CGPoint(x: -1.6, y: -11.9)
            line([hip, neck])
            line([hip, CGPoint(x: 4.2, y: -6.6), CGPoint(x: 7, y: -0.2)])        // knees up
            line([neck, CGPoint(x: 0.6, y: -5.4), CGPoint(x: 3.8, y: -6.8)])     // arm round the knees
        case .lying:
            headCenter = CGPoint(x: -6.8, y: -3.2)
            let neck = CGPoint(x: -3.4, y: -1.7), hip = CGPoint(x: 4.4, y: -1.4)
            line([neck, hip])
            line([hip, CGPoint(x: 9.6, y: -1.1)])
            line([hip, CGPoint(x: 9.2, y: -0.4)])
            line([CGPoint(x: -2, y: -1.6), CGPoint(x: 2.4, y: -0.6)])
            ctx.draw(Text("z").font(.system(size: 6, weight: .semibold)).foregroundStyle(.secondary), at: CGPoint(x: -1, y: -9))
        }

        if saiyan { drawHair(in: &ctx, head: headCenter, lying: pose.isLying) }
        let circle = Path(ellipseIn: CGRect(x: headCenter.x - 3.2, y: headCenter.y - 3.2, width: 6.4, height: 6.4))
        if let head { ctx.fill(circle, with: .color(head)) } else { ctx.stroke(circle, with: ink, style: stroke) }
    }

    /// Five gold spikes standing off the head, away from the floor when lying.
    private static func drawHair(in ctx: inout GraphicsContext, head c: CGPoint, lying: Bool) {
        var path = Path()
        let spikes: [(Double, Double)] = [(-3.2, 0.4), (-2.4, 4.2), (-1.1, 2.0), (0, 5.4), (1.2, 2.0), (2.6, 4.4), (3.3, 0.4)]
        for (i, (across, out)) in spikes.enumerated() {
            let p = lying
                ? CGPoint(x: c.x - 1.4 - out, y: c.y + across)
                : CGPoint(x: c.x + across, y: c.y - 1.4 - out)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        path.closeSubpath()
        ctx.fill(path, with: .color(Color(red: 1, green: 0.82, blue: 0.12)))
        ctx.stroke(path, with: .color(Color(red: 0.72, green: 0.53, blue: 0.04)), lineWidth: 0.5)
    }
}

private extension AgentPose {
    var isLying: Bool { if case .lying = self { return true } else { return false } }
}

/// Reports whether the popover's window is actually on screen. `MenuBarExtra` keeps its view
/// alive after the popover closes, so `onAppear`/`onDisappear` can't be trusted to stop the
/// animation; the window's occlusion state can.
private struct VisibilityTracker: NSViewRepresentable {
    @Binding var onScreen: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = { visible in
            if onScreen != visible { onScreen = visible }
        }
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return onChange(false) }
            // Selector-based, so it's removed with the view.
            NotificationCenter.default.addObserver(
                self, selector: #selector(report), name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
            report()
        }

        @objc private func report() {
            onChange(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}
