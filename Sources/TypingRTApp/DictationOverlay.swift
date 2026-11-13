import AppKit
import Observation
import SwiftUI
import TypingRTCore

private final class NonactivatingDictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Pointer and timing state that belongs to the overlay, not to a dictation.
@MainActor @Observable
final class OverlayInteraction {
    var isHovered = false
    var notice: String?
    /// Bumped on every app state change: the selected mode and readiness live
    /// outside SwiftUI observation and must still redraw the overlay.
    var revision = 0
}

/// Reports the pointer even while another app is active and lets the first
/// click reach the mode buttons without activating typingRT.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class DictationOverlay: NSObject {
    static let noticeDuration: Duration = .seconds(4)

    private let panel: NSPanel
    private let controller: DictationController
    private let interaction = OverlayInteraction()
    private var wantsVisibility = false
    private var lastMessage: String?
    private var noticeTask: Task<Void, Never>?

    init(controller: DictationController, selectMode: @escaping (DictationMode) -> Void) {
        self.controller = controller
        panel = NonactivatingDictationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Receives hover and mode clicks (see reposition); never key or main.
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        // The panel frame is owned by reposition(). A hosting controller would
        // resize the window to SwiftUI's fitting size (a tall dark block).
        let host = OverlayHostingView(rootView: DictationOverlayView(
            controller: controller, interaction: interaction, selectMode: selectMode))
        host.sizingOptions = []
        host.onHover = { [weak self] hovered in
            guard let self else { return }
            self.interaction.isHovered = hovered
            self.reposition()
        }
        panel.contentView = host
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func refresh() {
        wantsVisibility = true
        interaction.revision &+= 1
        updateNotice()
        reposition()
    }

    @objc private func screenParametersChanged(_ notification: Notification) { reposition() }

    /// Shows each new hint for a few seconds, independent of how soon the
    /// controller clears its message. Routine confirmations stay silent.
    private func updateNotice() {
        if controller.isRecording {
            // A new dictation replaces any older hint.
            noticeTask?.cancel()
            interaction.notice = nil
            lastMessage = nil
            return
        }
        var message = controller.message
        if message == controller.quietMessage { message = nil }
        guard message != lastMessage else { return }
        lastMessage = message
        // A cleared message does not end a hint that is still being shown.
        guard let message else { return }
        noticeTask?.cancel()
        interaction.notice = message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard let self, !Task.isCancelled else { return }
            self.interaction.notice = nil
            self.reposition()
        }
    }

    private func reposition() {
        guard wantsVisibility else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        var presentation = OverlayPresentation(controller: controller, interaction: interaction)
        var frame = OverlayPresentation.frame(size: presentation.panelSize, visibleFrame: screen.visibleFrame)
        // A shrinking window does not reliably deliver mouseExited: hover only
        // counts while the pointer is inside the frame about to be shown.
        if interaction.isHovered, !frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) {
            interaction.isHovered = false
            presentation = OverlayPresentation(controller: controller, interaction: interaction)
            frame = OverlayPresentation.frame(size: presentation.panelSize, visibleFrame: screen.visibleFrame)
        }
        panel.ignoresMouseEvents = !presentation.acceptsPointer
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        wantsVisibility = false
        noticeTask?.cancel()
        panel.orderOut(nil)
    }
}

extension OverlayPresentation {
    @MainActor init(controller: DictationController, interaction: OverlayInteraction) {
        _ = interaction.revision
        self.init(phase: controller.phase,
                  mode: controller.phase == .idle ? controller.modeProvider() : controller.activeMode,
                  message: controller.message, isHovered: interaction.isHovered,
                  notice: interaction.notice, isReady: controller.readinessProvider().canStart)
    }
}

@MainActor
private struct DictationOverlayView: View {
    @Bindable var controller: DictationController
    @Bindable var interaction: OverlayInteraction
    let selectMode: (DictationMode) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shell = Color(red: 10 / 255, green: 11 / 255, blue: 13 / 255)

    var body: some View {
        let state = OverlayPresentation(controller: controller, interaction: interaction)
        content(state)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(AppTheme.text)
            .background(Self.shell, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
            // No autonomous motion: the meter follows microphone data only.
            .transaction { if reduceMotion { $0.animation = nil } }
            .preferredColorScheme(.dark)
            .accessibilityElement(children: state.style == .modes ? .contain : .ignore)
            .accessibilityLabel(accessibilityDescription(state))
    }

    @ViewBuilder private func content(_ state: OverlayPresentation) -> some View {
        switch state.style {
        case .dot:
            dot(ready: state.isReady)
        case .modes:
            HStack(spacing: 10) {
                modeButton(.standard, selected: state.mode)
                dot(ready: state.isReady)
                modeButton(.coding, selected: state.mode)
            }.padding(.horizontal, 8)
        case .recording:
            HStack(spacing: 6) {
                if state.mode == .coding {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(AppTheme.accent)
                }
                levelBars(active: state.showsMeter)
            }
        case .processing:
            if state.isProcessing && !reduceMotion {
                ProgressView().controlSize(.small).scaleEffect(0.75)
            } else {
                Image(systemName: state.phase == .cancelling ? "xmark" : "ellipsis")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(AppTheme.muted)
            }
        case .notice:
            HStack(spacing: 8) {
                Image(systemName: state.phase == .awaitingResult ? "doc.on.clipboard" : "info.circle")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppTheme.accent)
                Text(state.noticeText ?? "").font(.system(size: 11)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 14)
        }
    }

    private func dot(ready: Bool) -> some View {
        Circle().fill(ready ? AppTheme.text.opacity(0.85) : AppTheme.muted.opacity(0.45))
            .frame(width: 9, height: 9)
    }

    private func modeButton(_ mode: DictationMode, selected: DictationMode) -> some View {
        Button { selectMode(mode) } label: {
            Text(mode.title)
                .font(.system(size: 11, weight: mode == selected ? .semibold : .regular))
                .foregroundStyle(mode == selected ? AppTheme.accent : AppTheme.muted)
                .frame(width: 84, height: 26)
                .background(mode == selected ? AppTheme.accent.opacity(0.14) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Modus \(mode.title)")
        .accessibilityAddTraits(mode == selected ? .isSelected : [])
    }

    private func levelBars(active: Bool) -> some View {
        let level = active ? OverlayPresentation.meterLevel(controller.level) : 0
        return HStack(spacing: 3) {
            ForEach(0..<7) { index in
                let envelope = 1 - abs(Double(index - 3)) / 4.5
                Capsule().fill(active ? AppTheme.accent : AppTheme.muted.opacity(0.6))
                    .frame(width: 3, height: 3 + 15 * level * envelope)
            }
        }
        .frame(width: 40, height: 20)
        // Smooths the sampled level; driven by microphone data only.
        .animation(.linear(duration: 0.09), value: level)
    }

    private func accessibilityDescription(_ state: OverlayPresentation) -> String {
        var parts = [state.title, state.mode.title]
        if state.showsMeter { parts.append("Dauer \(OverlayPresentation.duration(controller.elapsedSeconds))") }
        if let notice = state.noticeText { parts.append(notice) }
        return parts.joined(separator: ". ")
    }
}
