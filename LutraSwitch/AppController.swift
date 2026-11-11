import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import SwiftUI

@MainActor @Observable
final class AppController {
    private static let shortcutKey = "window-switch-shortcut"
    private(set) var shortcut: Shortcut
    private(set) var accessibilityAllowed = false
    private(set) var inputMonitoringAllowed = false
    private(set) var screenRecordingAllowed = false
    private(set) var isListening = false
    private(set) var canIdentifyWindows = true
    private(set) var isRecording = false
    private(set) var recordingError: String?
    private(set) var dockPreviewEnabled = UserDefaults.standard.object(forKey: "dock-preview-enabled") as? Bool ?? true

    @ObservationIgnored private let monitor = ShortcutMonitor()
    @ObservationIgnored private let preview = PreviewModel()
    @ObservationIgnored private let thumbnails = WindowThumbnails()
    @ObservationIgnored private lazy var dockPreview = DockPreview(catalog: catalog, thumbnails: thumbnails)
    @ObservationIgnored private lazy var panel = SwitcherPanel(
        model: preview,
        hover: { [weak self] in self?.hoverWindow($0) },
        click: { [weak self] in self?.clickWindow($0) },
        scroll: { [weak self] in self?.moveSelection($0) }
    )
    @ObservationIgnored private lazy var catalog = WindowCatalog { [weak self] change in
        Task { @MainActor in self?.catalogChanged(change) }
    }
    @ObservationIgnored private var interaction = SwitchInteraction()
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var lastPointerLocation: CGPoint?
    @ObservationIgnored private var snapshot: WindowSnapshot?
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var scanPending = false
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastPermissionCheck: TimeInterval = 0
    @ObservationIgnored private var memoryPressure: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private var localRecorder: Any?
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    @ObservationIgnored private var sessionActive = true

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.data(forKey: Self.shortcutKey)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        shortcut = stored.flatMap { $0.isValid ? $0 : nil } ?? .defaultValue
        if let stored, Shortcut.isSystemSwitcher(key: stored.keyCode, modifiers: stored.flags),
           let migrated = try? JSONEncoder().encode(shortcut) {
            defaults.set(migrated, forKey: Self.shortcutKey)
        }
    }

    func start() {
        guard !started else {
            checkPermissions()
            return
        }
        started = true
        canIdentifyWindows = catalog.canIdentifyWindows
        dockPreview.visibilityChanged = { [weak self] in self?.updateMaintenanceTimer() }
        monitor.action = { [weak self] in self?.handle($0) }
        monitor.interrupted = { [weak self] in
            self?.isListening = false
            self?.cancelSession()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { controller, pid in
            if let pid, let app = NSRunningApplication(processIdentifier: pid),
               controller.accessibilityAllowed, controller.isSwitchable(app) {
                controller.catalog.recordFocus(pid: pid)
            }
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { controller, pid in
            if let pid {
                controller.catalog.forgetApplication(pid)
                controller.thumbnails.removeApplication(pid)
            }
            controller.refreshSnapshot()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            observe(workspace, name) { controller, _ in controller.refreshSnapshot() }
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { controller, _ in
            controller.cancelSession()
            controller.dockPreview.dismiss()
            controller.refreshSnapshot()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { controller, _ in
            controller.cancelSession()
            controller.dockPreview.dismiss()
            controller.refreshSnapshot()
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observe(workspace, name) { controller, _ in
                controller.sessionActive = false
                controller.checkPermissions()
                controller.thumbnails.clear()
            }
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            observe(workspace, name) { controller, _ in
                controller.sessionActive = true
                controller.checkPermissions()
                controller.refreshSnapshot()
            }
        }
        observe(.default, NSWindow.didResignKeyNotification) { controller, _ in
            controller.endRecording()
        }

        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.captureTask?.cancel()
                self.captureTask = nil
                self.preview.images.removeAll()
                self.dockPreview.releaseThumbnails()
                self.thumbnails.clear()
            }
        }
        memoryPressure = pressure
        pressure.resume()
        updateMaintenanceTimer()
        checkPermissions()
    }

    isolated deinit { stop() }

    func stop() {
        guard started else { return }
        started = false
        timer?.invalidate()
        timer = nil
        memoryPressure?.cancel()
        memoryPressure = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        endRecording()
        cancelSession()
        dockPreview.setEnabled(false)
        monitor.stop()
        isListening = false
        thumbnails.clear()
        catalog.stop()
    }

    private func updateMaintenanceTimer() {
        guard started else { return }
        let interval: TimeInterval = interaction.selection != nil || dockPreview.isShowing ? 1 : 5
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastPermissionCheck >= 5 {
                    self.checkPermissions()
                }
                self.thumbnails.removeExpired()
                if self.interaction.selection != nil {
                    self.refreshSnapshot()
                } else if self.dockPreview.isShowing {
                    self.dockPreview.refresh()
                }
            }
        }
        timer.tolerance = interval * 0.2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func requestAccessibility() {
        // The SDK exposes kAXTrustedCheckOptionPrompt as a mutable global.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        checkPermissions()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        checkPermissions()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        checkPermissions()
    }

    func setDockPreviewEnabled(_ enabled: Bool) {
        dockPreviewEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "dock-preview-enabled")
        updateDockPreviewAvailability()
    }

    func beginRecording() {
        guard !isRecording else { return }
        cancelSession()
        isRecording = true
        recordingError = nil
        configureMonitor()
        updateDockPreviewAvailability()
        localRecorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = event.keyCode
            let flags = event.modifierFlags.rawValue
            let characters = event.charactersIgnoringModifiers
            let isRepeat = event.isARepeat
            MainActor.assumeIsolated {
                self?.record(key: key, flags: UInt64(flags), characters: characters, isRepeat: isRepeat)
            }
            return nil
        }
    }

    func endRecording() {
        if let localRecorder { NSEvent.removeMonitor(localRecorder) }
        localRecorder = nil
        isRecording = false
        recordingError = nil
        configureMonitor()
        updateDockPreviewAvailability()
    }

    func restoreShortcut() {
        saveShortcut(.defaultValue)
        endRecording()
    }

    private func record(key: UInt16, flags: UInt64, characters: String?, isRepeat: Bool) {
        guard !isRepeat else { return }
        if Int(key) == kVK_Escape {
            endRecording()
            return
        }
        let modifiers = CGEventFlags(rawValue: flags).intersection(Shortcut.modifierMask)
        if Shortcut.isSystemSwitcher(key: key, modifiers: modifiers) {
            recordingError = "⌘Tab 和 ⌘⇧Tab 由 macOS 使用。请选择其他组合键。"
            return
        }
        let special: [Int: String] = [
            kVK_Tab: "Tab", kVK_Space: "Space", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter",
            kVK_Delete: "Delete", kVK_ForwardDelete: "⌦", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
            kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
        ]
        let label = special[Int(key)] ?? characters?
            .trimmingCharacters(in: .controlCharacters).uppercased() ?? ""
        let candidate = Shortcut(keyCode: key, modifierFlags: modifiers.rawValue, keyLabel: label)
        guard candidate.isValid else {
            recordingError = "请按下 ⌘、⌥ 或 ⌃ 加一个按键。← 和 → 用于轮选。"
            return
        }
        saveShortcut(candidate)
        endRecording()
    }

    private func saveShortcut(_ value: Shortcut) {
        cancelSession()
        shortcut = value
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.shortcutKey)
        }
        configureMonitor()
    }

    private func checkPermissions() {
        guard started else { return }
        lastPermissionCheck = ProcessInfo.processInfo.systemUptime
        let trusted = AXIsProcessTrusted()
        if accessibilityAllowed != trusted { accessibilityAllowed = trusted }
        let canListen = CGPreflightListenEventAccess()
        if inputMonitoringAllowed != canListen { inputMonitoringAllowed = canListen }
        let canCapture = CGPreflightScreenCaptureAccess()
        if screenRecordingAllowed != canCapture {
            screenRecordingAllowed = canCapture
            dockPreview.setCaptureEnabled(canCapture)
            if !canCapture {
                captureTask?.cancel()
                captureTask = nil
                thumbnails.clear()
                preview.images.removeAll()
            } else if interaction.selection != nil {
                showSelection(reveal: false)
            }
        }

        let wasListening = isListening
        if trusted, canIdentifyWindows, sessionActive, !IsSecureEventInputEnabled() {
            let listening = monitor.start()
            if isListening != listening { isListening = listening }
            configureMonitor()
            if listening && !wasListening { refreshSnapshot() }
        } else {
            if isListening { isListening = false }
            monitor.stop()
        }
        if !isListening { cancelSession() }
        updateDockPreviewAvailability()
    }

    private func configureMonitor() {
        monitor.configure(shortcut: shortcut, enabled: isListening && !isRecording)
    }

    private func updateDockPreviewAvailability() {
        dockPreview.setEnabled(
            started && dockPreviewEnabled && accessibilityAllowed && canIdentifyWindows && sessionActive
                && !interaction.isRunning && !isRecording
        )
        updateMaintenanceTimer()
    }

    private func isSwitchable(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && !app.isTerminated
            && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    private func catalogChanged(_ change: WindowCatalog.Change) {
        guard started, accessibilityAllowed else { return }
        switch change {
        case .focus(let pid):
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                catalog.recordFocus(pid: pid)
            }
        case .windows:
            refreshSnapshot()
        }
    }

    private func refreshSnapshot() {
        guard started, accessibilityAllowed, canIdentifyWindows, sessionActive else { return }
        dockPreview.refresh()
        if scanInFlight {
            scanPending = true
            return
        }
        scanInFlight = true
        let requestedFor = sessionID
        let workspace = NSWorkspace.shared
        let frontPID = workspace.frontmostApplication?.processIdentifier
        let apps = workspace.runningApplications.filter(isSwitchable).map {
            RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "应用", hidden: $0.isHidden)
        }
        catalog.snapshot(apps: apps, frontPID: frontPID) { [weak self] result in
            Task { @MainActor in self?.didScan(result, requestedFor: requestedFor) }
        }
    }

    private func didScan(_ result: WindowSnapshot, requestedFor: UUID?) {
        scanInFlight = false
        if let requestedFor, requestedFor == sessionID {
            let live = Set(result.windows.map(\.id))
            for item in snapshot?.windows ?? [] where !live.contains(item.id) {
                thumbnails.remove(item.id)
            }
            snapshot = result
            if interaction.selection == nil {
                apply(interaction.prepare(windows: result.windows.map(\.id), current: result.current), reveal: true)
            } else {
                apply(interaction.retain(live))
            }
        }
        if scanPending {
            scanPending = false
            refreshSnapshot()
        }
    }

    private func handle(_ action: ShortcutInput.Action) {
        switch action {
        case .begin:
            guard isListening, !isRecording else { return }
            apply(interaction.cancel())
            sessionID = UUID()
            interaction.begin()
            updateDockPreviewAvailability()
            refreshSnapshot()
        case .move(let direction):
            moveSelection(direction)
        case .commit:
            apply(interaction.release())
        case .cancel:
            cancelSession()
        }
    }

    private func moveSelection(_ direction: Int) {
        apply(interaction.move(direction), reveal: true)
    }

    private func hoverWindow(_ id: WindowID) {
        let location = NSEvent.mouseLocation
        guard location != lastPointerLocation else { return }
        lastPointerLocation = location
        apply(interaction.hover(id))
    }

    private func clickWindow(_ id: WindowID) {
        let effect = interaction.click(id)
        if case .commit = effect { monitor.cancelHold() }
        apply(effect)
    }

    private func apply(_ effect: SwitchInteraction.Effect, reveal: Bool = false) {
        switch effect {
        case .none:
            break
        case .show:
            showSelection(reveal: reveal)
        case .dismiss:
            dismissPreview()
        case .commit(let id):
            dismissPreview()
            catalog.activate(id)
        }
    }

    private func showSelection(reveal: Bool) {
        guard let sessionID, let snapshot, let selection = interaction.selection else { return }
        let summaries = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0) })
        let ordered = selection.windows.compactMap { summaries[$0] }
        if preview.updateWindows(ordered) {
            captureTask?.cancel()
            captureTask = nil
        }
        preview.selected = selection.selected
        if reveal {
            // Moving cards under a stationary pointer should leave keyboard selection intact.
            lastPointerLocation = NSEvent.mouseLocation
        }
        panel.show(currentBounds: snapshot.currentBounds)
        updateMaintenanceTimer()
        if reveal { preview.revealSelection() }

        if captureTask == nil, screenRecordingAllowed {
            captureTask = Task { [weak self, thumbnails] in
                await thumbnails.load(ordered, selected: selection.selected) { [weak self] id, image in
                    guard let self, self.sessionID == sessionID,
                          self.interaction.selection?.windows.contains(id) == true else {
                        return
                    }
                    self.preview.images[id] = image
                }
            }
        }
    }

    private func cancelSession() {
        apply(interaction.cancel())
        monitor.cancelHold()
    }

    private func dismissPreview() {
        sessionID = nil
        snapshot = nil
        lastPointerLocation = nil
        captureTask?.cancel()
        captureTask = nil
        if !preview.windows.isEmpty { panel.hide() }
        preview.windows.removeAll()
        preview.selected = nil
        preview.images.removeAll()
        preview.icons.removeAll()
        updateDockPreviewAvailability()
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        using body: @escaping @MainActor (AppController, pid_t?) -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                if let self { body(self, pid) }
            }
        }
        observers.append((center, observer))
    }
}
