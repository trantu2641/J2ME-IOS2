//
//  GameViewController.swift
//  J2MEEmulator
//
//  Portrait J2ME emulator screen.
//

import UIKit

enum GameLayoutMode {
    case portrait
}

class GameViewController: UIViewController {

    let jarPath: String
    let appName: String
    let appIcon: UIImage
    let canvasWidth: Int
    let canvasHeight: Int
    let render3dScale: Int
    let fpsLimit: Int
    let layoutMode: GameLayoutMode

    private let emulatorView = EmulatorView()
    private let glowContainer = UIView()
    private let glowContentView = UIView()

    private lazy var formView = FormView()
    private lazy var listView = J2MEListView()

    private let backButton = UIButton(type: .system)
    private let lskButton = UIButton(type: .system)
    private let rskButton = UIButton(type: .system)

    private let softKeyHaptic = UIImpactFeedbackGenerator(style: .light)

    private(set) var placeholderIconView: UIImageView?

    private var joystickView: JoystickView?
    private var numpadView: NumpadView?

    private var alertTimeoutWork: DispatchWorkItem?
    private var gameStarted = false

    init(
        jarPath: String,
        appName: String,
        appIcon: UIImage,
        canvasWidth: Int = 240,
        canvasHeight: Int = 320,
        render3dScale: Int = 3,
        fpsLimit: Int = 0,
        layoutMode: GameLayoutMode = .portrait
    ) {
        self.jarPath = jarPath
        self.appName = appName
        self.appIcon = appIcon
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.render3dScale = render3dScale
        self.fpsLimit = fpsLimit
        self.layoutMode = layoutMode

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        setGlobalEmulatorView(nil)
        alertTimeoutWork?.cancel()
    }

    override var prefersStatusBarHidden: Bool {
        true
    }

    // Luôn giữ màn hình theo chiều dọc.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        emulatorView.canvasWidth = canvasWidth
        emulatorView.canvasHeight = canvasHeight

        setupPortraitLayout()

        // Biểu tượng tạm thời hiển thị khi bắt đầu game.
        let iconIV = UIImageView(image: appIcon)
        iconIV.contentMode = .center
        iconIV.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(iconIV)

        NSLayoutConstraint.activate([
            iconIV.centerXAnchor.constraint(
                equalTo: emulatorView.centerXAnchor
            ),
            iconIV.centerYAnchor.constraint(
                equalTo: emulatorView.centerYAnchor
            )
        ])

        placeholderIconView = iconIV

        view.bringSubviewToFront(backButton)

        // Ẩn icon khi JVM xuất ra khung hình đầu tiên.
        emulatorView.onFirstFrame = { [weak self] in
            guard let icon = self?.placeholderIconView else {
                return
            }

            UIView.animate(withDuration: 0.2) {
                icon.alpha = 0
            } completion: { _ in
                icon.removeFromSuperview()
                self?.placeholderIconView = nil
            }
        }

        // Đồng bộ khung hình sang lớp hiệu ứng.
        emulatorView.onFrame = { [weak self] cgImage in
            self?.glowContentView.layer.contents = cgImage
        }

        // Đăng ký callback native.
        setGlobalEmulatorView(emulatorView)

        j2me_render_set_flush_callback(flushCallback)
        j2me_ui_set_callback(gameUICallback)

        activeGameViewController = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !gameStarted else {
            return
        }

        gameStarted = true
        startGame()
    }

    // ============================================================
    // MARK: - Portrait Layout
    // ============================================================

    private func setupPortraitLayout() {

        let joystick = JoystickView()
        let numpad = NumpadView()

        joystickView = joystick
        numpadView = numpad

        // Glow background.
        glowContainer.isUserInteractionEnabled = false
        glowContainer.clipsToBounds = true

        glowContentView.layer.magnificationFilter = .trilinear
        glowContentView.layer.minificationFilter = .trilinear
        glowContentView.alpha = 0.6

        glowContainer.addSubview(glowContentView)

        glowContentView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            glowContentView.topAnchor.constraint(
                equalTo: glowContainer.topAnchor
            ),
            glowContentView.leadingAnchor.constraint(
                equalTo: glowContainer.leadingAnchor
            ),
            glowContentView.trailingAnchor.constraint(
                equalTo: glowContainer.trailingAnchor
            ),
            glowContentView.bottomAnchor.constraint(
                equalTo: glowContainer.bottomAnchor
            )
        ])

        // Blur background.
        let glowBlur = NeutralBlurView(radius: 100)
        glowBlur.isUserInteractionEnabled = false

        let allViews: [UIView] = [
            glowContainer,
            glowBlur,
            joystick,
            emulatorView,
            numpad,
            lskButton,
            rskButton,
            formView,
            listView,
            backButton
        ]

        for item in allViews {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }

        formView.isHidden = true
        listView.isHidden = true

        // Soft keys.
        for (button, title) in [
            (lskButton, "L"),
            (rskButton, "R")
        ] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(
                ofSize: 18,
                weight: .medium
            )

            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = UIColor(
                white: 0.12,
                alpha: 1
            )

            button.layer.cornerRadius = 10
            button.layer.borderColor = UIColor(
                white: 1,
                alpha: 0.12
            ).cgColor

            button.layer.borderWidth = 1

            button.addTarget(
                self,
                action: #selector(softKeyDown(_:)),
                for: .touchDown
            )

            button.addTarget(
                self,
                action: #selector(softKeyUp(_:)),
                for: [
                    .touchUpInside,
                    .touchUpOutside,
                    .touchCancel
                ]
            )
        }

        lskButton.tag = -6
        rskButton.tag = -7

        // Back button.
        backButton.setTitle("  \u{2715}  ", for: .normal)
        backButton.titleLabel?.font = .systemFont(
            ofSize: 20,
            weight: .medium
        )

        backButton.backgroundColor = UIColor(
            white: 0.15,
            alpha: 0.85
        )

        backButton.setTitleColor(.white, for: .normal)
        backButton.layer.cornerRadius = 10
        backButton.layer.borderColor = UIColor(
            white: 1,
            alpha: 0.12
        ).cgColor

        backButton.layer.borderWidth = 1

        backButton.addTarget(
            self,
            action: #selector(backTapped),
            for: .touchUpInside
        )

        let safe = view.safeAreaLayoutGuide

        let canvasRatio =
            CGFloat(emulatorView.canvasWidth) /
            CGFloat(max(1, emulatorView.canvasHeight))

        // Ưu tiên chiều cao màn hình game khoảng 42% chiều cao iPhone.
        // Nếu game có tỷ lệ ngang, Auto Layout sẽ tự thu nhỏ để vừa chiều rộng.
        let preferredCanvasHeight = emulatorView.heightAnchor.constraint(
            equalTo: view.heightAnchor,
            multiplier: 0.42
        )

        preferredCanvasHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([

            // Blur phủ toàn màn hình.
            glowBlur.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            glowBlur.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            glowBlur.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            glowBlur.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            ),

            // Game screen.
            emulatorView.topAnchor.constraint(
                equalTo: safe.topAnchor,
                constant: 48
            ),

            emulatorView.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),

            emulatorView.widthAnchor.constraint(
                equalTo: emulatorView.heightAnchor,
                multiplier: canvasRatio
            ),

            emulatorView.widthAnchor.constraint(
                lessThanOrEqualTo: safe.widthAnchor,
                constant: -28
            ),

            emulatorView.heightAnchor.constraint(
                lessThanOrEqualTo: view.heightAnchor,
                multiplier: 0.48
            ),

            // Glow bám theo game screen.
            glowContainer.centerXAnchor.constraint(
                equalTo: emulatorView.centerXAnchor
            ),

            glowContainer.centerYAnchor.constraint(
                equalTo: emulatorView.centerYAnchor
            ),

            glowContainer.widthAnchor.constraint(
                equalTo: emulatorView.widthAnchor
            ),

            glowContainer.heightAnchor.constraint(
                equalTo: emulatorView.heightAnchor
            ),

            // Hai phím mềm dưới màn hình game.
            lskButton.topAnchor.constraint(
                equalTo: emulatorView.bottomAnchor,
                constant: 10
            ),

            lskButton.centerXAnchor.constraint(
                equalTo: view.centerXAnchor,
                constant: -40
            ),

            lskButton.widthAnchor.constraint(
                equalToConstant: 64
            ),

            lskButton.heightAnchor.constraint(
                equalToConstant: 36
            ),

            rskButton.topAnchor.constraint(
                equalTo: emulatorView.bottomAnchor,
                constant: 10
            ),

            rskButton.centerXAnchor.constraint(
                equalTo: view.centerXAnchor,
                constant: 40
            ),

            rskButton.widthAnchor.constraint(
                equalToConstant: 64
            ),

            rskButton.heightAnchor.constraint(
                equalToConstant: 36
            ),

            // Bàn phím số bên phải.
            numpad.trailingAnchor.constraint(
                equalTo: safe.trailingAnchor,
                constant: -14
            ),

            numpad.bottomAnchor.constraint(
                equalTo: safe.bottomAnchor,
                constant: -18
            ),

            numpad.widthAnchor.constraint(
                equalTo: safe.widthAnchor,
                multiplier: 0.46
            ),

            numpad.heightAnchor.constraint(
                equalTo: numpad.widthAnchor,
                multiplier: 1.33
            ),

            // Joystick bên trái.
            joystick.leadingAnchor.constraint(
                equalTo: safe.leadingAnchor,
                constant: 14
            ),

            joystick.centerYAnchor.constraint(
                equalTo: numpad.centerYAnchor
            ),

            joystick.widthAnchor.constraint(
                equalTo: numpad.widthAnchor,
                multiplier: 0.78
            ),

            joystick.heightAnchor.constraint(
                equalTo: joystick.widthAnchor
            ),

            // Form view phủ toàn màn hình.
            formView.topAnchor.constraint(
                equalTo: view.topAnchor
            ),

            formView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),

            formView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),

            formView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            ),

            // List view phủ toàn màn hình.
            listView.topAnchor.constraint(
                equalTo: view.topAnchor
            ),

            listView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),

            listView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),

            listView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            ),

            // Nút thoát ở góc trên bên trái.
            backButton.topAnchor.constraint(
                equalTo: safe.topAnchor,
                constant: 4
            ),

            backButton.leadingAnchor.constraint(
                equalTo: safe.leadingAnchor,
                constant: 4
            ),

            backButton.widthAnchor.constraint(
                equalToConstant: 48
            ),

            backButton.heightAnchor.constraint(
                equalToConstant: 40
            )
        ])

        preferredCanvasHeight.isActive = true

        // Bo góc màn hình game.
        emulatorView.layer.cornerRadius = 8
        emulatorView.clipsToBounds = true

        emulatorView.layer.borderColor = UIColor(
            white: 1,
            alpha: 0.12
        ).cgColor

        emulatorView.layer.borderWidth = 1

        view.bringSubviewToFront(formView)
        view.bringSubviewToFront(listView)
        view.bringSubviewToFront(backButton)
    }

    // ============================================================
    // MARK: - Soft Keys
    // ============================================================

    @objc private func softKeyDown(_ sender: UIButton) {

        softKeyHaptic.impactOccurred(intensity: 0.6)

        j2me_input_post_key(
            Int32(J2ME_INPUT_KEY_PRESSED),
            Int32(sender.tag)
        )

        sender.backgroundColor = UIColor(
            white: 0.30,
            alpha: 1
        )
    }

    @objc private func softKeyUp(_ sender: UIButton) {

        j2me_input_post_key(
            Int32(J2ME_INPUT_KEY_RELEASED),
            Int32(sender.tag)
        )

        sender.backgroundColor = UIColor(
            white: 0.12,
            alpha: 1
        )
    }

    // ============================================================
    // MARK: - Game Lifecycle
    // ============================================================

    private func startGame() {

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in

            guard let self else {
                return
            }

            let launchError = self.runMIDlet()

            DispatchQueue.main.async { [weak self] in

                guard let self else {
                    return
                }

                if let error = launchError {
                    self.showLaunchError(error)
                } else {
                    self.dismiss(animated: true)
                }
            }
        }
    }

    private func runMIDlet() -> String? {

        guard let resRoot = Bundle.main.resourcePath else {
            return "Cannot locate application resources."
        }

        let fileManager = FileManager.default

        // JVM yêu cầu hai runtime JAR nằm ngay trong resource root.
        let runtimeFiles = [
            "minijvm_rt.jar",
            "j2me_api.jar"
        ]

        for file in runtimeFiles {

            let path = resRoot + "/" + file

            guard fileManager.fileExists(atPath: path) else {
                return """
                Missing runtime file:

                \(file)

                Please rebuild the IPA with the runtime JAR packaging fix.
                """
            }
        }

        guard fileManager.fileExists(atPath: jarPath) else {
            return "The selected game JAR file no longer exists."
        }

        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory()

        // Save riêng cho từng game.
        let jarFileName = URL(
            fileURLWithPath: jarPath
        ).deletingPathExtension().lastPathComponent

        let gameId = jarFileName.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]",
            with: "_",
            options: .regularExpression
        )

        let saveRoot = docs + "/Games Data/" + gameId

        do {
            try fileManager.createDirectory(
                atPath: saveRoot,
                withIntermediateDirectories: true
            )
        } catch {
            return "Cannot create game save directory: \(error.localizedDescription)"
        }

        print("[Swift] Runtime directory: \(resRoot)")
        print("[Swift] Game JAR: \(jarPath)")
        print("[Swift] Save directory: \(saveRoot)")

        // Khởi tạo JVM.
        let initResult = jvm_bridge_init(
            resRoot,
            saveRoot,
            jarPath,
            Int32(canvasWidth),
            Int32(canvasHeight),
            Int32(render3dScale),
            Int32(fpsLimit)
        )

        guard initResult == 0 else {

            print("[Swift] ERROR: JVM init failed: \(initResult)")

            return """
            JVM initialization failed.

            Error code: \(initResult)

            Check the MiniJVM runtime files and build log.
            """
        }

        print("[Swift] JVM initialized.")

        // Chạy MIDlet.
        let runResult = jvm_bridge_run_midlet(jarPath)

        print("[Swift] MIDlet run result: \(runResult)")

        // Dọn JVM sau khi game kết thúc.
        jvm_bridge_destroy()

        guard runResult == 0 else {
            return """
            The MIDlet could not run.

            Error code: \(runResult)

            The JAR may not contain a supported MIDlet entry point,
            or it may require an unsupported Java class.
            """
        }

        return nil
    }

    private func showLaunchError(_ message: String) {

        let alert = UIAlertController(
            title: "Cannot Start Game",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(
                title: "Back",
                style: .default
            ) { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )

        present(alert, animated: true)
    }

    @objc private func backTapped() {

        backButton.isEnabled = false

        jvm_bridge_request_stop()
    }

    // ============================================================
    // MARK: - View Switching
    // ============================================================

    func showCanvasView() {

        emulatorView.isHidden = false
        joystickView?.isHidden = false
        numpadView?.isHidden = false

        formView.isHidden = true
        listView.isHidden = true

        numpadView?.updateCommands()
    }

    func showFormView() {

        formView.buildFromNativeData()

        formView.isHidden = false

        emulatorView.isHidden = true
        joystickView?.isHidden = true
        numpadView?.isHidden = true

        listView.isHidden = true
    }

    func showListView() {

        listView.buildFromNativeData()

        listView.isHidden = false

        emulatorView.isHidden = true
        joystickView?.isHidden = true
        numpadView?.isHidden = true

        formView.isHidden = true
    }

    // ============================================================
    // MARK: - J2ME Alerts
    // ============================================================

    func showAlert() {

        let title = String(
            cString: j2me_ui_get_form_title()
        )

        let text = String(
            cString: j2me_ui_get_alert_text()
        )

        let alert = UIAlertController(
            title: title,
            message: text,
            preferredStyle: .alert
        )

        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let cmdCount = j2me_ui_get_command_count()

        if cmdCount == 0 {

            alert.addAction(
                UIAlertAction(
                    title: "OK",
                    style: .default
                ) { [weak self] _ in

                    self?.alertTimeoutWork?.cancel()

                    j2me_input_post_key(
                        Int32(J2ME_UI_ALERT_DISMISSED),
                        0
                    )
                }
            )

        } else {

            for i in 0..<cmdCount {

                let label = String(
                    cString: j2me_ui_get_command_label(Int32(i))
                )

                let cmdId = j2me_ui_get_command_id(Int32(i))

                alert.addAction(
                    UIAlertAction(
                        title: label,
                        style: .default
                    ) { [weak self] _ in

                        self?.alertTimeoutWork?.cancel()

                        j2me_input_post_key(
                            Int32(J2ME_UI_COMMAND_ACTION),
                            cmdId
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

// ============================================================
// MARK: - Game UI Callback
// ============================================================

private(set) weak var activeGameViewController: GameViewController?

let gameUICallback: @convention(c) (
    Int32,
    UnsafePointer<CChar>?
) -> Void = { action, data in

    DispatchQueue.main.async {

        guard let vc = activeGameViewController else {
            return
        }

        switch action {

        case Int32(J2ME_UI_ACTION_SHOW_CANVAS):
            vc.showCanvasView()

        case Int32(J2ME_UI_ACTION_SHOW_FORM):
            vc.showFormView()

        case Int32(J2ME_UI_ACTION_SHOW_LIST):
            vc.showListView()

        case Int32(J2ME_UI_ACTION_SHOW_ALERT):
            vc.showAlert()

        default:
            break
        }
    }
}
