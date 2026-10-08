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
    var hovered: WidgetKind? = nil
    var onTap: ((WidgetKind) -> Void)? = nil

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
        Group {
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
                .scaleEffect(hovered == item.kind ? 1.07 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered == item.kind)
                .contentShape(Rectangle())
                .onTapGesture { onTap?(item.kind) }
                .transition(.bud(from: towardDock, distance: size + gap))
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

/// System widgets beside the Dock: the Duo glyph always, a headset while one is
/// playing. Two click-through windows, one either side of the Dock; the headset
/// takes a click, and opens the sound menu.
final class WidgetShelf: ObservableObject {
    @Published private(set) var dockIsExact = false

    let status = SystemStatus()
    fileprivate let state = ShelfState()
    private let prefs = Preferences.shared
    private let soundPanel = SoundPanel()

    private var windows: [ShelfSide: NSWindow] = [:]
    private var layout: DockLayout?
    private var dockTimer: Timer?
    private var pointerMonitors: [Any] = []
    /// The Dock is tucked away — a full-screen app, or set to hide itself — so
    /// the widgets go with it and come out only when it does.
    private var dockAway = false
    private var onFullScreenSpace = false
    private var revealed = false
    private var reveal: DispatchWorkItem?
    private var tuck: DispatchWorkItem?
    private var live = Set<AnyCancellable>()
    private var cancellables = Set<AnyCancellable>()

    /// Widgets that answer a click. The rest let it through to the desktop.
    private static let clickable: Set<WidgetKind> = [.headphones]

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
        updateDockPresence()
        state.leading = []
        state.trailing = []
        windows.values.forEach {
            $0.reassertCollectionBehavior()
            $0.orderFrontRegardless()
        }

        status.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }
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
        workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.updateDockPresence() }
            .store(in: &live)
        // Minimising a window grows the Dock without telling anyone. Asking the
        // window server is cheap, so ask often.
        dockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateDockPresence()
            // On a full-screen Space the Dock isn't where it lives; keep the
            // place it had on the desktop.
            if !self.onFullScreenSpace || self.layout == nil { self.relayout(animated: true) }
            self.trackPointer()
        }

        // Windows ignore the mouse until it is over a widget that takes clicks.
        let track: (NSEvent) -> Void = { [weak self] _ in self?.trackPointer() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: track) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            track(event)
            return event
        }) {
            pointerMonitors.append(local)
        }

        // Switching on plays every widget in, one after another.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh(staggered: true) }
    }

    private func hide() {
        live.removeAll()
        dockTimer?.invalidate()
        dockTimer = nil
        pointerMonitors.forEach(NSEvent.removeMonitor)
        pointerMonitors.removeAll()
        reveal?.cancel()
        tuck?.cancel()
        revealed = false
        soundPanel.close()
        setHovered(nil)
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

    /// The Duo glyph — battery, network and volume in one, as on the iPhone Duo —
    /// always; a headset on the other side for as long as it is the output.
    /// Nothing while the Dock is tucked away.
    private func refresh(staggered: Bool = false, animated: Bool = true) {
        guard prefs.widgetsEnabled else { return }
        let out = !dockAway || revealed || soundPanel.isOpen
        let leading: [WidgetKind] = out ? [.duo] : []
        let trailing: [WidgetKind] = out && status.audio.headphones != nil ? [.headphones] : []

        guard animated else {
            state.leading = leading
            state.trailing = trailing
            return
        }

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
    }

    fileprivate func face(for kind: WidgetKind) -> WidgetFace {
        let audio = status.audio
        switch kind {
        case .duo:
            return .duo(battery: status.battery, network: status.network, volume: audio.volume, muted: audio.isMuted)
        case .headphones:
            return .headphones(audio.headphones ?? .headphones, battery: status.headphoneBattery,
                               volume: audio.volume, muted: audio.isMuted)
        }
    }

    // MARK: with the Dock

    /// A full-screen Space or a hiding Dock: the widgets leave with the Dock,
    /// at once, the way it does when the Space changes.
    private func updateDockPresence() {
        guard let screen = NSScreen.builtIn ?? NSScreen.main else { return }
        let fullScreen = DockProbe.showsFullScreenSpace(screen)
        onFullScreenSpace = fullScreen
        let away = fullScreen || (layout?.autohides ?? false)
        guard away != dockAway else { return }
        dockAway = away
        revealed = false
        reveal?.cancel()
        tuck?.cancel()
        Log.engine.notice("widgets \(away ? "tucked away" : "back", privacy: .public)\(fullScreen ? " (full-screen Space)" : "", privacy: .public)")
        refresh(animated: false)
    }

    /// The pointer pressed against the Dock's edge brings the Dock out, and the
    /// widgets with it; moving off it puts them all away again.
    private func followDockReveal(_ point: CGPoint) {
        guard dockAway, let layout, let screen = NSScreen.builtIn ?? NSScreen.main else { return }
        let frame = screen.frame
        let atEdge: Bool
        let overDock: Bool
        switch layout.edge {
        case .bottom:
            atEdge = point.y <= frame.minY + 1 && point.x >= frame.minX && point.x <= frame.maxX
            overDock = point.y <= layout.frame.maxY + 8
        case .left:
            atEdge = point.x <= frame.minX + 1 && point.y >= frame.minY && point.y <= frame.maxY
            overDock = point.x <= layout.frame.maxX + 8
        case .right:
            atEdge = point.x >= frame.maxX - 1 && point.y >= frame.minY && point.y <= frame.maxY
            overDock = point.x >= layout.frame.minX - 8
        }

        if !revealed {
            guard atEdge else {
                reveal?.cancel()
                reveal = nil
                return
            }
            guard reveal == nil else { return }
            // The Dock waits a beat before it comes out; so do the widgets.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.reveal = nil
                self.revealed = true
                self.refresh()
            }
            reveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay, execute: work)
        } else if overDock || soundPanel.isOpen {
            tuck?.cancel()
            tuck = nil
        } else if tuck == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.tuck = nil
                self.revealed = false
                self.refresh()
            }
            tuck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private static var revealDelay: Double {
        let stored = UserDefaults(suiteName: "com.apple.dock")?.object(forKey: "autohide-delay") as? Double
        return min(max(stored ?? 0.2, 0), 2)
    }

    // MARK: clicks

    fileprivate func tapped(_ kind: WidgetKind) {
        guard kind == .headphones, let layout, let bubble = bubbleFrame(kind) else { return }
        soundPanel.toggle(from: bubble, edge: layout.edge, status: status)
    }

    private func trackPointer() {
        let point = NSEvent.mouseLocation
        followDockReveal(point)
        let hovered = Self.clickable.first { bubbleFrame($0)?.contains(point) == true }
        setHovered(hovered)
    }

    private func setHovered(_ kind: WidgetKind?) {
        if state.hovered != kind { state.hovered = kind }
        for (side, window) in windows {
            let catches = kind.map { side == .leading ? state.leading.contains($0) : state.trailing.contains($0) } ?? false
            if window.ignoresMouseEvents == catches { window.ignoresMouseEvents = !catches }
        }
    }

    /// Where a widget sits on screen right now, or nil if it isn't showing.
    private func bubbleFrame(_ kind: WidgetKind) -> CGRect? {
        guard let layout else { return nil }
        let side: ShelfSide
        let index: Int
        if let found = state.leading.firstIndex(of: kind) {
            (side, index) = (.leading, found)
        } else if let found = state.trailing.firstIndex(of: kind) {
            (side, index) = (.trailing, found)
        } else {
            return nil
        }
        guard let window = windows[side], window.alphaValue > 0 else { return nil }
        let frame = window.frame
        let pad = Self.pad
        let size = state.bubble
        let offset = CGFloat(index) * (size + state.gap)
        switch towardDock(edge: layout.edge, side: side) {
        case .leading: return CGRect(x: frame.minX + pad + offset, y: frame.minY + pad, width: size, height: size)
        case .trailing: return CGRect(x: frame.maxX - pad - size - offset, y: frame.minY + pad, width: size, height: size)
        case .top: return CGRect(x: frame.minX + pad, y: frame.maxY - pad - size - offset, width: size, height: size)
        case .bottom: return CGRect(x: frame.minX + pad, y: frame.minY + pad + offset, width: size, height: size)
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
        }
    }

    private func makeWindow(_ side: ShelfSide) -> NSWindow {
        let window = ShelfWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = FirstClickHostingView(rootView: ShelfSideView(shelf: self, state: state, status: status, side: side))
        return window
    }
}

fileprivate enum ShelfSide: Hashable {
    case leading, trailing
}

/// The edge of a side's window that faces the Dock.
private func towardDock(edge: DockEdge, side: ShelfSide) -> Edge {
    switch (edge, side) {
    case (.bottom, .leading): return .trailing
    case (.bottom, .trailing): return .leading
    case (_, .leading): return .bottom
    case (_, .trailing): return .top
    }
}

/// Shows beside the Dock and never takes focus from anything — a click on it
/// leaves the app you were in at the front.
private final class ShelfWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

fileprivate final class ShelfState: ObservableObject {
    /// Nearest the Dock first.
    @Published var leading: [WidgetKind] = []
    @Published var trailing: [WidgetKind] = []
    @Published var bubble: CGFloat = 74
    @Published var edge: DockEdge = .bottom
    @Published var hovered: WidgetKind?
    let gap: CGFloat = 10
}

private struct ShelfSideView: View {
    let shelf: WidgetShelf
    @ObservedObject var state: ShelfState
    @ObservedObject var status: SystemStatus
    let side: ShelfSide

    var body: some View {
        let kinds = side == .leading ? state.leading : state.trailing
        WidgetStack(items: kinds.map { WidgetItem(kind: $0, face: shelf.face(for: $0)) },
                    size: state.bubble,
                    gap: state.gap,
                    towardDock: towardDock(edge: state.edge, side: side),
                    hovered: state.hovered) { kind in
            shelf.tapped(kind)
        }
        .padding(18)
    }
}
