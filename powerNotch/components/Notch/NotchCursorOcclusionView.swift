//
//  NotchCursorOcclusionView.swift
//  powerNotch
//
//  Renders a software mirror of the active system cursor composited beneath the
//  hardware-notch black feather transition when the pointer enters the top-center
//  transition zone of the expanded Liquid Glass notch, using SkyLight's
//  `SetsCursorInBackground` SPI so the cursor seamlessly dissolves into the
//  physical hardware notch as a unified visual element.
//

import AppKit
import CoreGraphics
import SwiftUI

/// Coordinates background hardware-cursor hiding via SkyLight SPI with strict
/// single-owner balance and automatic fail-safe restoration on sleep, lock,
/// app termination, or missed mouse-exit events.
@MainActor
final class SkyLightCursorController {
    static let shared = SkyLightCursorController()

    private typealias SLSMainConnectionIDFn = @convention(c) () -> Int32
    private typealias SLSSetConnectionPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias SLSCursorVisibilityFn = @convention(c) (Int32) -> Int32

    private let cid: Int32
    private let hideFn: SLSCursorVisibilityFn?
    private let showFn: SLSCursorVisibilityFn?
    private let isAvailable: Bool

    private(set) var isHidden: Bool = false
    private var ownerID: ObjectIdentifier?
    private var watchdogTimer: Timer?
    private var watchdogHandler: (() -> Void)?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)
        if let handle,
           let mainCIDPtr = dlsym(handle, "SLSMainConnectionID"),
           let setPropPtr = dlsym(handle, "SLSSetConnectionProperty"),
           let hidePtr = dlsym(handle, "SLSHideCursor"),
           let showPtr = dlsym(handle, "SLSShowCursor")
        {
            let mainCID = unsafeBitCast(mainCIDPtr, to: SLSMainConnectionIDFn.self)
            let setProp = unsafeBitCast(setPropPtr, to: SLSSetConnectionPropertyFn.self)
            let connection = mainCID()
            let status = setProp(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)

            self.cid = connection
            self.hideFn = unsafeBitCast(hidePtr, to: SLSCursorVisibilityFn.self)
            self.showFn = unsafeBitCast(showPtr, to: SLSCursorVisibilityFn.self)
            self.isAvailable = (status == 0)
        } else {
            self.cid = 0
            self.hideFn = nil
            self.showFn = nil
            self.isAvailable = false
        }

        registerFailSafeObservers()
    }

    private func registerFailSafeObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceRestore()
            }
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceRestore()
            }
        }
        wsCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceRestore()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.forceRestore()
            }
        }
    }

    /// Hides the hardware cursor on behalf of `owner`. Returns `true` if the
    /// hardware cursor is hidden and software rendering should proceed.
    @discardableResult
    func hide(owner: ObjectIdentifier, watchdog: @escaping () -> Void) -> Bool {
        guard isAvailable, let hideFn else { return false }

        watchdogHandler = watchdog

        if isHidden {
            ownerID = owner
            return true
        }

        let status = hideFn(cid)
        guard status == 0 else { return false }

        isHidden = true
        ownerID = owner
        startWatchdog()
        return true
    }

    /// Restores the hardware cursor if currently owned by `owner` (or unconditionally if `owner == nil`).
    func restore(owner: ObjectIdentifier? = nil) {
        if let owner, ownerID != owner {
            return
        }
        forceRestore()
    }

    func forceRestore() {
        stopWatchdog()
        watchdogHandler = nil
        ownerID = nil

        guard isHidden, let showFn else { return }
        _ = showFn(cid)
        isHidden = false
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.watchdogHandler?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }
}

/// Transparent click-through overlay that mirrors the active system cursor
/// underneath the physical hardware-notch Gaussian black feather when the
/// pointer enters the top-center transition region of the expanded notch.
struct NotchCursorOcclusionView: NSViewRepresentable {
    let isEnabled: Bool
    let physicalNotchSize: CGSize?
    let activeNotchSize: CGSize
    var onPointerExitedNotch: (() -> Void)? = nil

    func makeNSView(context: Context) -> NotchCursorOcclusionNSView {
        let view = NotchCursorOcclusionNSView()
        view.onPointerExitedNotch = onPointerExitedNotch
        view.updateConfiguration(
            isEnabled: isEnabled,
            physicalNotchSize: physicalNotchSize,
            activeNotchSize: activeNotchSize
        )
        return view
    }

    func updateNSView(_ nsView: NotchCursorOcclusionNSView, context: Context) {
        nsView.onPointerExitedNotch = onPointerExitedNotch
        nsView.updateConfiguration(
            isEnabled: isEnabled,
            physicalNotchSize: physicalNotchSize,
            activeNotchSize: activeNotchSize
        )
    }
}

@MainActor
final class NotchCursorOcclusionNSView: NSView {
    var onPointerExitedNotch: (() -> Void)?

    private var isOcclusionEnabled: Bool = false
    private var physicalNotchSize: CGSize?
    private var activeNotchSize: CGSize = openNotchSize

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var wasInsideNotchBounds: Bool = false
    private var didHideDuringOpenSession: Bool = false
    private var isRenderingSoftwareCursor: Bool = false
    private var currentCursorImage: NSImage?
    private var currentCursorHotSpot: NSPoint = .zero
    private var currentLocalPoint: NSPoint?
    private var previousCursorRect: NSRect = .zero

    private var cachedMaskImage: NSImage?
    private var cachedMaskKey: MaskCacheKey?

    private struct MaskCacheKey: Equatable {
        let notchWidth: Int
        let notchHeight: Int
        let zoneWidth: Int
        let zoneHeight: Int
        let scale: Int
    }

    private var ownerID: ObjectIdentifier { ObjectIdentifier(self) }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopMonitoring()
            deactivateSoftwareCursor()
        }
    }

    deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        let id = ObjectIdentifier(self)
        Task { @MainActor in
            SkyLightCursorController.shared.restore(owner: id)
        }
    }

    func updateConfiguration(isEnabled: Bool, physicalNotchSize: CGSize?, activeNotchSize: CGSize) {
        let active = isEnabled && (physicalNotchSize?.height ?? 0) > 0
        let sizeChanged = self.physicalNotchSize != physicalNotchSize
            || self.activeNotchSize != activeNotchSize

        self.isOcclusionEnabled = active
        self.physicalNotchSize = physicalNotchSize
        self.activeNotchSize = activeNotchSize

        if sizeChanged {
            cachedMaskImage = nil
            cachedMaskKey = nil
        }

        if active {
            startMonitoringIfNeeded()
            refreshMaskIfNeeded()
            evaluateCurrentMousePosition()
        } else {
            wasInsideNotchBounds = false
            didHideDuringOpenSession = false
            stopMonitoring()
            deactivateSoftwareCursor()
        }
    }

    override func layout() {
        super.layout()
        if isOcclusionEnabled {
            refreshMaskIfNeeded()
        }
    }

    private var activeNotchRect: NSRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        let width = min(bounds.width, max(0, activeNotchSize.width))
        let height = min(bounds.height, max(0, activeNotchSize.height))
        guard width > 0, height > 0 else { return .zero }
        return NSRect(
            x: bounds.midX - width / 2,
            y: 0,
            width: width,
            height: height
        )
    }

    private var occlusionZoneRect: NSRect {
        let notchBounds = activeNotchRect
        guard let physicalNotch = physicalNotchSize,
              physicalNotch.height > 0,
              !notchBounds.isEmpty
        else {
            return .zero
        }

        let clampedWidth = min(physicalNotch.width, max(0, notchBounds.width - 44))
        let clampedHeight = min(physicalNotch.height, notchBounds.height * 0.45)

        // Wide enough that both the pure-black core and Gaussian veil reach alpha == 0
        // well inside the zone perimeter so hardware <-> software handoff is invisible.
        let zoneWidth = min(notchBounds.width, clampedWidth + clampedHeight * 4.8)
        let zoneHeight = min(notchBounds.height, clampedHeight * 3.4)

        return NSRect(
            x: notchBounds.midX - zoneWidth / 2,
            y: 0,
            width: zoneWidth,
            height: zoneHeight
        )
    }

    private func startMonitoringIfNeeded() {
        guard globalMonitor == nil && localMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .scrollWheel
        ]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateCurrentMousePosition()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.evaluateCurrentMousePosition()
            return event
        }
    }

    private func stopMonitoring() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func evaluateCurrentMousePosition() {
        guard isOcclusionEnabled,
              let window,
              window.isVisible,
              window.alphaValue > 0.5
        else {
            deactivateSoftwareCursor()
            return
        }

        let zone = occlusionZoneRect
        guard !zone.isEmpty else {
            deactivateSoftwareCursor()
            return
        }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)

        let isInsideNotch = activeNotchRect.contains(localPoint)
        let exitedNotchAfterHiding = wasInsideNotchBounds && !isInsideNotch && didHideDuringOpenSession
        wasInsideNotchBounds = isInsideNotch

        // Require pointer to be strictly inside both our view bounds and the occlusion zone
        guard isInsideNotch, zone.contains(localPoint) else {
            deactivateSoftwareCursor()
            if exitedNotchAfterHiding {
                didHideDuringOpenSession = false
                onPointerExitedNotch?()
            }
            return
        }

        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        guard image.size.width > 0, image.size.height > 0 else {
            deactivateSoftwareCursor()
            return
        }

        refreshMaskIfNeeded()

        let didHide = SkyLightCursorController.shared.hide(owner: ownerID) { [weak self] in
            self?.evaluateCurrentMousePosition()
        }
        guard didHide else {
            deactivateSoftwareCursor()
            return
        }
        didHideDuringOpenSession = true

        let newCursorRect = NSRect(
            x: localPoint.x - cursor.hotSpot.x,
            y: localPoint.y - cursor.hotSpot.y,
            width: image.size.width,
            height: image.size.height
        ).insetBy(dx: -2, dy: -2)

        isRenderingSoftwareCursor = true
        currentCursorImage = image
        currentCursorHotSpot = cursor.hotSpot
        currentLocalPoint = localPoint

        let dirtyRect = previousCursorRect.isEmpty
            ? newCursorRect
            : previousCursorRect.union(newCursorRect)
        previousCursorRect = newCursorRect

        setNeedsDisplay(dirtyRect)
    }

    private func deactivateSoftwareCursor() {
        SkyLightCursorController.shared.restore(owner: ownerID)

        guard isRenderingSoftwareCursor || !previousCursorRect.isEmpty else { return }
        let dirty = previousCursorRect
        isRenderingSoftwareCursor = false
        currentCursorImage = nil
        currentLocalPoint = nil
        previousCursorRect = .zero

        if !dirty.isEmpty {
            setNeedsDisplay(dirty)
        }
    }

    private func refreshMaskIfNeeded() {
        guard let physicalNotch = physicalNotchSize, physicalNotch.height > 0 else { return }
        let zone = occlusionZoneRect
        guard !zone.isEmpty else { return }

        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let key = MaskCacheKey(
            notchWidth: Int(physicalNotch.width.rounded()),
            notchHeight: Int(physicalNotch.height.rounded()),
            zoneWidth: Int(zone.width.rounded()),
            zoneHeight: Int(zone.height.rounded()),
            scale: Int((backingScale * 10).rounded())
        )
        guard key != cachedMaskKey else { return }

        let notchBounds = activeNotchRect
        let clampedWidth = min(physicalNotch.width, max(0, notchBounds.width - 44))
        let clampedHeight = min(physicalNotch.height, notchBounds.height * 0.45)

        // Render the exact same Gaussian black core + mid-range veil as
        // NotchGlassBackground.hardwareNotchDarkTransition, feathered softly to 0
        // before the zone edges so hardware <-> software cursor handoff has zero seam.
        let maskView = ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: max(18, clampedHeight * 0.75),
                bottomTrailingRadius: max(18, clampedHeight * 0.75),
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black.opacity(0.78))
            .frame(width: clampedWidth + clampedHeight * 1.8, height: clampedHeight * 2.15)
            .blur(radius: max(18, clampedHeight * 0.74))
            .offset(y: -clampedHeight * 0.32)

            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: max(12, clampedHeight * 0.48),
                bottomTrailingRadius: max(12, clampedHeight * 0.48),
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
            .frame(width: clampedWidth + clampedHeight * 0.65, height: clampedHeight * 1.48)
            .blur(radius: max(10, clampedHeight * 0.38))
            .offset(y: -4)
        }
        .frame(width: zone.width, height: zone.height, alignment: .top)
        .mask {
            // Soft outer boundary taper guaranteeing alpha == 0.0 at zone left/right/bottom edges
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.78),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .white, location: 0.12),
                        .init(color: .white, location: 0.88),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .clipped()

        let renderer = ImageRenderer(content: maskView)
        renderer.scale = backingScale
        renderer.proposedSize = ProposedViewSize(zone.size)

        if let cgImage = renderer.cgImage {
            cachedMaskImage = NSImage(cgImage: cgImage, size: zone.size)
            cachedMaskKey = key
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isRenderingSoftwareCursor,
              let cursorImage = currentCursorImage,
              let localPoint = currentLocalPoint
        else {
            return
        }

        let cursorRect = NSRect(
            x: localPoint.x - currentCursorHotSpot.x,
            y: localPoint.y - currentCursorHotSpot.y,
            width: cursorImage.size.width,
            height: cursorImage.size.height
        )
        guard cursorRect.intersects(dirtyRect) else { return }

        // 1. Draw crisp Retina system cursor above all notch UI controls
        cursorImage.draw(
            in: cursorRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )

        // 2. Composite the hardware-notch black feather strictly source-atop the cursor
        //    pixels so the cursor darkens & dissolves into the physical notch bezel without
        //    affecting any underlying UI pixels.
        if let maskImage = cachedMaskImage {
            let zone = occlusionZoneRect
            maskImage.draw(
                in: zone,
                from: .zero,
                operation: .sourceAtop,
                fraction: 1.0,
                respectFlipped: true,
                hints: nil
            )
        }
    }
}
