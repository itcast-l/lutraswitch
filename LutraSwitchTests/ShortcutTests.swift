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
        #expect(input.keyDown(tab, flags: .maskAlternate, repeat: false, mode: .switching(shortcut))
            == .init(consume: true, action: .begin(backward: false)))
        #expect(input.keyUp(tab) == .init(consume: true))
        #expect(input.flagsChanged(.maskAlternate, shortcut: shortcut) == .init())
        #expect(input.flagsChanged([], shortcut: shortcut) == .init(action: .commit))
        #expect(input.flagsChanged([], shortcut: shortcut) == .init())
    }

    @Test func cyclesOnNewPressesAndConsumesAutorepeat() {
        var input = ShortcutInput()
        _ = input.keyDown(tab, flags: .maskAlternate, repeat: false, mode: .switching(shortcut))
        #expect(input.keyDown(tab, flags: .maskAlternate, repeat: true, mode: .switching(shortcut)) == .init(consume: true))
        _ = input.keyUp(tab)
        #expect(input.keyDown(tab, flags: .maskAlternate, repeat: false, mode: .switching(shortcut))
            == .init(consume: true, action: .move(1)))
        #expect(input.keyDown(UInt16(kVK_LeftArrow), flags: .maskAlternate, repeat: false, mode: .switching(shortcut))
            == .init(consume: true, action: .move(-1)))
    }

    @Test func escapeCancelsAndSwallowsMatchingKeyUp() {
        var input = ShortcutInput()
        _ = input.keyDown(tab, flags: .maskAlternate, repeat: false, mode: .switching(shortcut))
        #expect(input.keyDown(escape, flags: .maskAlternate, repeat: false, mode: .switching(shortcut))
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
        #expect(input.keyDown(tab, flags: .maskCommand, repeat: false, mode: .switching(custom)) == .init())
        #expect(input.keyUp(tab) == .init())
        #expect(input.keyDown(tab, flags: [.maskAlternate, .maskControl], repeat: false, mode: .switching(custom)).action
            == .begin(backward: false))
        #expect(input.flagsChanged(.maskAlternate, shortcut: custom).action == .commit)
    }

    @Test func defaultShortcutPassesBothNativeSwitcherChordsThrough() {
        #expect(shortcut.displayName == "⌥Tab")
        var input = ShortcutInput()
        for flags: CGEventFlags in [.maskCommand, [.maskCommand, .maskShift]] {
            #expect(input.keyDown(tab, flags: flags, repeat: false, mode: .switching(shortcut)) == .init())
            #expect(input.keyUp(tab) == .init())
        }
    }

    @Test func commandTabTakesOverBothDirectionsAndWaitsForCommandRelease() throws {
        let takeover = Shortcut.commandTab
        #expect(takeover.isValid)
        let data = try JSONEncoder().encode(takeover)
        #expect(try JSONDecoder().decode(Shortcut.self, from: data).replacesSystemSwitcher)

        var input = ShortcutInput()
        let reverse: CGEventFlags = [.maskCommand, .maskShift]
        #expect(input.keyDown(tab, flags: reverse, repeat: false, mode: .switching(takeover))
            == .init(consume: true, action: .begin(backward: true)))
        #expect(input.keyUp(tab) == .init(consume: true))
        #expect(input.flagsChanged(.maskCommand, shortcut: takeover) == .init())
        #expect(input.keyDown(tab, flags: .maskCommand, repeat: false, mode: .switching(takeover))
            == .init(consume: true, action: .move(1)))
        #expect(input.keyUp(tab) == .init(consume: true))
        #expect(input.keyDown(tab, flags: reverse, repeat: false, mode: .switching(takeover))
            == .init(consume: true, action: .move(-1)))
        #expect(input.flagsChanged(.maskShift, shortcut: takeover) == .init(action: .commit))
        #expect(input.keyUp(tab) == .init(consume: true))
        #expect(input.keyDown(tab, flags: .maskCommand, repeat: false, mode: .switching(takeover))
            == .init(consume: true, action: .begin(backward: false)))
    }

    @Test func recordingCapturesBothCommandTabChordsWithoutStartingSwitching() {
        let takeover = Shortcut.commandTab
        for flags: CGEventFlags in [.maskCommand, [.maskCommand, .maskShift]] {
            var input = ShortcutInput()
            #expect(input.keyDown(tab, flags: flags, repeat: false, mode: .recording)
                == .init(consume: true, action: .recordCommandTab))
            #expect(input.keyDown(tab, flags: flags, repeat: true, mode: .switching(takeover))
                == .init(consume: true))
            #expect(input.keyUp(tab) == .init(consume: true))
            #expect(input.flagsChanged([], shortcut: takeover) == .init())
            #expect(input.keyDown(tab, flags: .maskCommand, repeat: false, mode: .switching(takeover))
                == .init(consume: true, action: .begin(backward: false)))
        }
    }

    @Test func leavesOrdinaryShortcutsForTheLocalRecorder() {
        var input = ShortcutInput()
        #expect(input.keyDown(tab, flags: .maskAlternate, repeat: false, mode: .recording) == .init())
        #expect(input.keyDown(escape, flags: [], repeat: false, mode: .recording) == .init())
        #expect(input.keyDown(tab, flags: .maskCommand, repeat: true, mode: .recording) == .init())
        #expect(input.keyDown(tab, flags: .maskCommand, repeat: false, mode: .inactive) == .init())
    }

    @Test func passesUnrelatedTypingThroughDuringSelection() {
        var input = ShortcutInput()
        _ = input.keyDown(tab, flags: .maskAlternate, repeat: false, mode: .switching(shortcut))
        let letter = UInt16(kVK_ANSI_A)
        #expect(input.keyDown(letter, flags: .maskAlternate, repeat: false, mode: .switching(shortcut)) == .init())
        #expect(input.keyUp(letter) == .init())
    }
}
