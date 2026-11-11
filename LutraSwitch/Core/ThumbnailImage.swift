import CoreGraphics
import Foundation

enum ThumbnailImage {
    static func hasVisibleContent(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return true
        default:
            break
        }

        let width = min(image.width, 32)
        let height = min(image.height, 32)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return stride(from: 3, to: buffer.count, by: 4).contains { buffer[$0] != 0 }
        }
    }
}

// A hard bound on retained bitmap bytes; NSCache cost limits are advisory.
struct ThumbnailCache {
    private struct Entry {
        let image: CGImage
        let cost: Int
        var lastAccess: TimeInterval
    }

    let byteLimit: Int
    let countLimit: Int
    let maxAge: TimeInterval
    private var entries: [WindowID: Entry] = [:]
    private(set) var totalCost = 0
    var count: Int { entries.count }

    init(byteLimit: Int = 8 * 1024 * 1024, countLimit: Int = 16, maxAge: TimeInterval = 120) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
        self.maxAge = max(0, maxAge)
    }

    mutating func image(for id: WindowID, now: TimeInterval) -> CGImage? {
        guard var entry = entries[id] else { return nil }
        guard now - entry.lastAccess < maxAge else {
            remove(id)
            return nil
        }
        entry.lastAccess = now
        entries[id] = entry
        return entry.image
    }

    mutating func insert(_ image: CGImage, for id: WindowID, now: TimeInterval) {
        remove(id)
        let cost = image.bytesPerRow * image.height
        guard countLimit > 0, cost <= byteLimit else { return }
        removeExpired(now: now)
        while entries.count >= countLimit || totalCost > byteLimit - cost {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { break }
            remove(oldest)
        }
        entries[id] = Entry(image: image, cost: cost, lastAccess: now)
        totalCost += cost
    }

    mutating func remove(_ id: WindowID) {
        if let entry = entries.removeValue(forKey: id) { totalCost -= entry.cost }
    }

    mutating func removeExpired(now: TimeInterval) {
        for (id, entry) in entries where now - entry.lastAccess >= maxAge { remove(id) }
    }

    mutating func removeApplication(_ pid: Int32) {
        for id in entries.keys where id.pid == pid { remove(id) }
    }

    mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }
}

// A cancelled ScreenCaptureKit await may still be running in the framework.
// Keep one active operation and only the newest waiting preview request.
@MainActor
final class CaptureGate {
    private var occupied = false
    private var waiting: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                if !occupied {
                    occupied = true
                    continuation.resume(returning: true)
                } else {
                    waiting?.continuation.resume(returning: false)
                    waiting = (id, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.waiting?.id == id else { return }
                self.waiting?.continuation.resume(returning: false)
                self.waiting = nil
            }
        }
    }

    func release() {
        if let waiting {
            self.waiting = nil
            waiting.continuation.resume(returning: true)
        } else {
            occupied = false
        }
    }
}
