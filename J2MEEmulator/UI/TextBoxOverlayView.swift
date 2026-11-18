import UIKit

final class TextBoxOverlayView: UIView, UITextViewDelegate {

    var onConfirm: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = UILabel()
    private let textView = UITextView()
    private let counterLabel = UILabel()
    private let confirmButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let cardView = UIView()
    private var maxLength: Int = 256

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = UIColor.black.withAlphaComponent(0.6)

        cardView.backgroundColor = UIColor.secondarySystemBackground
        cardView.layer.cornerRadius = 16
        cardView.layer.masksToBounds = true
        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)

        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(titleLabel)

        counterLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        counterLabel.textColor = .secondaryLabel
        counterLabel.textAlignment = .right
        counterLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(counterLabel)

        textView.font = UIFont.systemFont(ofSize: 16)
        textView.textColor = .label
        textView.backgroundColor = UIColor.systemBackground
        textView.layer.cornerRadius = 10
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(textView)

        cancelButton.setTitle("Hủy", for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        cancelButton.setTitleColor(.systemRed, for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cancelButton)

        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.filled()
            config.title = "OK"
            config.baseBackgroundColor = .systemBlue
            config.baseForegroundColor = .white
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.boldSystemFont(ofSize: 16)
                return outgoing
            }
            confirmButton.configuration = config
        } else {
            confirmButton.setTitle("OK", for: .normal)
            confirmButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
            confirmButton.backgroundColor = .systemBlue
            confirmButton.setTitleColor(.white, for: .normal)
            confirmButton.layer.cornerRadius = 10
            confirmButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 20, bottom: 8, right: 20)
        }
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(confirmButton)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            cardView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 40),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: counterLabel.leadingAnchor, constant: -8),

            counterLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            counterLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            textView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            textView.heightAnchor.constraint(equalToConstant: 100),

            cancelButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 12),
            cancelButton.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            cancelButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),

            confirmButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            confirmButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
        ])
    }

    func configure(title: String, initialText: String, maxSize: Int, constraints: Int) {
        titleLabel.text = title.isEmpty ? "Nhập văn bản" : title
        maxLength = maxSize > 0 ? maxSize : 256

        let safeInitial = initialText.count > maxLength
            ? String(initialText.prefix(maxLength))
            : initialText
        textView.text = safeInitial
        updateCounter()

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

    private func updateCounter() {
        let len = textView.text?.count ?? 0
        counterLabel.text = "\(len)/\(maxLength)"
    }

    // Use textViewDidChange instead of shouldChangeTextIn so Vietnamese Telex/VNI IME composition never breaks
    func textViewDidChange(_ textView: UITextView) {
        if textView.markedTextRange == nil, let text = textView.text, text.count > maxLength {
            textView.text = String(text.prefix(maxLength))
        }
        updateCounter()
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
