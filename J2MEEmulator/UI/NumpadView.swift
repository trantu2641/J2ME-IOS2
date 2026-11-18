import UIKit

private let J2ME_KEY_UP: Int32         = -1
private let J2ME_KEY_DOWN: Int32       = -2
private let J2ME_KEY_LEFT: Int32       = -3
private let J2ME_KEY_RIGHT: Int32      = -4
private let J2ME_KEY_FIRE: Int32       = -5
private let J2ME_KEY_SOFT_LEFT: Int32  = -6
private let J2ME_KEY_SOFT_RIGHT: Int32 = -7

private let J2ME_KEY_NUM0: Int32       = 48
private let J2ME_KEY_NUM1: Int32       = 49
private let J2ME_KEY_NUM2: Int32       = 50
private let J2ME_KEY_NUM3: Int32       = 51
private let J2ME_KEY_NUM4: Int32       = 52
private let J2ME_KEY_NUM5: Int32       = 53
private let J2ME_KEY_NUM6: Int32       = 54
private let J2ME_KEY_NUM7: Int32       = 55
private let J2ME_KEY_NUM8: Int32       = 56
private let J2ME_KEY_NUM9: Int32       = 57
private let J2ME_KEY_STAR: Int32       = 42
private let J2ME_KEY_POUND: Int32      = 35

final class PadView: UIView {

    var onKeyDown: ((Int32) -> Void)?
    var onKeyUp: ((Int32) -> Void)?

    private let dpadContainer = UIView()
    private let dpadUpBtn = UIButton(type: .custom)
    private let dpadDownBtn = UIButton(type: .custom)
    private let dpadLeftBtn = UIButton(type: .custom)
    private let dpadRightBtn = UIButton(type: .custom)
    private let dpadFireBtn = UIButton(type: .custom)

    private let rightButtonsContainer = UIView()
    private let btnA = UIButton(type: .custom)
    private let btnB = UIButton(type: .custom)

    private let numpadContainer = UIView()
    private var numpadButtons: [UIButton] = []

    private let softLeftBtn = UIButton(type: .custom)
    private let softRightBtn = UIButton(type: .custom)
    private let toggleNumpadBtn = UIButton(type: .custom)

    private var showNumpad = false
    private var activeButtons: Set<UIButton> = []
    private var dpadDirection: Int32? = nil

    private let btnBg = UIColor(white: 0.22, alpha: 0.72)
    private let btnHighlightBg = UIColor(white: 0.45, alpha: 0.88)
    private let btnBorder = UIColor(white: 1.0, alpha: 0.25)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        setupSoftKeys()
        setupDPad()
        setupABButtons()
        setupNumpad()
        updateNumpadVisibility()
    }

    private func makeButton(title: String, fontSize: CGFloat = 15, bold: Bool = true) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = bold ? UIFont.boldSystemFont(ofSize: fontSize) : UIFont.systemFont(ofSize: fontSize)
        btn.backgroundColor = btnBg
        btn.layer.borderColor = btnBorder.cgColor
        btn.layer.borderWidth = 1.0
        btn.isUserInteractionEnabled = false
        return btn
    }

    private func setupSoftKeys() {
        softLeftBtn.tag = Int(J2ME_KEY_SOFT_LEFT)
        softLeftBtn.setTitle("LSK", for: .normal)
        softLeftBtn.setTitleColor(.white, for: .normal)
        softLeftBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        softLeftBtn.backgroundColor = btnBg
        softLeftBtn.layer.borderColor = btnBorder.cgColor
        softLeftBtn.layer.borderWidth = 1.0
        softLeftBtn.layer.cornerRadius = 8
        softLeftBtn.isUserInteractionEnabled = false
        addSubview(softLeftBtn)

        softRightBtn.tag = Int(J2ME_KEY_SOFT_RIGHT)
        softRightBtn.setTitle("RSK", for: .normal)
        softRightBtn.setTitleColor(.white, for: .normal)
        softRightBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        softRightBtn.backgroundColor = btnBg
        softRightBtn.layer.borderColor = btnBorder.cgColor
        softRightBtn.layer.borderWidth = 1.0
        softRightBtn.layer.cornerRadius = 8
        softRightBtn.isUserInteractionEnabled = false
        addSubview(softRightBtn)

        toggleNumpadBtn.setTitle("123", for: .normal)
        toggleNumpadBtn.setTitleColor(.white, for: .normal)
        toggleNumpadBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 12)
        toggleNumpadBtn.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.65)
        toggleNumpadBtn.layer.borderColor = btnBorder.cgColor
        toggleNumpadBtn.layer.borderWidth = 1.0
        toggleNumpadBtn.layer.cornerRadius = 8
        toggleNumpadBtn.addTarget(self, action: #selector(toggleNumpad), for: .touchUpInside)
        addSubview(toggleNumpadBtn)
    }

    private func setupDPad() {
        dpadContainer.backgroundColor = .clear
        dpadContainer.isUserInteractionEnabled = false
        addSubview(dpadContainer)

        let dirs: [(UIButton, String, Int32)] = [
            (dpadUpBtn, "▲", J2ME_KEY_UP),
            (dpadDownBtn, "▼", J2ME_KEY_DOWN),
            (dpadLeftBtn, "◀", J2ME_KEY_LEFT),
            (dpadRightBtn, "▶", J2ME_KEY_RIGHT),
            (dpadFireBtn, "●", J2ME_KEY_FIRE),
        ]

        for (btn, title, key) in dirs {
            btn.tag = Int(key)
            btn.setTitle(title, for: .normal)
            btn.setTitleColor(.white, for: .normal)
            btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: key == J2ME_KEY_FIRE ? 14 : 16)
            btn.backgroundColor = key == J2ME_KEY_FIRE ? UIColor(white: 0.30, alpha: 0.82) : btnBg
            btn.layer.borderColor = btnBorder.cgColor
            btn.layer.borderWidth = 1.0
            btn.layer.cornerRadius = 10
            btn.isUserInteractionEnabled = false
            dpadContainer.addSubview(btn)
        }
    }

    private func setupABButtons() {
        rightButtonsContainer.backgroundColor = .clear
        rightButtonsContainer.isUserInteractionEnabled = false
        addSubview(rightButtonsContainer)

        btnA.tag = Int(J2ME_KEY_FIRE)
        btnA.setTitle("A", for: .normal)
        btnA.setTitleColor(.white, for: .normal)
        btnA.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        btnA.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.62)
        btnA.layer.borderColor = btnBorder.cgColor
        btnA.layer.borderWidth = 1.5
        btnA.isUserInteractionEnabled = false
        rightButtonsContainer.addSubview(btnA)

        btnB.tag = Int(J2ME_KEY_SOFT_RIGHT)
        btnB.setTitle("B", for: .normal)
        btnB.setTitleColor(.white, for: .normal)
        btnB.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        btnB.backgroundColor = UIColor.systemRed.withAlphaComponent(0.62)
        btnB.layer.borderColor = btnBorder.cgColor
        btnB.layer.borderWidth = 1.5
        btnB.isUserInteractionEnabled = false
        rightButtonsContainer.addSubview(btnB)
    }

    private func setupNumpad() {
        numpadContainer.backgroundColor = .clear
        numpadContainer.isUserInteractionEnabled = false
        addSubview(numpadContainer)

        let keys: [(String, Int32)] = [
            ("1", J2ME_KEY_NUM1), ("2", J2ME_KEY_NUM2), ("3", J2ME_KEY_NUM3),
            ("4", J2ME_KEY_NUM4), ("5", J2ME_KEY_NUM5), ("6", J2ME_KEY_NUM6),
            ("7", J2ME_KEY_NUM7), ("8", J2ME_KEY_NUM8), ("9", J2ME_KEY_NUM9),
            ("*", J2ME_KEY_STAR), ("0", J2ME_KEY_NUM0), ("#", J2ME_KEY_POUND),
        ]

        for (title, keyCode) in keys {
            let btn = makeButton(title: title, fontSize: 16)
            btn.tag = Int(keyCode)
            btn.layer.cornerRadius = 8
            numpadContainer.addSubview(btn)
            numpadButtons.append(btn)
        }
    }

    @objc private func toggleNumpad() {
        showNumpad.toggle()
        toggleNumpadBtn.setTitle(showNumpad ? "Pad" : "123", for: .normal)
        updateNumpadVisibility()
        setNeedsLayout()
    }

    private func updateNumpadVisibility() {
        numpadContainer.isHidden = !showNumpad
        dpadContainer.isHidden = showNumpad
        rightButtonsContainer.isHidden = showNumpad
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let w = bounds.width
        let h = bounds.height
        let safeBottom = safeAreaInsets.bottom
        let sideMargin: CGFloat = 14
        let topBarHeight: CGFloat = 34
        let topBarY: CGFloat = 6

        // Top row: LSK, 123 toggle, RSK
        let softW: CGFloat = 68
        softLeftBtn.frame = CGRect(x: sideMargin, y: topBarY, width: softW, height: topBarHeight)
        softRightBtn.frame = CGRect(x: w - sideMargin - softW, y: topBarY, width: softW, height: topBarHeight)

        let toggleW: CGFloat = 52
        toggleNumpadBtn.frame = CGRect(x: (w - toggleW) / 2, y: topBarY, width: toggleW, height: topBarHeight)

        // Available vertical area below top bar and above safe area bottom
        let contentTop = topBarY + topBarHeight + 8
        let contentBottom = max(contentTop + 80, h - max(safeBottom, 8) - 6)
        let availH = contentBottom - contentTop

        // Adaptive D-Pad size so it never clips off bottom or overlaps center
        let dpadSize: CGFloat = min(144, max(108, min(availH, w * 0.38)))
        let dpadY = contentTop + (availH - dpadSize) / 2
        dpadContainer.frame = CGRect(x: sideMargin, y: dpadY, width: dpadSize, height: dpadSize)

        let cellSize = dpadSize / 3
        dpadUpBtn.frame = CGRect(x: cellSize, y: 0, width: cellSize, height: cellSize)
        dpadDownBtn.frame = CGRect(x: cellSize, y: cellSize * 2, width: cellSize, height: cellSize)
        dpadLeftBtn.frame = CGRect(x: 0, y: cellSize, width: cellSize, height: cellSize)
        dpadRightBtn.frame = CGRect(x: cellSize * 2, y: cellSize, width: cellSize, height: cellSize)
        dpadFireBtn.frame = CGRect(x: cellSize, y: cellSize, width: cellSize, height: cellSize)

        // Right side: A & B diagonal buttons
        let abBtnSize: CGFloat = min(56, max(44, dpadSize * 0.38))
        let abContainerW = abBtnSize * 2 + 12
        let abContainerH = abBtnSize * 2 + 8
        let abY = contentTop + (availH - abContainerH) / 2
        rightButtonsContainer.frame = CGRect(
            x: w - sideMargin - abContainerW,
            y: abY,
            width: abContainerW,
            height: abContainerH
        )

        btnB.frame = CGRect(x: 0, y: abContainerH - abBtnSize, width: abBtnSize, height: abBtnSize)
        btnB.layer.cornerRadius = abBtnSize / 2

        btnA.frame = CGRect(x: abContainerW - abBtnSize, y: 0, width: abBtnSize, height: abBtnSize)
        btnA.layer.cornerRadius = abBtnSize / 2

        // Numpad layout
        let padW: CGFloat = min(260, w - sideMargin * 2)
        let padH: CGFloat = min(availH, 176)
        let padX = (w - padW) / 2
        let padY = contentTop + (availH - padH) / 2
        numpadContainer.frame = CGRect(x: padX, y: padY, width: padW, height: padH)

        let gap: CGFloat = 5
        let btnW = (padW - gap * 2) / 3
        let btnH = (padH - gap * 3) / 4

        for (i, btn) in numpadButtons.enumerated() {
            let col = CGFloat(i % 3)
            let row = CGFloat(i / 3)
            btn.frame = CGRect(
                x: col * (btnW + gap),
                y: row * (btnH + gap),
                width: btnW,
                height: btnH
            )
        }
    }

    func setSoftKeyLabels(left: String?, right: String?) {
        softLeftBtn.setTitle(left ?? "LSK", for: .normal)
        softRightBtn.setTitle(right ?? "RSK", for: .normal)
    }

    private func allTappableButtons() -> [UIButton] {
        var list = [softLeftBtn, softRightBtn]
        if showNumpad {
            list.append(contentsOf: numpadButtons)
        } else {
            list.append(contentsOf: [dpadUpBtn, dpadDownBtn, dpadLeftBtn, dpadRightBtn, dpadFireBtn, btnA, btnB])
        }
        return list
    }

    private func buttonAt(_ point: CGPoint) -> UIButton? {
        for btn in allTappableButtons() {
            guard !btn.isHidden, let parent = btn.superview else { continue }
            let localPt = convert(point, to: parent)
            let hitRect = btn.frame.insetBy(dx: -6, dy: -6)
            if hitRect.contains(localPt) {
                return btn
            }
        }
        return nil
    }

    private func isDpadButton(_ btn: UIButton) -> Bool {
        return btn === dpadUpBtn || btn === dpadDownBtn || btn === dpadLeftBtn || btn === dpadRightBtn
    }

    private func dpadDirectionForPoint(_ point: CGPoint) -> Int32? {
        guard !showNumpad else { return nil }
        let localPt = convert(point, to: dpadContainer)
        let expanded = dpadContainer.bounds.insetBy(dx: -16, dy: -16)
        guard expanded.contains(localPt) else { return nil }

        let center = CGPoint(x: dpadContainer.bounds.midX, y: dpadContainer.bounds.midY)
        let dx = localPt.x - center.x
        let dy = localPt.y - center.y
        let deadZone = dpadContainer.bounds.width * 0.14
        if hypot(dx, dy) < deadZone {
            return nil
        }

        if abs(dx) > abs(dy) {
            return dx < 0 ? J2ME_KEY_LEFT : J2ME_KEY_RIGHT
        } else {
            return dy < 0 ? J2ME_KEY_UP : J2ME_KEY_DOWN
        }
    }

    private func dpadButton(for direction: Int32) -> UIButton? {
        switch direction {
        case J2ME_KEY_UP: return dpadUpBtn
        case J2ME_KEY_DOWN: return dpadDownBtn
        case J2ME_KEY_LEFT: return dpadLeftBtn
        case J2ME_KEY_RIGHT: return dpadRightBtn
        default: return nil
        }
    }

    private func highlight(_ btn: UIButton, active: Bool) {
        if btn === btnA {
            btn.backgroundColor = UIColor.systemGreen.withAlphaComponent(active ? 0.92 : 0.62)
        } else if btn === btnB {
            btn.backgroundColor = UIColor.systemRed.withAlphaComponent(active ? 0.92 : 0.62)
        } else if btn === dpadFireBtn {
            btn.backgroundColor = UIColor(white: active ? 0.55 : 0.30, alpha: 0.85)
        } else {
            btn.backgroundColor = active ? btnHighlightBg : btnBg
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pt = touch.location(in: self)
            if let btn = buttonAt(pt), !activeButtons.contains(btn) {
                activeButtons.insert(btn)
                highlight(btn, active: true)
                let key = Int32(btn.tag)
                if isDpadButton(btn) {
                    dpadDirection = key
                }
                onKeyDown?(key)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pt = touch.location(in: self)
            if let newDir = dpadDirectionForPoint(pt) {
                if let prevDir = dpadDirection, prevDir != newDir {
                    if let prevBtn = dpadButton(for: prevDir) {
                        activeButtons.remove(prevBtn)
                        highlight(prevBtn, active: false)
                    }
                    onKeyUp?(prevDir)
                    dpadDirection = newDir
                    if let newBtn = dpadButton(for: newDir) {
                        activeButtons.insert(newBtn)
                        highlight(newBtn, active: true)
                    }
                    onKeyDown?(newDir)
                } else if dpadDirection == nil {
                    dpadDirection = newDir
                    if let newBtn = dpadButton(for: newDir) {
                        activeButtons.insert(newBtn)
                        highlight(newBtn, active: true)
                    }
                    onKeyDown?(newDir)
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let allTouches = event?.allTouches else { return }
        let remaining = allTouches.subtracting(touches).filter {
            $0.phase != .ended && $0.phase != .cancelled
        }

        var stillPressed: Set<UIButton> = []
        for t in remaining {
            let pt = t.location(in: self)
            if let btn = buttonAt(pt) {
                stillPressed.insert(btn)
            }
            if let dir = dpadDirectionForPoint(pt), let dirBtn = dpadButton(for: dir) {
                stillPressed.insert(dirBtn)
            }
        }

        for btn in activeButtons.subtracting(stillPressed) {
            activeButtons.remove(btn)
            highlight(btn, active: false)
            let key = Int32(btn.tag)
            if isDpadButton(btn) && dpadDirection == key {
                dpadDirection = nil
            }
            onKeyUp?(key)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for btn in activeButtons {
            highlight(btn, active: false)
            onKeyUp?(Int32(btn.tag))
        }
        activeButtons.removeAll()
        dpadDirection = nil
    }
}
