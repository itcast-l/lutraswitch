import CoreGraphics
import Foundation
import Testing

struct WindowSelectionTests {
    private let weChat = WindowID(pid: 10, number: 101)
    private let chrome = WindowID(pid: 20, number: 201)
    private let otherChrome = WindowID(pid: 20, number: 202)
    private let finder = WindowID(pid: 30, number: 301)

    @Test func selectsLastFocusedWindowAcrossApps() {
        var history = WindowRecency()
        history.record(finder)
        history.record(weChat)
        history.record(chrome)
        let order = history.ordered([chrome, finder, weChat], current: chrome)
        #expect(order == [chrome, weChat, finder])
        #expect(WindowSelection(windows: order, current: chrome).selected == weChat)
    }

    @Test func startingInReverseSelectsTheLastWindowOnQuickRelease() {
        var interaction = SwitchInteraction()
        interaction.begin(backward: true)
        #expect(interaction.release() == .none)
        #expect(interaction.prepare(windows: [chrome, weChat, finder], current: chrome) == .commit(finder))
    }

    @Test func tracksWindowsInTheSameAppIndependently() {
        var history = WindowRecency()
        history.record(chrome)
        history.record(otherChrome)
        history.record(otherChrome)
        let order = history.ordered([otherChrome, weChat, chrome], current: otherChrome)
        #expect(order == [otherChrome, chrome, weChat])
        #expect(WindowSelection(windows: order, current: otherChrome).selected == chrome)
    }

    @Test func fallsBackToServerOrderWithNoHistory() {
        let order = WindowRecency().ordered([chrome, finder, weChat], current: chrome)
        #expect(WindowSelection(windows: order, current: chrome).selected == finder)
        #expect(WindowSelection(windows: order, current: nil).selected == chrome)
    }

    @Test func ignoresClosedAndOutOfScopeWindows() {
        var history = WindowRecency()
        history.record(weChat)
        history.record(finder)
        history.record(chrome)
        history.retain([chrome, finder])
        let order = history.ordered([chrome, otherChrome], current: chrome)
        #expect(order == [chrome, otherChrome])
        #expect(history.ordered([chrome, otherChrome, weChat], current: chrome) == [chrome, otherChrome, weChat])
    }

    @Test func wrapsInBothDirections() {
        var selection = WindowSelection(windows: [chrome, weChat, finder], current: chrome)
        selection.move(1)
        #expect(selection.selected == finder)
        selection.move(1)
        #expect(selection.selected == chrome)
        selection.move(-1)
        #expect(selection.selected == finder)
    }

    @Test func handlesEmptyAndSingleWindow() {
        var interaction = SwitchInteraction()
        interaction.begin()
        #expect(interaction.prepare(windows: [], current: nil) == .dismiss)
        #expect(interaction.release() == .none)
        interaction.begin()
        #expect(interaction.prepare(windows: [weChat], current: weChat) == .show)
        #expect(interaction.move(1) == .show)
        #expect(interaction.release() == .commit(weChat))
    }

    @Test func quickReleaseCommitsWithoutShowingPanel() {
        var interaction = SwitchInteraction()
        interaction.begin()
        #expect(interaction.release() == .none)
        #expect(interaction.prepare(windows: [chrome, weChat, finder], current: chrome) == .commit(weChat))
        #expect(!interaction.isRunning)
    }

    @Test func appliesNavigationBeforeSnapshotFinishes() {
        var interaction = SwitchInteraction()
        interaction.begin()
        _ = interaction.move(1)
        _ = interaction.release()
        #expect(interaction.prepare(windows: [chrome, weChat, finder], current: chrome) == .commit(finder))
    }

    @Test func cancellingDiscardsLateSnapshotAndRelease() {
        var interaction = SwitchInteraction()
        interaction.begin()
        #expect(interaction.cancel() == .dismiss)
        #expect(interaction.prepare(windows: [chrome, weChat], current: chrome) == .none)
        #expect(interaction.release() == .none)
    }

    @Test func removingSelectionDoesNotSwitchToASurpriseWindow() {
        var interaction = SwitchInteraction()
        interaction.begin()
        _ = interaction.prepare(windows: [chrome, weChat, finder], current: chrome)
        #expect(interaction.retain([chrome, finder, otherChrome]) == .show)
        #expect(interaction.selection?.windows == [chrome, finder])
        #expect(interaction.selection?.selected == nil)
        #expect(interaction.release() == .dismiss)
    }

    @Test func hoverChangesSelectionWithoutCommitting() {
        var interaction = SwitchInteraction()
        interaction.begin()
        _ = interaction.prepare(windows: [chrome, weChat, finder], current: chrome)
        #expect(interaction.selection?.selected == weChat)
        #expect(interaction.hover(chrome) == .show)
        #expect(interaction.hover(finder) == .show)
        #expect(interaction.hover(finder) == .none)
        #expect(interaction.release() == .commit(finder))
    }

    @Test func clickingCommitsThatCardAndIgnoresTheLaterKeyRelease() {
        var interaction = SwitchInteraction()
        interaction.begin()
        _ = interaction.prepare(windows: [chrome, weChat, finder], current: chrome)
        #expect(interaction.selection?.selected == weChat)
        #expect(interaction.click(finder) == .commit(finder))
        #expect(interaction.release() == .none)
    }

    @Test func ignoresPointerEventsForRemovedCardsAndInactivePreview() {
        var interaction = SwitchInteraction()
        #expect(interaction.click(weChat) == .none)
        interaction.begin()
        _ = interaction.prepare(windows: [chrome, weChat, finder], current: chrome)
        _ = interaction.retain([chrome, weChat])
        #expect(interaction.hover(finder) == .none)
        #expect(interaction.click(finder) == .none)
        #expect(interaction.selection?.selected == weChat)
    }
}

struct PreviewLayoutTests {
    @Test func onlyTheFirstFiveGetThumbnailCards() {
        let available = CGSize(width: 1600, height: 900)
        let five = PreviewLayout(style: .switcher, windowCount: 5, available: available)
        let twelve = PreviewLayout(style: .switcher, windowCount: 12, available: available)

        #expect(five.iconRange(page: 0).isEmpty)
        #expect(twelve.thumbnailColumns == 5)
        #expect(twelve.size.width == five.size.width)
        #expect(twelve.size.height > five.size.height)
        #expect(twelve.iconRange(page: 0) == 0..<7)
        #expect(twelve.page(containingWindowAt: 4) == nil)
        #expect(twelve.page(containingWindowAt: 5) == 0)
    }

    @Test func wrapsThumbnailsAndIconsOnNarrowDisplays() {
        let available = CGSize(width: 600, height: 500)
        let layout = PreviewLayout(style: .dock, windowCount: 19, available: available)

        #expect(layout.thumbnailColumns < 5)
        #expect(layout.size.width <= available.width)
        #expect(layout.size.height <= available.height)
        #expect(layout.iconRowsHeight > PreviewLayout.iconHeight)
    }

    @Test func paginatesEveryOverflowWindowWithinScreenBounds() {
        let available = CGSize(width: 900, height: 450)
        let total = 137
        let layout = PreviewLayout(style: .switcher, windowCount: total, available: available)
        let indices = (0..<layout.pageCount).flatMap { layout.iconRange(page: $0) }

        #expect(layout.pageCount > 1)
        #expect(layout.size.height <= available.height)
        #expect(indices == Array(0..<(total - PreviewLayout.thumbnailLimit)))
        #expect(layout.page(containingWindowAt: total - 1) == layout.pageCount - 1)
    }
}

struct ThumbnailImageTests {
    @Test func rejectsTransparentCapture() throws {
        let image = try makeImage(pixel: [0, 0, 0, 0])
        #expect(!ThumbnailImage.hasVisibleContent(image))
    }

    @Test func acceptsSolidWhiteAndTranslucentWindows() throws {
        let white = try makeImage(pixel: [255, 255, 255, 255])
        let translucent = try makeImage(pixel: [60, 0, 0, 120])
        #expect(ThumbnailImage.hasVisibleContent(white))
        #expect(ThumbnailImage.hasVisibleContent(translucent))
    }

    private func makeImage(pixel: [UInt8]) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(pixel) as CFData))
        return try #require(CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: [.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }
}

struct ThumbnailCacheTests {
    private func image(width: Int = 8, height: Int = 8) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    @Test func boundsBytesAndCountAcrossTenThousandWindows() throws {
        let bitmap = try image()
        let cost = bitmap.bytesPerRow * bitmap.height
        var cache = ThumbnailCache(byteLimit: cost * 3, countLimit: 5)
        for number in 0..<10_000 {
            cache.insert(bitmap, for: WindowID(pid: 1, number: UInt32(number)), now: Double(number) / 100)
            #expect(cache.totalCost <= cost * 3)
            #expect(cache.count <= 3)
        }
        var countLimited = ThumbnailCache(byteLimit: cost * 10, countLimit: 2)
        for number in 0..<100 {
            countLimited.insert(bitmap, for: WindowID(pid: 1, number: UInt32(number)), now: Double(number))
        }
        #expect(countLimited.count == 2)
    }

    @Test func keepsRecentlyUsedImagesAndRejectsOversizedImages() throws {
        let bitmap = try image()
        let ids = (1...3).map { WindowID(pid: 1, number: UInt32($0)) }
        var cache = ThumbnailCache(byteLimit: bitmap.bytesPerRow * bitmap.height * 2)
        cache.insert(bitmap, for: ids[0], now: 0)
        cache.insert(bitmap, for: ids[1], now: 1)
        #expect(cache.image(for: ids[0], now: 2) != nil)
        cache.insert(bitmap, for: ids[2], now: 3)
        #expect(cache.image(for: ids[1], now: 4) == nil)
        #expect(cache.image(for: ids[0], now: 4) != nil)
        cache.insert(try image(width: 64), for: ids[1], now: 5)
        #expect(cache.count == 2)
        #expect(cache.image(for: ids[1], now: 5) == nil)
    }

    @Test func expiresIdleImagesAndBalancesReplacementAndRemovalCosts() throws {
        let bitmap = try image()
        let first = WindowID(pid: 1, number: 1)
        let second = WindowID(pid: 2, number: 2)
        var cache = ThumbnailCache(maxAge: 120)
        cache.insert(bitmap, for: first, now: 0)
        cache.insert(bitmap, for: first, now: 1)
        #expect(cache.totalCost == bitmap.bytesPerRow * bitmap.height)
        cache.insert(bitmap, for: second, now: 2)
        cache.removeApplication(1)
        #expect(cache.count == 1)
        cache.removeExpired(now: 122)
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
        cache.insert(bitmap, for: first, now: 130)
        #expect(cache.image(for: first, now: 250) == nil)
        cache.insert(bitmap, for: second, now: 260)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
    }

    @Test func forgetsAllFocusHistoryForTerminatedProcess() {
        let old = WindowID(pid: 1, number: 1)
        let other = WindowID(pid: 2, number: 2)
        var history = WindowRecency()
        history.record(other)
        history.record(old)
        history.removeApplication(1)
        #expect(history.ordered([old, other], current: nil) == [other, old])
    }
}

@MainActor
struct CaptureGateTests {
    @Test func admitsOnlyNewestPendingRequest() async {
        let gate = CaptureGate()
        #expect(await gate.acquire())
        var firstStarted = false
        let first = Task {
            firstStarted = true
            return await gate.acquire()
        }
        while !firstStarted { await Task.yield() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await gate.acquire()
        }
        while !secondStarted { await Task.yield() }
        #expect(await first.value == false)
        gate.release()
        #expect(await second.value)
        gate.release()
        #expect(await gate.acquire())
        gate.release()
    }

    @Test func cancellingWaiterDoesNotBlockNextCapture() async {
        let gate = CaptureGate()
        #expect(await gate.acquire())
        var started = false
        let cancelled = Task {
            started = true
            return await gate.acquire()
        }
        while !started { await Task.yield() }
        cancelled.cancel()
        #expect(await cancelled.value == false)
        gate.release()
        #expect(await gate.acquire())
        gate.release()
    }

    @Test func alreadyCancelledRequestNeverAcquiresGate() async {
        let gate = CaptureGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.acquire()
        }
        #expect(await task.value == false)
        #expect(await gate.acquire())
        gate.release()
    }
}

@MainActor
struct ResourceLifecycleTests {
    @Test func panelReleasesItsHostingViewAndModel() {
        weak var released: PreviewModel?
        autoreleasepool {
            let model = PreviewModel()
            released = model
            let panel = SwitcherPanel(model: model, hover: { _ in }, click: { _ in }, scroll: { _ in })
            panel.hide()
        }
        #expect(released == nil)
    }

    @Test func previewReleasesRemovedImagesAndIcons() throws {
        let model = PreviewModel()
        let id = WindowID(pid: 1, number: 1)
        let window = WindowSummary(id: id, appName: "Test", title: "Test", minimized: false, bounds: nil, canClose: true)
        _ = model.updateWindows([window])
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bitmap = try #require(context.makeImage())
        model.images[id] = bitmap
        _ = model.updateWindows([])
        #expect(model.images.isEmpty)
        #expect(model.icons.isEmpty)
    }

    @Test func controllerReleasesAfterRepeatedStartStop() async {
        weak var released: AppController?
        for _ in 0..<20 {
            var controller: AppController? = AppController()
            released = controller
            controller?.start()
            controller?.stop()
            controller?.start()
            controller?.stop()
            controller = nil
            #expect(released == nil)
        }
        // Drain cancellation callbacks and queued run-loop source removal.
        for _ in 0..<5 { await Task.yield() }
    }

    @Test func controllerDeinitCleansUpWithoutExplicitStop() async {
        weak var released: AppController?
        var controller: AppController? = AppController()
        released = controller
        controller?.start()
        controller = nil
        #expect(released == nil)
        for _ in 0..<5 { await Task.yield() }
    }
}
