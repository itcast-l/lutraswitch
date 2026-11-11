import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor @Observable
final class PreviewModel {
    var windows: [WindowSummary] = []
    var selected: WindowID?
    var images: [WindowID: CGImage] = [:]
    var icons: [pid_t: NSImage] = [:]
    private(set) var layout: PreviewLayout?
    private(set) var iconPage = 0

    func updateWindows(_ updated: [WindowSummary]) -> Bool {
        guard windows != updated else { return false }
        let previous = windows.prefix(PreviewLayout.thumbnailLimit).map(\.id)
        let thumbnailIDs = updated.prefix(PreviewLayout.thumbnailLimit).map(\.id)
        windows = updated
        let pids = Set(updated.map(\.id.pid))
        icons = icons.filter { pids.contains($0.key) }
        for pid in pids where icons[pid] == nil {
            icons[pid] = NSRunningApplication(processIdentifier: pid)?.icon
        }
        images = images.filter { thumbnailIDs.contains($0.key) }
        return previous != thumbnailIDs
    }

    func updateLayout(_ layout: PreviewLayout) {
        guard self.layout != layout else { return }
        self.layout = layout
        iconPage = min(iconPage, layout.pageCount - 1)
        revealSelection()
    }

    func revealSelection() {
        guard let index = windows.firstIndex(where: { $0.id == selected }),
              let page = layout?.page(containingWindowAt: index) else { return }
        iconPage = page
    }

    func changeIconPage(_ direction: Int) {
        guard let layout else { return }
        iconPage = min(max(iconPage + direction, 0), layout.pageCount - 1)
    }

    func resetLayout() {
        layout = nil
        iconPage = 0
    }
}

@MainActor
final class WindowThumbnails {
    private var cache = ThumbnailCache()
    private let captureGate = CaptureGate()
    private var generation = UUID()

    func clear() {
        generation = UUID()
        cache.removeAll()
    }

    func remove(_ id: WindowID) { cache.remove(id) }
    func removeApplication(_ pid: pid_t) { cache.removeApplication(pid) }
    func removeExpired() { cache.removeExpired(now: ProcessInfo.processInfo.systemUptime) }

    func load(
        _ windows: [WindowSummary], selected: WindowID?,
        update: @MainActor (WindowID, CGImage) -> Void
    ) async {
        guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
        let thumbnails = windows.prefix(PreviewLayout.thumbnailLimit)
        let ordered = thumbnails.filter { $0.id == selected } + thumbnails.filter { $0.id != selected }

        for window in ordered {
            if let image = cache.image(for: window.id, now: ProcessInfo.processInfo.systemUptime) {
                update(window.id, image)
            }
        }

        guard ordered.contains(where: { !$0.minimized }) else { return }
        let generation = self.generation
        guard await captureGate.acquire() else { return }
        defer { captureGate.release() }
        guard !Task.isCancelled, generation == self.generation else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              !Task.isCancelled, generation == self.generation else { return }

        let sources = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        for window in ordered where !window.minimized {
            guard !Task.isCancelled, generation == self.generation else { return }
            guard let source = sources[window.id.number], source.owningApplication?.processID == window.id.pid else {
                continue
            }
            let filter = SCContentFilter(desktopIndependentWindow: source)
            let configuration = SCStreamConfiguration()
            let width = max(source.frame.width, 1)
            let height = max(source.frame.height, 1)
            let scale = min(1, 520 / width, 320 / height)
            configuration.width = max(1, Int(width * scale))
            configuration.height = max(1, Int(height * scale))
            configuration.ignoreShadowsSingleWindow = true
            configuration.showsCursor = false

            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            ), !Task.isCancelled, generation == self.generation,
               ThumbnailImage.hasVisibleContent(image) else { continue }
            cache.insert(image, for: window.id, now: ProcessInfo.processInfo.systemUptime)
            update(window.id, image)
        }
    }
}

@MainActor
final class SwitcherPanel {
    private final class Panel: NSPanel {
        var scrollSelection: ((Int) -> Void)?

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        override func sendEvent(_ event: NSEvent) {
            if event.type == .scrollWheel, !event.hasPreciseScrollingDeltas,
               abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
                scrollSelection?(event.scrollingDeltaY < 0 ? 1 : -1)
                return
            }
            super.sendEvent(event)
        }
    }

    private final class HostingView: NSHostingView<WindowPreview> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let model: PreviewModel
    private let panel: Panel
    private let style: PreviewStyle

    init(
        model: PreviewModel,
        hover: @escaping (WindowID) -> Void,
        click: @escaping (WindowID) -> Void,
        scroll: @escaping (Int) -> Void,
        style: PreviewStyle = .switcher
    ) {
        self.model = model
        self.style = style
        panel = Panel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.scrollSelection = scroll
        let hosting = HostingView(rootView: WindowPreview(model: model, style: style, hover: hover, click: click))
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    isolated deinit {
        panel.contentView = nil
        panel.close()
    }

    func show(currentBounds: CGRect?) {
        guard let screen = screen(for: currentBounds) else { return }
        let usable = screen.visibleFrame.insetBy(dx: 16, dy: 0)
        let size = layout(in: usable)
        show(
            in: CGRect(x: usable.midX - size.width / 2, y: usable.midY - size.height / 2,
                       width: size.width, height: size.height)
        )
    }

    var visibleFrame: CGRect? { panel.isVisible ? panel.frame : nil }

    func show(nearDockIcon icon: CGRect) {
        let center = CGPoint(x: icon.midX, y: icon.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return }
        let usable = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let left = icon.midX - screen.frame.minX
        let right = screen.frame.maxX - icon.midX
        let bottom = icon.midY - screen.frame.minY
        let gap: CGFloat = 8
        var area = usable
        let bottomDock = bottom <= min(left, right)
        if bottomDock {
            area.origin.y = max(usable.minY, icon.maxY + gap)
            area.size.height = usable.maxY - area.minY
        } else if left < right {
            area.origin.x = max(usable.minX, icon.maxX + gap)
            area.size.width = usable.maxX - area.minX
        } else {
            area.size.width = min(usable.maxX, icon.minX - gap) - area.minX
        }
        guard area.width > 0, area.height > 0 else { return }
        let size = layout(in: area)
        let x = bottomDock ? icon.midX - size.width / 2 : (left < right ? area.minX : area.maxX - size.width)
        let y = bottomDock ? area.minY : icon.midY - size.height / 2
        show(in: CGRect(
            x: min(max(area.minX, x), area.maxX - size.width),
            y: min(max(area.minY, y), area.maxY - size.height),
            width: size.width, height: size.height
        ))
    }

    private func layout(in usable: CGRect) -> CGSize {
        let layout = PreviewLayout(style: style, windowCount: model.windows.count, available: usable.size)
        model.updateLayout(layout)
        return layout.size
    }

    private func show(in frame: CGRect) {
        if panel.frame != frame.integral {
            panel.setFrame(frame.integral, display: panel.isVisible)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        panel.orderOut(nil)
        model.resetLayout()
    }

    private func screen(for bounds: CGRect?) -> NSScreen? {
        let screens = NSScreen.screens
        if let bounds {
            let intersections = screens.compactMap { screen -> (NSScreen, CGFloat)? in
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
                let intersection = CGDisplayBounds(number.uint32Value).intersection(bounds)
                guard !intersection.isEmpty else { return nil }
                return (screen, intersection.width * intersection.height)
            }
            if let best = intersections.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        return screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
}

private struct WindowPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let model: PreviewModel
    let style: PreviewStyle
    let hover: (WindowID) -> Void
    let click: (WindowID) -> Void

    var body: some View {
        VStack(spacing: style.cardSpacing) {
            if style == .dock {
                dockHeader
            }
            if let layout = model.layout {
                thumbnailGrid(layout)
                if model.windows.count > PreviewLayout.thumbnailLimit {
                    iconGrid(layout)
                }
                if layout.pageCount > 1 {
                    pageControls(layout)
                }
            }
            if style == .switcher {
                switcherFooter
            }
        }
        .padding(.vertical, style.panelPadding)
        .background {
            let shape = RoundedRectangle(cornerRadius: 23)
            shape.fill(.regularMaterial)
                .overlay { shape.fill(panelTint.opacity(reduceTransparency ? 1 : 0.78)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 23))
        .overlay {
            RoundedRectangle(cornerRadius: 23)
                .strokeBorder(.primary.opacity(contrast == .increased ? 0.36 : 0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func thumbnailGrid(_ layout: PreviewLayout) -> some View {
        let columns = Array(repeating: GridItem(.fixed(layout.thumbnailWidth), spacing: style.cardSpacing),
                            count: layout.thumbnailColumns)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: style.cardSpacing) {
            ForEach(model.windows.prefix(PreviewLayout.thumbnailLimit)) { window in
                card(window, width: layout.thumbnailWidth, thumbnailHeight: layout.thumbnailHeight)
            }
        }
        .frame(width: layout.contentWidth, height: layout.thumbnailRowsHeight, alignment: .topLeading)
        .padding(.horizontal, style.panelPadding)
    }

    private func iconGrid(_ layout: PreviewLayout) -> some View {
        let columns = Array(repeating: GridItem(.fixed(layout.iconWidth), spacing: PreviewLayout.iconSpacing),
                            count: layout.iconColumns)
        let range = layout.iconRange(page: model.iconPage)
        let windows = model.windows.dropFirst(PreviewLayout.thumbnailLimit)
        let visible = windows.dropFirst(range.lowerBound).prefix(range.count)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: PreviewLayout.iconSpacing) {
            ForEach(visible) { window in
                card(window, width: layout.iconWidth, thumbnailHeight: nil)
            }
        }
        .frame(width: layout.contentWidth, height: layout.iconRowsHeight, alignment: .topLeading)
        .padding(.horizontal, style.panelPadding)
    }

    private func card(_ window: WindowSummary, width: CGFloat, thumbnailHeight: CGFloat?) -> some View {
        Button {
            click(window.id)
        } label: {
            PreviewCard(
                window: window, image: model.images[window.id], icon: model.icons[window.id.pid],
                selected: model.selected == window.id, style: style, width: width, thumbnailHeight: thumbnailHeight
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            if case .active = phase { hover(window.id) }
        }
    }

    private func pageControls(_ layout: PreviewLayout) -> some View {
        HStack(spacing: 10) {
            pageButton("chevron.left", label: "上一页图标", direction: -1)
                .disabled(model.iconPage == 0)
            Text("\(model.iconPage + 1) / \(layout.pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            pageButton("chevron.right", label: "下一页图标", direction: 1)
                .disabled(model.iconPage + 1 >= layout.pageCount)
        }
        .frame(height: PreviewLayout.pageControlsHeight)
    }

    private func pageButton(_ symbol: String, label: String, direction: Int) -> some View {
        Button {
            model.changeIconPage(direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 36, height: PreviewLayout.pageControlsHeight)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var dockHeader: some View {
        HStack(spacing: 9) {
            if let window = model.windows.first {
                PreviewAppIcon(icon: model.icons[window.id.pid], size: 24)
                Text(window.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            windowCount
        }
        .padding(.horizontal, style.panelPadding + style.cardPadding)
        .frame(height: style.chromeHeight)
    }

    private var switcherFooter: some View {
        HStack {
            windowCount
            Spacer(minLength: 12)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    keyHint("← →", action: "轮选")
                    Text("松键或点击切换")
                    keyHint("Esc", action: "取消")
                }
                HStack(spacing: 8) {
                    Text("松键或点击切换")
                    keyHint("Esc", action: "取消")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, style.panelPadding + style.cardPadding)
        .frame(height: style.chromeHeight)
    }

    private var windowCount: some View {
        Text("\(model.windows.count) 个窗口")
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func keyHint(_ key: String, action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            Text(action)
        }
        .fixedSize()
    }

    private var panelTint: Color {
        colorScheme == .dark ? Color(red: 0.09, green: 0.105, blue: 0.135)
                             : Color(red: 0.96, green: 0.97, blue: 0.985)
    }
}

private struct PreviewCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let window: WindowSummary
    let image: CGImage?
    let icon: NSImage?
    let selected: Bool
    let style: PreviewStyle
    let width: CGFloat
    let thumbnailHeight: CGFloat?

    var body: some View {
        VStack(spacing: style.metadataSpacing) {
            if let thumbnailHeight {
                thumbnail(height: thumbnailHeight)
                metadata
            } else {
                compactIcon
            }
        }
        .frame(width: width - 2 * style.cardPadding)
        .padding(style.cardPadding)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(selected ? selectionColor : .primary.opacity(contrast == .increased ? 0.24 : 0.10),
                              lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var compactIcon: some View {
        VStack(spacing: 4) {
            PreviewAppIcon(icon: icon, size: 30)
            Text(window.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: PreviewLayout.iconHeight - style.cardPadding * 2)
        .overlay(alignment: .topTrailing) {
            if selected || window.minimized {
                Image(systemName: selected ? "checkmark.circle.fill" : "minus.rectangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? selectionColor : Color.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title)，\(window.appName)")
        .accessibilityValue(window.minimized ? "已最小化" : "")
    }

    private func thumbnail(height: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.075)
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                } else {
                    PreviewAppIcon(icon: icon, size: 42)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)

            if window.minimized {
                Label("已最小化", systemImage: "minus.rectangle")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.thickMaterial, in: Capsule())
                    .padding(6)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            if style == .switcher {
                PreviewAppIcon(icon: icon, size: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(window.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if style == .switcher {
                    Text(window.appName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selectionColor)
                .opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 3)
        .frame(height: style.metadataHeight)
    }

    private var cardFill: Color {
        if selected { return selectionColor.opacity(colorScheme == .dark ? 0.17 : 0.10) }
        return colorScheme == .dark ? .white.opacity(0.055) : .white.opacity(0.72)
    }

    private var selectionColor: Color {
        colorScheme == .dark ? Color(red: 0.42, green: 0.68, blue: 1)
                             : Color(red: 0.14, green: 0.35, blue: 0.82)
    }
}

private struct PreviewAppIcon: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
