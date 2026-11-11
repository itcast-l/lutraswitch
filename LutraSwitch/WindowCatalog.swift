import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct RunningApp: Sendable {
    let pid: pid_t
    let name: String
    let hidden: Bool
}

struct WindowSummary: Identifiable, Equatable, Sendable {
    let id: WindowID
    let appName: String
    let title: String
    let minimized: Bool
    let bounds: CGRect?
    let canClose: Bool
}

struct WindowSnapshot: Sendable {
    let windows: [WindowSummary]
    let current: WindowID?
    let currentBounds: CGRect?
}

// AX requests may block on another application. All catalog state and AX calls
// are confined to the serial queue. Observer callbacks only forward the PID.
final class WindowCatalog: @unchecked Sendable {
    enum Change: Sendable {
        case focus(pid_t)
        case windows
    }

    private struct Application {
        let element: AXUIElement
        let observation: Observation?
        var observedWindows: [WindowID: AXUIElement] = [:]
    }

    // The callback context outlives removal from the main run loop. It never
    // dereferences the catalog, which can be released on its worker queue.
    private final class Observation: @unchecked Sendable {
        let observer: AXObserver
        let changed: @Sendable (Change) -> Void

        init(observer: AXObserver, changed: @escaping @Sendable (Change) -> Void) {
            self.observer = observer
            self.changed = changed
        }

        func stop() {
            DispatchQueue.main.async { [self] in
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
    }

    private struct ServerWindows {
        let frontToBack: [WindowID]
        let normalLayers: Set<WindowID>
        let bounds: [WindowID: CGRect]
        let spaces: WindowSystem.Spaces?

        var onScreen: Set<WindowID> { Set(frontToBack) }
    }

    private struct PendingFocus {
        let token: UUID
        let id: WindowID
        let app: NSRunningApplication
        let application: AXUIElement
        let window: AXUIElement
    }

    private let queue = DispatchQueue(label: "LutraSwitch.WindowCatalog", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    private let system = WindowSystem()
    private let changed: @Sendable (Change) -> Void
    private var applications: [pid_t: Application] = [:]
    private var recency = WindowRecency()
    private var pendingFocus: PendingFocus?

    init(changed: @escaping @Sendable (Change) -> Void) {
        self.changed = changed
    }

    deinit {
        for application in applications.values { application.observation?.stop() }
    }

    func stop() {
        queue.async {
            self.pendingFocus = nil
            for pid in Array(self.applications.keys) { self.removeApplication(pid) }
            self.recency = WindowRecency()
        }
    }

    var canIdentifyWindows: Bool { system.canIdentifyWindows }

    func snapshot(apps: [RunningApp], frontPID: pid_t?, completion: @escaping @Sendable (WindowSnapshot) -> Void) {
        queue.async {
            let livePIDs = Set(apps.map(\.pid))
            for pid in Array(self.applications.keys) where !livePIDs.contains(pid) {
                self.removeApplication(pid)
            }
            for app in apps where self.applications[app.pid] == nil {
                self.addApplication(app.pid)
            }

            let server = self.serverWindows()
            let summaries = self.summaries(for: apps, server: server)
            let actualFocus = frontPID.flatMap { self.focusedWindow(pid: $0) }
            let current = actualFocus ?? server.frontToBack.first { $0.pid == frontPID }
            if let actualFocus { self.recency.record(actualFocus) }

            self.recency.retain(server.normalLayers.union(summaries.map(\.id)))
            let ordered = self.ordered(summaries, server: server, current: current)
            completion(WindowSnapshot(
                windows: ordered,
                current: current,
                currentBounds: current.flatMap { server.bounds[$0] }
            ))
        }
    }

    func dockWindows(for apps: [RunningApp], completion: @escaping @Sendable ([WindowSummary]) -> Void) {
        queue.async {
            for app in apps where self.applications[app.pid] == nil {
                self.addApplication(app.pid)
            }
            let server = self.serverWindows()
            completion(self.ordered(self.summaries(for: apps, server: server), server: server, current: nil))
        }
    }

    private func summaries(for apps: [RunningApp], server: ServerWindows) -> [WindowSummary] {
        let onScreen = server.onScreen
        return apps.filter { !$0.hidden }.flatMap { windows(for: $0, server: server, onScreen: onScreen) }
    }

    private func ordered(_ summaries: [WindowSummary], server: ServerWindows, current: WindowID?) -> [WindowSummary] {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = server.frontToBack + summaries.map(\.id)
        return recency.ordered(candidates.filter { byID[$0] != nil }, current: current).compactMap { byID[$0] }
    }

    func recordFocus(pid: pid_t) {
        queue.async {
            let element = self.applications[pid]?.element ?? self.applicationElement(pid: pid)
            if let focused = self.focusedWindow(pid: pid, application: element) {
                self.recency.record(focused)
            }
        }
    }

    func forgetApplication(_ pid: pid_t) {
        queue.async {
            self.removeApplication(pid)
        }
    }

    func close(_ id: WindowID) {
        queue.async {
            guard AXIsProcessTrusted(),
                  let app = NSRunningApplication(processIdentifier: id.pid),
                  !app.isHidden, !app.isTerminated else { return }
            let application = self.applications[id.pid]?.element ?? self.applicationElement(pid: id.pid)
            guard let window = self.window(id, in: application),
                  let button: CFTypeRef = self.attribute(window, kAXCloseButtonAttribute),
                  CFGetTypeID(button) == AXUIElementGetTypeID() else { return }

            if AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success {
                self.changed(.windows)
            }
        }
    }

    func activate(_ id: WindowID) {
        queue.async {
            self.pendingFocus = nil
            guard let app = NSRunningApplication(processIdentifier: id.pid),
                  !app.isHidden, !app.isTerminated, AXIsProcessTrusted() else { return }

            let application = self.applications[id.pid]?.element ?? self.applicationElement(pid: id.pid)
            guard let window = self.window(id, in: application),
                  let attributes = self.windowAttributes(window) else { return }

            let server = self.serverWindows()
            guard self.isEligible(id, minimized: attributes.minimized, server: server, onScreen: server.onScreen) else {
                return
            }

            if app.isActive, self.focusedWindow(pid: id.pid, application: application) == id { return }
            if attributes.minimized,
               AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) != .success {
                return
            }

            self.raise(window, application: application)
            if !app.isActive {
                guard app.activate(options: []) else { return }
            }

            // Activation and deminiaturization are asynchronous. Once the app
            // becomes frontmost, AppKit may have picked a different key window.
            let token = UUID()
            self.pendingFocus = PendingFocus(token: token, id: id, app: app, application: application, window: window)
            self.confirmFocus(token, attempts: 5)
        }
    }

    private func confirmFocus(_ token: UUID, attempts: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(55)) {
            guard let target = self.pendingFocus, target.token == token else { return }
            guard !target.app.isTerminated, !target.app.isHidden,
                  self.system.number(of: target.window) == target.id.number else {
                self.pendingFocus = nil
                return
            }
            if target.app.isActive {
                if self.focusedWindow(pid: target.id.pid, application: target.application) == target.id {
                    self.recency.record(target.id)
                    self.pendingFocus = nil
                    return
                }
                self.raise(target.window, application: target.application)
            }
            if attempts > 1 {
                self.confirmFocus(token, attempts: attempts - 1)
            } else {
                self.pendingFocus = nil
            }
        }
    }

    private func raise(_ window: AXUIElement, application: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
    }

    private func serverWindows() -> ServerWindows {
        let visible = windowRows([.optionOnScreenOnly, .excludeDesktopElements])
        let all = windowRows([.optionAll, .excludeDesktopElements])
        let frontToBack = visible.compactMap(windowID)
        let bounds = Dictionary(visible.compactMap { row -> (WindowID, CGRect)? in
            guard let id = windowID(row), let raw = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return (id, rect)
        }, uniquingKeysWith: { first, _ in first })

        return ServerWindows(
            frontToBack: frontToBack,
            normalLayers: Set(all.compactMap(windowID)).union(frontToBack),
            bounds: bounds,
            spaces: system.currentSpaces()
        )
    }

    private func windowRows(_ options: CGWindowListOption) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private func windowID(_ row: [String: Any]) -> WindowID? {
        guard (row[kCGWindowLayer as String] as? NSNumber)?.int32Value == CGWindowLevelForKey(.normalWindow),
              let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let number = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
        return WindowID(pid: pid, number: number)
    }

    private func isEligible(_ id: WindowID, minimized: Bool, server: ServerWindows, onScreen: Set<WindowID>) -> Bool {
        guard minimized || server.normalLayers.contains(id) else { return false }
        if let spaces = server.spaces, let matches = system.isOnCurrentSpace(id.number, spaces: spaces) {
            return matches
        }
        return !minimized && onScreen.contains(id)
    }

    private func windows(for app: RunningApp, server: ServerWindows, onScreen: Set<WindowID>) -> [WindowSummary] {
        guard var application = applications[app.pid] else { return [] }
        guard let elements: [AXUIElement] = attribute(application.element, kAXWindowsAttribute) else { return [] }
        var currentElements: [WindowID: AXUIElement] = [:]
        var summaries: [WindowSummary] = []

        for element in elements {
            guard let number = system.number(of: element) else { continue }
            let id = WindowID(pid: app.pid, number: number)
            guard currentElements[id] == nil else { continue }
            currentElements[id] = element

            guard let attributes = windowAttributes(element),
                  isEligible(id, minimized: attributes.minimized, server: server, onScreen: onScreen) else { continue }
            summaries.append(WindowSummary(
                id: id,
                appName: app.name,
                title: attributes.title.isEmpty ? app.name : attributes.title,
                minimized: attributes.minimized,
                bounds: server.bounds[id],
                canClose: attributes.canClose
            ))
        }
        updateWindowObservers(for: &application, currentElements: currentElements)
        applications[app.pid] = application
        return summaries
    }

    private func windowAttributes(_ element: AXUIElement) -> (title: String, minimized: Bool, canClose: Bool)? {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute,
                     kAXTitleAttribute, kAXCloseButtonAttribute] as CFArray
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &result) == .success,
              let values = result as? [Any], values.count == 5,
              values[0] as? String == kAXWindowRole else { return nil }
        let minimized = values[2] as? Bool ?? false
        let subrole = values[1] as? String
        // WeChat reports its standard main window as a dialog while minimized.
        guard subrole == kAXStandardWindowSubrole || (minimized && subrole == kAXDialogSubrole) else { return nil }
        let title = (values[3] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let canClose = CFGetTypeID(values[4] as CFTypeRef) == AXUIElementGetTypeID()
        return (title, minimized, canClose)
    }

    private func window(_ id: WindowID, in application: AXUIElement) -> AXUIElement? {
        let windows: [AXUIElement] = attribute(application, kAXWindowsAttribute) ?? []
        return windows.first { system.number(of: $0) == id.number }
    }

    private func focusedWindow(pid: pid_t, application: AXUIElement? = nil) -> WindowID? {
        guard let application = application ?? applications[pid]?.element,
              let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute),
              let number = system.number(of: window) else { return nil }
        return WindowID(pid: pid, number: number)
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func applicationElement(pid: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.12)
        return application
    }

    private func addApplication(_ pid: pid_t) {
        let element = applicationElement(pid: pid)
        var observer: AXObserver?
        var observation: Observation?
        if AXObserverCreate(pid, Self.observerCallback, &observer) == .success, let observer {
            let registration = Observation(observer: observer, changed: changed)
            observation = registration
            let context = Unmanaged.passUnretained(registration).toOpaque()
            for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, context)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        applications[pid] = Application(element: element, observation: observation)
    }

    private func removeApplication(_ pid: pid_t) {
        if let application = applications.removeValue(forKey: pid) {
            application.observation?.stop()
        }
        recency.removeApplication(pid)
    }

    private func updateWindowObservers(
        for application: inout Application, currentElements: [WindowID: AXUIElement]
    ) {
        for id in application.observedWindows.keys where currentElements[id] == nil { recency.remove(id) }
        if let observation = application.observation {
            let observer = observation.observer
            let names = [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
            for (id, element) in application.observedWindows where currentElements[id] == nil {
                for name in names { AXObserverRemoveNotification(observer, element, name as CFString) }
            }
            let context = Unmanaged.passUnretained(observation).toOpaque()
            for (id, element) in currentElements where application.observedWindows[id] == nil {
                for name in names { AXObserverAddNotification(observer, element, name as CFString, context) }
            }
        }
        application.observedWindows = currentElements
    }

    private static let observerCallback: AXObserverCallback = { _, element, notification, context in
        guard let context else { return }
        let observation = Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue()
        if notification as String == kAXFocusedWindowChangedNotification {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success {
                observation.changed(.focus(pid))
            }
        } else {
            observation.changed(.windows)
        }
    }
}
