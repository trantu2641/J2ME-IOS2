import UIKit

final class GameViewController: UIViewController {

    private struct SessionTab {
        var sessionId: Int32
        var game: J2MEGame
        var title: String
        var proxyEnabled: Bool
        var proxyType: Int32 // 1 = HTTP, 2 = SOCKS5
        var proxyHost: String
        var proxyPort: Int32
        var proxyUser: String
        var proxyPass: String
    }

    private let initialGame: J2MEGame
    private let screenWidth: Int32
    private let screenHeight: Int32
    private let render3DScale: Int32
    private let fpsLimit: Int32

    private var tabs: [SessionTab] = []
    private var activeTabIndex: Int = -1

    private let emulatorView = EmulatorView()
    private let padView = PadView()
    private var formView: FormView?
    private var textBoxOverlay: TextBoxOverlayView?
    private var alertBanner: UIView?

    private let topBar = UIView()
    private let exitButton = UIButton(type: .system)
    private let tabScrollView = UIScrollView()
    private let tabStackView = UIStackView()
    private let addTabButton = UIButton(type: .system)
    private let proxyButton = UIButton(type: .system)
    private let loadingIndicator = UIActivityIndicatorView(style: .large)

    private var padHeightConstraint: NSLayoutConstraint?
    private var isPadVisible = true

    private static weak var currentController: GameViewController?

    init(game: J2MEGame,
         screenWidth: Int32 = 240,
         screenHeight: Int32 = 320,
         render3DScale: Int32 = 1,
         fpsLimit: Int32 = 0) {
        self.initialGame = game
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.render3DScale = render3DScale
        self.fpsLimit = fpsLimit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        GameViewController.currentController = self

        setupTopBar()
        setupEmulatorView()
        setupPadView()
        setupLoadingIndicator()
        setupCallbacks()

        createAndStartTab(for: initialGame)
    }

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }

    // MARK: - Top Bar & Multi-Tab UI

    private func setupTopBar() {
        topBar.backgroundColor = UIColor(white: 0.08, alpha: 0.95)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        exitButton.setTitle("✕", for: .normal)
        exitButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 16)
        exitButton.setTitleColor(.systemRed, for: .normal)
        exitButton.addTarget(self, action: #selector(exitTapped), for: .touchUpInside)
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(exitButton)

        proxyButton.setTitle("Proxy", for: .normal)
        proxyButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 12)
        proxyButton.setTitleColor(.systemTeal, for: .normal)
        proxyButton.backgroundColor = UIColor(white: 0.16, alpha: 1.0)
        proxyButton.layer.cornerRadius = 6
        proxyButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        proxyButton.addTarget(self, action: #selector(proxyButtonTapped), for: .touchUpInside)
        proxyButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(proxyButton)

        addTabButton.setTitle("+", for: .normal)
        addTabButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
        addTabButton.setTitleColor(.systemGreen, for: .normal)
        addTabButton.addTarget(self, action: #selector(addTabTapped), for: .touchUpInside)
        addTabButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(addTabButton)

        tabScrollView.showsHorizontalScrollIndicator = false
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(tabScrollView)

        tabStackView.axis = .horizontal
        tabStackView.spacing = 6
        tabStackView.alignment = .center
        tabStackView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.addSubview(tabStackView)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 36),

            exitButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            exitButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            exitButton.widthAnchor.constraint(equalToConstant: 32),
            exitButton.heightAnchor.constraint(equalToConstant: 32),

            proxyButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            proxyButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            addTabButton.trailingAnchor.constraint(equalTo: proxyButton.leadingAnchor, constant: -6),
            addTabButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            addTabButton.widthAnchor.constraint(equalToConstant: 30),
            addTabButton.heightAnchor.constraint(equalToConstant: 30),

            tabScrollView.leadingAnchor.constraint(equalTo: exitButton.trailingAnchor, constant: 4),
            tabScrollView.trailingAnchor.constraint(equalTo: addTabButton.leadingAnchor, constant: -4),
            tabScrollView.topAnchor.constraint(equalTo: topBar.topAnchor),
            tabScrollView.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),

            tabStackView.leadingAnchor.constraint(equalTo: tabScrollView.leadingAnchor),
            tabStackView.trailingAnchor.constraint(equalTo: tabStackView.trailingAnchor),
            tabStackView.centerYAnchor.constraint(equalTo: tabScrollView.centerYAnchor),
            tabStackView.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setupEmulatorView() {
        emulatorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emulatorView)

        NSLayoutConstraint.activate([
            emulatorView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            emulatorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emulatorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupPadView() {
        padView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(padView)

        // Adaptive pad height that respects safeAreaInsets.bottom and never clips buttons
        let isCompactHeight = UIScreen.main.bounds.height <= 667
        let basePadHeight: CGFloat = isCompactHeight ? 185 : 210
        let padH = padView.heightAnchor.constraint(equalToConstant: basePadHeight)
        padHeightConstraint = padH

        NSLayoutConstraint.activate([
            padView.topAnchor.constraint(equalTo: emulatorView.bottomAnchor),
            padView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            padView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            padView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            padH,
        ])

        padView.onKeyDown = { keyCode in
            j2me_input_post_key(J2ME_INPUT_KEY_DOWN, keyCode)
        }
        padView.onKeyUp = { keyCode in
            j2me_input_post_key(J2ME_INPUT_KEY_UP, keyCode)
        }
    }

    private func setupLoadingIndicator() {
        loadingIndicator.color = .white
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.startAnimating()
        view.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: emulatorView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: emulatorView.centerYAnchor),
        ])
    }

    // MARK: - Native Callbacks

    private func setupCallbacks() {
        j2me_render_set_fps_limit(fpsLimit)

        j2me_ui_set_callback { action, titlePtr in
            let title = titlePtr != nil ? String(cString: titlePtr!) : ""
            DispatchQueue.main.async {
                GameViewController.currentController?.handleUIAction(action, title: title)
            }
        }

        jvm_bridge_set_session_exit_callback { sessionId, _ in
            DispatchQueue.main.async {
                GameViewController.currentController?.handleNaturalSessionExit(sessionId: sessionId)
            }
        }
    }

    // MARK: - Session Management

    private func createAndStartTab(for game: J2MEGame) {
        guard let resRoot = Bundle.main.resourcePath else { return }
        let saveRoot = saveDirectory(for: game, instanceIndex: tabs.count + 1)

        let sessionId = jvm_bridge_session_create(
            resRoot,
            saveRoot,
            game.jarPath,
            screenWidth,
            screenHeight,
            render3DScale,
            fpsLimit
        )

        guard sessionId > 0 else {
            showAlert("Không thể khởi tạo máy ảo cho \(game.title)")
            return
        }

        let tab = SessionTab(
            sessionId: sessionId,
            game: game,
            title: game.title,
            proxyEnabled: false,
            proxyType: 2, // SOCKS5 default
            proxyHost: "",
            proxyPort: 1080,
            proxyUser: "",
            proxyPass: ""
        )
        tabs.append(tab)
        let newIndex = tabs.count - 1
        switchToTab(index: newIndex)

        let startRet = jvm_bridge_session_start(sessionId)
        loadingIndicator.stopAnimating()
        if startRet != 0 {
            showAlert("Lỗi khởi chạy \(game.title)")
        }
    }

    private func saveDirectory(for game: J2MEGame, instanceIndex: Int) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safeName = game.title.replacingOccurrences(of: "/", with: "_")
        let dir = docs.appendingPathComponent("RMS/\(safeName)_tab\(instanceIndex)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func switchToTab(index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        activeTabIndex = index
        let tab = tabs[index]
        jvm_bridge_session_set_active(tab.sessionId)
        updateProxyButtonAppearance(for: tab)
        rebuildTabBar()
    }

    private func closeTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        let closing = tabs.remove(at: index)

        DispatchQueue.global(qos: .userInitiated).async {
            jvm_bridge_session_destroy(closing.sessionId)
        }

        if tabs.isEmpty {
            dismissEmulator()
        } else {
            let nextIndex = min(index, tabs.count - 1)
            switchToTab(index: nextIndex)
        }
    }

    private func handleNaturalSessionExit(sessionId: Int32) {
        if let idx = tabs.firstIndex(where: { $0.sessionId == sessionId }) {
            closeTab(at: idx)
        }
    }

    private func rebuildTabBar() {
        for sub in tabStackView.arrangedSubviews {
            tabStackView.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        for (i, tab) in tabs.enumerated() {
            let btn = UIButton(type: .system)
            let isSelected = (i == activeTabIndex)
            let proxyDot = tab.proxyEnabled ? " [P]" : ""
            btn.setTitle("\(i + 1). \(tab.title)\(proxyDot)", for: .normal)
            btn.titleLabel?.font = isSelected ? UIFont.boldSystemFont(ofSize: 12) : UIFont.systemFont(ofSize: 12)
            btn.setTitleColor(isSelected ? .white : .lightGray, for: .normal)
            btn.backgroundColor = isSelected ? UIColor.systemBlue.withAlphaComponent(0.75) : UIColor(white: 0.16, alpha: 1.0)
            btn.layer.cornerRadius = 6
            btn.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            btn.tag = i
            btn.addTarget(self, action: #selector(tabButtonTapped(_:)), for: .touchUpInside)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(tabLongPressed(_:)))
            btn.addGestureRecognizer(longPress)

            tabStackView.addArrangedSubview(btn)
        }
    }

    private func updateProxyButtonAppearance(for tab: SessionTab) {
        if tab.proxyEnabled {
            proxyButton.setTitle("Proxy: ON", for: .normal)
            proxyButton.setTitleColor(.white, for: .normal)
            proxyButton.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.75)
        } else {
            proxyButton.setTitle("Proxy", for: .normal)
            proxyButton.setTitleColor(.systemTeal, for: .normal)
            proxyButton.backgroundColor = UIColor(white: 0.16, alpha: 1.0)
        }
    }

    // MARK: - Per-Tab Proxy Configuration

    @objc private func proxyButtonTapped() {
        guard activeTabIndex >= 0 && activeTabIndex < tabs.count else { return }
        let currentTab = tabs[activeTabIndex]

        let alert = UIAlertController(
            title: "Proxy riêng cho Tab \(activeTabIndex + 1)",
            message: "Chỉ áp dụng cho tab \"\(currentTab.title)\".\nChọn giao thức bên dưới:",
            preferredStyle: .alert
        )

        alert.addTextField { tf in
            tf.placeholder = "Host / IP (vd: 127.0.0.1)"
            tf.text = currentTab.proxyHost
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .none
        }

        alert.addTextField { tf in
            tf.placeholder = "Port (vd: 1080)"
            tf.text = currentTab.proxyPort > 0 ? "\(currentTab.proxyPort)" : ""
            tf.keyboardType = .numberPad
        }

        alert.addTextField { tf in
            tf.placeholder = "Username (tùy chọn)"
            tf.text = currentTab.proxyUser
            tf.autocorrectionType = .no
            tf.autocapitalizationType = .none
        }

        alert.addTextField { tf in
            tf.placeholder = "Password (tùy chọn)"
            tf.text = currentTab.proxyPass
            tf.isSecureTextEntry = true
        }

        alert.addAction(UIAlertAction(title: "Bật SOCKS5", style: .default) { [weak self] _ in
            self?.applyProxyFromAlert(alert, enabled: true, type: 2)
        })

        alert.addAction(UIAlertAction(title: "Bật HTTP", style: .default) { [weak self] _ in
            self?.applyProxyFromAlert(alert, enabled: true, type: 1)
        })

        alert.addAction(UIAlertAction(title: "Tắt Proxy", style: .destructive) { [weak self] _ in
            self?.applyProxyFromAlert(alert, enabled: false, type: 0)
        })

        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        present(alert, animated: true)
    }

    private func applyProxyFromAlert(_ alert: UIAlertController, enabled: Bool, type: Int32) {
        guard activeTabIndex >= 0 && activeTabIndex < tabs.count else { return }
        let fields = alert.textFields ?? []
        let host = (fields.count > 0 ? fields[0].text : "")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let portStr = (fields.count > 1 ? fields[1].text : "")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let user = (fields.count > 2 ? fields[2].text : "") ?? ""
        let pass = (fields.count > 3 ? fields[3].text : "") ?? ""
        let port = Int32(portStr) ?? 0

        if enabled && (host.isEmpty || port <= 0 || port > 65535) {
            showAlert("Host hoặc Port Proxy không hợp lệ.")
            return
        }

        tabs[activeTabIndex].proxyEnabled = enabled
        tabs[activeTabIndex].proxyType = enabled ? type : 0
        tabs[activeTabIndex].proxyHost = host
        tabs[activeTabIndex].proxyPort = port
        tabs[activeTabIndex].proxyUser = user
        tabs[activeTabIndex].proxyPass = pass

        let tab = tabs[activeTabIndex]
        jvm_bridge_session_set_proxy(
            tab.sessionId,
            enabled ? type : 0,
            host,
            port,
            user,
            pass
        )

        updateProxyButtonAppearance(for: tab)
        rebuildTabBar()
    }

    // MARK: - Actions

    @objc private func tabButtonTapped(_ sender: UIButton) {
        switchToTab(index: sender.tag)
    }

    @objc private func tabLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let btn = gesture.view as? UIButton else { return }
        let idx = btn.tag
        guard idx >= 0 && idx < tabs.count else { return }

        let sheet = UIAlertController(title: tabs[idx].title, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Đóng tab này", style: .destructive) { [weak self] _ in
            self?.closeTab(at: idx)
        })
        sheet.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = btn
            popover.sourceRect = btn.bounds
        }
        present(sheet, animated: true)
    }

    @objc private func addTabTapped() {
        let games = J2MELibraryManager.shared.scanGames()
        guard !games.isEmpty else {
            createAndStartTab(for: initialGame)
            return
        }

        let sheet = UIAlertController(title: "Mở game trong tab mới", message: nil, preferredStyle: .actionSheet)
        for game in games {
            sheet.addAction(UIAlertAction(title: game.title, style: .default) { [weak self] _ in
                self?.createAndStartTab(for: game)
            })
        }
        sheet.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = addTabButton
            popover.sourceRect = addTabButton.bounds
        }
        present(sheet, animated: true)
    }

    @objc private func exitTapped() {
        if tabs.count > 1 {
            let alert = UIAlertController(
                title: "Thoát game",
                message: "Bạn muốn đóng tab hiện tại hay thoát toàn bộ?",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Đóng tab này", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.closeTab(at: self.activeTabIndex)
            })
            alert.addAction(UIAlertAction(title: "Thoát tất cả", style: .destructive) { [weak self] _ in
                self?.closeAllAndDismiss()
            })
            alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
            present(alert, animated: true)
        } else {
            closeAllAndDismiss()
        }
    }

    private func closeAllAndDismiss() {
        tabs.removeAll()
        activeTabIndex = -1
        DispatchQueue.global(qos: .userInitiated).async {
            jvm_bridge_session_destroy_all()
        }
        dismissEmulator()
    }

    private func dismissEmulator() {
        j2me_ui_set_callback(nil)
        jvm_bridge_set_session_exit_callback(nil)
        dismiss(animated: true)
    }

    // MARK: - LCDUI Native Overlays (Form / List / Alert / TextBox)

    private func handleUIAction(_ action: Int32, title: String) {
        switch action {
        case J2ME_UI_ACTION_SHOW_CANVAS:
            removeFormView()
            removeTextBoxOverlay()

        case J2ME_UI_ACTION_SHOW_FORM, J2ME_UI_ACTION_SHOW_LIST:
            showNativeForm(title: title, isList: action == J2ME_UI_ACTION_SHOW_LIST)

        case J2ME_UI_ACTION_SHOW_ALERT:
            let msgPtr = j2me_ui_get_alert_text()
            let msg = msgPtr != nil ? String(cString: msgPtr!) : title
            showAlert(msg)

        case J2ME_UI_ACTION_SHOW_TEXTBOX:
            showNativeTextBox(title: title)

        default:
            break
        }
    }

    private func showNativeForm(title: String, isList: Bool) {
        removeFormView()
        let fv = FormView(frame: emulatorView.bounds)
        fv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fv.loadFromNative(title: title, isList: isList)
        fv.onCommandSelected = { [weak self] cmdId in
            j2me_input_post_key(J2ME_UI_COMMAND_EVENT, cmdId)
            self?.removeFormView()
        }
        fv.onListItemSelected = { index in
            j2me_input_post_key(J2ME_UI_LIST_SELECT, Int32(index))
        }
        emulatorView.addSubview(fv)
        formView = fv
    }

    private func removeFormView() {
        formView?.removeFromSuperview()
        formView = nil
    }

    private func showNativeTextBox(title: String) {
        removeTextBoxOverlay()
        let initialPtr = j2me_ui_get_form_item_text(0)
        let initial = initialPtr != nil ? String(cString: initialPtr!) : ""
        let maxSize = j2me_ui_get_form_item_param1(0)
        let constraints = j2me_ui_get_form_item_param2(0)

        let overlay = TextBoxOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.configure(
            title: title,
            initialText: initial,
            maxSize: Int(maxSize),
            constraints: Int(constraints)
        )
        overlay.onConfirm = { [weak self] text in
            text.withCString { cstr in
                j2me_ui_set_form_item_text(0, cstr)
            }
            let cmdCount = j2me_ui_get_command_count()
            var okCmdId: Int32 = 0
            for i in 0..<cmdCount {
                let type = j2me_ui_get_command_type(i)
                if type == 4 || type == 1 { // OK or SCREEN
                    okCmdId = j2me_ui_get_command_id(i)
                    break
                }
            }
            j2me_input_post_key(J2ME_UI_FORM_COMMIT, 0)
            j2me_input_post_key(J2ME_UI_COMMAND_EVENT, okCmdId)
            self?.removeTextBoxOverlay()
        }
        overlay.onCancel = { [weak self] in
            let cmdCount = j2me_ui_get_command_count()
            var cancelCmdId: Int32 = 1
            for i in 0..<cmdCount {
                let type = j2me_ui_get_command_type(i)
                if type == 2 || type == 3 { // BACK or CANCEL
                    cancelCmdId = j2me_ui_get_command_id(i)
                    break
                }
            }
            j2me_input_post_key(J2ME_UI_COMMAND_EVENT, cancelCmdId)
            self?.removeTextBoxOverlay()
        }
        view.addSubview(overlay)
        textBoxOverlay = overlay
    }

    private func removeTextBoxOverlay() {
        textBoxOverlay?.removeFromSuperview()
        textBoxOverlay = nil
    }

    private func showAlert(_ message: String) {
        alertBanner?.removeFromSuperview()
        let banner = UIView()
        banner.backgroundColor = UIColor(white: 0.12, alpha: 0.92)
        banner.layer.cornerRadius = 10
        banner.translatesAutoresizingMaskIntoConstraints = false

        let lbl = UILabel()
        lbl.text = message
        lbl.textColor = .white
        lbl.font = UIFont.systemFont(ofSize: 13)
        lbl.numberOfLines = 0
        lbl.textAlignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(lbl)

        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            lbl.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            lbl.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
            lbl.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            lbl.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
        ])
        alertBanner = banner

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak banner] in
            banner?.removeFromSuperview()
        }
    }
}
