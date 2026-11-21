//
// J2MEQWERTYKeyboardView.swift
// JarBox Gboard-style keyboard adapter.
//
// This keeps the existing GameViewController API so the rest of JarBox does
// not need to know that the keyboard implementation was replaced.
//
import UIKit

final class J2MEQWERTYKeyboardView: UIView {
    var onTextChanged: ((String) -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    private var text = "" {
        didSet { onTextChanged?(text) }
    }
    private var attached = false
    private var theme = UserDefaults.standard.string(forKey: "J2MEQWERTYTheme") ?? "dark"

    private var manager: JBKeyboardManager {
        JBKeyboardManager.shared
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isHidden = true
        manager.keyboardHeight = max(180, min(420, frame.height > 0 ? frame.height : 285))
        installManagerCallbacks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard !attached, superview != nil else { return }
        attached = true
        manager.hostViewController = nearestViewController()
        manager.attach(to: self)
        manager.setKeyboardHeight(max(180, min(420, bounds.height > 0 ? bounds.height : 285)), animated: false)
        manager.hide()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard attached else { return }
        let h = max(180, min(420, bounds.height))
        manager.setKeyboardHeight(h, animated: false)
    }

    func begin(initialText: String = "") {
        text = initialText
        manager.keyboardView.vietnamese = true
        manager.keyboardView.shift = false
        manager.show()
        isHidden = false
    }

    func clear() {
        text = ""
    }

    func setTheme(_ value: String) {
        theme = value
        UserDefaults.standard.set(value, forKey: "J2MEQWERTYTheme")
        // JBKeyboardView owns its visual theme. Keep the setting so a future
        // theme reload can use the same preference without changing callers.
        manager.keyboardView.reloadKeyboard()
    }

    private func installManagerCallbacks() {
        manager.currentTextProvider = { [weak self] in
            self?.text ?? ""
        }

        manager.insertTextHandler = { [weak self] value in
            guard let self else { return }
            self.text.append(contentsOf: value)
        }

        manager.deleteBackwardHandler = { [weak self] in
            guard let self, !self.text.isEmpty else { return }
            self.text.removeLast()
        }

        manager.returnHandler = { [weak self] in
            guard let self else { return }
            self.manager.hide()
            self.onDone?()
        }
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

private extension JBKeyboardManager {
    func attach(to hostView: UIView) {
        attachToView(hostView)
    }
}
