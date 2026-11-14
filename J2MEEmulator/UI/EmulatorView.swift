//
// EmulatorView.swift
// J2ME framebuffer viewport: preserve the virtual canvas, fit the complete
// image into the available iPhone area, and map touches back to JAR coordinates.
// iOS 16.4+
//

import UIKit

final class EmulatorView: UIView {

    /// MIDP logical screen resolution selected for the running JAR.
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
        // The framebuffer image itself is untouched. This color is only the
        // surrounding viewport area (the bars visible when the JAR aspect
        // ratio does not fill the whole iPhone viewport).
        backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? .black
                : .systemBackground
        }

        clipsToBounds = true
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true

        framebufferView.translatesAutoresizingMaskIntoConstraints = true
        framebufferView.backgroundColor = .black
        framebufferView.contentMode = .scaleToFill
        framebufferView.clipsToBounds = true
        framebufferView.isUserInteractionEnabled = false
        framebufferView.layer.magnificationFilter = .nearest
        framebufferView.layer.minificationFilter = .nearest
        addSubview(framebufferView)
    }

    /// Number of UIKit points used by one logical J2ME pixel after fit-to-screen.
    /// Values below 1 mean that a high-resolution JAR is being rendered more
    /// densely inside the same physical viewport.
    var effectiveDisplayScale: CGFloat {
        guard canvasWidth > 0 else { return 0 }
        return fittedImageRect().width / CGFloat(canvasWidth)
    }

    /// The outer EmulatorView stays full-size. Only this image rectangle changes.
    private func fittedImageRect() -> CGRect {
        let viewportWidth = bounds.width
        let viewportHeight = bounds.height

        guard viewportWidth > 0, viewportHeight > 0 else { return .zero }

        let sourceWidth = CGFloat(
            framebufferPixelWidth > 0 ? framebufferPixelWidth : max(1, canvasWidth)
        )
        let sourceHeight = CGFloat(
            framebufferPixelHeight > 0 ? framebufferPixelHeight : max(1, canvasHeight)
        )

        // Uniform scale: never crop, stretch, or enlarge the viewport itself.
        let scale = min(
            viewportWidth / sourceWidth,
            viewportHeight / sourceHeight
        )

        let displayedWidth = sourceWidth * scale
        let displayedHeight = sourceHeight * scale

        return CGRect(
            x: (viewportWidth - displayedWidth) * 0.5,
            y: (viewportHeight - displayedHeight) * 0.5,
            width: displayedWidth,
            height: displayedHeight
        )
    }

    override func traitCollectionDidChange(
        _ previousTraitCollection: UITraitCollection?
    ) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard previousTraitCollection?.userInterfaceStyle
                != traitCollection.userInterfaceStyle else {
            return
        }

        // Keep only the outer viewport background synchronized with
        // Light/Dark mode. The JAR framebuffer is never recolored.
        backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? .black
                : .systemBackground
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        framebufferView.frame = fittedImageRect()
    }

    // MARK: - Framebuffer

    func displayImage(_ cgImage: CGImage) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.framebufferPixelWidth = cgImage.width
            self.framebufferPixelHeight = cgImage.height
            self.framebufferView.image = UIImage(
                cgImage: cgImage,
                scale: 1,
                orientation: .up
            )

            self.setNeedsLayout()
            self.layoutIfNeeded()
            self.onFrame?(cgImage)

            if !self.hasDisplayedFirstFrame {
                self.hasDisplayedFirstFrame = true
                let callback = self.onFirstFrame
                self.onFirstFrame = nil
                callback?()
            }
        }
    }

    // MARK: - Touch coordinate conversion

    private func virtualPoint(for point: CGPoint, clampToImage: Bool) -> (Int, Int)? {
        let rect = fittedImageRect()

        guard rect.width > 0,
              rect.height > 0,
              canvasWidth > 0,
              canvasHeight > 0 else {
            return nil
        }

        if !clampToImage && !rect.contains(point) {
            // Do not send taps from the black bars surrounding the fitted image.
            return nil
        }

        let maxX = rect.maxX.nextDown
        let maxY = rect.maxY.nextDown
        let x = min(max(point.x, rect.minX), maxX)
        let y = min(max(point.y, rect.minY), maxY)

        let normalizedX = (x - rect.minX) / rect.width
        let normalizedY = (y - rect.minY) / rect.height

        let virtualX = Int(normalizedX * CGFloat(canvasWidth))
        let virtualY = Int(normalizedY * CGFloat(canvasHeight))

        return (
            min(max(virtualX, 0), canvasWidth - 1),
            min(max(virtualY, 0), canvasHeight - 1)
        )
    }

    // MARK: - Touch events

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let (x, y) = virtualPoint(
                for: touch.location(in: self),
                clampToImage: false
            ) else { continue }

            j2me_input_post_touch(
                Int32(J2ME_INPUT_POINTER_PRESSED),
                Int32(x),
                Int32(y)
            )
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let (x, y) = virtualPoint(
                for: touch.location(in: self),
                clampToImage: true
            ) else { continue }

            j2me_input_post_touch(
                Int32(J2ME_INPUT_POINTER_DRAGGED),
                Int32(x),
                Int32(y)
            )
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let (x, y) = virtualPoint(
                for: touch.location(in: self),
                clampToImage: true
            ) else { continue }

            j2me_input_post_touch(
                Int32(J2ME_INPUT_POINTER_RELEASED),
                Int32(x),
                Int32(y)
            )
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
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
) -> Void = { cgImagePointer, width, height in
    guard let cgImagePointer else { return }

    let cgImage = Unmanaged<CGImage>
        .fromOpaque(cgImagePointer)
        .takeRetainedValue()

    globalEmulatorView?.displayImage(cgImage)
}
