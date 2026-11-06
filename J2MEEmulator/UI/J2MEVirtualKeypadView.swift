//
// J2MEVirtualKeypadView.swift
// Portrait on-screen keypad for the J2ME emulator.
// iOS 16.4 compatible.
//

import UIKit

final class J2MEVirtualKeypadView: UIView {

    var onKeyEvent: ((Int32, Int32) -> Void)?

    private struct KeySpec {
        let title: String
        let codes: [Int32]
    }

    private let leftRows: [[KeySpec?]] = [
        [
            KeySpec(title: "1", codes: [49]),
            KeySpec(title: "2", codes: [50]),
            KeySpec(title: "3", codes: [51])
        ],
        [
            KeySpec(title: "4", codes: [52]),
            KeySpec(title: "5", codes: [53]),
            KeySpec(title: "6", codes: [54])
        ],
        [
            KeySpec(title: "7", codes: [55]),
            KeySpec(title: "8", codes: [56]),
            KeySpec(title: "9", codes: [57])
        ],
        [
            KeySpec(title: "*", codes: [42]),
            KeySpec(title: "0", codes: [48]),
            KeySpec(title: "#", codes: [35])
        ]
    ]

    // L / empty / R, then directional keys and FIRE.
    private let rightRows: [[KeySpec?]] = [
        [
            KeySpec(title: "L", codes: [-6]),
            nil,
            KeySpec(title: "R", codes: [-7])
        ],
        [
            KeySpec(title: "↖", codes: [-1, -3]),
            KeySpec(title: "↑", codes: [-1]),
            KeySpec(title: "↗", codes: [-1, -4])
        ],
        [
            KeySpec(title: "←", codes: [-3]),
            KeySpec(title: "F", codes: [-5]),
            KeySpec(title: "→", codes: [-4])
        ],
        [
            KeySpec(title: "↙", codes: [-2, -3]),
            KeySpec(title: "↓", codes: [-2]),
            KeySpec(title: "↘", codes: [-2, -4])
        ]
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        let leftGrid = makeGrid(rows: leftRows)
        let rightGrid = makeGrid(rows: rightRows)

        let stack = UIStackView(
            arrangedSubviews: [leftGrid, rightGrid]
        )

        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1)
        ])
    }

    private func makeGrid(rows: [[KeySpec?]]) -> UIStackView {
        let column = UIStackView()
        column.axis = .vertical
        column.alignment = .fill
        column.distribution = .fillEqually
        column.spacing = 3

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.alignment = .fill
            rowStack.distribution = .fillEqually
            rowStack.spacing = 3

            for spec in row {
                if let spec {
                    rowStack.addArrangedSubview(makeButton(spec))
                } else {
                    let spacer = UIView()
                    spacer.backgroundColor = .clear
                    rowStack.addArrangedSubview(spacer)
                }
            }

            column.addArrangedSubview(rowStack)
        }

        return column
    }

    private func makeButton(_ spec: KeySpec) -> UIButton {
        let button = J2MEKeyButton(
            title: spec.title,
            codes: spec.codes
        )

        button.onKeyEvent = { [weak self] type, code in
            self?.onKeyEvent?(type, code)
        }

        return button
    }
}

private final class J2MEKeyButton: UIButton {

    private let codes: [Int32]
    var onKeyEvent: ((Int32, Int32) -> Void)?
    private var isPressed = false

    private let normalColor = UIColor(
        red: 0.89,
        green: 0.89,
        blue: 0.91,
        alpha: 1
    )

    private let pressedColor = UIColor(
        red: 0.72,
        green: 0.75,
        blue: 0.82,
        alpha: 1
    )

    init(title: String, codes: [Int32]) {
        self.codes = codes
        super.init(frame: .zero)

        setTitle(title, for: .normal)

        setTitleColor(
            UIColor(red: 0.03, green: 0.08, blue: 0.45, alpha: 1),
            for: .normal
        )

        titleLabel?.font = .systemFont(ofSize: 23, weight: .medium)
        backgroundColor = normalColor
        clipsToBounds = true

        addTarget(self, action: #selector(keyDown), for: .touchDown)

        addTarget(
            self,
            action: #selector(keyUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height * 0.24, 18)
    }

    @objc private func keyDown() {
        guard !isPressed else { return }

        isPressed = true
        backgroundColor = pressedColor

        for code in codes {
            onKeyEvent?(
                Int32(J2ME_INPUT_KEY_PRESSED),
                code
            )
        }
    }

    @objc private func keyUp() {
        guard isPressed else { return }

        isPressed = false
        backgroundColor = normalColor

        for code in codes {
            onKeyEvent?(
                Int32(J2ME_INPUT_KEY_RELEASED),
                code
            )
        }
    }
}
