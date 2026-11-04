import AppKit
import SwiftUI

enum Brand {
    static let navy = Color(red: 10 / 255, green: 25 / 255, blue: 41 / 255)
    static let lightNavy = Color(red: 21 / 255, green: 44 / 255, blue: 66 / 255)
    static let red = Color(red: 230 / 255, green: 57 / 255, blue: 70 / 255)
    static let yellow = Color(red: 1, green: 214 / 255, blue: 10 / 255)
    static let gray = Color(red: 138 / 255, green: 148 / 255, blue: 166 / 255)
}

@MainActor
final class PanelModel: ObservableObject {
    enum Mode: Equatable {
        case hidden
        case recording
        case working(String)
        case message(String, good: Bool)
    }
    @Published var mode: Mode = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: 18)
    @Published var handsFree = false
    @Published var startedAt = Date()

    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

/// Floating pill near the bottom of the screen. Never takes keyboard focus.
@MainActor
final class RecordingPanel {
    let model = PanelModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
    }

    func showRecording(handsFree: Bool) {
        hideWork?.cancel()
        model.levels = Array(repeating: 0, count: model.levels.count)
        model.handsFree = handsFree
        model.startedAt = Date()
        model.mode = .recording
        present()
    }

    func showWorking(_ text: String) {
        hideWork?.cancel()
        model.mode = .working(text)
        present()
    }

    func flash(_ text: String, good: Bool = true, seconds: Double = 1.6) {
        hideWork?.cancel()
        model.mode = .message(text, good: good)
        present()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        model.mode = .hidden
        panel.orderOut(nil)
    }

    private func present() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 36))
        }
        panel.orderFrontRegardless()
    }
}

struct PillView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .hidden:
                EmptyView()
            case .recording:
                recording
            case .working(let text):
                ProgressView().controlSize(.small).tint(Brand.yellow)
                Text(text).foregroundStyle(.white)
            case .message(let text, let good):
                Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(good ? Brand.yellow : Brand.red)
                Text(text).foregroundStyle(.white)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(Brand.navy))
        .overlay(Capsule().strokeBorder(Brand.lightNavy, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .opacity(model.mode == .hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var recording: some View {
        Circle().fill(Brand.red).frame(width: 9, height: 9)
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Brand.yellow.opacity(0.55 + Double(level) * 0.45))
                    .frame(width: 3, height: 4 + CGFloat(level) * 20)
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.08), value: model.levels)
        TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
            let s = Int(context.date.timeIntervalSince(model.startedAt))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .monospacedDigit()
                .foregroundStyle(Brand.gray)
        }
        if model.handsFree {
            Text("hands-free").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Brand.yellow)
        }
        Button { model.onCancel?() } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22).background(Circle().fill(Brand.lightNavy))
        }
        .buttonStyle(.plain).foregroundStyle(Brand.gray).help("Cancel (Esc)")
        Button { model.onFinish?() } label: {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22).background(Circle().fill(Brand.red))
        }
        .buttonStyle(.plain).foregroundStyle(.white).help("Finish")
    }
}
