//
//  AnimatedBackgroundView.swift
//  J2MEEmulator
//
//  Animated colored blobs covered by a blur.
//

import UIKit

final class AnimatedBackgroundView: UIView {

    private let circlesContainer = UIView()
    private let blurView = NeutralBlurView(radius: 40)
    private var circleViews: [UIView] = []

    private var animating = false
    private var animationsPaused = false

    private static let colors: [UIColor] = [
        UIColor(red: 0.15, green: 0.22, blue: 0.55, alpha: 0.38),
        UIColor(red: 0.42, green: 0.12, blue: 0.33, alpha: 0.33),
        UIColor(red: 0.06, green: 0.33, blue: 0.36, alpha: 0.33),
        UIColor(red: 0.33, green: 0.15, blue: 0.45, alpha: 0.33),
        UIColor(red: 0.10, green: 0.30, blue: 0.22, alpha: 0.28),
        UIColor(red: 0.48, green: 0.22, blue: 0.15, alpha: 0.28)
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setup() {
        backgroundColor = .black
        clipsToBounds = true

        circlesContainer.clipsToBounds = true
        addSubview(circlesContainer)

        for color in Self.colors {
            let circle = UIView()
            circle.backgroundColor = color
            circlesContainer.addSubview(circle)
            circleViews.append(circle)
        }

        blurView.backgroundColor = UIColor(
            white: 0,
            alpha: 0.3
        )

        addSubview(blurView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        circlesContainer.frame = bounds
        blurView.frame = bounds

        guard !animationsPaused else {
            return
        }

        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        if !animating {
            for circle in circleViews {
                let size = randomSize()

                circle.frame = CGRect(
                    x: CGFloat.random(
                        in: -size / 2 ... bounds.width - size / 2
                    ),
                    y: CGFloat.random(
                        in: -size / 2 ... bounds.height - size / 2
                    ),
                    width: size,
                    height: size
                )

                circle.layer.cornerRadius = size / 2
            }

            animating = true
            startAnimations()
        }
    }

    private func startAnimations() {
        guard !animationsPaused else {
            return
        }

        for (index, circle) in circleViews.enumerated() {
            let delay = Double(index) * 1.5
            animateCircle(circle, delay: delay)
        }
    }

    private func animateCircle(
        _ circle: UIView,
        delay: TimeInterval
    ) {
        guard !animationsPaused else {
            return
        }

        let duration = Double.random(in: 10...16)
        let newSize = randomSize()

        UIView.animate(
            withDuration: duration,
            delay: delay,
            options: [
                .curveEaseInOut,
                .allowUserInteraction
            ],
            animations: { [weak self] in

                guard let self,
                      !self.animationsPaused else {
                    return
                }

                let x = CGFloat.random(
                    in: -newSize / 2 ... self.bounds.width - newSize / 2
                )

                let y = CGFloat.random(
                    in: -newSize / 2 ... self.bounds.height - newSize / 2
                )

                circle.frame = CGRect(
                    x: x,
                    y: y,
                    width: newSize,
                    height: newSize
                )

                circle.layer.cornerRadius = newSize / 2

            },
            completion: { [weak self] finished in

                guard let self,
                      finished,
                      !self.animationsPaused else {
                    return
                }

                self.animateCircle(
                    circle,
                    delay: 0
                )
            }
        )
    }

    // MARK: - Pause

    func pauseAnimations() {
        guard !animationsPaused else {
            return
        }

        animationsPaused = true
        animating = false

        // Cancel all circle animations.
        // Completion callbacks will not restart them.
        for circle in circleViews {
            circle.layer.removeAllAnimations()
        }

        // Hide the whole background, including blur.
        isHidden = true
    }

    // MARK: - Resume

    func resumeAnimations() {
        guard animationsPaused else {
            return
        }

        animationsPaused = false
        animating = false

        isHidden = false

        // Recalculate positions and start animations again.
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func randomSize() -> CGFloat {
        let base = min(bounds.width, bounds.height)

        guard base > 0 else {
            return 0
        }

        return CGFloat.random(
            in: base * 0.3 ... base * 0.7
        )
    }
}
