//
// EmulatorView.swift
// J2ME framebuffer viewport with aspect-fit rendering and accurate touch mapping.
// iOS 16.4+
//

import UIKit

final class EmulatorView: UIView {

    /// Logical MIDP canvas dimensions for the selected JAR.
    var canvasWidth: Int = 240 {
        didSet { setNeedsLayout() }
    }

    var canvasHeight: Int = 320 {
        didSet { setNeedsLayout() }
    }

    private let framebufferView = UIImageView()
    private var framebufferPixelWidth = 0
    private var framebufferPixelHeight = 0
    private var hasDisplayedFirstFrame = false

    // Keep only the newest image while the main queue is busy.
    private let frameLock = NSLock()
    private var pendingFrame: CGImage?
    private var frameDeliveryScheduled = false

    var onFirstFrame: (() -> Void)?
    var onFrame: ((CGImage) -> Void)?

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
        clipsToBounds = true
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        framebufferView.translatesAutoresizingMaskIntoConstraints = false
        framebufferView.backgroundColor = .black
        framebufferView.contentMode = .scaleAspectFit
        framebufferView.clipsToBounds = true
        framebufferView.isUserInteractionEnabled = false
        framebufferView.layer.magnificationFilter = .nearest
        framebufferView.layer.minificationFilter = .nearest
        framebufferView.layer.contentsGravity = .resizeAspect

        addSubview(framebufferView)

        NSLayoutConstraint.activate([
            framebufferView.topAnchor.constraint(equalTo: topAnchor),
            framebufferView.leadingAnchor.constraint(equalTo: leadingAnchor),
            framebufferView.trailingAnchor.constraint(equalTo: trailingAnchor),
            framebufferView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// UIKit points occupied by one logical J2ME pixel after aspect fitting.
    var effectiveDisplayScale: CGFloat {
        guard canvasWidth > 0 else { return 0 }
        return fittedImageRect().width / CGFloat(canvasWidth)
    }

    /// Image rectangle inside the full-size UIImageView.
    private func fittedImageRect() -> CGRect {
        let viewWidth = bounds.width
        let viewHeight = bounds.height

        guard viewWidth > 0, viewHeight > 0 else {
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

    override func layoutSubviews() {
        super.layoutSubviews()
        framebufferView.frame = bounds
    }

    // MARK: - Framebuffer

    func displayImage(_ cgImage: CGImage) {

        frameLock.lock()

        // Replace any older frame that has not reached the screen yet.
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

    private func displayPendingFrame() {

        frameLock.lock()

        let cgImage = pendingFrame

        pendingFrame = nil
        frameDeliveryScheduled = false

        frameLock.unlock()

        guard let cgImage else {
            return
        }

        framebufferPixelWidth = cgImage.width
        framebufferPixelHeight = cgImage.height

        framebufferView.image = UIImage(
            cgImage: cgImage,
            scale: 1.0,
            orientation: .up
        )

        setNeedsLayout()
        layoutIfNeeded()

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

        let x = min(max(point.x, rect.minX), rect.maxX.nextDown)
        let y = min(max(point.y, rect.minY), rect.maxY.nextDown)

        let normalizedX = (x - rect.minX) / rect.width
        let normalizedY = (y - rect.minY) / rect.height

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

    guard let cgImagePointer else { return }

    let cgImage = Unmanaged<CGImage>
        .fromOpaque(cgImagePointer)
        .takeRetainedValue()

    globalEmulatorView?.displayImage(cgImage)
}
