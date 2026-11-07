
import UIKit

final class EmulatorView: UIView {

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
        backgroundColor = .black
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

    var effectiveDisplayScale: CGFloat {
        let width = max(
            1,
            framebufferPixelWidth > 0
                ? framebufferPixelWidth
                : canvasWidth
        )

        guard bounds.width > 0 else {
            return 0
        }

        return bounds.width / CGFloat(width)
    }

    // Luôn phủ kín vùng hiển thị vật lý.
    // Không aspectFit, không tạo vùng ảnh nhỏ ở giữa.
    override func layoutSubviews() {
        super.layoutSubviews()
        framebufferView.frame = bounds
    }

    // MARK: Framebuffer

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

            self.framebufferView.frame = self.bounds
            self.setNeedsLayout()

            self.onFrame?(cgImage)

            if !self.hasDisplayedFirstFrame {
                self.hasDisplayedFirstFrame = true

                let callback = self.onFirstFrame
                self.onFirstFrame = nil

                callback?()
            }
        }
    }

    // MARK: Touch mapping

    private func virtualPoint(
        for point: CGPoint,
        clampToViewport: Bool
    ) -> (Int, Int)? {

        let viewport = bounds

        guard viewport.width > 0,
              viewport.height > 0 else {
            return nil
        }

        let logicalWidth = max(
            1,
            framebufferPixelWidth > 0
                ? framebufferPixelWidth
                : canvasWidth
        )

        let logicalHeight = max(
            1,
            framebufferPixelHeight > 0
                ? framebufferPixelHeight
                : canvasHeight
        )

        if !clampToViewport && !viewport.contains(point) {
            return nil
        }

        let px = min(
            max(point.x - viewport.minX, 0),
            viewport.width.nextDown
        )

        let py = min(
            max(point.y - viewport.minY, 0),
            viewport.height.nextDown
        )

        let x = Int(
            (px / viewport.width) * CGFloat(logicalWidth)
        )

        let y = Int(
            (py / viewport.height) * CGFloat(logicalHeight)
        )

        return (
            min(max(x, 0), logicalWidth - 1),
            min(max(y, 0), logicalHeight - 1)
        )
    }

    // MARK: Touch events

    override func touchesBegan(
        _ touches: Set<UITouch>,
        with event: UIEvent?
    ) {
        for touch in touches {
            guard let (x, y) = virtualPoint(
                for: touch.location(in: self),
                clampToViewport: false
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
                clampToViewport: true
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
                clampToViewport: true
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

// MARK: Global framebuffer callback

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
