//
// GameViewController.swift
// J2ME portrait game screen with keyboard input,
// framebuffer viewport, multi-session tabs, and background audio keep-alive.
//

import UIKit
import AVFoundation
import UniformTypeIdentifiers

// Kết nối trực tiếp tới hàm trong j2me_render.m mà không cần sửa Bridging Header
@_silgen_name("j2me_render_set_background_mode")
private func j2me_render_set_background_mode(_ isBackground: Int32)

// Bộ phát âm thanh im lặng giữ cho ứng dụng không bị iOS đóng băng khi tắt màn hình / ẩn app
private final class J2MEBackgroundAudioKeeper {
    static let shared = J2MEBackgroundAudioKeeper()
    private var audioPlayer: AVAudioPlayer?
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let wavData = makeSilentWAVData(durationSeconds: 1.0, sampleRate: 8000)
            let player = try AVAudioPlayer(data: wavData)
            player.numberOfLoops = -1
            player.volume = 0.0
            player.prepareToPlay()
            player.play()

            self.audioPlayer = player
            self.isRunning = true
            print("[BackgroundKeeper] Started silent audio keep-alive")
        } catch {
            print("[BackgroundKeeper] Failed to start audio session: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        audioPlayer?.stop()
        audioPlayer = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        print("[BackgroundKeeper] Stopped silent audio keep-alive")
    }

    private func makeSilentWAVData(durationSeconds: Double, sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let numSamples = Int(Double(sampleRate) * durationSeconds)
        let subchunk2Size = UInt32(numSamples * Int(blockAlign))
        let chunkSize = 36 + subchunk2Size

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian) { Array($0) })
        data.append(Data(count: Int(subchunk2Size)))
        return data
    }
}

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

private final class J2MEKeyboardInputView: UIView, UIKeyInput {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .default
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextDashesType = .no
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

    func insertText(_ text: String) { onInsertText?(text) }
    func deleteBackward() { onDeleteBackward?() }
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
    private let tabScrollView = UIScrollView()
    private let tabStack = UIStackView()
    private let addJarButton = UIButton(type: .system)
    private let removeJarButton = UIButton(type: .system)

    private var runningSessions: [J2MERunningSession] = []
    private var activeSessionIndex = 0
    private var jarPickerOverlay: UIView?
    private var jarPickerPanel: UIView?
    private var jarPickerTableView: UITableView?
    private var jarPickerItems: [(name: String, path: String, icon: UIImage)] = []
    private var jarPickerMessageLabel: UILabel?
    private var jarPickerMessageWork: DispatchWorkItem?
    private var activeJarPickerContextMenu: UIMenu?

    private enum JarPickerDocumentPurpose {
        case importJAR
        case customIcon(String)
    }
    private var jarPickerDocumentPurpose: JarPickerDocumentPurpose?

    private let toggleKeypadButton = UIButton(type: .system)
    private let systemKeyboardButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)

    private var moreMenuOverlay: UIView?
    private var moreMenuPanel: UIView?

    private let keyboardInput = J2MEKeyboardInputView(frame: .zero)

    private var keypadHeightConstraint: NSLayoutConstraint!
    private var keypadCollapsedConstraint: NSLayoutConstraint!
    private var keypadBottomConstraint: NSLayoutConstraint!

    private var keyboardIsVisible = false

    private var isCanvasScreenVisible: Bool {
        !emulatorView.isHidden && formView.isHidden && listView.isHidden
    }

    private var gameStarted = false
    private var userRequestedExit = false

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
        fpsLimit: Int = 0
    ) {
        self.jarPath = jarPath
        self.appName = appName
        self.appIcon = appIcon
        self.canvasWidth = min(max(1, canvasWidth), 4096)
        self.canvasHeight = min(max(1, canvasHeight), 4096)
        self.render3dScale = max(1, render3dScale)

        let supportedFPS = [0, 15, 20, 30, 45]
        self.fpsLimit = supportedFPS.contains(fpsLimit) ? fpsLimit : 0

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

        J2MEBackgroundAudioKeeper.shared.stop()
        j2me_render_set_background_mode(0)

        setGlobalEmulatorView(nil)
        jvm_bridge_session_destroy_all()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? .black : .systemBackground
        }

        if UserDefaults.standard.bool(forKey: "J2MEKeepScreenOn") {
            UIApplication.shared.isIdleTimerDisabled = true
        }

        emulatorView.canvasWidth = canvasWidth
        emulatorView.canvasHeight = canvasHeight
        emulatorView.setDisplayFPS(fpsLimit)

        buildHeader()
        buildGameLayout()
        buildKeyboardInput()
        buildOverlays()

        let iconView = UIImageView(image: appIcon)
        iconView.contentMode = .center
        iconView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: emulatorView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: emulatorView.centerYAnchor)
        ])

        placeholderIconView = iconView

        emulatorView.onFirstFrame = { [weak self] in
            guard let self, let icon = self.placeholderIconView else { return }
            self.startupWatchdog?.cancel()
            self.startupWatchdog = nil

            UIView.animate(withDuration: 0.2, animations: {
                icon.alpha = 0
            }, completion: { _ in
                icon.removeFromSuperview()
                self.placeholderIconView = nil
            })
        }

        setGlobalEmulatorView(emulatorView)

        j2me_render_set_fps_limit(0)
        j2me_render_set_flush_ready_callback(flushReadyCallback)
        j2me_render_set_flush_callback(flushCallback)
        j2me_ui_set_callback(gameUICallback)

        activeGameViewController = self

        // Theo dõi vòng đời App (tắt màn hình / ẩn xuống nền) để bật âm thanh giữ sống & giảm FPS render
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !gameStarted else { return }
        gameStarted = true
        startGame()
    }

    // MARK: - Background Keep-Alive Handlers

    @objc private func handleAppDidEnterBackground() {
        guard !userRequestedExit, !runningSessions.isEmpty else { return }
        j2me_render_set_background_mode(1)
        J2MEBackgroundAudioKeeper.shared.start()
    }

    @objc private func handleAppWillEnterForeground() {
        j2me_render_set_background_mode(0)
        J2MEBackgroundAudioKeeper.shared.stop()
    }

    // MARK: - Interface style

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
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }

        rebuildTabs()
        toggleKeypadButton.tintColor = uiPrimaryTextColor
        systemKeyboardButton.tintColor = uiPrimaryTextColor
        addJarButton.tintColor = uiPrimaryTextColor
        removeJarButton.tintColor = uiPrimaryTextColor
        moreButton.tintColor = uiPrimaryTextColor
    }

    // MARK: - Header

    private func buildHeader() {
        configureHeaderButton(addJarButton, symbol: "plus", accessibility: "Add JAR")
        configureHeaderButton(removeJarButton, symbol: "minus", accessibility: "Close current JAR")
        configureHeaderButton(toggleKeypadButton, symbol: "keyboard", accessibility: "Show or hide game keypad")
        configureHeaderButton(systemKeyboardButton, symbol: "text.cursor", accessibility: "Show or hide iPhone keyboard")
        configureHeaderButton(moreButton, symbol: "ellipsis", accessibility: "More options")

        addJarButton.addTarget(self, action: #selector(addJarTapped), for: .touchUpInside)
        removeJarButton.addTarget(self, action: #selector(removeCurrentJarTapped), for: .touchUpInside)
        toggleKeypadButton.addTarget(self, action: #selector(toggleKeypad), for: .touchUpInside)
        systemKeyboardButton.addTarget(self, action: #selector(toggleSystemKeyboard), for: .touchUpInside)
        moreButton.addTarget(self, action: #selector(showMoreMenu), for: .touchUpInside)

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

    private func configureHeaderButton(_ button: UIButton, symbol: String, accessibility: String) {
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium, scale: .medium)
        button.setImage(UIImage(systemName: symbol, withConfiguration: symbolConfiguration), for: .normal)
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
            button.setTitleColor(index == activeSessionIndex ? .white : uiPrimaryTextColor, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            button.backgroundColor = index == activeSessionIndex ? UIColor.systemBlue : uiControlBackgroundColor
            button.layer.cornerRadius = 9
            button.accessibilityLabel = "JAR \(index + 1): \(session.name)"
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
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
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let base = URL(fileURLWithPath: jarPath).deletingPathExtension().lastPathComponent
        let gameID = base.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
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
            try FileManager.default.createDirectory(atPath: saveRoot, withIntermediateDirectories: true)
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
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let id = gameID(forPath: url.path)
                let defaults = UserDefaults.standard
                let savedDisplayName = defaults.string(forKey: "jarbox_display_name_\(id)")?.trimmingCharacters(in: .whitespacesAndNewlines)
                let metadata = JARMetadata.read(from: url.path)

                let name: String
                if let savedDisplayName, !savedDisplayName.isEmpty {
                    name = savedDisplayName
                } else {
                    name = metadata?.midletName ?? url.deletingPathExtension().lastPathComponent
                }

                let customIconURL = iconsDir.appendingPathComponent("\(id).png")
                let customIcon = UIImage(contentsOfFile: customIconURL.path)
                let icon = customIcon ?? metadata?.readIcon(from: url.path) ?? UIImage(systemName: "gamecontroller")!

                return (name: name, path: url.path, icon: icon)
            }
    }

    private func showJarPickerMessage(_ text: String) {
        jarPickerMessageWork?.cancel()
        jarPickerMessageLabel?.removeFromSuperview()

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

        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 20),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            label.heightAnchor.constraint(equalToConstant: 38)
        ])

        jarPickerMessageLabel = label

        UIView.animate(withDuration: 0.12) { label.alpha = 1 }

        let work = DispatchWorkItem { [weak self, weak label] in
            guard let self, let label else { return }
            UIView.animate(withDuration: 0.15, animations: { label.alpha = 0 }, completion: { _ in
                label.removeFromSuperview()
                if self.jarPickerMessageLabel === label { self.jarPickerMessageLabel = nil }
            })
        }

        jarPickerMessageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    @objc private func addJarTapped() {
        showJarPicker()
    }

    private func showJarPicker() {
        if jarPickerOverlay != nil { return }

        let overlay = UIControl()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.28 : 0.18)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.addTarget(self, action: #selector(closeJarPicker), for: .touchUpInside)

        let panel = UIView()
        panel.backgroundColor = uiPanelBackgroundColor
        panel.layer.cornerRadius = 20
        panel.layer.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "DANH SÁCH JAR"
        title.textColor = uiPrimaryTextColor
        title.font = .systemFont(ofSize: 19, weight: .semibold)
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
        exit.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
        exit.contentHorizontalAlignment = .center
        exit.backgroundColor = .clear
        exit.addTarget(self, action: #selector(closeJarPicker), for: .touchUpInside)
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
        jarPickerItems.removeAll(keepingCapacity: false)
        table.reloadData()

        overlay.alpha = 0
        panel.alpha = 0
        panel.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)

        UIView.animate(withDuration: 0.16) {
            overlay.alpha = 1
            panel.alpha = 1
            panel.transform = .identity
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak table, weak overlay] in
            guard let self else { return }
            let items = self.scanInstalledJARs()

            DispatchQueue.main.async {
                guard let table, let overlay, overlay.superview != nil, self.jarPickerTableView === table else { return }
                self.jarPickerItems = items
                table.reloadData()
            }
        }
    }

    // MARK: - JAR-list long-press menu

    private var jarPickerDocumentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func jarPickerCustomIconURL(for id: String) -> URL {
        jarPickerDocumentsURL
            .appendingPathComponent("Game Icons", isDirectory: true)
            .appendingPathComponent("\(id).png")
    }

    private func makeJarPickerContextMenu(for item: (name: String, path: String, icon: UIImage)) -> UIMenu {
        let id = gameID(forPath: item.path)
        let defaults = UserDefaults.standard
        let fm = FileManager.default
        let hasCustomIcon = fm.fileExists(atPath: jarPickerCustomIconURL(for: id).path)

        let importJAR = UIAction(title: "Thêm tệp JAR", image: UIImage(systemName: "doc.badge.plus")) { [weak self] _ in
            self?.presentJarDocumentPicker(for: .importJAR)
        }

        let rename = UIAction(title: "Đổi tên", image: UIImage(systemName: "pencil")) { [weak self] _ in
            self?.renameJarPickerItem(item)
        }

        let changeIcon = UIAction(title: "Đổi biểu tượng...", image: UIImage(systemName: "photo")) { [weak self] _ in
            self?.presentJarDocumentPicker(for: .customIcon(id))
        }

        var manageActions: [UIMenuElement] = [rename, changeIcon]
        if hasCustomIcon {
            let resetIcon = UIAction(title: "Khôi phục biểu tượng gốc", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                self?.resetJarPickerCustomIcon(for: item)
            }
            manageActions.append(resetIcon)
        }

        let duplicate = UIAction(title: "Sao chép JAR", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.duplicateJarPickerItem(item)
        }
        manageActions.append(duplicate)

        let manageMenu = UIMenu(title: "Quản lý JAR", image: UIImage(systemName: "app"), children: manageActions)

        let threeDEnabled = defaults.bool(forKey: "ss3d_\(id)")
        let toggle3D = UIAction(
            title: threeDEnabled ? "Tắt tăng cường 3D" : "Bật tăng cường 3D",
            image: UIImage(systemName: "cube"),
            state: threeDEnabled ? .on : .off
        ) { _ in
            defaults.set(!threeDEnabled, forKey: "ss3d_\(id)")
        }

        let currentWidth = defaults.object(forKey: "resW_\(id)") as? Int ?? 320
        let currentHeight = defaults.object(forKey: "resH_\(id)") as? Int ?? 400
        let resolutionOptions: [(label: String, width: Int, height: Int)] = [
            ("320×400", 320, 400),
            ("330×360", 330, 360),
            ("360×450", 360, 450),
            ("400×500", 400, 500)
        ]
        let resolutionActions = resolutionOptions.map { option in
            UIAction(
                title: option.label,
                state: option.width == currentWidth && option.height == currentHeight ? .on : .off
            ) { _ in
                defaults.set(option.width, forKey: "resW_\(id)")
                defaults.set(option.height, forKey: "resH_\(id)")
            }
        }
        let customResolution = UIAction(title: "Độ phân giải tùy chỉnh...", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
            self?.promptJarPickerCustomResolution(for: item)
        }
        let resolutionMenu = UIMenu(title: "Độ phân giải màn hình", image: UIImage(systemName: "aspectratio"), children: resolutionActions + [customResolution])

        let savedFPS = defaults.object(forKey: "fpsLimit_\(id)") as? Int ?? 30
        let fpsOptions: [(label: String, value: Int)] = [
            ("Không giới hạn", 0),
            ("15 FPS", 15),
            ("20 FPS", 20),
            ("30 FPS", 30),
            ("45 FPS", 45)
        ]
        let fpsActions = fpsOptions.map { option in
            UIAction(title: option.label, state: option.value == savedFPS ? .on : .off) { _ in
                defaults.set(option.value, forKey: "fpsLimit_\(id)")
            }
        }
        let fpsMenu = UIMenu(title: "Giới hạn FPS", image: UIImage(systemName: "speedometer"), children: fpsActions)

        let clearData = UIAction(title: "Xóa dữ liệu trò chơi", image: UIImage(systemName: "eraser")) { [weak self] _ in
            self?.confirmClearJarPickerData(for: item)
        }
        let deleteJAR = UIAction(title: "Xóa JAR", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmDeleteJarPickerItem(for: item)
        }
        let destructiveActions = UIMenu(options: .displayInline, children: [clearData, deleteJAR])

        return UIMenu(children: [importJAR, toggle3D, manageMenu, resolutionMenu, fpsMenu, destructiveActions])
    }

    private func presentJarDocumentPicker(for purpose: JarPickerDocumentPurpose) {
        jarPickerDocumentPurpose = purpose
        let contentTypes: [UTType]
        switch purpose {
        case .importJAR: contentTypes = [.data]
        case .customIcon(_): contentTypes = [.image]
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = {
            if case .importJAR = purpose { return true }
            return false
        }()

        DispatchQueue.main.async { [weak self] in
            self?.present(picker, animated: true)
        }
    }

    private func renameJarPickerItem(_ item: (name: String, path: String, icon: UIImage)) {
        let alert = UIAlertController(title: "Đổi tên JAR", message: "Tên mới sẽ được hiển thị trong danh sách JAR.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = item.name
            field.placeholder = "Tên JAR"
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Lưu", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text else { return }
            let newName = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            let id = self.gameID(forPath: item.path)
            UserDefaults.standard.set(newName, forKey: "jarbox_display_name_\(id)")
            self.refreshJarPickerItems()
            self.refreshUnderlyingHomeList()
        })
        DispatchQueue.main.async { [weak self] in self?.present(alert, animated: true) }
    }

    private func resetJarPickerCustomIcon(for item: (name: String, path: String, icon: UIImage)) {
        let id = gameID(forPath: item.path)
        try? FileManager.default.removeItem(at: jarPickerCustomIconURL(for: id))
        refreshJarPickerItems()
        refreshUnderlyingHomeList()
    }

    private func duplicateJarPickerItem(_ item: (name: String, path: String, icon: UIImage)) {
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: item.path)
        guard fm.fileExists(atPath: sourceURL.path) else {
            showJarPickerOperationResult(title: "Không thể sao chép JAR", message: "Tệp JAR gốc không còn tồn tại.")
            return
        }

        let gamesURL = jarPickerDocumentsURL.appendingPathComponent("games", isDirectory: true)
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.isEmpty ? "jar" : sourceURL.pathExtension
        let destinationURL = gamesURL.appendingPathComponent("\(stem)__copy_\(UUID().uuidString).\(ext)")

        do {
            try fm.createDirectory(at: gamesURL, withIntermediateDirectories: true)
            try fm.copyItem(at: sourceURL, to: destinationURL)

            let oldID = gameID(forPath: item.path)
            let newID = gameID(forPath: destinationURL.path)
            let existingNames = Set(jarPickerItems.map { $0.name })
            let baseName = "\(item.name) (Copy)"
            var displayName = baseName
            var suffix = 2
            while existingNames.contains(displayName) {
                displayName = "\(baseName) \(suffix)"
                suffix += 1
            }
            UserDefaults.standard.set(displayName, forKey: "jarbox_display_name_\(newID)")

            let oldIconURL = jarPickerCustomIconURL(for: oldID)
            let newIconURL = jarPickerCustomIconURL(for: newID)
            if fm.fileExists(atPath: oldIconURL.path) {
                try fm.createDirectory(at: newIconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: oldIconURL, to: newIconURL)
            }

            for prefix in ["ss3d_", "resW_", "resH_", "fpsLimit_"] {
                if let value = UserDefaults.standard.object(forKey: prefix + oldID) {
                    UserDefaults.standard.set(value, forKey: prefix + newID)
                }
            }

            refreshJarPickerItems()
            refreshUnderlyingHomeList()
            showJarPickerOperationResult(
                title: "Đã sao chép JAR",
                message: "\(displayName) đã được thêm vào danh sách. Dữ liệu lưu trò chơi được giữ riêng."
            )
        } catch {
            showJarPickerOperationResult(title: "Sao chép thất bại", message: error.localizedDescription)
        }
    }

    private func promptJarPickerCustomResolution(for item: (name: String, path: String, icon: UIImage)) {
        let id = gameID(forPath: item.path)
        let defaults = UserDefaults.standard
        let alert = UIAlertController(title: "Độ phân giải JAR tùy chỉnh", message: "Nhập chiều rộng và chiều cao Canvas.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Rộng"
            field.keyboardType = .numberPad
            field.text = "\(defaults.object(forKey: "resW_\(id)") as? Int ?? 320)"
        }
        alert.addTextField { field in
            field.placeholder = "Cao"
            field.keyboardType = .numberPad
            field.text = "\(defaults.object(forKey: "resH_\(id)") as? Int ?? 400)"
        }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Áp dụng", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            guard let fields = alert?.textFields, fields.count == 2,
                  let width = Int(fields[0].text ?? ""),
                  let height = Int(fields[1].text ?? ""),
                  (1...4096).contains(width), (1...4096).contains(height) else {
                self.showJarPickerOperationResult(title: "Độ phân giải không hợp lệ", message: "Chiều rộng và chiều cao phải từ 1 đến 4096.")
                return
            }
            defaults.set(width, forKey: "resW_\(id)")
            defaults.set(height, forKey: "resH_\(id)")
        })
        DispatchQueue.main.async { [weak self] in self?.present(alert, animated: true) }
    }

    private func confirmClearJarPickerData(for item: (name: String, path: String, icon: UIImage)) {
        let id = gameID(forPath: item.path)
        let alert = UIAlertController(title: "Xóa dữ liệu trò chơi", message: "Xóa toàn bộ dữ liệu lưu của \(item.name)?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Xóa dữ liệu", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let saveURL = self.jarPickerDocumentsURL
                .appendingPathComponent("Games Data", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.removeItem(at: saveURL)
        })
        DispatchQueue.main.async { [weak self] in self?.present(alert, animated: true) }
    }

    private func confirmDeleteJarPickerItem(for item: (name: String, path: String, icon: UIImage)) {
        let alert = UIAlertController(title: "Xóa JAR", message: "Xóa \(item.name) và toàn bộ dữ liệu lưu của trò chơi này?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Xóa JAR", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let id = self.gameID(forPath: item.path)
            let saveURL = self.jarPickerDocumentsURL
                .appendingPathComponent("Games Data", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            try? FileManager.default.removeItem(at: saveURL)
            try? FileManager.default.removeItem(atPath: item.path)
            try? FileManager.default.removeItem(at: self.jarPickerCustomIconURL(for: id))
            for key in ["jarbox_display_name_\(id)", "ss3d_\(id)", "resW_\(id)", "resH_\(id)", "fpsLimit_\(id)"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            self.refreshJarPickerItems()
            self.refreshUnderlyingHomeList()
        })
        DispatchQueue.main.async { [weak self] in self?.present(alert, animated: true) }
    }

    private func refreshJarPickerItems() {
        guard let table = jarPickerTableView else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak table] in
            guard let self else { return }
            let items = self.scanInstalledJARs()
            DispatchQueue.main.async {
                guard let table, table.superview != nil, self.jarPickerTableView === table else { return }
                self.jarPickerItems = items
                table.reloadData()
            }
        }
    }

    private func refreshUnderlyingHomeList() {
        NotificationCenter.default.post(name: Notification.Name("J2MEExternalJARChange"), object: nil)
        var current: UIViewController? = self
        while let controller = current {
            if let appsList = controller as? AppsListViewController {
                appsList.refreshAfterExternalJARChange()
                return
            }
            if let presented = controller.presentedViewController, presented !== self {
                if let appsList = findAppsListViewController(in: presented) {
                    appsList.refreshAfterExternalJARChange()
                    return
                }
            }
            current = controller.presentingViewController
        }
    }

    private func findAppsListViewController(in controller: UIViewController) -> AppsListViewController? {
        if let appsList = controller as? AppsListViewController { return appsList }
        if let navigation = controller as? UINavigationController {
            for child in navigation.viewControllers.reversed() {
                if let appsList = findAppsListViewController(in: child) { return appsList }
            }
        }
        if let tabBar = controller as? UITabBarController {
            for child in tabBar.viewControllers ?? [] {
                if let appsList = findAppsListViewController(in: child) { return appsList }
            }
        }
        for child in controller.children.reversed() {
            if let appsList = findAppsListViewController(in: child) { return appsList }
        }
        return nil
    }

    private func showJarPickerOperationResult(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.presentedViewController == nil {
                self.present(alert, animated: true)
            } else {
                self.presentedViewController?.present(alert, animated: true)
            }
        }
    }

    private func importJARFilesFromPicker(_ urls: [URL]) {
        let fm = FileManager.default
        let gamesURL = jarPickerDocumentsURL.appendingPathComponent("games", isDirectory: true)
        var imported: [String] = []
        var failures: [String] = []

        do {
            try fm.createDirectory(at: gamesURL, withIntermediateDirectories: true)
        } catch {
            showJarPickerOperationResult(title: "Nhập JAR thất bại", message: error.localizedDescription)
            return
        }

        for sourceURL in urls {
            let fileName = sourceURL.lastPathComponent
            guard sourceURL.pathExtension.lowercased() == "jar" else {
                failures.append("\(fileName): không phải tệp .jar")
                continue
            }

            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessing { sourceURL.stopAccessingSecurityScopedResource() } }

            let originalURL = gamesURL.appendingPathComponent(fileName)
            let destinationURL: URL
            if !fm.fileExists(atPath: originalURL.path) {
                destinationURL = originalURL
            } else {
                let sourceName = URL(fileURLWithPath: fileName)
                let stem = sourceName.deletingPathExtension().lastPathComponent
                let ext = sourceName.pathExtension.isEmpty ? "jar" : sourceName.pathExtension
                destinationURL = gamesURL.appendingPathComponent("\(stem)__install_\(UUID().uuidString).\(ext)")
            }

            let temporaryURL = gamesURL.appendingPathComponent(".import-\(UUID().uuidString).tmp")
            do {
                try fm.copyItem(at: sourceURL, to: temporaryURL)
                try fm.moveItem(at: temporaryURL, to: destinationURL)
                imported.append(destinationURL.lastPathComponent)
            } catch {
                try? fm.removeItem(at: temporaryURL)
                failures.append("\(fileName): \(error.localizedDescription)")
            }
        }

        if !imported.isEmpty {
            refreshJarPickerItems()
            refreshUnderlyingHomeList()
        }
        var resultParts: [String] = []
        if !imported.isEmpty { resultParts.append("Đã nhập \(imported.count) tệp JAR:\n" + imported.joined(separator: "\n")) }
        if !failures.isEmpty { resultParts.append("Không thể nhập:\n" + failures.joined(separator: "\n")) }
        if resultParts.isEmpty { resultParts.append("Bạn chưa chọn tệp nào.") }
        showJarPickerOperationResult(title: imported.isEmpty ? "Không có JAR được nhập" : "Nhập JAR hoàn tất", message: resultParts.joined(separator: "\n\n"))
    }

    private func saveJarPickerCustomIcon(from url: URL, for id: String) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data),
              let pngData = image.pngData() else {
            showJarPickerOperationResult(title: "Lỗi biểu tượng", message: "Không thể đọc ảnh đã chọn.")
            return
        }

        let destinationURL = jarPickerCustomIconURL(for: id)
        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pngData.write(to: destinationURL, options: .atomic)
            refreshJarPickerItems()
            refreshUnderlyingHomeList()
        } catch {
            showJarPickerOperationResult(title: "Lỗi biểu tượng", message: error.localizedDescription)
        }
    }

    @objc private func closeJarPicker() {
        guard jarPickerOverlay != nil || jarPickerPanel != nil || jarPickerTableView != nil else { return }

        jarPickerMessageWork?.cancel()
        jarPickerMessageWork = nil
        jarPickerMessageLabel?.removeFromSuperview()
        jarPickerMessageLabel = nil

        if let table = jarPickerTableView {
            table.delegate = nil
            table.dataSource = nil
            table.removeFromSuperview()
        }
        jarPickerTableView = nil
        jarPickerItems.removeAll(keepingCapacity: false)

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

        let alert = UIAlertController(title: nil, message: "Bạn có muốn đóng cửa sổ không", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Đóng", style: .destructive) { [weak self] _ in
            guard let self, !self.runningSessions.isEmpty else { return }

            let session = self.runningSessions[self.activeSessionIndex]
            jvm_bridge_session_request_stop(session.id)
            jvm_bridge_session_destroy(session.id)
            self.runningSessions.remove(at: self.activeSessionIndex)

            if self.runningSessions.isEmpty {
                self.userRequestedExit = true
                J2MEBackgroundAudioKeeper.shared.stop()
                j2me_render_set_background_mode(0)
                self.dismiss(animated: true)
                return
            }

            self.activeSessionIndex = min(self.activeSessionIndex, self.runningSessions.count - 1)
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
        overlay.backgroundColor = UIColor.black.withAlphaComponent(traitCollection.userInterfaceStyle == .dark ? 0.28 : 0.18)
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

        stack.addArrangedSubview(makeMoreMenuButton(title: "Ẩn ứng dụng", color: .systemBlue, action: #selector(hideApplicationFromMenu)))
        stack.addArrangedSubview(makeMoreMenuButton(
            title: UIApplication.shared.isIdleTimerDisabled ? "✓ Treo tắt màn" : "Treo tắt màn",
            color: .systemBlue,
            action: #selector(toggleKeepScreenOnFromMenu)
        ))
        stack.addArrangedSubview(makeMoreMenuButton(title: "Cỡ màn hình", color: .systemBlue, action: #selector(showScreenSizeMenu)))
        stack.addArrangedSubview(makeMoreMenuButton(title: "Proxy", color: .systemBlue, action: #selector(showProxyMenu)))
        stack.addArrangedSubview(makeMoreMenuButton(title: "Thoát", color: .systemRed, action: #selector(exitFromMoreMenu)))
        stack.addArrangedSubview(makeMoreMenuButton(title: "Hủy", color: .systemBlue, action: #selector(closeMoreMenu)))

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

    private func makeMoreMenuButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(color, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .regular)
        button.contentHorizontalAlignment = .center
        button.heightAnchor.constraint(equalToConstant: 58).isActive = true
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
        // Kích hoạt ngay background keep-alive trước khi ẩn ứng dụng xuống nền
        j2me_render_set_background_mode(1)
        J2MEBackgroundAudioKeeper.shared.start()

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
        let alert = UIAlertController(title: "Cỡ màn hình", message: "Nhập độ phân giải Canvas cho JAR hiện tại.", preferredStyle: .alert)

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
                  width > 0, height > 0, width <= 4096, height <= 4096 else { return }

            let old = self.runningSessions[self.activeSessionIndex]
            let id = self.gameID(forPath: old.path)
            UserDefaults.standard.set(width, forKey: "resW_\(id)")
            UserDefaults.standard.set(height, forKey: "resH_\(id)")

            let notice = UIAlertController(title: "Cỡ màn hình", message: "Cần khởi động lại JAR để thay đổi độ phân giải.", preferredStyle: .alert)
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

        let alert = UIAlertController(title: "Proxy", message: enabled ? "Proxy đang bật." : "Proxy đang tắt.", preferredStyle: .alert)

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
        emulatorView.translatesAutoresizingMaskIntoConstraints = false
        emulatorView.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? .black : .systemBackground
        }
        emulatorView.clipsToBounds = true
        view.addSubview(emulatorView)

        keypadView.translatesAutoresizingMaskIntoConstraints = false
        keypadView.onKeyEvent = { type, code in
            j2me_input_post_key(type, code)
        }
        view.addSubview(keypadView)

        let safe = view.safeAreaLayoutGuide

        keypadHeightConstraint = keypadView.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.45, constant: 50)
        keypadHeightConstraint.priority = .required

        keypadCollapsedConstraint = keypadView.heightAnchor.constraint(equalToConstant: 0)
        keypadCollapsedConstraint.priority = .required

        keypadBottomConstraint = keypadView.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -7)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: safe.topAnchor, constant: 3),
            headerStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            headerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            headerStack.heightAnchor.constraint(equalToConstant: 36),

            emulatorView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 5),
            emulatorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emulatorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emulatorView.bottomAnchor.constraint(equalTo: keypadView.topAnchor, constant: -8),

            keypadView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            keypadView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            keypadBottomConstraint,
            keypadHeightConstraint
        ])
    }

    // MARK: - Form and list overlays

    private func buildOverlays() {
        for overlay in [formView, listView] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: view.topAnchor),
                overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
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
            guard let self else { return }
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
            keyboardInput.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            keyboardInput.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 1),
            keyboardInput.widthAnchor.constraint(equalToConstant: 2),
            keyboardInput.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    // MARK: - Keypad

    @objc private func toggleKeypad() {
        guard !keyboardIsVisible else { return }
        setKeypadVisible(keypadView.isHidden)
    }

    @objc private func toggleSystemKeyboard() {
        if keyboardInput.isFirstResponder || keyboardIsVisible {
            keyboardInput.resignFirstResponder()
            return
        }

        guard keyboardInput.becomeFirstResponder() else { return }
        keyboardIsVisible = true
        keypadBottomConstraint.constant = -7
        setKeypadVisible(false, duration: 0.18)
    }

    private func hideSystemKeyboard() {
        keyboardInput.resignFirstResponder()
    }

    // MARK: - Keyboard frame

    @objc private func handleKeyboardWillChangeFrame(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let screenFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

        let keyboardFrame = view.convert(screenFrame, from: nil)
        let intersection = view.bounds.intersection(keyboardFrame)

        let systemKeyboardVisible = !intersection.isNull &&
            intersection.width >= view.bounds.width * 0.5 &&
            intersection.height > 80

        let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let animationOptions = UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)

        let keyboardInset: CGFloat
        if systemKeyboardVisible {
            let safeBottom = view.safeAreaLayoutGuide.layoutFrame.maxY
            keyboardInset = max(0, safeBottom - keyboardFrame.minY)
        } else {
            keyboardInset = 0
        }

        keypadBottomConstraint.constant = -(keyboardInset + 7)

        if systemKeyboardVisible {
            keyboardIsVisible = true
            setKeypadVisible(false, duration: duration, animationOptions: animationOptions)
        } else {
            keyboardIsVisible = false
            if isCanvasScreenVisible && !userRequestedExit {
                setKeypadVisible(true, duration: duration, animationOptions: animationOptions)
            } else {
                UIView.animate(withDuration: duration, delay: 0, options: animationOptions) {
                    self.view.layoutIfNeeded()
                }
            }
        }
    }

    @objc private func handleKeyboardWillHide(_ notification: Notification) {
        keyboardIsVisible = false
        keypadBottomConstraint.constant = -7

        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        let animationOptions = UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)

        if isCanvasScreenVisible && !userRequestedExit {
            setKeypadVisible(true, duration: duration, animationOptions: animationOptions)
        } else {
            UIView.animate(withDuration: duration, delay: 0, options: animationOptions) {
                self.view.layoutIfNeeded()
            }
        }
    }

    private func setKeypadVisible(
        _ visible: Bool,
        duration: TimeInterval = 0.18,
        animationOptions: UIView.AnimationOptions = [.beginFromCurrentState]
    ) {
        let shouldShow = visible && !keyboardIsVisible && !userRequestedExit
        keypadView.isHidden = !shouldShow
        keypadHeightConstraint.isActive = shouldShow
        keypadCollapsedConstraint.isActive = !shouldShow
        toggleKeypadButton.tintColor = uiPrimaryTextColor

        let changes = { self.view.layoutIfNeeded() }
        if duration <= 0 {
            UIView.performWithoutAnimation { changes() }
        } else {
            UIView.animate(withDuration: duration, delay: 0, options: animationOptions, animations: changes)
        }
    }

    private func sendKeyPulse(_ code: Int32) {
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
    }

    // MARK: - Game lifecycle

    private func startGame() {
        addRunningJar(
            path: jarPath,
            name: appName,
            icon: appIcon,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            render3dScale: render3dScale,
            fpsLimit: fpsLimit
        )
    }

    // MARK: - Exit

    @objc private func backTapped() {
        userRequestedExit = true
        startupWatchdog?.cancel()
        startupWatchdog = nil

        keyboardInput.resignFirstResponder()
        keyboardIsVisible = false
        keypadBottomConstraint.constant = -7

        J2MEBackgroundAudioKeeper.shared.stop()
        j2me_render_set_background_mode(0)

        jvm_bridge_session_destroy_all()
        dismiss(animated: true)
    }

    // MARK: - MIDP transitions

    func showCanvasView() {
        emulatorView.isHidden = false
        formView.isHidden = true
        listView.isHidden = true
        setKeypadVisible(!keyboardIsVisible, duration: 0)
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

    // MARK: - Alert

    func showAlert() {
        let title = String(cString: j2me_ui_get_form_title())
        let message = String(cString: j2me_ui_get_alert_text())

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let count = j2me_ui_get_command_count()
        if count == 0 {
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                j2me_input_post_key(Int32(J2ME_UI_ALERT_DISMISSED), 0)
            })
        } else {
            for index in 0..<count {
                let label = String(cString: j2me_ui_get_command_label(Int32(index)))
                let commandID = j2me_ui_get_command_id(Int32(index))
                alert.addAction(UIAlertAction(title: label, style: .default) { _ in
                    j2me_input_post_key(Int32(J2ME_UI_COMMAND_ACTION), commandID)
                })
            }
        }

        present(alert, animated: true)

        let timeout = j2me_ui_get_alert_timeout()
        if timeout > 0 {
            let work = DispatchWorkItem { [weak alert] in
                alert?.dismiss(animated: true) {
                    j2me_input_post_key(Int32(J2ME_UI_ALERT_DISMISSED), 0)
                }
            }
            alertTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeout) / 1000.0, execute: work)
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
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 58)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension GameViewController: UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        jarPickerItems.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "jar", for: indexPath) as! J2MEJarPickerCell
        guard indexPath.row >= 0, indexPath.row < jarPickerItems.count else { return cell }
        let item = jarPickerItems[indexPath.row]
        cell.nameLabel.text = item.name
        cell.iconView.image = item.icon
        return cell
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard tableView === jarPickerTableView,
              indexPath.row >= 0,
              indexPath.row < jarPickerItems.count else { return nil }

        let item = jarPickerItems[indexPath.row]
        let identifier = NSString(string: gameID(forPath: item.path))
        return UIContextMenuConfiguration(
            identifier: identifier,
            previewProvider: nil,
            actionProvider: { [weak self] _ in
                guard let self else { return nil }
                let menu = self.makeJarPickerContextMenu(for: item)
                self.activeJarPickerContextMenu = menu
                return menu
            }
        )
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let items = jarPickerItems
        guard indexPath.row >= 0, indexPath.row < items.count else { return }
        let item = items[indexPath.row]

        let normalizedPath = URL(fileURLWithPath: item.path).standardizedFileURL.path
        if runningSessions.contains(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == normalizedPath }) {
            showJarPickerMessage("JAR này đang được mở")
            tableView.deselectRow(at: indexPath, animated: true)
            return
        }

        closeJarPicker()

        let id = gameID(forPath: item.path)
        let defaults = UserDefaults.standard

        let resolution = defaults.object(forKey: "resW_\(id)") as? Int ?? 320
        let resolutionH = defaults.object(forKey: "resH_\(id)") as? Int ?? 400
        let fps = defaults.object(forKey: "fpsLimit_\(id)") as? Int ?? 0
        let scale = defaults.bool(forKey: "ss3d_\(id)") ? 3 : 1

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

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let purpose = jarPickerDocumentPurpose else { return }
        jarPickerDocumentPurpose = nil

        switch purpose {
        case .importJAR:
            importJARFilesFromPicker(urls)
        case .customIcon(let id):
            guard let selectedURL = urls.first else { return }
            saveJarPickerCustomIcon(from: selectedURL, for: id)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        jarPickerDocumentPurpose = nil
    }

    private func gameID(forPath path: String) -> String {
        URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }
}

// MARK: - Global game controller

private(set) weak var activeGameViewController: GameViewController?

let gameUICallback: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { action, data in
    DispatchQueue.main.async {
        guard let controller = activeGameViewController else { return }
        switch action {
        case Int32(J2ME_UI_ACTION_SHOW_CANVAS): controller.showCanvasView()
        case Int32(J2ME_UI_ACTION_SHOW_FORM): controller.showFormView()
        case Int32(J2ME_UI_ACTION_SHOW_LIST): controller.showListView()
        case Int32(J2ME_UI_ACTION_SHOW_ALERT): controller.showAlert()
        default: break
        }
    }
}
