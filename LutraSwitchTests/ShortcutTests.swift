import Carbon
import CoreGraphics
import Foundation
import Testing

struct ShortcutTests {
    private let tab = UInt16(kVK_Tab)
    private let escape = UInt16(kVK_Escape)
    private let shortcut = Shortcut.defaultValue

    @Test func triggersAndCommitsOnModifierRelease() {
        var input = ShortcutInput()
        #expect(input.keyDown(tab, flags: .maskAlternate, repeat: false, shortcut: shortcut)
            == .init(consume: true, action: .begin))
        #expect(input.keyUp(tab) == .init(consume: true))
        #expect(input.flagsChanged(.maskAlternate, shortcut: shortcut) == .init())
        #expect(input.flagsChanged([], shortcut: shortcut) == .init(action: .commit))
        #expect(input.flagsChanged([], shortcut: shortcut) == .init())
    }

    @Test func cyclesOnNewPressesAndConsumesAutorepeat() {
        var input = ShortcutInput()
        _ = input.keyDown(tab, flags: .maskAlternate, repeat: false, shortcut: shortcut)
        #expect(input.keyDown(tab, flags: .maskAlternate, repeat: true, shortcut: shortcut) == .init(consume: true))
        _ = input.keyUp(tab)
        #expect(input.keyDown(tab, flags: .maskAlternate, repeat: false, shortcut: shortcut)
            == .init(consume: true, action: .move(1)))
        #expect(input.keyDown(UInt16(kVK_LeftArrow), flags: .maskAlternate, repeat: false, shortcut: shortcut)
            == .init(consume: true, action: .move(-1)))
    }

    @Test func escapeCancelsAndSwallowsMatchingKeyUp() {
        var input = ShortcutInput()
        _ = input.keyDown(tab, flags: .maskAlternate, repeat: false, shortcut: shortcut)
        #expect(input.keyDown(escape, flags: .maskAlternate, repeat: false, shortcut: shortcut)
            == .init(consume: true, action: .cancel))
        #expect(input.keyUp(escape) == .init(consume: true))
        #expect(input.flagsChanged([], shortcut: shortcut) == .init())
    }

    @Test func customBindingPassesCommandTabThroughAndCommitsOnEitherModifier() throws {
        let custom = Shortcut(
            keyCode: tab, modifierFlags: CGEventFlags([.maskAlternate, .maskControl]).rawValue, keyLabel: "Tab"
        )
        let data = try JSONEncoder().encode(custom)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data) == custom)
        var input = ShortcutInput()
        #expect(input.keyDown(tab, flags: .maskCommand, repeat: false, shortcut: custom) == .init())
        #expect(input.keyUp(tab) == .init())
        #expect(input.keyDown(tab, flags: [.maskAlternate, .maskControl], repeat: false, shortcut: custom).action == .begin)
        #expect(input.flagsChanged(.maskAlternate, shortcut: custom).action == .commit)
    }

    @Test func reservesNativeSwitcherEvenIfAnOldBindingIsLoaded() {
        #expect(shortcut.displayName == "⌥Tab")
        for flags: CGEventFlags in [.maskCommand, [.maskCommand, .maskShift]] {
            let legacy = Shortcut(keyCode: tab, modifierFlags: flags.rawValue, keyLabel: "Tab")
            #expect(!legacy.isValid)
            var input = ShortcutInput()
            #expect(input.keyDown(tab, flags: flags, repeat: false, shortcut: legacy) == .init())
            #expect(input.keyUp(tab) == .init())
        }
    }

    @Test func passesUnrelatedTypingThroughDuringSelection() {
        var input = ShortcutInput()
        _ = input.keyDown(tab, flags: .maskAlternate, repeat: false, shortcut: shortcut)
        let letter = UInt16(kVK_ANSI_A)
        #expect(input.keyDown(letter, flags: .maskAlternate, repeat: false, shortcut: shortcut) == .init())
        #expect(input.keyUp(letter) == .init())
    }
}
