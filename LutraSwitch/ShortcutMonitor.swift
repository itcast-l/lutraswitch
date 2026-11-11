import CoreGraphics
import Foundation

@MainActor
final class ShortcutMonitor {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var input = ShortcutInput()
    private var shortcut = Shortcut.defaultValue
    private var enabled = false
    var action: ((ShortcutInput.Action) -> Void)?
    var interrupted: (() -> Void)?

    isolated deinit { stop() }

    var isListening: Bool {
        port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    func start() -> Bool {
        if let port {
            if !isListening { CGEvent.tapEnable(tap: port, enable: true) }
            return isListening
        }
        let eventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { return false }

        self.port = port
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return isListening
    }

    func configure(shortcut: Shortcut, enabled: Bool) {
        if self.shortcut != shortcut || !enabled { input.cancelHold() }
        self.shortcut = shortcut
        self.enabled = enabled
    }

    func cancelHold() {
        input.cancelHold()
    }

    func stop() {
        input.reset()
        enabled = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
    }

    private func shouldConsume(_ type: CGEventType, key: UInt16, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            input.reset()
            enabled = false
            DispatchQueue.main.async { [weak self] in self?.interrupted?() }
            return false
        }

        let result: ShortcutInput.Result
        switch type {
        case .keyUp:
            result = input.keyUp(key)
        case .keyDown where enabled:
            result = input.keyDown(key, flags: flags, repeat: isRepeat, shortcut: shortcut)
        case .flagsChanged where enabled:
            result = input.flagsChanged(flags, shortcut: shortcut)
        default:
            return false
        }

        if let action = result.action {
            DispatchQueue.main.async { [weak self] in self?.action?(action) }
        }
        return result.consume
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
        let key = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // The event tap source is installed on the main run loop.
        let consume = MainActor.assumeIsolated { monitor.shouldConsume(type, key: key, flags: flags, isRepeat: isRepeat) }
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
