import Foundation

struct WindowID: Hashable, Sendable {
    let pid: Int32
    let number: UInt32
}

struct WindowRecency {
    private var history: [WindowID] = []

    mutating func record(_ id: WindowID) {
        guard history.first != id else { return }
        history.removeAll { $0 == id }
        history.insert(id, at: 0)
    }

    mutating func remove(_ id: WindowID) {
        history.removeAll { $0 == id }
    }

    mutating func removeApplication(_ pid: Int32) {
        history.removeAll { $0.pid == pid }
    }

    mutating func retain(_ live: Set<WindowID>) {
        history.removeAll { !live.contains($0) }
    }

    func ordered(_ frontToBack: [WindowID], current: WindowID?) -> [WindowID] {
        var remaining = Set(frontToBack)
        let priority = [current].compactMap { $0 } + history + frontToBack
        return priority.filter { remaining.remove($0) != nil }
    }
}

struct WindowSelection: Equatable {
    private(set) var windows: [WindowID]
    private(set) var selected: WindowID?

    init(windows: [WindowID], current: WindowID?) {
        self.init(windows: windows, selected: windows.first { $0 != current } ?? windows.first)
    }

    init(windows: [WindowID], selected: WindowID?) {
        self.windows = windows
        self.selected = selected
    }

    mutating func move(_ direction: Int) {
        guard !windows.isEmpty else { return }
        guard let selected, let index = windows.firstIndex(of: selected) else {
            selected = direction < 0 ? windows.last : windows.first
            return
        }
        self.selected = windows[(index + direction + windows.count) % windows.count]
    }

    mutating func highlight(_ id: WindowID) -> Bool {
        guard selected != id, windows.contains(id) else { return false }
        selected = id
        return true
    }

    mutating func retain(_ live: Set<WindowID>) {
        windows.removeAll { !live.contains($0) }
        if let selected, !live.contains(selected) {
            self.selected = nil
        }
    }
}

struct SwitchInteraction {
    enum Effect: Equatable {
        case none
        case show
        case dismiss
        case commit(WindowID)
    }

    private enum Phase {
        case idle
        case loading(moves: [Int], released: Bool)
        case selecting(WindowSelection)
    }

    private var phase = Phase.idle

    var isRunning: Bool {
        if case .idle = phase { return false }
        return true
    }

    var selection: WindowSelection? {
        if case .selecting(let selection) = phase { return selection }
        return nil
    }

    mutating func begin() {
        phase = .loading(moves: [], released: false)
    }

    mutating func prepare(windows: [WindowID], current: WindowID?) -> Effect {
        guard case let .loading(moves, released) = phase else { return .none }
        var selection = WindowSelection(windows: windows, current: current)
        for direction in moves { selection.move(direction) }

        if released || windows.isEmpty {
            phase = .idle
            return selection.selected.map(Effect.commit) ?? .dismiss
        }
        phase = .selecting(selection)
        return .show
    }

    mutating func move(_ direction: Int) -> Effect {
        switch phase {
        case .loading(var moves, false):
            moves.append(direction)
            phase = .loading(moves: moves, released: false)
        case .selecting(var selection):
            selection.move(direction)
            phase = .selecting(selection)
            return .show
        default:
            break
        }
        return .none
    }

    mutating func retain(_ live: Set<WindowID>) -> Effect {
        guard case .selecting(var selection) = phase else { return .none }
        selection.retain(live)
        if selection.windows.isEmpty { return cancel() }
        phase = .selecting(selection)
        return .show
    }

    mutating func hover(_ id: WindowID) -> Effect {
        guard case .selecting(var selection) = phase, selection.highlight(id) else { return .none }
        phase = .selecting(selection)
        return .show
    }

    mutating func click(_ id: WindowID) -> Effect {
        guard case .selecting(let selection) = phase, selection.windows.contains(id) else { return .none }
        phase = .idle
        return .commit(id)
    }

    mutating func release() -> Effect {
        switch phase {
        case .idle:
            return .none
        case .loading(let moves, _):
            phase = .loading(moves: moves, released: true)
            return .none
        case .selecting(let selection):
            phase = .idle
            return selection.selected.map(Effect.commit) ?? .dismiss
        }
    }

    mutating func cancel() -> Effect {
        guard isRunning else { return .none }
        phase = .idle
        return .dismiss
    }
}
