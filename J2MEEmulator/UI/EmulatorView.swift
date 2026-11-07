//
// EmulatorView.swift
// Optimized J2ME framebuffer rendering.
// Uses CADisplayLink and a single pending-frame slot.
// Compatible with iOS 16.4+.
//

import UIKit
import QuartzCore

private final class EmulatorDisplayLinkTarget: NSObject {

    weak var owner: EmulatorView?

    init(owner: EmulatorView) {
        self.owner = owner
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        owner?.displayPendingFrame()
    }
}

final class EmulatorView: UIView {

    // MARK: - Virtual resolution

    var canvasWidth: Int = 240 {
        didSet {
            setNeedsLayout()
        }
    }

    var canvasHeight: Int = 320 {
        didSet {
            setNeedsLayout()
        }
    }

    // MARK: - Rendering

    private let framebufferLayer = CALayer()

    private var framebufferPixelWidth = 0
    private var framebufferPixelHeight = 0

    private var hasDisplayedFirstFrame = false

    // MARK: - Frame queue

    private let frameLock = NSLock()
    private var pendingFrame: CGImage?

    // Frame timing counters are protected independently from frameLock.
    private let metricsLock = NSLock()
    private var metricsWindowStart = CACurrentMediaTime()
    private var metricsDisplayTicks = 0
    private var metricsFramesReceived = 0
    private var metricsFramesDisplayed = 0
    private var metricsFramesReplaced = 0
    private var metricsLayerTotalMs = 0.0
    private var metricsLayerMaxMs = 0.0
    private var metricsCallbackTotalMs = 0.0
    private var metricsCallbackMaxMs = 0.0
    private var metricsTickTotalMs = 0.0
    private var metricsTickMaxMs = 0.0

    private var displayLink: CADisplayLink?
    private var displayLinkTarget: EmulatorDisplayLinkTarget?

    var onFirstFrame: (() -> Void)?
    var onFrame: ((CGImage) -> Void)?

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        displayLink?.invalidate()
    }

    private func setup() {

        // Register the real iOS main pthread so the native CPU profiler
        // can distinguish UIKit's main thread from MiniJVM workers.
        if Thread.isMainThread {
            jvm_bridge_register_main_thread()
        } else {
            DispatchQueue.main.async {
                jvm_bridge_register_main_thread()
            }
        }

        backgroundColor = .black

        isOpaque = true
        clipsToBounds = true

        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        framebufferLayer.backgroundColor =
            UIColor.black.cgColor

        framebufferLayer.contentsGravity = .resizeAspect

        framebufferLayer.magnificationFilter = .nearest
        framebufferLayer.minificationFilter = .nearest

        framebufferLayer.contentsScale =
            UIScreen.main.scale

        framebufferLayer.isOpaque = true
        framebufferLayer.contents = nil

        layer.addSublayer(framebufferLayer)
    }

    // MARK: - Display link lifecycle

    override func didMoveToWindow() {

        super.didMoveToWindow()

        if window != nil {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    private func startDisplayLink() {

        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startDisplayLink()
            }
            return
        }

        guard displayLink == nil else {
            return
        }

        let target = EmulatorDisplayLinkTarget(owner: self)

        let link = CADisplayLink(
            target: target,
            selector: #selector(EmulatorDisplayLinkTarget.tick(_:))
        )

        // Keep one display-link callback per display refresh.
        // Frame submission only fills the pending slot and never dispatches
        // an additional main-queue block for every frame.
        link.isPaused = false

        displayLinkTarget = target
        displayLink = link

        link.add(
            to: .main,
            forMode: .common
        )
    }

    private func stopDisplayLink() {

        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.stopDisplayLink()
            }
            return
        }

        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
    }

    // MARK: - Layout

    override func layoutSubviews() {

        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        framebufferLayer.frame = bounds

        CATransaction.commit()
    }

    // MARK: - Aspect fit

    var effectiveDisplayScale: CGFloat {

        guard canvasWidth > 0 else {
            return 0
        }

        return fittedImageRect().width /
            CGFloat(canvasWidth)
    }

    private func fittedImageRect() -> CGRect {

        let viewWidth = bounds.width
        let viewHeight = bounds.height

        guard viewWidth > 0,
              viewHeight > 0 else {

            return .zero
        }

        let pixelWidth = framebufferPixelWidth > 0
            ? framebufferPixelWidth
            : max(1, canvasWidth)

        let pixelHeight = framebufferPixelHeight > 0
            ? framebufferPixelHeight
            : max(1, canvasHeight)

        let sourceWidth = CGFloat(pixelWidth)
        let sourceHeight = CGFloat(pixelHeight)

        let scale = min(
            viewWidth / sourceWidth,
            viewHeight / sourceHeight
        )

        let displayedWidth = sourceWidth * scale
        let displayedHeight = sourceHeight * scale

        return CGRect(
            x: (viewWidth - displayedWidth) * 0.5,
            y: (viewHeight - displayedHeight) * 0.5,
            width: displayedWidth,
            height: displayedHeight
        )
    }

    // MARK: - Framebuffer submission

    /// Called by the native renderer before creating a CGImage snapshot.
    /// Returning 0 tells native code to skip this frame.
    func canAcceptFrame() -> Int32 {

        frameLock.lock()
        defer {
            frameLock.unlock()
        }

        return pendingFrame == nil ? 1 : 0
    }

    func displayImage(_ cgImage: CGImage) {

        frameLock.lock()

        let replacedPendingFrame = pendingFrame != nil

        // Keep the newest frame if another frame arrives.
        pendingFrame = cgImage

        frameLock.unlock()

        metricsLock.lock()
        metricsFramesReceived += 1

        if replacedPendingFrame {
            metricsFramesReplaced += 1
        }

        metricsLock.unlock()
    }

    // MARK: - Frame performance metrics

    private func recordDisplayMetrics(
        frameDisplayed: Bool,
        layerMs: Double,
        callbackMs: Double,
        tickMs: Double
    ) {

        let now = CACurrentMediaTime()
        var logLine: String?

        metricsLock.lock()

        metricsDisplayTicks += 1

        if frameDisplayed {
            metricsFramesDisplayed += 1

            metricsLayerTotalMs += layerMs
            metricsLayerMaxMs = max(metricsLayerMaxMs, layerMs)

            metricsCallbackTotalMs += callbackMs
            metricsCallbackMaxMs = max(metricsCallbackMaxMs, callbackMs)

            metricsTickTotalMs += tickMs
            metricsTickMaxMs = max(metricsTickMaxMs, tickMs)
        }

        let elapsed = now - metricsWindowStart

        if elapsed >= 5.0 {

            let ticksPerSecond =
                Double(metricsDisplayTicks) / elapsed

            let receivedPerSecond =
                Double(metricsFramesReceived) / elapsed

            let displayedPerSecond =
                Double(metricsFramesDisplayed) / elapsed

            let replacedPerSecond =
                Double(metricsFramesReplaced) / elapsed

            let frameCount = max(1, metricsFramesDisplayed)

            logLine = String(
                format:
                    "[UI Frame Perf] displayLink/s=%.1f received/s=%.1f displayed/s=%.1f replaced/s=%.1f avgLayerMs=%.3f maxLayerMs=%.3f avgCallbackMs=%.3f maxCallbackMs=%.3f avgTickMs=%.3f maxTickMs=%.3f",
                ticksPerSecond,
                receivedPerSecond,
                displayedPerSecond,
                replacedPerSecond,
                metricsLayerTotalMs / Double(frameCount),
                metricsLayerMaxMs,
                metricsCallbackTotalMs / Double(frameCount),
                metricsCallbackMaxMs,
                metricsTickTotalMs / Double(frameCount),
                metricsTickMaxMs
            )

            metricsWindowStart = now
            metricsDisplayTicks = 0
            metricsFramesReceived = 0
            metricsFramesDisplayed = 0
            metricsFramesReplaced = 0
            metricsLayerTotalMs = 0
            metricsLayerMaxMs = 0
            metricsCallbackTotalMs = 0
            metricsCallbackMaxMs = 0
            metricsTickTotalMs = 0
            metricsTickMaxMs = 0
        }

        metricsLock.unlock()

        if let logLine {
            print(logLine)
        }
    }

    // MARK: - Display frame

    fileprivate func displayPendingFrame() {

        dispatchPrecondition(
            condition: .onQueue(.main)
        )

        let tickStart = CACurrentMediaTime()

        frameLock.lock()

        let cgImage = pendingFrame
        pendingFrame = nil

        frameLock.unlock()

        guard let cgImage else {

            recordDisplayMetrics(
                frameDisplayed: false,
                layerMs: 0,
                callbackMs: 0,
                tickMs: (CACurrentMediaTime() - tickStart) * 1000.0
            )

            return
        }

        framebufferPixelWidth = cgImage.width
        framebufferPixelHeight = cgImage.height

        let layerStart = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        framebufferLayer.contents = cgImage

        CATransaction.commit()

        let layerMs =
            (CACurrentMediaTime() - layerStart) * 1000.0

        let callbackStart = CACurrentMediaTime()

        onFrame?(cgImage)

        if !hasDisplayedFirstFrame {

            hasDisplayedFirstFrame = true

            let callback = onFirstFrame
            onFirstFrame = nil

            callback?()
        }

        let callbackMs =
            (CACurrentMediaTime() - callbackStart) * 1000.0

        let tickMs =
            (CACurrentMediaTime() - tickStart) * 1000.0

        recordDisplayMetrics(
            frameDisplayed: true,
            layerMs: layerMs,
            callbackMs: callbackMs,
            tickMs: tickMs
        )
    }

    // MARK: - Touch conversion

    private func virtualPoint(
        for point: CGPoint,
        clampToImage: Bool
    ) -> (Int, Int)? {

        let rect = fittedImageRect()

        guard rect.width > 0,
              rect.height > 0,
              canvasWidth > 0,
              canvasHeight > 0 else {

            return nil
        }

        if !clampToImage && !rect.contains(point) {
            return nil
        }

        let x = min(
            max(point.x, rect.minX),
            rect.maxX.nextDown
        )

        let y = min(
            max(point.y, rect.minY),
            rect.maxY.nextDown
        )

        let normalizedX =
            (x - rect.minX) / rect.width

        let normalizedY =
            (y - rect.minY) / rect.height

        let virtualX = Int(
            normalizedX * CGFloat(canvasWidth)
        )

        let virtualY = Int(
            normalizedY * CGFloat(canvasHeight)
        )

        return (
            min(max(virtualX, 0), canvasWidth - 1),
            min(max(virtualY, 0), canvasHeight - 1)
        )
    }

    // MARK: - Touch events

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {

        for touch in touches {

            guard let (x, y) = virtualPoint(
                for: touch.location(in: self),
                clampToImage: false
            ) else {
                continue
            }

            j2me_input_post_touch(
                Int32(J2ME_INPUT_POINTER_PRESSED),
                Int32(x),
                Int32(y)
            )
        }
    }

    override func touchesMoved(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {

        for touch in touches {

            guard let (x, y) = virtualPoint(
                for: touch.location(in: self),
                clampToImage: true
            ) else {
                continue
            }

            j2me_input_post_touch(
                Int32(J2ME_INPUT_POINTER_DRAGGED),
                Int32(x),
                Int32(y)
            )
        }
    }

    override func touchesEnded(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {

        for touch in touches {

            guard let (x, y) = virtualPoint(
                for: touch.location(in: self),
                clampToImage: true
            ) else {
                continue
            }

            j2me_input_post_touch(
                Int32(J2ME_INPUT_POINTER_RELEASED),
                Int32(x),
                Int32(y)
            )
        }
    }

    override func touchesCancelled(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {

        touchesEnded(touches, with: event)
    }
}

// MARK: - Global framebuffer callbacks

private weak var globalEmulatorView: EmulatorView?

func setGlobalEmulatorView(_ view: EmulatorView?) {
    globalEmulatorView = view
}

let flushReadyCallback: @convention(c) () -> Int32 = {

    guard let view = globalEmulatorView else {
        return 0
    }

    return view.canAcceptFrame()
}

let flushCallback: @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    Int32
) -> Void = { cgImagePointer, _, _ in

    guard let cgImagePointer else {
        return
    }

    let cgImage = Unmanaged<CGImage>
        .fromOpaque(cgImagePointer)
        .takeRetainedValue()

    globalEmulatorView?.displayImage(cgImage)
}
