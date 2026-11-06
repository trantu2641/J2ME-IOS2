import UIKit

final class J2MEVirtualKeypadView: UIView {

    var onKeyEvent: ((Int32, Int32) -> Void)?

    private struct Key {
        let title: String
        let codes: [Int32]
    }

    private let leftRows: [[Key?]] = [
        [
            Key(title: "1", codes: [49]),
            Key(title: "2", codes: [50]),
            Key(title: "3", codes: [51])
        ],
        [
            Key(title: "4", codes: [52]),
            Key(title: "5", codes: [53]),
            Key(title: "6", codes: [54])
        ],
        [
            Key(title: "7", codes: [55]),
            Key(title: "8", codes: [56]),
            Key(title: "9", codes: [57])
        ],
        [
            Key(title: "*", codes: [42]),
            Key(title: "0", codes: [48]),
            Key(title: "#", codes: [35])
        ]
    ]

    private let rightRows: [[Key?]] = [
        [
            Key(title: "L", codes: [-6]),
            nil,
            Key(title: "R", codes: [-7])
        ],
        [
            Key(title: "↖", codes: [-1, -3]),
            Key(title: "↑", codes: [-1]),
            Key(title: "↗", codes: [-1, -4])
        ],
        [
            Key(title: "←", codes: [-3]),
            Key(title: "F", codes: [-5]),
            Key(title: "→", codes: [-4])
        ],
        [
            Key(title: "↙", codes: [-2, -3]),
            Key(title: "↓", codes: [-2]),
            Key(title: "↘", codes: [-2, -4])
        ]
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setup() {

        let leftGrid = makeGrid(rows: leftRows)
        let rightGrid = makeGrid(rows: rightRows)

        let mainStack = UIStackView(
            arrangedSubviews: [leftGrid, rightGrid]
        )

        mainStack.axis = .horizontal
        mainStack.alignment = .fill
        mainStack.distribution = .fillEqually
        mainStack.spacing = 10

        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2)
        ])
    }

    private func makeGrid(rows: [[Key?]]) -> UIStackView {

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

            for key in row {

                if let key {
                    let button = makeButton(key)
                    rowStack.addArrangedSubview(button)
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

    private func makeButton(_ key: Key) -> UIButton {

        let button = J2MEKeyButton(
            title: key.title,
            codes: key.codes
        )

        button.onKeyEvent = { [weak self] type, code in
            self?.onKeyEvent?(type, code)
        }

        return button
    }
}

// ============================================================
// MARK: - Individual key button
// ============================================================

private final class J2MEKeyButton: UIButton {

    private let codes: [Int32]

    var onKeyEvent: ((Int32, Int32) -> Void)?

    init(title: String, codes: [Int32]) {

        self.codes = codes

        super.init(frame: .zero)

        setTitle(title, for: .normal)

        setTitleColor(
            UIColor(red: 0.03, green: 0.08, blue: 0.45, alpha: 1),
            for: .normal
        )

        titleLabel?.font = .systemFont(
            ofSize: 23,
            weight: .medium
        )

        backgroundColor = UIColor(
            red: 0.89,
            green: 0.89,
            blue: 0.91,
            alpha: 1
        )

        layer.cornerRadius = 15
        clipsToBounds = true

        addTarget(
            self,
            action: #selector(keyDown),
            for: .touchDown
        )

        addTarget(
            self,
            action: #selector(keyUp),
            for: [
                .touchUpInside,
                .touchUpOutside,
                .touchCancel
            ]
        )
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height * 0.25, 18)
    }

    @objc private func keyDown() {

        backgroundColor = UIColor(
            red: 0.72,
            green: 0.75,
            blue: 0.82,
            alpha: 1
        )

        for code in codes {
            onKeyEvent?(
                Int32(J2ME_INPUT_KEY_PRESSED),
                code
            )
        }
    }

    @objc private func keyUp() {

        backgroundColor = UIColor(
            red: 0.89,
            green: 0.89,
            blue: 0.91,
            alpha: 1
        )

        for code in codes {
            onKeyEvent?(
                Int32(J2ME_INPUT_KEY_RELEASED),
                code
            )
        }
    }
}
