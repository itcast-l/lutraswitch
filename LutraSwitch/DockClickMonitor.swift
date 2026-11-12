import AppKit
import CoreGraphics
import Foundation
import Synchronization

final class DockClickRequest: Sendable {
    private enum State {
        case pending, applying, forwarded
    }

    let deadline: DispatchTime
    private let state = Mutex(State.pending)

    init(deadline: DispatchTime = .now() + .milliseconds(120)) {
        self.deadline = deadline
    }

    var canPrepare: Bool {
        state.withLock { $0 == .pending && DispatchTime.now() < deadline }
    }

    // Once a write starts, its result decides whether forwarding is safe.
    func beginApplying() -> Bool {
        state.withLock {
            guard $0 == .pending, DispatchTime.now() < deadline else { return false }
            $0 = .applying
            return true
        }
    }

    func claimFallback(afterCompletion: Bool = false) -> Bool {
        state.withLock {
            guard $0 == .pending || (afterCompletion && $0 == .applying) else { return false }
            $0 = .forwarded
            return true
        }
    }
}

@MainActor
final class DockClickMonitor {
    private struct Target: Sendable {
        let icon: DockIcon
        let bundlePath: String
        let pids: [pid_t]

        init(icon: DockIcon) {
            self.icon = icon
            bundlePath = icon.bundlePath
            pids = icon.runningApplications(includeHidden: true).map(\.processIdentifier)
        }
    }

    private struct Press {
        let id = UUID()
        let location: CGPoint
        let timestamp: CGEventTimestamp
        let frontPID: pid_t?
        var target: Target?
    }

    private struct PendingClick {
        let request: DockClickRequest
        let release: Release
        let dockPID: pid_t
        let timeout: DispatchWorkItem

        func replayIfPending() {
            guard request.claimFallback() else { return }
            DispatchQueue.main.async { [release, dockPID] in release.replayClick(to: dockPID) }
        }
    }

    private struct Release: Sendable {
        let location: CGPoint
        let timestamp: CGEventTimestamp
        let flags: CGEventFlags
        let eventNumber: Int64
        let clickCount: Int64

        init(_ event: CGEvent) {
            location = event.location
            timestamp = event.timestamp
            flags = event.flags
            eventNumber = event.getIntegerValueField(.mouseEventNumber)
            clickCount = event.getIntegerValueField(.mouseEventClickState)
        }

        func replayClick(to dockPID: pid_t) {
            guard NSRunningApplication(processIdentifier: dockPID)?.bundleIdentifier == "com.apple.dock",
                  let source = CGEventSource(stateID: .privateState) else { return }
            source.userData = DockClickMonitor.replayedEvent
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                     mouseCursorPosition: location, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                   mouseCursorPosition: location, mouseButton: .left) else { return }
            for event in [down, up] {
                event.flags = flags
                event.setIntegerValueField(.mouseEventNumber, value: eventNumber)
                event.setIntegerValueField(.mouseEventClickState, value: clickCount)
                event.postToPid(dockPID)
            }
        }
    }

    private enum Event: Sendable {
        case press(CGPoint, CGEventTimestamp)
        case release(Release)
        case cancelPress
        case interrupted

        init?(_ type: CGEventType, _ event: CGEvent) {
            if (type == .leftMouseDown || type == .leftMouseUp),
               event.getIntegerValueField(.eventSourceUserData) == DockClickMonitor.replayedEvent {
                return nil
            }
            switch type {
            case .leftMouseDown:
                self = event.flags.intersection(DockClickMonitor.modifiers).isEmpty
                    ? .press(event.location, event.timestamp) : .cancelPress
            case .leftMouseUp:
                self = event.flags.intersection(DockClickMonitor.modifiers).isEmpty
                    ? .release(Release(event)) : .cancelPress
            case .leftMouseDragged, .rightMouseDown, .otherMouseDown:
                self = .cancelPress
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                self = .interrupted
            default:
                return nil
            }
        }
    }

    private nonisolated static let replayedEvent: Int64 = 0x4C_75_74_72_61_44_6F_63
    private nonisolated static let modifiers: CGEventFlags = [
        .maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn
    ]
    private let hitTester = DockHitTester(timeout: 0.05)
    private let catalog: WindowCatalog
    private let handledClick: @MainActor (DockIcon) -> Void
    private var dockPID: pid_t?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var press: Press?
    private var probing = false
    private var pendingClick: PendingClick?
    private var configuration = UUID()

    init(catalog: WindowCatalog, handledClick: @escaping @MainActor (DockIcon) -> Void) {
        self.catalog = catalog
        self.handledClick = handledClick
    }

    isolated deinit { stop() }

    func configure(enabled: Bool) {
        guard enabled, let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            stop()
            return
        }
        let pid = dock.processIdentifier
        if dockPID == pid, let port, CFMachPortIsValid(port) {
            if !CGEvent.tapIsEnabled(tap: port) { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }

        stop()
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreateForPid(
            pid: pid, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return }

        dockPID = pid
        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func invalidateClick() {
        press = nil
        configuration = UUID()
        pendingClick?.timeout.cancel()
        pendingClick?.replayIfPending()
    }

    private func stop() {
        guard dockPID != nil else { return }
        invalidateClick()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        dockPID = nil
        source = nil
        port = nil
    }

    private func shouldCancelDockRelease(_ event: Event) -> Bool {
        switch event {
        case .press(let point, let timestamp):
            beginPress(at: point, timestamp: timestamp)
        case .cancelPress:
            press = nil
        case .release(let release):
            defer { press = nil }
            guard let press, let target = press.target, let dockPID, pendingClick == nil,
                  release.timestamp >= press.timestamp, release.timestamp - press.timestamp < 450_000_000,
                  abs(press.location.x - release.location.x) <= 4,
                  abs(press.location.y - release.location.y) <= 4,
                  target.icon.frame.contains(release.location),
                  catalog.mayToggleDockWindows(bundlePath: target.bundlePath, appPIDs: target.pids, frontPID: press.frontPID)
            else { return false }

            // Ordinary clicks and presses without a confirmed target reach Dock unchanged.
            toggle(target, frontPID: press.frontPID, release: release, dockPID: dockPID)
            return true
        case .interrupted:
            invalidateClick()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
        }
        return false
    }

    private func beginPress(at point: CGPoint, timestamp: CGEventTimestamp) {
        press = nil
        // Keep the slot until AX returns, even when the gesture has been cancelled.
        guard !probing, pendingClick == nil else { return }
        let press = Press(location: point, timestamp: timestamp,
                          frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        self.press = press
        probing = true
        let id = press.id
        let deadline = DispatchTime.now() + .milliseconds(100)
        hitTester.hit(at: point) { [weak self] icon in
            let target = icon.flatMap {
                $0.frame.contains(point) && DispatchTime.now() < deadline ? Target(icon: $0) : nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                guard self.press?.id == id, DispatchTime.now() < deadline else { return }
                self.press?.target = target
            }
        }
    }

    private func toggle(_ target: Target, frontPID: pid_t?, release: Release, dockPID: pid_t) {
        let request = DockClickRequest()
        let configuration = self.configuration
        let timeout = DispatchWorkItem {
            if request.claimFallback() { release.replayClick(to: dockPID) }
        }
        pendingClick = PendingClick(request: request, release: release, dockPID: dockPID, timeout: timeout)
        DispatchQueue.main.asyncAfter(deadline: request.deadline, execute: timeout)
        catalog.toggleDockWindows(bundlePath: target.bundlePath, appPIDs: target.pids, frontPID: frontPID,
                                  request: request) { [weak self] handled in
            DispatchQueue.main.async {
                if let self {
                    self.pendingClick?.timeout.cancel()
                    self.pendingClick = nil
                    if handled, self.configuration == configuration { self.handledClick(target.icon) }
                }
                if !handled, request.claimFallback(afterCompletion: true) { release.replayClick(to: dockPID) }
            }
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context, let input = Event(type, event) else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<DockClickMonitor>.fromOpaque(context).takeUnretainedValue()
        if MainActor.assumeIsolated({ monitor.shouldCancelDockRelease(input) }) {
            // Let Dock end its press without activating the icon. Only move the event's location.
            let display = CGDisplayBounds(CGMainDisplayID())
            event.location = CGPoint(x: display.midX, y: display.midY)
        }
        return Unmanaged.passUnretained(event)
    }
}
