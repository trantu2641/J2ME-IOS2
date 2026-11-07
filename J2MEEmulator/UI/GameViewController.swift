//
// GameViewController.swift
// J2ME portrait game screen with keyboard input, framebuffer viewport
// and startup diagnostics. Compatible with iOS 16.4+.
//

import UIKit

private final class J2MEKeyboardInputView: UIView, UIKeyInput {

    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var returnKeyType: UIReturnKeyType = .done
    var enablesReturnKeyAutomatically: Bool = false
    var isSecureTextEntry: Bool = false
    var textContentType: UITextContentType? = nil

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func insertText(_ text: String) {
        onInsertText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }
}

final class GameViewController: UIViewController {

    let jarPath: String
    let appName: String
    let appIcon: UIImage
    let canvasWidth: Int
    let canvasHeight: Int
    let render3dScale: Int
    let fpsLimit: Int

    private let emulatorView = EmulatorView()
    private let keypadView = J2MEVirtualKeypadView()
    private lazy var formView = FormView()
    private lazy var listView = J2MEListView()

    private let headerStack = UIStackView()
    private let titleLabel = UILabel()
    private let toggleKeypadButton = UIButton(type: .system)
    private let systemKeyboardButton = UIButton(type: .system)
    private let exitButton = UIButton(type: .system)
    private let keyboardInput = J2MEKeyboardInputView(frame: .zero)

    private var keypadHeightConstraint: NSLayoutConstraint!
    private var keypadCollapsedConstraint: NSLayoutConstraint!

    private var keypadWasVisibleBeforeKeyboard = true
    private var keyboardIsVisible = false

    private var gameStarted = false
    private var userRequestedExit = false

    private var lastJVMLog = ""
    private var lastJVMLogPath = ""

    private(set) var placeholderIconView: UIImageView?

    private var alertTimeoutWork: DispatchWorkItem?
    private var startupWatchdog: DispatchWorkItem?

    init(
        jarPath: String,
        appName: String,
        appIcon: UIImage,
        canvasWidth: Int = 240,
        canvasHeight: Int = 320,
        render3dScale: Int = 1,
        fpsLimit: Int = 30
    ) {
        self.jarPath = jarPath
        self.appName = appName
        self.appIcon = appIcon
        self.canvasWidth = min(max(1, canvasWidth), 4096)
        self.canvasHeight = min(max(1, canvasHeight), 4096)
        self.render3dScale = max(1, render3dScale)

        // 0 = Unlimited. Positive values are capped at 45 FPS.
        if fpsLimit <= 0 {
            self.fpsLimit = 0
        } else {
            self.fpsLimit = min(fpsLimit, 45)
        }

        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        alertTimeoutWork?.cancel()
        startupWatchdog?.cancel()

        NotificationCenter.default.removeObserver(self)
        setGlobalEmulatorView(nil)
    }

    override var prefersStatusBarHidden: Bool {
        true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        emulatorView.canvasWidth = canvasWidth
        emulatorView.canvasHeight = canvasHeight

        buildHeader()
        buildGameLayout()
        buildKeyboardInput()
        buildOverlays()

        let iconView = UIImageView(image: appIcon)

        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(
                equalTo: emulatorView.centerXAnchor
            ),
            iconView.centerYAnchor.constraint(
                equalTo: emulatorView.centerYAnchor
            )
        ])

        placeholderIconView = iconView

        emulatorView.onFirstFrame = { [weak self] in

            guard let self,
                  let icon = self.placeholderIconView else {
                return
            }

            self.startupWatchdog?.cancel()
            self.startupWatchdog = nil

            UIView.animate(
                withDuration: 0.2,
                animations: {
                    icon.alpha = 0
                },
                completion: { _ in
                    icon.removeFromSuperview()
                    self.placeholderIconView = nil
                }
            )
        }

        setGlobalEmulatorView(emulatorView)

        // Reset native rendering state before starting a new game.
        j2me_render_stop()
        j2me_render_cleanup()

        if fpsLimit > 0 {
            j2me_render_set_fps_limit(Int32(fpsLimit))
        } else {
            print("[FPS] Unlimited mode enabled")
        }

        j2me_render_set_flush_callback(flushCallback)
        j2me_ui_set_callback(gameUICallback)

        activeGameViewController = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !gameStarted else {
            return
        }

        gameStarted = true
        startGame()
    }

    // MARK: - Header

    private func buildHeader() {

        titleLabel.text = appName
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(
            ofSize: 15,
            weight: .semibold
        )

        titleLabel.lineBreakMode = .byTruncatingTail

        titleLabel.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )

        configureHeaderButton(
            toggleKeypadButton,
            symbol: "keyboard",
            accessibility: "Show or hide game keypad"
        )

        configureHeaderButton(
            systemKeyboardButton,
            symbol: "text.cursor",
            accessibility: "Show iPhone keyboard"
        )

        configureHeaderButton(
            exitButton,
            symbol: "xmark",
            accessibility: "Exit game"
        )

        toggleKeypadButton.addTarget(
            self,
            action: #selector(toggleKeypad),
            for: .touchUpInside
        )

        systemKeyboardButton.addTarget(
            self,
            action: #selector(showSystemKeyboard),
            for: .touchUpInside
        )

        exitButton.addTarget(
            self,
            action: #selector(backTapped),
            for: .touchUpInside
        )

        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.distribution = .fill
        headerStack.spacing = 8

        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(toggleKeypadButton)
        headerStack.addArrangedSubview(systemKeyboardButton)
        headerStack.addArrangedSubview(exitButton)

        headerStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerStack)
    }

    private func configureHeaderButton(
        _ button: UIButton,
        symbol: String,
        accessibility: String
    ) {

        button.setImage(
            UIImage(systemName: symbol),
            for: .normal
        )

        button.tintColor = .white
        button.backgroundColor = UIColor(
            white: 0.16,
            alpha: 1
        )

        button.layer.cornerRadius = 9
        button.accessibilityLabel = accessibility
        button.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 38),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    // MARK: - Viewport and keypad layout

    private func buildGameLayout() {

        emulatorView.translatesAutoresizingMaskIntoConstraints = false
        emulatorView.backgroundColor = .black
        emulatorView.clipsToBounds = true

        view.addSubview(emulatorView)

        keypadView.translatesAutoresizingMaskIntoConstraints = false

        keypadView.onKeyEvent = { type, code in
            j2me_input_post_key(type, code)
        }

        view.addSubview(keypadView)

        let safe = view.safeAreaLayoutGuide

        // The previous value was 20.
        // Increase by another 30 points to bring the keypad up to the red line.
        keypadHeightConstraint =
            keypadView.heightAnchor.constraint(
                equalTo: view.widthAnchor,
                multiplier: 0.45,
                constant: 50
            )

        // Required priority ensures Auto Layout does not discard this height.
        keypadHeightConstraint.priority = .required

        keypadCollapsedConstraint =
            keypadView.heightAnchor.constraint(
                equalToConstant: 0
            )

        keypadCollapsedConstraint.priority = .required

        NSLayoutConstraint.activate([

            headerStack.topAnchor.constraint(
                equalTo: safe.topAnchor,
                constant: 3
            ),

            headerStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 8
            ),

            headerStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -8
            ),

            headerStack.heightAnchor.constraint(
                equalToConstant: 36
            ),

            emulatorView.topAnchor.constraint(
                equalTo: headerStack.bottomAnchor,
                constant: 5
            ),

            emulatorView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),

            emulatorView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),

            emulatorView.bottomAnchor.constraint(
                equalTo: keypadView.topAnchor,
                constant: -8
            ),

            keypadView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 2
            ),

            keypadView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -2
            ),

            keypadView.bottomAnchor.constraint(
                equalTo: safe.bottomAnchor,
                constant: -7
            ),

            keypadHeightConstraint
        ])
    }

    // MARK: - Form and list overlays

    private func buildOverlays() {

        for overlay in [formView, listView] {

            overlay.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(overlay)

            NSLayoutConstraint.activate([

                overlay.topAnchor.constraint(
                    equalTo: view.topAnchor
                ),

                overlay.leadingAnchor.constraint(
                    equalTo: view.leadingAnchor
                ),

                overlay.trailingAnchor.constraint(
                    equalTo: view.trailingAnchor
                ),

                overlay.bottomAnchor.constraint(
                    equalTo: view.bottomAnchor
                )
            ])

            overlay.isHidden = true
        }
    }

    // MARK: - iOS software keyboard

    private func buildKeyboardInput() {

        keyboardInput.translatesAutoresizingMaskIntoConstraints = false
        keyboardInput.alpha = 0.02

        keyboardInput.keyboardType = .default
        keyboardInput.keyboardAppearance = .dark
        keyboardInput.autocorrectionType = .no
        keyboardInput.spellCheckingType = .no
        keyboardInput.smartQuotesType = .no
        keyboardInput.smartDashesType = .no
        keyboardInput.autocapitalizationType = .none
        keyboardInput.returnKeyType = .done
        keyboardInput.enablesReturnKeyAutomatically = false
        keyboardInput.isSecureTextEntry = false

        keyboardInput.onDeleteBackward = { [weak self] in
            self?.sendKeyPulse(-8)
        }

        keyboardInput.onInsertText = { [weak self] text in

            guard let self else {
                return
            }

            if text == "\n" || text == "\r" {

                self.sendKeyPulse(-5)
                self.hideSystemKeyboard()

                return
            }

            for scalar in text.unicodeScalars {

                if scalar.value <= 0xFFFF {
                    self.sendKeyPulse(Int32(scalar.value))
                }
            }
        }

        view.addSubview(keyboardInput)

        NSLayoutConstraint.activate([

            keyboardInput.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 1
            ),

            keyboardInput.topAnchor.constraint(
                equalTo: headerStack.bottomAnchor,
                constant: 1
            ),

            keyboardInput.widthAnchor.constraint(
                equalToConstant: 2
            ),

            keyboardInput.heightAnchor.constraint(
                equalToConstant: 2
            )
        ])
    }

    @objc private func toggleKeypad() {

        if keyboardIsVisible {

            keypadWasVisibleBeforeKeyboard = false

            keyboardInput.resignFirstResponder()
            keyboardIsVisible = false
        }

        let show = keypadView.isHidden

        setKeypadVisible(show)
    }

    @objc private func showSystemKeyboard() {

        keypadWasVisibleBeforeKeyboard = !keypadView.isHidden

        setKeypadVisible(false)

        let becameFirstResponder =
            keyboardInput.becomeFirstResponder()

        keyboardIsVisible = becameFirstResponder

        if !becameFirstResponder {

            print("[Keyboard] Could not become first responder")

            restoreKeypadAfterKeyboardIfNeeded()
        }
    }

    private func hideSystemKeyboard() {

        keyboardInput.resignFirstResponder()
        keyboardIsVisible = false

        restoreKeypadAfterKeyboardIfNeeded()
    }

    @objc private func handleKeyboardWillHide(
        _ notification: Notification
    ) {

        keyboardIsVisible = false

        restoreKeypadAfterKeyboardIfNeeded()
    }

    private func restoreKeypadAfterKeyboardIfNeeded() {

        guard keypadWasVisibleBeforeKeyboard,
              !userRequestedExit else {
            return
        }

        keypadWasVisibleBeforeKeyboard = false

        setKeypadVisible(true)
    }

    private func setKeypadVisible(_ visible: Bool) {

        keypadView.isHidden = !visible

        keypadHeightConstraint.isActive = visible
        keypadCollapsedConstraint.isActive = !visible

        toggleKeypadButton.tintColor =
            visible ? .white : .systemGreen

        UIView.animate(withDuration: 0.18) {
            self.view.layoutIfNeeded()
        }
    }

    private func sendKeyPulse(_ code: Int32) {

        j2me_input_post_key(
            Int32(J2ME_INPUT_KEY_PRESSED),
            code
        )

        j2me_input_post_key(
            Int32(J2ME_INPUT_KEY_RELEASED),
            code
        )
    }

    // MARK: - Game lifecycle and startup diagnostics

    private func startGame() {

        let watchdog = DispatchWorkItem { [weak self] in

            guard let self,
                  self.placeholderIconView != nil,
                  !self.userRequestedExit,
                  self.presentedViewController == nil else {
                return
            }

            print("[JVM] Startup watchdog triggered")

            self.loadJVMLog()

            let details: String

            if self.lastJVMLog.isEmpty {
                details = "No MiniJVM log was created."
            } else {
                details = String(
                    self.lastJVMLog.suffix(5000)
                )
            }

            let alert = UIAlertController(
                title: "Game chưa tạo được khung hình",
                message:
                    "JarBox đã chạy 20 giây nhưng chưa nhận được hình ảnh từ JAR.\n\n"
                    + details,
                preferredStyle: .alert
            )

            alert.addAction(
                UIAlertAction(
                    title: "Copy Log",
                    style: .default
                ) { [weak self] _ in

                    UIPasteboard.general.string =
                        self?.lastJVMLog ?? ""
                }
            )

            alert.addAction(
                UIAlertAction(
                    title: "Đóng",
                    style: .cancel
                )
            )

            self.present(alert, animated: true)
        }

        startupWatchdog = watchdog

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 20,
            execute: watchdog
        )

        DispatchQueue.global(
            qos: .userInitiated
        ).async { [weak self] in

            guard let self else {
                return
            }

            let result = self.runMIDlet()

            DispatchQueue.main.async { [weak self] in

                guard let self else {
                    return
                }

                self.startupWatchdog?.cancel()
                self.startupWatchdog = nil

                if self.userRequestedExit {

                    self.dismiss(animated: true)

                } else if result == 0 {

                    self.dismiss(animated: true)

                } else {

                    self.showLaunchError(result)
                }
            }
        }
    }

    // MARK: - MiniJVM launch

    private func runMIDlet() -> Int {

        guard let resourceRoot = Bundle.main.resourcePath else {
            return -100
        }

        let fm = FileManager.default

        for file in ["minijvm_rt.jar", "j2me_api.jar"] {

            let path = (resourceRoot as NSString)
                .appendingPathComponent(file)

            guard fm.fileExists(atPath: path) else {

                print("[JVM] Required runtime missing: \(path)")

                return -101
            }
        }

        guard fm.fileExists(atPath: jarPath) else {
            return -102
        }

        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory()

        let baseName = URL(fileURLWithPath: jarPath)
            .deletingPathExtension()
            .lastPathComponent

        let gameID = baseName.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]",
            with: "_",
            options: .regularExpression
        )

        let saveRoot = (docs as NSString)
            .appendingPathComponent("Games Data/\(gameID)")

        do {

            try fm.createDirectory(
                atPath: saveRoot,
                withIntermediateDirectories: true
            )

        } catch {

            print("[JVM] Cannot create save directory: \(error)")

            return -103
        }

        lastJVMLogPath = (saveRoot as NSString)
            .appendingPathComponent("minijvm.log")

        lastJVMLog = ""

        try? fm.removeItem(atPath: lastJVMLogPath)

        print("[JVM] Resource root: \(resourceRoot)")
        print("[JVM] MIDlet JAR: \(jarPath)")
        print("[JVM] Virtual resolution: \(canvasWidth)x\(canvasHeight)")
        print("[JVM] Diagnostic log: \(lastJVMLogPath)")
        print("[JVM] FPS limit: \(fpsLimit == 0 ? "Unlimited" : "\(fpsLimit)")")

        let initResult = jvm_bridge_init(
            resourceRoot,
            saveRoot,
            jarPath,
            Int32(canvasWidth),
            Int32(canvasHeight),
            Int32(render3dScale),
            Int32(fpsLimit)
        )

        guard initResult == 0 else {

            print("[JVM] jvm_bridge_init failed: \(initResult)")

            loadJVMLog()

            return Int(initResult)
        }

        let runResult = jvm_bridge_run_midlet(jarPath)

        print(
            "[JVM] jvm_bridge_run_midlet returned: \(runResult)"
        )

        jvm_bridge_destroy()

        loadJVMLog()

        return Int(runResult)
    }

    // MARK: - Diagnostic log

    private func loadJVMLog() {

        guard !lastJVMLogPath.isEmpty,
              let data = FileManager.default.contents(
                atPath: lastJVMLogPath
              ),
              let text = String(
                data: data,
                encoding: .utf8
              ) else {

            lastJVMLog = "No MiniJVM log was created."

            return
        }

        lastJVMLog = text
    }

    // MARK: - Launch error

    private func showLaunchError(_ code: Int) {

        let baseText: String

        switch code {

        case -100:
            baseText = "Cannot locate the app resource directory."

        case -101:
            baseText = "Missing MiniJVM runtime files: minijvm_rt.jar or j2me_api.jar."

        case -102:
            baseText = "The selected JAR file no longer exists. Import it again."

        case -103:
            baseText = "The game save folder could not be created."

        default:
            baseText = "MiniJVM returned error code \(code). The diagnostic log is shown below."
        }

        let message =
            baseText
            + "\n\n"
            + String(lastJVMLog.suffix(3500))

        let alert = UIAlertController(
            title: "Cannot Start Game",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(
                title: "Copy Log",
                style: .default
            ) { [weak self] _ in

                UIPasteboard.general.string =
                    self?.lastJVMLog
            }
        )

        alert.addAction(
            UIAlertAction(
                title: "Back",
                style: .cancel
            ) { [weak self] _ in

                self?.dismiss(animated: true)
            }
        )

        present(alert, animated: true)
    }

    // MARK: - Exit game

    @objc private func backTapped() {

        userRequestedExit = true

        keypadWasVisibleBeforeKeyboard = false

        startupWatchdog?.cancel()
        startupWatchdog = nil

        keyboardInput.resignFirstResponder()

        keyboardIsVisible = false
        exitButton.isEnabled = false

        jvm_bridge_request_stop()
    }

    // MARK: - MIDP view transitions

    func showCanvasView() {

        emulatorView.isHidden = false
        keypadView.isHidden = false

        keypadHeightConstraint.isActive = true
        keypadCollapsedConstraint.isActive = false

        formView.isHidden = true
        listView.isHidden = true
    }

    func showFormView() {

        formView.buildFromNativeData()
        formView.isHidden = false

        emulatorView.isHidden = true
        keypadView.isHidden = true

        keypadHeightConstraint.isActive = false
        keypadCollapsedConstraint.isActive = true

        listView.isHidden = true
    }

    func showListView() {

        listView.buildFromNativeData()
        listView.isHidden = false

        emulatorView.isHidden = true
        keypadView.isHidden = true

        keypadHeightConstraint.isActive = false
        keypadCollapsedConstraint.isActive = true

        formView.isHidden = true
    }

    // MARK: - MIDP Alert

    func showAlert() {

        let title = String(
            cString: j2me_ui_get_form_title()
        )

        let message = String(
            cString: j2me_ui_get_alert_text()
        )

        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )

        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let count = j2me_ui_get_command_count()

        if count == 0 {

            alert.addAction(
                UIAlertAction(
                    title: "OK",
                    style: .default
                ) { _ in

                    j2me_input_post_key(
                        Int32(J2ME_UI_ALERT_DISMISSED),
                        0
                    )
                }
            )

        } else {

            for index in 0..<count {

                let label = String(
                    cString: j2me_ui_get_command_label(
                        Int32(index)
                    )
                )

                let commandID =
                    j2me_ui_get_command_id(Int32(index))

                alert.addAction(
                    UIAlertAction(
                        title: label,
                        style: .default
                    ) { _ in

                        j2me_input_post_key(
                            Int32(J2ME_UI_COMMAND_ACTION),
                            commandID
                        )
                    }
                )
            }
        }

        present(alert, animated: true)

        let timeout = j2me_ui_get_alert_timeout()

        if timeout > 0 {

            let work = DispatchWorkItem { [weak alert] in

                alert?.dismiss(animated: true) {

                    j2me_input_post_key(
                        Int32(J2ME_UI_ALERT_DISMISSED),
                        0
                    )
                }
            }

            alertTimeoutWork = work

            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(timeout) / 1000.0,
                execute: work
            )
        }
    }
}

// MARK: - Global game controller and J2ME UI callback

private(set) weak var activeGameViewController: GameViewController?

let gameUICallback: @convention(c) (
    Int32,
    UnsafePointer<CChar>?
) -> Void = { action, data in

    DispatchQueue.main.async {

        guard let controller = activeGameViewController else {
            return
        }

        switch action {

        case Int32(J2ME_UI_ACTION_SHOW_CANVAS):
            controller.showCanvasView()

        case Int32(J2ME_UI_ACTION_SHOW_FORM):
            controller.showFormView()

        case Int32(J2ME_UI_ACTION_SHOW_LIST):
            controller.showListView()

        case Int32(J2ME_UI_ACTION_SHOW_ALERT):
            controller.showAlert()

        default:
            break
        }
    }
}
