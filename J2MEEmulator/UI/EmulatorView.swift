//
// EmulatorView.swift
// J2ME virtual framebuffer with automatic aspect-fit and matching touch mapping.
// iOS 16.4 compatible.
//

import UIKit

final class EmulatorView: UIView {

    // Logical J2ME canvas resolution.
    // Independent from the iPhone's physical display size.
    var canvasWidth: Int = 240 {
        didSet { setNeedsLayout() }
    }

    var canvasHeight: Int = 320 {
        didSet { setNeedsLayout() }
    }

    private let framebufferView = UIImageView()
    private var framebufferPixelWidth: Int = 0
    private var framebufferPixelHeight: Int = 0

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

        // Keep the original J2ME pixel-art appearance.
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

    // Actual display scale: UIKit points per logical J2ME pixel.
    var effectiveDisplayScale: CGFloat {
        let rect = fittedImageRect()

        guard canvasWidth > 0 else {
            return 0
        }

        return rect.width / CGFloat(canvasWidth)
    }

    // MARK: - Display framebuffer

    func displayImage(_ cgImage: CGImage) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.framebufferPixelWidth = cgImage.width
            self.framebufferPixelHeight = cgImage.height

            self.framebufferView.image = UIImage(
                cgImage: cgImage,
                scale: 1.0,
                orientation: .up
            )

            self.setNeedsLayout()
            self.layoutIfNeeded()

            self.onFrame?(cgImage)

            if let callback = self.onFirstFrame {
                self.onFirstFrame = nil
                callback()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        framebufferView.frame = bounds
    }

    // MARK: - Aspect-fit geometry

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

        // Select the smaller scale so the entire image fits.
        let scale = min(
            viewWidth / sourceWidth,
            viewHeight / sourceHeight
        )

        let displayedWidth = sourceWidth * scale
        let displayedHeight = sourceHeight * scale

        return CGRect(
            x: (viewWidth - displayedWidth) / 2,
            y: (viewHeight - displayedHeight) / 2,
            width: displayedWidth,
            height: displayedHeight
        )
    }

    // MARK: - Touch conversion

    private func convertToVirtual(
        _ point: CGPoint,
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
            // Ignore taps in the black letterbox area.
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

    // MARK: - Touch handling

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        for touch in touches {
            let point = touch.location(in: self)

            guard let (x, y) = convertToVirtual(
                point,
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
            let point = touch.location(in: self)

            guard let (x, y) = convertToVirtual(
                point,
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
            let point = touch.location(in: self)

            guard let (x, y) = convertToVirtual(
                point,
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
) -> Void = { cgImagePointer, width, height in

    guard let cgImagePointer else {
        return
    }

    let cgImage = Unmanaged<CGImage>
        .fromOpaque(cgImagePointer)
        .takeRetainedValue()

    globalEmulatorView?.displayImage(cgImage)
}
