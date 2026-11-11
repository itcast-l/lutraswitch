import AppKit
import ApplicationServices
import Foundation

private struct DockIcon: Sendable {
    let url: URL
    let frame: CGRect
}

// Dock AX calls can block while the Dock is animating or showing a menu.
private final class DockHitTester: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LutraSwitch.DockHitTester", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    private var dockPID: pid_t?
    private var root: AXUIElement?

    func hit(at point: CGPoint, completion: @escaping @Sendable (DockIcon?) -> Void) {
        queue.async {
            completion(self.icon(at: point))
        }
    }

    private func icon(at point: CGPoint) -> DockIcon? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        if dockPID != dock.processIdentifier {
            dockPID = dock.processIdentifier
            root = AXUIElementCreateApplication(dock.processIdentifier)
            if let root { AXUIElementSetMessagingTimeout(root, 0.1) }
        }

        var hit: AXUIElement?
        guard let root,
              AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        let names = [kAXSubroleAttribute, "AXIsApplicationRunning", kAXURLAttribute,
                     kAXPositionAttribute, kAXSizeAttribute] as CFArray
        var attributes: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(hit, names, [], &attributes) == .success,
              let values = attributes as? [Any], values.count == 5,
              values[0] as? String == "AXApplicationDockItem", values[1] as? Bool == true,
              let url = values[2] as? URL, url.isFileURL,
              let position = axValue(values[3]), let dimensions = axValue(values[4]) else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(dimensions, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return DockIcon(url: url, frame: CGRect(origin: origin, size: size))
    }

    private func axValue(_ value: Any) -> AXValue? {
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        return (object as! AXValue)
    }
}

@MainActor
final class DockPreview {
    private let hitTester = DockHitTester()
    private let catalog: WindowCatalog
    private let thumbnails: WindowThumbnails
    private let model = PreviewModel()
    private lazy var panel = SwitcherPanel(
        model: model,
        hover: { [weak self] in self?.highlight($0) },
        click: { [weak self] in self?.open($0) },
        scroll: { [weak self] in self?.moveSelection($0) },
        style: .dock,
        close: { [weak self] in self?.catalog.close($0) }
    )

    private var timer: Timer?
    private var enabled = false
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var lastPointerActivity: TimeInterval = 0
    var visibilityChanged: (() -> Void)?
    private var candidate: (icon: DockIcon, since: TimeInterval)?
    private var item: DockIcon?
    private var suppressedIcon: DockIcon?
    private var lastInside: TimeInterval = 0
    private var lastProbed: CGPoint?
    private var lastProbeTime: TimeInterval = 0
    private var probing = false
    private var requestID = UUID()
    private var loading = false
    private var captureEnabled = false
    private var captureTask: Task<Void, Never>?
    private var lastPointerLocation: CGPoint?

    init(catalog: WindowCatalog, thumbnails: WindowThumbnails) {
        self.catalog = catalog
        self.thumbnails = thumbnails
    }

    var isShowing: Bool { !model.windows.isEmpty }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            let events: NSEvent.EventTypeMask = [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseUp, .rightMouseUp, .otherMouseUp
            ]
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerActivity() }
            }
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.pointerActivity() }
                return event
            }
            pointerActivity()
        } else {
            if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
            if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
            globalPointerMonitor = nil
            localPointerMonitor = nil
            timer?.invalidate()
            timer = nil
            dismiss()
        }
    }

    isolated deinit {
        timer?.invalidate()
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        captureTask?.cancel()
    }

    private func pointerActivity() {
        guard enabled else { return }
        lastPointerActivity = ProcessInfo.processInfo.systemUptime
        startSampling()
    }

    private func startSampling() {
        guard enabled, timer == nil else { return }
        // Coalesce high-frequency mouse events; stop ticking once the pointer rests.
        let timer = Timer(timeInterval: 0.055, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
        timer.tolerance = 0.01
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setCaptureEnabled(_ enabled: Bool) {
        guard enabled != captureEnabled else { return }
        captureEnabled = enabled
        if enabled {
            loadThumbnails()
        } else {
            releaseThumbnails()
        }
    }

    func releaseThumbnails() {
        captureTask?.cancel()
        captureTask = nil
        model.images.removeAll()
    }

    func dismiss() {
        candidate = nil
        lastProbed = nil
        clearItem()
    }

    func refresh() {
        guard let item, !loading else { return }
        let apps = runningApps(for: item.url)
        guard !apps.isEmpty else {
            clearPanel()
            return
        }
        loading = true
        let request = requestID
        catalog.dockWindows(for: apps) { [weak self] windows in
            Task { @MainActor in self?.receiveWindows(windows, request: request) }
        }
    }

    private func samplePointer() {
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        defer {
            if candidate == nil, now - lastPointerActivity >= 0.6 {
                timer?.invalidate()
                timer = nil
            }
        }
        if let suppressedIcon, !suppressedIcon.frame.contains(point) { self.suppressedIcon = nil }

        if isOverPreview(point) {
            lastInside = now
            return
        }

        if NSEvent.pressedMouseButtons != 0 {
            if let icon = item ?? candidate?.icon, icon.frame.contains(point) {
                suppressedIcon = icon
            }
            dismiss()
            return
        }

        if let item {
            if item.frame.contains(point) {
                lastInside = now
            } else if now - lastInside >= 0.22 {
                clearItem()
            }
        }

        if let pending = candidate {
            if !pending.icon.frame.contains(point) {
                candidate = nil
            } else if now - pending.since >= 0.30 {
                candidate = nil
                clearItem()
                item = pending.icon
                lastInside = now
                refresh()
            }
        }

        guard !probing, point != lastProbed || now - lastProbeTime >= 0.25,
              let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              nearEdge(point, of: screen.frame) else { return }

        probing = true
        lastProbed = point
        lastProbeTime = now
        let desktopTop = primary.frame.maxY
        let axPoint = CGPoint(x: point.x, y: desktopTop - point.y)
        hitTester.hit(at: axPoint) { [weak self] icon in
            Task { @MainActor in
                self?.receiveHit(icon, probedAt: point, desktopTop: desktopTop)
            }
        }
    }

    private func receiveHit(_ hit: DockIcon?, probedAt point: CGPoint, desktopTop: CGFloat) {
        probing = false
        guard enabled, !isOverPreview(NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0 else { return }

        guard let hit else {
            if NSEvent.mouseLocation == point { candidate = nil }
            return
        }

        let frame = CGRect(x: hit.frame.minX, y: desktopTop - hit.frame.maxY,
                           width: hit.frame.width, height: hit.frame.height)
        guard frame.contains(NSEvent.mouseLocation), suppressedIcon?.url != hit.url else { return }

        if item?.url == hit.url {
            lastInside = ProcessInfo.processInfo.systemUptime
            return
        }
        if item != nil { clearItem() }
        let since = candidate?.icon.url == hit.url ? candidate?.since : nil
        candidate = (DockIcon(url: hit.url, frame: frame), since ?? ProcessInfo.processInfo.systemUptime)
        startSampling()
    }

    private func nearEdge(_ point: CGPoint, of frame: CGRect) -> Bool {
        min(point.x - frame.minX, frame.maxX - point.x, point.y - frame.minY) <= 180
    }

    private func isOverPreview(_ point: CGPoint) -> Bool {
        guard let item, isShowing, let frame = panel.visibleFrame else { return false }
        if frame.contains(point) { return true }

        let icon = item.frame
        // Keep the panel open in the gap traversed from the icon to a card.
        if frame.minY >= icon.maxY {
            return CGRect(x: frame.minX, y: icon.maxY, width: frame.width,
                          height: frame.minY - icon.maxY).contains(point)
        }
        if frame.minX >= icon.maxX {
            return CGRect(x: icon.maxX, y: frame.minY, width: frame.minX - icon.maxX,
                          height: frame.height).contains(point)
        }
        if frame.maxX <= icon.minX {
            return CGRect(x: frame.maxX, y: frame.minY, width: icon.minX - frame.maxX,
                          height: frame.height).contains(point)
        }
        return false
    }

    private func runningApps(for url: URL) -> [RunningApp] {
        let expected = url.resolvingSymlinksInPath().standardizedFileURL.path
        let regularApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && !$0.isHidden
        }
        var matches = regularApps.filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == expected }
        if matches.isEmpty, let bundleID = Bundle(url: url)?.bundleIdentifier {
            let sameBundle = regularApps.filter { $0.bundleIdentifier == bundleID }
            if sameBundle.count == 1 { matches = sameBundle }
        }
        return matches.map { app in
            return RunningApp(pid: app.processIdentifier, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                              hidden: false)
        }
    }

    private func receiveWindows(_ windows: [WindowSummary], request: UUID) {
        guard request == requestID, let item else { return }
        loading = false
        guard isShowing || item.frame.contains(NSEvent.mouseLocation) else {
            clearItem()
            return
        }
        guard !windows.isEmpty else {
            clearPanel()
            return
        }

        if let selected = model.selected, !windows.contains(where: { $0.id == selected }) {
            model.selected = nil
        }
        let wasShowing = isShowing
        let thumbnailsChanged = model.updateWindows(windows)
        panel.show(nearDockIcon: item.frame)
        if !wasShowing { visibilityChanged?() }
        if thumbnailsChanged { loadThumbnails() }
    }

    private func loadThumbnails() {
        guard captureEnabled, isShowing else { return }
        captureTask?.cancel()
        let windows = model.windows
        let request = requestID
        let selected = model.selected
        captureTask = Task { [weak self, thumbnails] in
            await thumbnails.load(windows, selected: selected) { [weak self] id, image in
                guard let self, self.requestID == request,
                      self.model.windows.contains(where: { $0.id == id }) else { return }
                self.model.images[id] = image
            }
        }
    }

    private func highlight(_ id: WindowID) {
        let location = NSEvent.mouseLocation
        guard location != lastPointerLocation else { return }
        lastPointerLocation = location
        if model.selected != id { model.selected = id }
    }

    private func moveSelection(_ direction: Int) {
        var selection = WindowSelection(windows: model.windows.map(\.id), selected: model.selected)
        selection.move(direction)
        lastPointerLocation = NSEvent.mouseLocation
        model.selected = selection.selected
        model.revealSelection()
    }

    private func open(_ id: WindowID) {
        guard model.windows.contains(where: { $0.id == id }) else { return }
        suppressedIcon = item
        dismiss()
        catalog.activate(id)
    }

    private func clearItem() {
        item = nil
        requestID = UUID()
        loading = false
        clearPanel()
    }

    private func clearPanel() {
        let wasShowing = isShowing
        lastPointerLocation = nil
        captureTask?.cancel()
        captureTask = nil
        if isShowing { panel.hide() }
        model.windows.removeAll()
        model.selected = nil
        model.icons.removeAll()
        model.images.removeAll()
        if wasShowing { visibilityChanged?() }
    }
}
