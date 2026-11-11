import Carbon
import CoreGraphics
import Foundation

struct Shortcut: Codable, Equatable {
    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    static let defaultValue = Shortcut(
        keyCode: UInt16(kVK_Tab), modifierFlags: CGEventFlags.maskAlternate.rawValue, keyLabel: "Tab"
    )
    static let commandTab = Shortcut(
        keyCode: UInt16(kVK_Tab), modifierFlags: CGEventFlags.maskCommand.rawValue, keyLabel: "Tab"
    )
    static let reverseCommandTabFlags: CGEventFlags = [.maskCommand, .maskShift]

    let keyCode: UInt16
    let modifierFlags: UInt64
    let keyLabel: String

    var flags: CGEventFlags { CGEventFlags(rawValue: modifierFlags) }

    var replacesSystemSwitcher: Bool { keyCode == Self.commandTab.keyCode && flags == .maskCommand }

    static func isSystemSwitcher(key: UInt16, modifiers: CGEventFlags) -> Bool {
        key == commandTab.keyCode && (modifiers == commandTab.flags || modifiers == reverseCommandTabFlags)
    }

    var isValid: Bool {
        !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
            && flags == flags.intersection(Self.modifierMask)
            && !(keyCode == Self.commandTab.keyCode && flags == Self.reverseCommandTabFlags)
            && ![kVK_Escape, kVK_LeftArrow, kVK_RightArrow].contains(Int(keyCode))
            && !keyLabel.isEmpty
    }

    var displayName: String {
        let modifiers: [(CGEventFlags, String)] = [
            (.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")
        ]
        return modifiers.compactMap { flags.contains($0.0) ? $0.1 : nil }.joined() + keyLabel
    }
}

struct ShortcutInput {
    enum Mode: Equatable {
        case inactive
        case switching(Shortcut)
        case recording
    }

    enum Action: Equatable {
        case begin(backward: Bool)
        case move(Int)
        case commit
        case cancel
        case recordCommandTab
    }

    struct Result: Equatable {
        var consume = false
        var action: Action?
    }

    private(set) var isHolding = false
    private var consumedKeys = Set<UInt16>()

    mutating func keyDown(_ key: UInt16, flags: CGEventFlags, repeat isRepeat: Bool, mode: Mode) -> Result {
        if consumedKeys.contains(key) { return Result(consume: true) }
        let modifiers = flags.intersection(Shortcut.modifierMask)
        if mode == .recording {
            guard !isRepeat, Shortcut.isSystemSwitcher(key: key, modifiers: modifiers) else { return Result() }
            consumedKeys.insert(key)
            return Result(consume: true, action: .recordCommandTab)
        }
        guard case .switching(let shortcut) = mode else { return Result() }
        let backward = shortcut.replacesSystemSwitcher && modifiers == Shortcut.reverseCommandTabFlags
        let matches = key == shortcut.keyCode && (modifiers == shortcut.flags || backward)
        let action: Action

        if isHolding {
            switch Int(key) {
            case kVK_Escape: action = .cancel
            case kVK_LeftArrow: action = .move(-1)
            case kVK_RightArrow: action = .move(1)
            default:
                guard matches else { return Result() }
                action = .move(backward ? -1 : 1)
            }
        } else {
            guard matches, !isRepeat else { return Result() }
            action = .begin(backward: backward)
        }

        guard !isRepeat else { return Result(consume: true) }
        consumedKeys.insert(key)
        switch action {
        case .begin: isHolding = true
        case .cancel: isHolding = false
        default: break
        }
        return Result(consume: true, action: action)
    }

    mutating func keyUp(_ key: UInt16) -> Result {
        Result(consume: consumedKeys.remove(key) != nil)
    }

    mutating func flagsChanged(_ flags: CGEventFlags, shortcut: Shortcut) -> Result {
        guard isHolding, !flags.contains(shortcut.flags) else { return Result() }
        isHolding = false
        return Result(action: .commit)
    }

    mutating func cancelHold() {
        isHolding = false
    }

    mutating func reset() {
        isHolding = false
        consumedKeys.removeAll()
    }
}
