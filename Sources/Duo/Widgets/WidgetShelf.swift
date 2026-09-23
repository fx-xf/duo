import AppKit
import SwiftUI
import Combine

// MARK: - Layout shared by the live shelf and the settings preview

struct WidgetItem: Identifiable, Equatable {
    let kind: WidgetKind
    let face: WidgetFace
    var id: WidgetKind { kind }
}

/// A run of widgets beside the Dock. `items` come nearest-the-Dock first, and
/// `towardDock` is the edge the Dock lies beyond — where new widgets bud from.
struct WidgetStack: View {
    let items: [WidgetItem]
    let size: CGFloat
    let gap: CGFloat
    let towardDock: Edge

    private var horizontal: Bool { towardDock == .leading || towardDock == .trailing }

    /// On-screen order: whichever end faces the Dock holds the nearest widget.
    private var ordered: [WidgetItem] {
        towardDock == .trailing || towardDock == .bottom ? items.reversed() : items
    }

    private var alignment: Alignment {
        switch towardDock {
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    var body: some View {
        glass {
            if horizontal {
                HStack(spacing: gap) { bubbles }
            } else {
                VStack(spacing: gap) { bubbles }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: items.map(\.kind))
    }

    private var bubbles: some View {
        ForEach(ordered) { item in
            WidgetBubble(face: item.face, size: size)
                .transition(.bud(from: towardDock, distance: size + gap))
        }
    }

    /// In one glass container, discs that come close melt into each other — so
    /// a widget pulling away from its neighbour pinches off like a drop.
    @ViewBuilder
    private func glass<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: gap * 1.6) { content() }
        } else {
            content()
        }
    }
}

private struct Bud: ViewModifier {
    let settled: Bool
    let offset: CGSize

    func body(content: Content) -> some View {
        content
            .scaleEffect(settled ? 1 : 0.32)
            .offset(settled ? .zero : offset)
            .blur(radius: settled ? 0 : 5)
            .opacity(settled ? 1 : 0)
    }
}

extension AnyTransition {
    /// Grows out of whatever lies toward the Dock — the Dock itself, or the
    /// widget nearer to it — and slides out into place; leaves the same way.
    static func bud(from edge: Edge, distance: CGFloat) -> AnyTransition {
        let offset: CGSize
        switch edge {
        case .leading: offset = CGSize(width: -distance, height: 0)
        case .trailing: offset = CGSize(width: distance, height: 0)
        case .top: offset = CGSize(width: 0, height: -distance)
        case .bottom: offset = CGSize(width: 0, height: distance)
        }
        return .modifier(active: Bud(settled: false, offset: offset), identity: Bud(settled: true, offset: .zero))
    }
}

// MARK: - The live shelf

/// System widgets beside the Dock: battery always, the rest when they have
/// something to say. Two click-through windows, one either side of the Dock.
final class WidgetShelf: ObservableObject {
    @Published private(set) var dockIsExact = false

    let status = SystemStatus()
    fileprivate let state = ShelfState()
    private let prefs = Preferences.shared

    private var windows: [ShelfSide: NSWindow] = [:]
    private var layout: DockLayout?
    private var volumeUntil = Date.distantPast
    private var networkUntil = Date.distantPast
    private var expiry: DispatchWorkItem?
    private var dockTimer: Timer?
    private var live = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()

    /// Room around the discs for the spring to overshoot into.
    private static let pad: CGFloat = 18

    init() {
        prefs.$widgetsEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in enabled ? self?.show() : self?.hide() }
            .store(in: &cancellables)
    }

    // MARK: on and off

    private func show() {
        status.start()
        for side in [ShelfSide.leading, .trailing] where windows[side] == nil {
            windows[side] = makeWindow(side)
        }
        relayout(animated: false)
        state.leading = []
        state.trailing = []
        windows.values.forEach { $0.orderFrontRegardless() }

        status.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &live)
        status.volumeChanged
            .sink { [weak self] in
                self?.volumeUntil = Date().addingTimeInterval(2.2)
                self?.refresh()
            }
            .store(in: &live)
        status.networkChanged
            .sink { [weak self] in
                self?.networkUntil = Date().addingTimeInterval(3.5)
                self?.refresh()
            }
            .store(in: &live)

        // The Dock grows and shrinks as apps come and go; follow it.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.publisher(for: name)
                .delay(for: .milliseconds(450), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.relayout(animated: true) }
                .store(in: &live)
        }
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.relayout(animated: false) }
            .store(in: &live)
        dockTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.relayout(animated: true)
        }

        // Switching on plays every widget in, one after another.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh(staggered: true) }
    }

    private func hide() {
        live.removeAll()
        dockTimer?.invalidate()
        dockTimer = nil
        expiry?.cancel()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            state.leading = []
            state.trailing = []
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, !self.prefs.widgetsEnabled else { return }
            self.windows.values.forEach { $0.orderOut(nil) }
        }
    }

    // MARK: what shows

    /// Battery always; headphones while connected; network while it is down
    /// and for a moment after it changes; volume for a moment after it moves.
    private func refresh(staggered: Bool = false) {
        guard prefs.widgetsEnabled else { return }
        let now = Date()
        var visible = Set<WidgetKind>()
        if status.battery != nil { visible.insert(.battery) }
        if now < volumeUntil { visible.insert(.volume) }
        if status.audio.headphones != nil { visible.insert(.headphones) }
        if status.network == .offline || now < networkUntil { visible.insert(.network) }

        let leading = [WidgetKind.battery, .volume].filter(visible.contains)
        let trailing = [WidgetKind.headphones, .network].filter(visible.contains)

        if staggered {
            for (index, kind) in (leading + trailing).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.14) { [weak self] in
                    guard let self else { return }
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                        if leading.contains(kind) { self.state.leading = leading.filter { $0 == kind || self.state.leading.contains($0) } }
                        else { self.state.trailing = trailing.filter { $0 == kind || self.state.trailing.contains($0) } }
                    }
                }
            }
        } else if leading != state.leading || trailing != state.trailing {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                state.leading = leading
                state.trailing = trailing
            }
        }

        // Come back when the next transient widget is due to go.
        expiry?.cancel()
        let upcoming = [volumeUntil, networkUntil].filter { $0 > now }.min()
        if let upcoming {
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            expiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + upcoming.timeIntervalSince(now) + 0.02, execute: work)
        }
    }

    fileprivate func face(for kind: WidgetKind) -> WidgetFace {
        switch kind {
        case .battery:
            return .battery(status.battery ?? BatteryState(level: 1, isCharging: false, isPluggedIn: true, isLowPower: false))
        case .volume:
            return .volume(level: status.audio.volume, muted: status.audio.isMuted)
        case .headphones:
            return .headphones(status.audio.headphones ?? .headphones, battery: status.headphoneBattery)
        case .network:
            return .network(status.network)
        }
    }

    // MARK: where it goes

    private func relayout(animated: Bool) {
        guard let screen = NSScreen.builtIn ?? NSScreen.main else { return }
        let layout = DockProbe.measure(on: screen)
        if dockIsExact != layout.exact { dockIsExact = layout.exact }
        guard layout != self.layout else { return }
        let first = self.layout == nil
        self.layout = layout

        if state.bubble != layout.bubbleSize { state.bubble = layout.bubbleSize }
        if state.edge != layout.edge { state.edge = layout.edge }

        let pad = Self.pad
        let bubble = layout.bubbleSize
        let span = bubble * 2 + state.gap + pad * 2
        let thick = bubble + pad * 2
        let dock = layout.frame
        let gap = state.gap

        var frames: [ShelfSide: CGRect] = [:]
        switch layout.edge {
        case .bottom:
            frames[.leading] = CGRect(x: dock.minX - gap - span + pad, y: dock.midY - thick / 2, width: span, height: thick)
            frames[.trailing] = CGRect(x: dock.maxX + gap - pad, y: dock.midY - thick / 2, width: span, height: thick)
        case .left, .right:
            frames[.leading] = CGRect(x: dock.midX - thick / 2, y: dock.maxY + gap - pad, width: thick, height: span)
            frames[.trailing] = CGRect(x: dock.midX - thick / 2, y: dock.minY - gap - span + pad, width: thick, height: span)
        }

        for (side, frame) in frames {
            guard let window = windows[side] else { continue }
            if animated && !first {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                }
            } else {
                window.setFrame(frame, display: true)
            }
            // An auto-hiding Dock leaves nothing to sit beside.
            window.alphaValue = layout.autohides ? 0 : 1
        }
    }

    private func makeWindow(_ side: ShelfSide) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ShelfSideView(shelf: self, state: state, status: status, side: side))
        return window
    }
}

fileprivate enum ShelfSide: Hashable {
    case leading, trailing
}

fileprivate final class ShelfState: ObservableObject {
    /// Nearest the Dock first.
    @Published var leading: [WidgetKind] = []
    @Published var trailing: [WidgetKind] = []
    @Published var bubble: CGFloat = 74
    @Published var edge: DockEdge = .bottom
    let gap: CGFloat = 10
}

private struct ShelfSideView: View {
    let shelf: WidgetShelf
    @ObservedObject var state: ShelfState
    @ObservedObject var status: SystemStatus
    let side: ShelfSide

    private var towardDock: Edge {
        switch (state.edge, side) {
        case (.bottom, .leading): return .trailing
        case (.bottom, .trailing): return .leading
        case (_, .leading): return .bottom
        case (_, .trailing): return .top
        }
    }

    var body: some View {
        let kinds = side == .leading ? state.leading : state.trailing
        WidgetStack(items: kinds.map { WidgetItem(kind: $0, face: shelf.face(for: $0)) },
                    size: state.bubble,
                    gap: state.gap,
                    towardDock: towardDock)
            .padding(18)
    }
}
