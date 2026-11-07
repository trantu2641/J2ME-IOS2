//
// EmulatorView.swift
// Optimized J2ME framebuffer rendering.
// Direct CGImage -> CALayer rendering.
// iOS 16.4+
//

import UIKit
import QuartzCore

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

    // MARK: - Direct Core Animation rendering

    private let framebufferLayer = CALayer()

    private var framebufferPixelWidth = 0
    private var framebufferPixelHeight = 0

    private var hasDisplayedFirstFrame = false

    // MARK: - Frame coalescing

    private let frameLock = NSLock()

    private var pendingFrame: CGImage?
    private var frameDeliveryScheduled = false

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

    private func setup() {

        backgroundColor = .black

        isOpaque = true
        clipsToBounds = true

        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        // Use a dedicated CALayer instead of UIImageView.
        framebufferLayer.backgroundColor = UIColor.black.cgColor

        framebufferLayer.contentsGravity = kCAGravityResizeAspect

        framebufferLayer.magnificationFilter = .nearest
        framebufferLayer.minificationFilter = .nearest

        framebufferLayer.contentsScale = UIScreen.main.scale

        framebufferLayer.isOpaque = true

        framebufferLayer.contents = nil

        layer.addSublayer(framebufferLayer)
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

    /// Called from the native J2ME rendering thread.
    ///
    /// Only the newest pending frame is retained.
    /// At most one main-queue delivery is scheduled at a time.
    func displayImage(_ cgImage: CGImage) {

        frameLock.lock()

        pendingFrame = cgImage

        let shouldSchedule = !frameDeliveryScheduled

        if shouldSchedule {
            frameDeliveryScheduled = true
        }

        frameLock.unlock()

        guard shouldSchedule else {
            return
        }

        DispatchQueue.main.async { [weak self] in

            self?.displayPendingFrame()
        }
    }

    /// Must execute on the main thread.
    ///
    /// Directly commits CGImage to CALayer.
    /// No UIImage allocation and no forced Auto Layout pass.
    private func displayPendingFrame() {

        dispatchPrecondition(
            condition: .onQueue(.main)
        )

        frameLock.lock()

        let cgImage = pendingFrame

        pendingFrame = nil
        frameDeliveryScheduled = false

        frameLock.unlock()

        guard let cgImage else {
            return
        }

        // Update dimensions for correct touch mapping.
        framebufferPixelWidth = cgImage.width
        framebufferPixelHeight = cgImage.height

        // Avoid implicit Core Animation animations.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Direct native image assignment.
        framebufferLayer.contents = cgImage

        CATransaction.commit()

        // Do not call setNeedsLayout() or layoutIfNeeded()
        // for every frame. The layer already fills the view.

        onFrame?(cgImage)

        // First frame notification.
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

    // MARK: - Pointer input

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

// MARK: - Global framebuffer callback

private weak var globalEmulatorView: EmulatorView?

func setGlobalEmulatorView(_ view: EmulatorView?) {
    globalEmulatorView = view
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
