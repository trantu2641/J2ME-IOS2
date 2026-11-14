//
// GameViewController.swift
// J2ME portrait game screen with keyboard input,
// framebuffer viewport and startup diagnostics.
//
// FPS is limited at the iOS display layer only.
// MiniJVM / Java Canvas always runs normally.
//

import UIKit

private struct J2MERunningSession {
    let id: Int32
    let name: String
    let path: String
    let icon: UIImage
    let canvasWidth: Int
    let canvasHeight: Int
    let render3dScale: Int
    let fpsLimit: Int
}

private final class J2MEKeyboardInputView:
    UIView,
    UIKeyInput {

    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        true
    }

    var hasText: Bool {
        true
    }

    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .default
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

        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    func insertText(_ text: String) {
        onInsertText?(text)
    }

    func deleteBackward() {
        onDeleteBackward?()
    }
}

final class GameViewController:
    UIViewController {

    let jarPath: String
    let appName: String
    let appIcon: UIImage

    let canvasWidth: Int
    let canvasHeight: Int

    let render3dScale: Int

    //
    // This value is now ONLY a display FPS.
    //
    let fpsLimit: Int

    private let emulatorView =
        EmulatorView()

    private let keypadView =
        J2MEVirtualKeypadView()

    private lazy var formView =
        FormView()

    private lazy var listView =
        J2MEListView()

    private let headerStack =
        UIStackView()

    private let tabScrollView =
        UIScrollView()

    private let tabStack =
        UIStackView()

    private let addJarButton =
        UIButton(type: .system)

    private let removeJarButton =
        UIButton(type: .system)

    private var runningSessions: [J2MERunningSession] = []
    private var activeSessionIndex = 0
    private var jarPickerOverlay: UIView?
    private var jarPickerPanel: UIView?
    private var jarPickerTableView: UITableView?
    private var jarPickerMessageLabel: UILabel?
    private var jarPickerMessageWork: DispatchWorkItem?
    private var jarPickerItems: [(name: String, path: String, icon: UIImage)] = []

    private let titleLabel =
        UILabel()

    private let toggleKeypadButton =
        UIButton(type: .system)

    private let systemKeyboardButton =
        UIButton(type: .system)

    private let moreButton =
        UIButton(type: .system)

    private var moreMenuOverlay: UIView?
    private var moreMenuPanel: UIView?

    private let keyboardInput =
        J2MEKeyboardInputView(frame: .zero)

    private var keypadHeightConstraint:
        NSLayoutConstraint!

    private var keypadCollapsedConstraint:
        NSLayoutConstraint!

    private var keypadBottomConstraint:
        NSLayoutConstraint!

    private var keyboardIsVisible = false

    private var isCanvasScreenVisible: Bool {

        !emulatorView.isHidden &&
        formView.isHidden &&
        listView.isHidden
    }

    private var gameStarted = false
    private var userRequestedExit = false

    private var lastJVMLog = ""
    private var lastJVMLogPath = ""

    private(set) var placeholderIconView:
        UIImageView?

    private var alertTimeoutWork:
        DispatchWorkItem?

    private var startupWatchdog:
        DispatchWorkItem?

    init(
        jarPath: String,
        appName: String,
        appIcon: UIImage,
        canvasWidth: Int = 240,
        canvasHeight: Int = 320,
        render3dScale: Int = 1,
        fpsLimit: Int = 0
    ) {

        self.jarPath = jarPath
        self.appName = appName
        self.appIcon = appIcon

        self.canvasWidth =
            min(
                max(1, canvasWidth),
                4096
            )

        self.canvasHeight =
            min(
                max(1, canvasHeight),
                4096
            )

        self.render3dScale =
            max(
                1,
                render3dScale
            )

        let supportedFPS =
            [0, 15, 20, 30, 45]

        self.fpsLimit =
            supportedFPS.contains(fpsLimit)
            ? fpsLimit
            : 0

        super.init(nibName: nil, bundle: nil)

        modalPresentationStyle =
            .fullScreen
    }

    required init?(coder: NSCoder) {

        fatalError(
            "init(coder:) has not been implemented"
        )
    }

    deinit {

        alertTimeoutWork?.cancel()
        startupWatchdog?.cancel()

        NotificationCenter.default
            .removeObserver(self)

        setGlobalEmulatorView(nil)
        jvm_bridge_session_destroy_all()
    }

    override var prefersStatusBarHidden:
        Bool {
        true
    }

    override var supportedInterfaceOrientations:
        UIInterfaceOrientationMask {

        .portrait
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {

        super.viewDidLoad()

        view.backgroundColor = .systemBackground

        if UserDefaults.standard.bool(forKey: "J2MEKeepScreenOn") {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        emulatorView.canvasWidth =
            canvasWidth

        emulatorView.canvasHeight =
            canvasHeight

        //
        // IMPORTANT:
        //
        // FPS is applied to display presentation.
        //
        // Do this BEFORE the game starts.
        //
        emulatorView.setDisplayFPS(
            fpsLimit
        )

        buildHeader()
        buildGameLayout()
        buildKeyboardInput()
        buildOverlays()

        let iconView =
            UIImageView(image: appIcon)

        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints =
            false

        view.addSubview(iconView)

        NSLayoutConstraint.activate([

            iconView.centerXAnchor.constraint(
                equalTo:
                    emulatorView.centerXAnchor
            ),

            iconView.centerYAnchor.constraint(
                equalTo:
                    emulatorView.centerYAnchor
            )
        ])

        placeholderIconView =
            iconView

        emulatorView.onFirstFrame =
            { [weak self] in

                guard let self,
                      let icon =
                        self.placeholderIconView else {
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

                        self.placeholderIconView =
                            nil
                    }
                )
            }

        setGlobalEmulatorView(
            emulatorView
        )

        // Multi-session renderer stays alive while JAR sessions coexist.
        j2me_render_set_fps_limit(0)

        j2me_render_set_flush_ready_callback(
            flushReadyCallback
        )

        j2me_render_set_flush_callback(
            flushCallback
        )

        j2me_ui_set_callback(
            gameUICallback
        )

        activeGameViewController =
            self

        NotificationCenter.default.addObserver(
            self,
            selector:
                #selector(
                    handleKeyboardWillChangeFrame(_:)
                ),
            name:
                UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector:
                #selector(
                    handleKeyboardWillHide(_:)
                ),
            name:
                UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    override func viewDidAppear(
        _ animated: Bool
    ) {

        super.viewDidAppear(animated)

        guard !gameStarted else {
            return
        }

        gameStarted = true

        startGame()
    }

    // MARK: - Interface style

    // Keep the emulator UI synchronized with the iPhone's Light/Dark appearance.
    // The game Canvas itself is not recolored; these colors apply only to the
    // J2ME emulator controls, menus, picker and surrounding UI.
    private var uiControlBackgroundColor: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.16, alpha: 1)
                : UIColor(white: 0.90, alpha: 1)
        }
    }

    private var uiPanelBackgroundColor: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.black.withAlphaComponent(0.88)
                : UIColor.systemBackground.withAlphaComponent(0.96)
        }
    }

    private var uiPrimaryTextColor: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? .white : .black
        }
    }

    private var uiSeparatorColor: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.35, alpha: 0.55)
                : UIColor(white: 0.70, alpha: 0.70)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else {
            return
        }

        // Dynamic UIColor values update automatically. Rebuild the tab buttons
        // so their selected/unselected backgrounds also follow the new style.
        rebuildTabs()
    }

    // MARK: - Header

    private func buildHeader() {

        configureHeaderButton(
            addJarButton,
            symbol: "plus",
            accessibility: "Add JAR"
        )

        configureHeaderButton(
            removeJarButton,
            symbol: "minus",
            accessibility: "Close current JAR"
        )

        configureHeaderButton(
            toggleKeypadButton,
            symbol: "keyboard",
            accessibility: "Show or hide game keypad"
        )

        configureHeaderButton(
            systemKeyboardButton,
            symbol: "text.cursor",
            accessibility: "Show or hide iPhone keyboard"
        )

        configureHeaderButton(
            moreButton,
            symbol: "ellipsis",
            accessibility: "More options"
        )

        addJarButton.addTarget(
            self,
            action: #selector(addJarTapped),
            for: .touchUpInside
        )

        removeJarButton.addTarget(
            self,
            action: #selector(removeCurrentJarTapped),
            for: .touchUpInside
        )

        toggleKeypadButton.addTarget(
            self,
            action: #selector(toggleKeypad),
            for: .touchUpInside
        )

        systemKeyboardButton.addTarget(
            self,
            action: #selector(toggleSystemKeyboard),
            for: .touchUpInside
        )

        moreButton.addTarget(
            self,
            action: #selector(showMoreMenu),
            for: .touchUpInside
        )

        tabScrollView.showsHorizontalScrollIndicator = false
        tabScrollView.showsVerticalScrollIndicator = false
        tabScrollView.alwaysBounceHorizontal = true
        tabScrollView.alwaysBounceVertical = false
        tabScrollView.backgroundColor = .clear
        tabScrollView.clipsToBounds = true
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false

        tabStack.axis = .horizontal
        tabStack.alignment = .center
        tabStack.spacing = 3
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        tabScrollView.addSubview(tabStack)

        NSLayoutConstraint.activate([
            tabStack.leadingAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.leadingAnchor),
            tabStack.trailingAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.trailingAnchor),
            tabStack.topAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScrollView.contentLayoutGuide.bottomAnchor),
            tabStack.heightAnchor.constraint(equalTo: tabScrollView.frameLayoutGuide.heightAnchor)
        ])

        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 5
        headerStack.distribution = .fill
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        headerStack.addArrangedSubview(tabScrollView)
        headerStack.addArrangedSubview(addJarButton)
        headerStack.addArrangedSubview(removeJarButton)
        headerStack.addArrangedSubview(toggleKeypadButton)
        headerStack.addArrangedSubview(systemKeyboardButton)
        headerStack.addArrangedSubview(moreButton)

        view.addSubview(headerStack)
    }

    private func configureHeaderButton(
        _ button: UIButton,
        symbol: String,
        accessibility: String
    ) {

        // Keep every header control on the exact same 38 x 34 box and
        // normalize the SF Symbol drawing size as well. Without an explicit
        // symbol configuration, symbols such as `ellipsis`, `keyboard`,
        // `text.cursor`, `plus` and `minus` have different visual bounds.
        let symbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 17,
            weight: .medium,
            scale: .medium
        )

        button.setImage(
            UIImage(systemName: symbol, withConfiguration: symbolConfiguration),
            for: .normal
        )

        button.tintColor = uiPrimaryTextColor
        button.backgroundColor = uiControlBackgroundColor
        button.layer.cornerRadius = 9
        button.clipsToBounds = true
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center
        button.imageView?.contentMode = .center
        button.accessibilityLabel = accessibility
        button.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 38),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
    }

    // MARK: - JAR tabs

    private func rebuildTabs() {
        tabStack.arrangedSubviews.forEach { view in
            tabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, session) in runningSessions.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle("\(index + 1)", for: .normal)
            button.setTitleColor(
                index == activeSessionIndex ? .white : uiPrimaryTextColor,
                for: .normal
            )
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.backgroundColor = index == activeSessionIndex
                ? UIColor.systemBlue
                : uiControlBackgroundColor
            button.layer.cornerRadius = 9
            button.accessibilityLabel = "JAR \(index + 1): \(session.name)"
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                // JAR tabs use the exact same button box as the function buttons.
                button.widthAnchor.constraint(equalToConstant: 38),
                button.heightAnchor.constraint(equalToConstant: 34)
            ])
            tabStack.addArrangedSubview(button)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollTabIntoView(index: self.activeSessionIndex, animated: false)
        }
    }

    private func scrollTabIntoView(index: Int, animated: Bool) {
        guard index >= 0, index < tabStack.arrangedSubviews.count else { return }
        let target = tabStack.arrangedSubviews[index].frame
        tabScrollView.scrollRectToVisible(target.insetBy(dx: -8, dy: 0), animated: animated)
    }

    @objc private func tabTapped(_ sender: UIButton) {
        switchToSession(at: sender.tag)
    }

    private func switchToSession(at index: Int) {
        guard index >= 0, index < runningSessions.count else { return }
        activeSessionIndex = index
        let session = runningSessions[index]

        jvm_bridge_session_set_active(session.id)

        emulatorView.canvasWidth = session.canvasWidth
        emulatorView.canvasHeight = session.canvasHeight
        emulatorView.setDisplayFPS(session.fpsLimit)

        toggleKeypadButton.tintColor = uiPrimaryTextColor
        rebuildTabs()
    }

    private func makeSaveRoot(for jarPath: String) -> String {
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory,
            .userDomainMask,
            true
        ).first ?? NSTemporaryDirectory()

        let base = URL(fileURLWithPath: jarPath)
            .deletingPathExtension()
            .lastPathComponent

        let gameID = base.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]",
            with: "_",
            options: .regularExpression
        )

        return (docs as NSString).appendingPathComponent("Games Data/\(gameID)")
    }

    private func addRunningJar(
        path: String,
        name: String,
        icon: UIImage,
        canvasWidth: Int,
        canvasHeight: Int,
        render3dScale: Int,
        fpsLimit: Int
    ) {
        if let existing = runningSessions.firstIndex(where: { $0.path == path }) {
            switchToSession(at: existing)
            return
        }

        guard let resourceRoot = Bundle.main.resourcePath else { return }
        let saveRoot = makeSaveRoot(for: path)

        do {
            try FileManager.default.createDirectory(
                atPath: saveRoot,
                withIntermediateDirectories: true
            )
        } catch {
            print("[JVM] Cannot create session save directory: \(error)")
            return
        }

        let safeFPS = [0, 15, 20, 30, 45].contains(fpsLimit) ? fpsLimit : 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let sessionID = jvm_bridge_session_create(
                resourceRoot,
                saveRoot,
                path,
                Int32(canvasWidth),
                Int32(canvasHeight),
                Int32(max(1, render3dScale)),
                Int32(safeFPS)
            )

            guard sessionID > 0 else {
                print("[JVM] Cannot create multi-session runtime: \(sessionID)")
                return
            }

            let startResult = jvm_bridge_session_start(sessionID)
            guard startResult == 0 else {
                print("[JVM] Cannot start session \(sessionID): \(startResult)")
                jvm_bridge_session_destroy(sessionID)
                return
            }

            DispatchQueue.main.async {
                let session = J2MERunningSession(
                    id: sessionID,
                    name: name,
                    path: path,
                    icon: icon,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                    render3dScale: max(1, render3dScale),
                    fpsLimit: safeFPS
                )

                self.runningSessions.append(session)
                self.activeSessionIndex = self.runningSessions.count - 1
                self.rebuildTabs()
                self.switchToSession(at: self.activeSessionIndex)
            }
        }
    }

    private func scanInstalledJARs() -> [(name: String, path: String, icon: UIImage)] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let gamesDir = docs.appendingPathComponent("games", isDirectory: true)
        let iconsDir = docs.appendingPathComponent("Game Icons", isDirectory: true)

        let files = (try? FileManager.default.contentsOfDirectory(
            at: gamesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { $0.pathExtension.lowercased() == "jar" }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare(
                    $1.lastPathComponent
                ) == .orderedAscending
            }
            .map { url in
                let id = gameID(forPath: url.path)
                let defaults = UserDefaults.standard

                // AppsListViewController stores the renamed/external name here.
                // Use it first so the + picker is identical to the home list.
                let savedDisplayName =
                    defaults.string(forKey: "jarbox_display_name_\(id)")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let metadata = JARMetadata.read(from: url.path)

                let name: String
                if let savedDisplayName, !savedDisplayName.isEmpty {
                    name = savedDisplayName
                } else {
                    name = metadata?.midletName ??
                        url.deletingPathExtension().lastPathComponent
                }

                let customIconURL = iconsDir.appendingPathComponent("\(id).png")
                let customIcon = UIImage(contentsOfFile: customIconURL.path)

                let icon =
                    customIcon ??
                    metadata?.readIcon(from: url.path) ??
                    UIImage(systemName: "gamecontroller")!

                return (name: name, path: url.path, icon: icon)
            }
    }

    private func showJarPickerMessage(_ text: String) {
        jarPickerMessageWork?.cancel()
        jarPickerMessageLabel?.removeFromSuperview()

        guard let panel = jarPickerPanel else { return }

        let label = UILabel()
        label.text = text
        label.textColor = uiPrimaryTextColor
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.backgroundColor = uiControlBackgroundColor
        label.layer.cornerRadius = 10
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -66),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: panel.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -20),
            label.heightAnchor.constraint(equalToConstant: 38)
        ])

        jarPickerMessageLabel = label

        UIView.animate(withDuration: 0.12) {
            label.alpha = 1
        }

        let work = DispatchWorkItem { [weak self, weak label] in
            guard let self, let label else { return }

            UIView.animate(
                withDuration: 0.15,
                animations: {
                    label.alpha = 0
                },
                completion: { _ in
                    label.removeFromSuperview()
                    if self.jarPickerMessageLabel === label {
                        self.jarPickerMessageLabel = nil
                    }
                }
            )
        }

        jarPickerMessageWork = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2.0,
            execute: work
        )
    }

    @objc private func addJarTapped() {
        showJarPicker()
    }

    private func showJarPicker() {
        if jarPickerOverlay != nil { return }

        // JAR picker uses the same centered modal style as the three-dot menu.
        let overlay = UIControl()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(
            traitCollection.userInterfaceStyle == .dark ? 0.28 : 0.18
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.addTarget(
            self,
            action: #selector(closeJarPicker),
            for: .touchUpInside
        )

        let panel = UIView()
        panel.backgroundColor = uiPanelBackgroundColor
        panel.layer.cornerRadius = 20
        panel.layer.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "DANH SÁCH JAR"
        title.textColor = uiPrimaryTextColor
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorColor = uiSeparatorColor
        table.separatorInset = UIEdgeInsets(top: 0, left: 18, bottom: 0, right: 18)
        table.showsVerticalScrollIndicator = true
        table.alwaysBounceVertical = true
        table.translatesAutoresizingMaskIntoConstraints = false
        table.register(J2MEJarPickerCell.self, forCellReuseIdentifier: "jar")
        table.dataSource = self
        table.delegate = self

        let exit = UIButton(type: .system)
        exit.setTitle("HỦY", for: .normal)
        exit.setTitleColor(.systemBlue, for: .normal)
        exit.titleLabel?.font = .systemFont(ofSize: 17, weight: .regular)
        exit.contentHorizontalAlignment = .center
        exit.backgroundColor = .clear
        exit.addTarget(
            self,
            action: #selector(closeJarPicker),
            for: .touchUpInside
        )
        exit.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(title)
        panel.addSubview(table)
        panel.addSubview(exit)
        view.addSubview(overlay)
        view.addSubview(panel)

        let panelWidth = min(view.bounds.width - 48, 520)
        let panelHeight = min(max(300, view.bounds.height * 0.62), 620)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: panelWidth),
            panel.heightAnchor.constraint(equalToConstant: panelHeight),

            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            title.heightAnchor.constraint(equalToConstant: 34),

            table.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            table.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            table.bottomAnchor.constraint(equalTo: exit.topAnchor, constant: -4),

            exit.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            exit.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            exit.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
            exit.heightAnchor.constraint(equalToConstant: 58)
        ])

        jarPickerOverlay = overlay
        jarPickerPanel = panel
        jarPickerTableView = table

        // Scan the JAR directory only once when the picker opens.
        // UITableView callbacks must not rescan the filesystem while scrolling.
        jarPickerItems = scanInstalledJARs()
        table.reloadData()

        overlay.alpha = 0
        panel.alpha = 0
        panel.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)

        UIView.animate(
            withDuration: 0.16,
            animations: {
                overlay.alpha = 1
                panel.alpha = 1
                panel.transform = .identity
            }
        )
    }

    @objc private func closeJarPicker() {
        // Cancel any temporary duplicate-JAR message.
        jarPickerMessageWork?.cancel()
        jarPickerMessageWork = nil
        jarPickerMessageLabel?.removeFromSuperview()
        jarPickerMessageLabel = nil

        // Detach the table before removing the panel so there is no stale
        // delegate/data-source interaction after the picker is dismissed.
        if let table = jarPickerTableView {
            table.delegate = nil
            table.dataSource = nil
            table.removeFromSuperview()
        }
        jarPickerTableView = nil
        jarPickerItems.removeAll()

        if let panel = jarPickerPanel {
            panel.layer.removeAllAnimations()
            panel.removeFromSuperview()
        }
        jarPickerPanel = nil

        if let overlay = jarPickerOverlay {
            overlay.layer.removeAllAnimations()
            overlay.removeFromSuperview()
        }
        jarPickerOverlay = nil
    }

    @objc private func removeCurrentJarTapped() {
        guard !runningSessions.isEmpty else { return }

        let alert = UIAlertController(
            title: nil,
            message: "Bạn có muốn đóng cửa sổ không",
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Đóng", style: .destructive) { [weak self] _ in
            guard let self, !self.runningSessions.isEmpty else { return }

            let session = self.runningSessions[self.activeSessionIndex]
            jvm_bridge_session_request_stop(session.id)
            jvm_bridge_session_destroy(session.id)
            self.runningSessions.remove(at: self.activeSessionIndex)

            if self.runningSessions.isEmpty {
                self.userRequestedExit = true
                self.dismiss(animated: true)
                return
            }

            self.activeSessionIndex = min(
                self.activeSessionIndex,
                self.runningSessions.count - 1
            )
            self.rebuildTabs()
            self.switchToSession(at: self.activeSessionIndex)
        })

        present(alert, animated: true)
    }

    // MARK: - More options menu

    @objc private func showMoreMenu() {
        if moreMenuOverlay != nil {
            closeMoreMenu()
            return
        }

        let overlay = UIControl()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(
            traitCollection.userInterfaceStyle == .dark ? 0.28 : 0.18
        )
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.addTarget(self, action: #selector(closeMoreMenu), for: .touchUpInside)

        let panel = UIView()
        panel.backgroundColor = uiPanelBackgroundColor
        panel.layer.cornerRadius = 20
        panel.layer.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeMoreMenuButton(
            title: "Ẩn ứng dụng",
            color: .systemBlue,
            action: #selector(hideApplicationFromMenu)
        ))

        stack.addArrangedSubview(makeMoreMenuButton(
            title: UIApplication.shared.isIdleTimerDisabled ? "✓ Treo tắt màn" : "Treo tắt màn",
            color: .systemBlue,
            action: #selector(toggleKeepScreenOnFromMenu)
        ))

        stack.addArrangedSubview(makeMoreMenuButton(
            title: "Cỡ màn hình",
            color: .systemBlue,
            action: #selector(showScreenSizeMenu)
        ))

        stack.addArrangedSubview(makeMoreMenuButton(
            title: "Proxy",
            color: .systemBlue,
            action: #selector(showProxyMenu)
        ))

        stack.addArrangedSubview(makeMoreMenuButton(
            title: "Thoát",
            color: .systemRed,
            action: #selector(exitFromMoreMenu)
        ))

        stack.addArrangedSubview(makeMoreMenuButton(
            title: "Hủy",
            color: .systemBlue,
            action: #selector(closeMoreMenu)
        ))

        view.addSubview(overlay)
        view.addSubview(panel)
        panel.addSubview(stack)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            panel.widthAnchor.constraint(equalToConstant: min(520, max(280, UIScreen.main.bounds.width - 48))),

            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor)
        ])

        moreMenuOverlay = overlay
        moreMenuPanel = panel

        overlay.alpha = 0
        panel.alpha = 0
        panel.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)

        UIView.animate(withDuration: 0.16) {
            overlay.alpha = 1
            panel.alpha = 1
            panel.transform = .identity
        }
    }

    private func makeMoreMenuButton(
        title: String,
        color: UIColor,
        action: Selector
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(color, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
        button.contentHorizontalAlignment = .center
        button.heightAnchor.constraint(equalToConstant: 72).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func closeMoreMenu() {
        guard let overlay = moreMenuOverlay else { return }

        let panel = moreMenuPanel
        moreMenuOverlay = nil
        moreMenuPanel = nil

        UIView.animate(withDuration: 0.12, animations: {
            overlay.alpha = 0
            panel?.alpha = 0
        }, completion: { _ in
            panel?.removeFromSuperview()
            overlay.removeFromSuperview()
        })
    }

    @objc private func hideApplicationFromMenu() {
        closeMoreMenu()

        // Same behavior as the IPA: request iOS to suspend the current app.
        // This selector is private and is intentionally used only on the
        // jailbreak/emulator build where the reference IPA uses this behavior.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let selector = NSSelectorFromString("suspend")
            let application = UIApplication.shared
            if application.responds(to: selector) {
                _ = application.perform(selector)
            }
        }
    }

    @objc private func toggleKeepScreenOnFromMenu() {
        let newValue = !UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = newValue
        UserDefaults.standard.set(newValue, forKey: "J2MEKeepScreenOn")
        closeMoreMenu()
    }

    @objc private func showScreenSizeMenu() {
        closeMoreMenu()

        guard !runningSessions.isEmpty else { return }

        let session = runningSessions[activeSessionIndex]
        let alert = UIAlertController(
            title: "Cỡ màn hình",
            message: "Nhập độ phân giải Canvas cho JAR hiện tại.",
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = "Rộng"
            field.text = "\(session.canvasWidth)"
            field.keyboardType = .numberPad
        }

        alert.addTextField { field in
            field.placeholder = "Cao"
            field.text = "\(session.canvasHeight)"
            field.keyboardType = .numberPad
        }

        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            guard let self, let alert,
                  let width = Int(alert.textFields?[0].text ?? ""),
                  let height = Int(alert.textFields?[1].text ?? ""),
                  width > 0, height > 0,
                  width <= 4096, height <= 4096 else { return }

            let old = self.runningSessions[self.activeSessionIndex]

            // Resolution changes are intentionally deferred until this JAR
            // is restarted. Do not resize the currently running Canvas here.
            let id = self.gameID(forPath: old.path)
            UserDefaults.standard.set(width, forKey: "resW_\(id)")
            UserDefaults.standard.set(height, forKey: "resH_\(id)")

            let notice = UIAlertController(
                title: "Cỡ màn hình",
                message: "Cần khởi động lại JAR để thay đổi độ phân giải.",
                preferredStyle: .alert
            )
            notice.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(notice, animated: true)
        })

        present(alert, animated: true)
    }

    @objc private func showProxyMenu() {
        closeMoreMenu()

        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: "J2MEProxyHost") ?? ""
        let port = defaults.object(forKey: "J2MEProxyPort") as? Int ?? 0
        let enabled = defaults.bool(forKey: "J2MEProxyEnabled")

        let alert = UIAlertController(
            title: "Proxy",
            message: enabled ? "Proxy đang bật." : "Proxy đang tắt.",
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = "Địa chỉ proxy"
            field.text = host
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }

        alert.addTextField { field in
            field.placeholder = "Cổng"
            field.text = port > 0 ? "\(port)" : ""
            field.keyboardType = .numberPad
        }

        alert.addAction(UIAlertAction(title: "Tắt Proxy", style: .destructive) { _ in
            defaults.set(false, forKey: "J2MEProxyEnabled")
            defaults.removeObject(forKey: "J2MEProxyHost")
            defaults.removeObject(forKey: "J2MEProxyPort")
            unsetenv("HTTP_PROXY")
            unsetenv("HTTPS_PROXY")
            unsetenv("ALL_PROXY")
        })

        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))

        alert.addAction(UIAlertAction(title: "Lưu", style: .default) { [weak alert] _ in
            let h = alert?.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let p = Int(alert?.textFields?[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            guard !h.isEmpty, p > 0, p <= 65535 else { return }

            let value = "http://\(h):\(p)"
            defaults.set(true, forKey: "J2MEProxyEnabled")
            defaults.set(h, forKey: "J2MEProxyHost")
            defaults.set(p, forKey: "J2MEProxyPort")

            // Export the conventional proxy variables so networking layers
            // that honor process proxy environment variables use the same
            // configuration immediately.
            setenv("HTTP_PROXY", value, 1)
            setenv("HTTPS_PROXY", value, 1)
            setenv("ALL_PROXY", value, 1)
        })

        present(alert, animated: true)
    }

    @objc private func exitFromMoreMenu() {
        closeMoreMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.backTapped()
        }
    }

    // MARK: - Viewport and keypad layout

    private func buildGameLayout() {

        emulatorView.translatesAutoresizingMaskIntoConstraints =
            false

        emulatorView.backgroundColor =
            .black

        emulatorView.clipsToBounds =
            true

        view.addSubview(
            emulatorView
        )

        keypadView.translatesAutoresizingMaskIntoConstraints =
            false

        keypadView.onKeyEvent =
            { type, code in

                j2me_input_post_key(
                    type,
                    code
                )
            }

        view.addSubview(
            keypadView
        )

        let safe =
            view.safeAreaLayoutGuide

        keypadHeightConstraint =
            keypadView.heightAnchor.constraint(
                equalTo:
                    view.widthAnchor,
                multiplier:
                    0.45,
                constant:
                    50
            )

        keypadHeightConstraint.priority =
            .required

        keypadCollapsedConstraint =
            keypadView.heightAnchor.constraint(
                equalToConstant:
                    0
            )

        keypadCollapsedConstraint.priority =
            .required

        keypadBottomConstraint =
            keypadView.bottomAnchor.constraint(
                equalTo:
                    safe.bottomAnchor,
                constant:
                    -7
            )

        NSLayoutConstraint.activate([

            headerStack.topAnchor.constraint(
                equalTo:
                    safe.topAnchor,
                constant:
                    3
            ),

            headerStack.leadingAnchor.constraint(
                equalTo:
                    view.leadingAnchor,
                constant:
                    8
            ),

            headerStack.trailingAnchor.constraint(
                equalTo:
                    view.trailingAnchor,
                constant:
                    -8
            ),

            headerStack.heightAnchor.constraint(
                equalToConstant:
                    36
            ),

            emulatorView.topAnchor.constraint(
                equalTo:
                    headerStack.bottomAnchor,
                constant:
                    5
            ),

            emulatorView.leadingAnchor.constraint(
                equalTo:
                    view.leadingAnchor
            ),

            emulatorView.trailingAnchor.constraint(
                equalTo:
                    view.trailingAnchor
            ),

            emulatorView.bottomAnchor.constraint(
                equalTo:
                    keypadView.topAnchor,
                constant:
                    -8
            ),

            keypadView.leadingAnchor.constraint(
                equalTo:
                    view.leadingAnchor,
                constant:
                    2
            ),

            keypadView.trailingAnchor.constraint(
                equalTo:
                    view.trailingAnchor,
                constant:
                    -2
            ),

            keypadBottomConstraint,
            keypadHeightConstraint
        ])
    }

    // MARK: - Form and list overlays

    private func buildOverlays() {

        for overlay in [
            formView,
            listView
        ] {

            overlay.translatesAutoresizingMaskIntoConstraints =
                false

            view.addSubview(
                overlay
            )

            NSLayoutConstraint.activate([

                overlay.topAnchor.constraint(
                    equalTo:
                        view.topAnchor
                ),

                overlay.leadingAnchor.constraint(
                    equalTo:
                        view.leadingAnchor
                ),

                overlay.trailingAnchor.constraint(
                    equalTo:
                        view.trailingAnchor
                ),

                overlay.bottomAnchor.constraint(
                    equalTo:
                        view.bottomAnchor
                )
            ])

            overlay.isHidden =
                true
        }
    }

    // MARK: - iOS software keyboard

    private func buildKeyboardInput() {

        keyboardInput.translatesAutoresizingMaskIntoConstraints =
            false

        keyboardInput.alpha =
            0.02

        keyboardInput.keyboardType =
            .default

        keyboardInput.keyboardAppearance =
            .dark

        keyboardInput.autocorrectionType =
            .no

        keyboardInput.spellCheckingType =
            .no

        keyboardInput.smartQuotesType =
            .no

        keyboardInput.smartDashesType =
            .no

        keyboardInput.autocapitalizationType =
            .none

        keyboardInput.returnKeyType =
            .done

        keyboardInput.enablesReturnKeyAutomatically =
            false

        keyboardInput.isSecureTextEntry =
            false

        keyboardInput.onDeleteBackward =
            { [weak self] in

                self?.sendKeyPulse(
                    -8
                )
            }

        keyboardInput.onInsertText =
            { [weak self] text in

                guard let self else {
                    return
                }

                if text == "\n" ||
                    text == "\r" {

                    self.sendKeyPulse(
                        -5
                    )

                    self.hideSystemKeyboard()

                    return
                }

                for scalar in
                    text.unicodeScalars {

                    if scalar.value <=
                        0xFFFF {

                        self.sendKeyPulse(
                            Int32(
                                scalar.value
                            )
                        )
                    }
                }
            }

        view.addSubview(
            keyboardInput
        )

        NSLayoutConstraint.activate([

            keyboardInput.leadingAnchor.constraint(
                equalTo:
                    view.leadingAnchor,
                constant:
                    1
            ),

            keyboardInput.topAnchor.constraint(
                equalTo:
                    headerStack.bottomAnchor,
                constant:
                    1
            ),

            keyboardInput.widthAnchor.constraint(
                equalToConstant:
                    2
            ),

            keyboardInput.heightAnchor.constraint(
                equalToConstant:
                    2
            )
        ])
    }

    // MARK: - Keypad

    @objc private func toggleKeypad() {

        guard !keyboardIsVisible else {
            return
        }

        let show =
            keypadView.isHidden

        setKeypadVisible(
            show
        )
    }

    @objc private func toggleSystemKeyboard() {

        if keyboardInput.isFirstResponder ||
            keyboardIsVisible {

            keyboardInput.resignFirstResponder()
            return
        }

        let becameFirstResponder =
            keyboardInput.becomeFirstResponder()

        guard becameFirstResponder else {

            print(
                "[Keyboard] Could not become first responder"
            )

            return
        }

        keyboardIsVisible =
            true

        keypadBottomConstraint.constant =
            -7

        setKeypadVisible(
            false,
            duration:
                0.18
        )
    }

    private func hideSystemKeyboard() {

        keyboardInput.resignFirstResponder()
    }

    // MARK: - Keyboard frame

    @objc private func handleKeyboardWillChangeFrame(
        _ notification: Notification
    ) {

        guard
            let userInfo =
                notification.userInfo,

            let screenFrame =
                userInfo[
                    UIResponder.keyboardFrameEndUserInfoKey
                ] as? CGRect else {

            return
        }

        let keyboardFrame =
            view.convert(
                screenFrame,
                from: nil
            )

        let intersection =
            view.bounds.intersection(
                keyboardFrame
            )

        let systemKeyboardVisible =
            !intersection.isNull &&
            intersection.width >=
                view.bounds.width * 0.5 &&
            intersection.height > 80

        let duration =
            userInfo[
                UIResponder.keyboardAnimationDurationUserInfoKey
            ] as? Double ?? 0.25

        let curve =
            userInfo[
                UIResponder.keyboardAnimationCurveUserInfoKey
            ] as? UInt ?? 7

        let animationOptions =
            UIView.AnimationOptions(
                rawValue:
                    curve << 16
            ).union(
                .beginFromCurrentState
            )

        let keyboardInset:
            CGFloat

        if systemKeyboardVisible {

            let safeBottom =
                view.safeAreaLayoutGuide
                    .layoutFrame.maxY

            keyboardInset =
                max(
                    0,
                    safeBottom -
                        keyboardFrame.minY
                )

        } else {

            keyboardInset =
                0
        }

        keypadBottomConstraint.constant =
            -(keyboardInset + 7)

        if systemKeyboardVisible {

            keyboardIsVisible =
                true

            setKeypadVisible(
                false,
                duration:
                    duration,
                animationOptions:
                    animationOptions
            )

        } else {

            keyboardIsVisible =
                false

            if isCanvasScreenVisible &&
                !userRequestedExit {

                setKeypadVisible(
                    true,
                    duration:
                        duration,
                    animationOptions:
                        animationOptions
                )

            } else {

                UIView.animate(
                    withDuration:
                        duration,
                    delay:
                        0,
                    options:
                        animationOptions,
                    animations: {

                        self.view.layoutIfNeeded()
                    }
                )
            }
        }
    }

    @objc private func handleKeyboardWillHide(
        _ notification: Notification
    ) {

        keyboardIsVisible =
            false

        keypadBottomConstraint.constant =
            -7

        let duration =
            notification.userInfo?[
                UIResponder.keyboardAnimationDurationUserInfoKey
            ] as? Double ?? 0.25

        let curve =
            notification.userInfo?[
                UIResponder.keyboardAnimationCurveUserInfoKey
            ] as? UInt ?? 7

        let animationOptions =
            UIView.AnimationOptions(
                rawValue:
                    curve << 16
            ).union(
                .beginFromCurrentState
            )

        if isCanvasScreenVisible &&
            !userRequestedExit {

            setKeypadVisible(
                true,
                duration:
                    duration,
                animationOptions:
                    animationOptions
            )

        } else {

            UIView.animate(
                withDuration:
                    duration,
                delay:
                    0,
                options:
                    animationOptions,
                animations: {

                    self.view.layoutIfNeeded()
                }
            )
        }
    }

    private func setKeypadVisible(
        _ visible: Bool,
        duration:
            TimeInterval = 0.18,
        animationOptions:
            UIView.AnimationOptions =
                [.beginFromCurrentState]
    ) {

        let shouldShow =
            visible &&
            !keyboardIsVisible &&
            !userRequestedExit

        keypadView.isHidden =
            !shouldShow

        keypadHeightConstraint.isActive =
            shouldShow

        keypadCollapsedConstraint.isActive =
            !shouldShow

        // The keyboard icon follows the J2ME UI appearance instead of
        // forcing white in Light mode.
        toggleKeypadButton.tintColor =
            shouldShow
            ? uiPrimaryTextColor
            : .systemGreen

        let changes = {

            self.view.layoutIfNeeded()
        }

        if duration <= 0 {

            UIView.performWithoutAnimation {

                changes()
            }

        } else {

            UIView.animate(
                withDuration:
                    duration,
                delay:
                    0,
                options:
                    animationOptions,
                animations:
                    changes
            )
        }
    }

    private func sendKeyPulse(
        _ code: Int32
    ) {

        j2me_input_post_key(
            Int32(
                J2ME_INPUT_KEY_PRESSED
            ),
            code
        )

        j2me_input_post_key(
            Int32(
                J2ME_INPUT_KEY_RELEASED
            ),
            code
        )
    }

    // MARK: - Game lifecycle

    private func startGame() {
        let initialIcon = appIcon
        let initialName = appName
        let initialPath = jarPath
        let initialWidth = canvasWidth
        let initialHeight = canvasHeight
        let initialScale = render3dScale
        let initialFPS = fpsLimit

        addRunningJar(
            path: initialPath,
            name: initialName,
            icon: initialIcon,
            canvasWidth: initialWidth,
            canvasHeight: initialHeight,
            render3dScale: initialScale,
            fpsLimit: initialFPS
        )
    }

    // MARK: - MiniJVM launch

    private func runMIDlet() -> Int {

        guard let resourceRoot =
            Bundle.main.resourcePath else {

            return -100
        }

        let fm =
            FileManager.default

        for file in [
            "minijvm_rt.jar",
            "j2me_api.jar"
        ] {

            let path =
                (resourceRoot as NSString)
                    .appendingPathComponent(
                        file
                    )

            guard fm.fileExists(
                atPath:
                    path
            ) else {

                print(
                    "[JVM] Required runtime missing: \(path)"
                )

                return -101
            }
        }

        guard fm.fileExists(
            atPath:
                jarPath
        ) else {

            return -102
        }

        let docs =
            NSSearchPathForDirectoriesInDomains(
                .documentDirectory,
                .userDomainMask,
                true
            ).first
            ?? NSTemporaryDirectory()

        let baseName =
            URL(fileURLWithPath: jarPath)
                .deletingPathExtension()
                .lastPathComponent

        let gameID =
            baseName.replacingOccurrences(
                of:
                    "[^a-zA-Z0-9._-]",
                with:
                    "_",
                options:
                    .regularExpression
            )

        let saveRoot =
            (docs as NSString)
                .appendingPathComponent(
                    "Games Data/\(gameID)"
                )

        do {

            try fm.createDirectory(
                atPath:
                    saveRoot,
                withIntermediateDirectories:
                    true
            )

        } catch {

            print(
                "[JVM] Cannot create save directory: \(error)"
            )

            return -103
        }

        lastJVMLogPath =
            (saveRoot as NSString)
                .appendingPathComponent(
                    "minijvm.log"
                )

        lastJVMLog = ""

        try? fm.removeItem(
            atPath:
                lastJVMLogPath
        )

        print(
            "[JVM] Resource root: \(resourceRoot)"
        )

        print(
            "[JVM] MIDlet JAR: \(jarPath)"
        )

        print(
            "[JVM] Virtual resolution: \(canvasWidth)x\(canvasHeight)"
        )

        print(
            "[JVM] Diagnostic log: \(lastJVMLogPath)"
        )

        let fpsDescription =
            fpsLimit == 0
            ? "Unlimited"
            : "\(fpsLimit) FPS display"

        print(
            "[JVM] Display FPS: \(fpsDescription)"
        )

        //
        // IMPORTANT:
        //
        // Pass 0 for the MiniJVM FPS parameter.
        //
        // The Java runtime must NOT be throttled.
        //
        // This is what prevents animated GIF / Canvas
        // code from becoming stuck when 30 FPS is selected.
        //
        let initResult =
            jvm_bridge_init(
                resourceRoot,
                saveRoot,
                jarPath,
                Int32(canvasWidth),
                Int32(canvasHeight),
                Int32(render3dScale),
                0
            )

        guard initResult == 0 else {

            print(
                "[JVM] jvm_bridge_init failed: \(initResult)"
            )

            loadJVMLog()

            return Int(
                initResult
            )
        }

        let runResult =
            jvm_bridge_run_midlet(
                jarPath
            )

        print(
            "[JVM] jvm_bridge_run_midlet returned: \(runResult)"
        )

        jvm_bridge_destroy()

        loadJVMLog()

        return Int(
            runResult
        )
    }

    // MARK: - Diagnostic log

    private func loadJVMLog() {

        guard !lastJVMLogPath.isEmpty,
              let data =
                FileManager.default.contents(
                    atPath:
                        lastJVMLogPath
                ),
              let text =
                String(
                    data:
                        data,
                    encoding:
                        .utf8
                ) else {

            lastJVMLog =
                "No MiniJVM log was created."

            return
        }

        lastJVMLog =
            text
    }

    // MARK: - Launch error

    private func showLaunchError(
        _ code: Int
    ) {

        let baseText:
            String

        switch code {

        case -100:
            baseText =
                "Cannot locate the app resource directory."

        case -101:
            baseText =
                "Missing MiniJVM runtime files: minijvm_rt.jar or j2me_api.jar."

        case -102:
            baseText =
                "The selected JAR file no longer exists. Import it again."

        case -103:
            baseText =
                "The game save folder could not be created."

        default:
            baseText =
                "MiniJVM returned error code \(code). The diagnostic log is shown below."
        }

        let message =
            baseText
            + "\n\n"
            + String(
                lastJVMLog.suffix(
                    3500
                )
            )

        let alert =
            UIAlertController(
                title:
                    "Cannot Start Game",
                message:
                    message,
                preferredStyle:
                    .alert
            )

        alert.addAction(
            UIAlertAction(
                title:
                    "Copy Log",
                style:
                    .default
            ) { [weak self] _ in

                UIPasteboard.general.string =
                    self?.lastJVMLog
            }
        )

        alert.addAction(
            UIAlertAction(
                title:
                    "Back",
                style:
                    .cancel
            ) { [weak self] _ in

                self?.dismiss(
                    animated:
                        true
                )
            }
        )

        present(
            alert,
            animated:
                true
        )
    }

    // MARK: - Exit

    @objc private func backTapped() {

        userRequestedExit =
            true

        startupWatchdog?.cancel()
        startupWatchdog = nil

        keyboardInput.resignFirstResponder()

        keyboardIsVisible =
            false

        keypadBottomConstraint.constant =
            -7

        jvm_bridge_session_destroy_all()

        dismiss(animated: true)
    }

    // MARK: - MIDP transitions

    func showCanvasView() {

        emulatorView.isHidden =
            false

        formView.isHidden =
            true

        listView.isHidden =
            true

        setKeypadVisible(
            !keyboardIsVisible,
            duration:
                0
        )
    }

    func showFormView() {

        formView.buildFromNativeData()

        formView.isHidden =
            false

        emulatorView.isHidden =
            true

        keypadView.isHidden =
            true

        keypadHeightConstraint.isActive =
            false

        keypadCollapsedConstraint.isActive =
            true

        listView.isHidden =
            true
    }

    func showListView() {

        listView.buildFromNativeData()

        listView.isHidden =
            false

        emulatorView.isHidden =
            true

        keypadView.isHidden =
            true

        keypadHeightConstraint.isActive =
            false

        keypadCollapsedConstraint.isActive =
            true

        formView.isHidden =
            true
    }

    // MARK: - Alert

    func showAlert() {

        let title =
            String(
                cString:
                    j2me_ui_get_form_title()
            )

        let message =
            String(
                cString:
                    j2me_ui_get_alert_text()
            )

        let alert =
            UIAlertController(
                title:
                    title,
                message:
                    message,
                preferredStyle:
                    .alert
            )

        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let count =
            j2me_ui_get_command_count()

        if count == 0 {

            alert.addAction(
                UIAlertAction(
                    title:
                        "OK",
                    style:
                        .default
                ) { _ in

                    j2me_input_post_key(
                        Int32(
                            J2ME_UI_ALERT_DISMISSED
                        ),
                        0
                    )
                }
            )

        } else {

            for index in
                0..<count {

                let label =
                    String(
                        cString:
                            j2me_ui_get_command_label(
                                Int32(index)
                            )
                    )

                let commandID =
                    j2me_ui_get_command_id(
                        Int32(index)
                    )

                alert.addAction(
                    UIAlertAction(
                        title:
                            label,
                        style:
                            .default
                    ) { _ in

                        j2me_input_post_key(
                            Int32(
                                J2ME_UI_COMMAND_ACTION
                            ),
                            commandID
                        )
                    }
                )
            }
        }

        present(
            alert,
            animated:
                true
        )

        let timeout =
            j2me_ui_get_alert_timeout()

        if timeout > 0 {

            let work =
                DispatchWorkItem {
                    [weak alert] in

                    alert?.dismiss(
                        animated:
                            true
                    ) {

                        j2me_input_post_key(
                            Int32(
                                J2ME_UI_ALERT_DISMISSED
                            ),
                            0
                        )
                    }
                }

            alertTimeoutWork =
                work

            DispatchQueue.main.asyncAfter(
                deadline:
                    .now()
                    + Double(timeout)
                    / 1000.0,
                execute:
                    work
            )
        }
    }
}

private final class J2MEJarPickerCell: UITableViewCell {
    let iconView = UIImageView()
    let nameLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.textColor = .label
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(iconView)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension GameViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        jarPickerItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.row >= 0, indexPath.row < jarPickerItems.count else {
            return UITableViewCell()
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "jar", for: indexPath) as! J2MEJarPickerCell
        let item = jarPickerItems[indexPath.row]
        cell.nameLabel.text = item.name
        cell.iconView.image = item.icon
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row >= 0, indexPath.row < jarPickerItems.count else {
            return
        }

        let item = jarPickerItems[indexPath.row]

        let normalizedPath =
            URL(fileURLWithPath: item.path)
                .standardizedFileURL
                .path

        // If this JAR is already running, keep the picker OPEN and only
        // show a temporary message. This is intentional.
        if runningSessions.contains(where: {
            URL(fileURLWithPath: $0.path)
                .standardizedFileURL
                .path == normalizedPath
        }) {
            showJarPickerMessage("JAR này đang được mở")
            tableView.deselectRow(at: indexPath, animated: true)
            return
        }

        // A normal selection closes the picker immediately.
        closeJarPicker()

        let id = gameID(forPath: item.path)
        let defaults = UserDefaults.standard

        let resolution =
            defaults.object(forKey: "resW_\(id)") as? Int ?? 240
        let resolutionH =
            defaults.object(forKey: "resH_\(id)") as? Int ?? 320
        let fps =
            defaults.object(forKey: "fpsLimit_\(id)") as? Int ?? 0
        let scale =
            defaults.bool(forKey: "ss3d_\(id)") ? 3 : 1

        addRunningJar(
            path: item.path,
            name: item.name,
            icon: item.icon,
            canvasWidth: max(1, resolution),
            canvasHeight: max(1, resolutionH),
            render3dScale: scale,
            fpsLimit: fps
        )
    }

    private func gameID(forPath path: String) -> String {
        URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }
}

// MARK: - Global game controller

private(set) weak var activeGameViewController:
    GameViewController?

let gameUICallback:
    @convention(c) (
        Int32,
        UnsafePointer<CChar>?
    ) -> Void = {

    action,
    data in

    DispatchQueue.main.async {

        guard let controller =
            activeGameViewController else {
            return
        }

        switch action {

        case Int32(
            J2ME_UI_ACTION_SHOW_CANVAS
        ):

            controller.showCanvasView()

        case Int32(
            J2ME_UI_ACTION_SHOW_FORM
        ):

            controller.showFormView()

        case Int32(
            J2ME_UI_ACTION_SHOW_LIST
        ):

            controller.showListView()

        case Int32(
            J2ME_UI_ACTION_SHOW_ALERT
        ):

            controller.showAlert()

        default:
            break
        }
    }
}
