import UIKit

final class TextBoxOverlayView: UIView, UITextViewDelegate {

    var onConfirm: ((String) -> Void)?
    var onCancel: (() -> Void)?

    static let barHeight: CGFloat = 58
    private let barView = UIView()
    private let textView = UITextView()
    private let confirmButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var maxLength: Int = 256
    private var barBottomConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // Cho phép chạm vào màn hình game phía trên khung nhập mà không bị chặn
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private func setupUI() {
        backgroundColor = .clear

        barView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.97)
        barView.layer.cornerRadius = 12
        barView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        barView.layer.borderWidth = 0.5
        barView.layer.borderColor = UIColor.separator.cgColor
        barView.layer.masksToBounds = true
        barView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barView)

        textView.font = UIFont.systemFont(ofSize: 15)
        textView.textColor = .label
        textView.backgroundColor = UIColor.systemBackground
        textView.layer.cornerRadius = 8
        textView.layer.borderWidth = 0.8
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        barView.addSubview(textView)

        cancelButton.setTitle("Hủy", for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        cancelButton.setTitleColor(.systemRed, for: .normal)
        cancelButton.backgroundColor = UIColor.tertiarySystemFill
        cancelButton.layer.cornerRadius = 8
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        barView.addSubview(cancelButton)

        confirmButton.setTitle("Lưu", for: .normal)
        confirmButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        confirmButton.backgroundColor = .systemBlue
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.layer.cornerRadius = 8
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        barView.addSubview(confirmButton)

        barBottomConstraint = barView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0)

        // Chiều cao vừa đủ 2 dòng văn bản (~46pt)
        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: trailingAnchor),
            barBottomConstraint,

            textView.topAnchor.constraint(equalTo: barView.topAnchor, constant: 6),
            textView.bottomAnchor.constraint(equalTo: barView.bottomAnchor, constant: -6),
            textView.leadingAnchor.constraint(equalTo: barView.leadingAnchor, constant: 8),
            textView.heightAnchor.constraint(equalToConstant: 46),

            cancelButton.leadingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 6),
            cancelButton.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 48),
            cancelButton.heightAnchor.constraint(equalToConstant: 36),

            confirmButton.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 6),
            confirmButton.trailingAnchor.constraint(equalTo: barView.trailingAnchor, constant: -8),
            confirmButton.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            confirmButton.widthAnchor.constraint(equalToConstant: 52),
            confirmButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    func updateKeyboardBottomOffset(_ bottomOffset: CGFloat) {
        barBottomConstraint.constant = -max(0, bottomOffset)
    }

    func configure(title: String, initialText: String, maxSize: Int, constraints: Int) {
        maxLength = maxSize > 0 ? maxSize : 256

        let safeInitial = initialText.count > maxLength
            ? String(initialText.prefix(maxLength))
            : initialText
        textView.text = safeInitial

        let baseType = constraints & 0xFFFF
        switch baseType {
        case 2:
            textView.keyboardType = .numberPad
        case 5:
            textView.keyboardType = .decimalPad
        case 3:
            textView.keyboardType = .phonePad
        case 1:
            textView.keyboardType = .emailAddress
        case 4:
            textView.keyboardType = .URL
        default:
            textView.keyboardType = .default
        }

        textView.isSecureTextEntry = (constraints & 0x10000) != 0
        textView.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        if textView.markedTextRange == nil, let text = textView.text, text.count > maxLength {
            textView.text = String(text.prefix(maxLength))
        }
    }

    @objc private func confirmTapped() {
        textView.resignFirstResponder()
        onConfirm?(textView.text ?? "")
    }

    @objc private func cancelTapped() {
        textView.resignFirstResponder()
        onCancel?()
    }
}
