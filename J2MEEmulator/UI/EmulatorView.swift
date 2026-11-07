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

        frameLock.lock()
        let hasPendingFrame = pendingFrame != nil
        frameLock.unlock()

        link.isPaused = !hasPendingFrame

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

        let wasEmpty = pendingFrame == nil

        // Keep the newest frame if another frame arrives.
        pendingFrame = cgImage

        frameLock.unlock()

        guard wasEmpty else {
            return
        }

        // Wake the display link only when a frame is waiting.
        DispatchQueue.main.async { [weak self] in

            guard let self,
                  let link = self.displayLink else {
                return
            }

            link.isPaused = false
        }
    }

    // MARK: - Display frame

    fileprivate func displayPendingFrame() {

        dispatchPrecondition(
            condition: .onQueue(.main)
        )

        frameLock.lock()

        let cgImage = pendingFrame
        pendingFrame = nil

        frameLock.unlock()

        // Pause until the native renderer submits another frame.
        displayLink?.isPaused = true

        guard let cgImage else {
            return
        }

        framebufferPixelWidth = cgImage.width
        framebufferPixelHeight = cgImage.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        framebufferLayer.contents = cgImage

        CATransaction.commit()

        onFrame?(cgImage)

        if !hasDisplayedFirstFrame {

            hasDisplayedFirstFrame = true

            let callback = onFirstFrame
            onFirstFrame = nil

            callback?()
        }
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
