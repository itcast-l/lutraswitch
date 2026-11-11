import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class WindowSystem {
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias DisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias WindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let windowNumber: WindowNumber?
    private let mainConnection: MainConnection?
    private let displaySpaces: DisplaySpaces?
    private let windowSpaces: WindowSpaces?
    private let accessibilityHandle: UnsafeMutableRawPointer?
    private let skyLightHandle: UnsafeMutableRawPointer?

    init() {
        let accessibility = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        accessibilityHandle = accessibility
        skyLightHandle = skyLight

        // Keep the frameworks loaded for exactly as long as the function pointers.
        windowNumber = Self.symbol("_AXUIElementGetWindow", in: accessibility, as: WindowNumber.self)
        mainConnection = Self.symbol("SLSMainConnectionID", in: skyLight, as: MainConnection.self)
        displaySpaces = Self.symbol("SLSCopyManagedDisplaySpaces", in: skyLight, as: DisplaySpaces.self)
        windowSpaces = Self.symbol("SLSCopySpacesForWindows", in: skyLight, as: WindowSpaces.self)
    }

    deinit {
        if let accessibilityHandle { dlclose(accessibilityHandle) }
        if let skyLightHandle { dlclose(skyLightHandle) }
    }

    var canIdentifyWindows: Bool { windowNumber != nil }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    func number(of element: AXUIElement) -> CGWindowID? {
        var number = kCGNullWindowID
        guard windowNumber?(element, &number) == .success, number != kCGNullWindowID else { return nil }
        return number
    }

    struct Spaces {
        let connection: Int32
        let visible: Set<UInt64>
    }

    func currentSpaces() -> Spaces? {
        guard let connection = mainConnection?(), windowSpaces != nil,
              let displays = displaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]],
              !displays.isEmpty else { return nil }

        let ids = displays.compactMap {
            (($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
        }.filter { $0 != 0 }
        guard ids.count == displays.count else { return nil }
        return Spaces(connection: connection, visible: Set(ids))
    }

    func isOnCurrentSpace(_ number: CGWindowID, spaces: Spaces) -> Bool? {
        // 0x7 queries all Space membership types. An empty result leaves membership unknown.
        let numbers = [NSNumber(value: number)] as CFArray
        guard let membership = windowSpaces?(spaces.connection, 0x7, numbers)?
            .takeRetainedValue() as? [NSNumber], !membership.isEmpty else { return nil }

        return membership.contains { spaces.visible.contains($0.uint64Value) }
    }
}
