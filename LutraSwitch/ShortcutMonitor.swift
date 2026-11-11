import CoreGraphics
import Foundation

@MainActor
final class ShortcutMonitor {
    private enum Event: Sendable {
        case keyDown(UInt16, CGEventFlags, isRepeat: Bool)
        case keyUp(UInt16)
        case flagsChanged(CGEventFlags)
        case mouseDown(Int64, CGPoint)
        case mouseDragged(Int64)
        case mouseUp(Int64)
        case interrupted

        nonisolated init?(_ type: CGEventType, _ event: CGEvent) {
            switch type {
            case .keyDown:
                let key = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                self = .keyDown(key, event.flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            case .keyUp:
                self = .keyUp(UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
            case .flagsChanged:
                self = .flagsChanged(event.flags)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                self = .mouseDown(event.getIntegerValueField(.mouseEventButtonNumber), event.unflippedLocation)
            case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                self = .mouseDragged(event.getIntegerValueField(.mouseEventButtonNumber))
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                self = .mouseUp(event.getIntegerValueField(.mouseEventButtonNumber))
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                self = .interrupted
            default:
                return nil
            }
        }
    }

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var input = ShortcutInput()
    private var mode = ShortcutInput.Mode.inactive
    var previewFrame: CGRect?
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
        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseUp, .rightMouseUp, .otherMouseUp
        ]
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

    func configure(_ mode: ShortcutInput.Mode) {
        if self.mode != mode { input.cancelHold() }
        self.mode = mode
    }

    func cancelHold() {
        input.cancelHold()
    }

    func stop() {
        input.reset()
        mode = .inactive
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
    }

    private func shouldConsume(_ event: Event) -> Bool {
        let result: ShortcutInput.Result
        switch event {
        case .keyUp(let key):
            result = input.keyUp(key)
        case .keyDown(let key, let flags, let isRepeat):
            result = input.keyDown(key, flags: flags, repeat: isRepeat, mode: mode)
        case .flagsChanged(let flags):
            guard case .switching(let shortcut) = mode else { return false }
            result = input.flagsChanged(flags, shortcut: shortcut)
        case .mouseDown(let button, let location):
            result = input.mouseDown(button, at: location, previewFrame: previewFrame)
        case .mouseDragged(let button):
            result = input.mouseDragged(button)
        case .mouseUp(let button):
            result = input.mouseUp(button)
        case .interrupted:
            input.reset()
            mode = .inactive
            DispatchQueue.main.async { [weak self] in self?.interrupted?() }
            return false
        }

        if let action = result.action {
            DispatchQueue.main.async { [weak self] in self?.action?(action) }
        }
        return result.consume
    }

    private static let callback: CGEventTapCallBack = { _, type, event, context in
        guard let context, let inputEvent = Event(type, event) else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
        // The event tap source is installed on the main run loop.
        let consume = MainActor.assumeIsolated { monitor.shouldConsume(inputEvent) }
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
