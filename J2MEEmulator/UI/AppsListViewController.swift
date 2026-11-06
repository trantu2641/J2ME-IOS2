//
//  AppsListViewController.swift
//  J2MEEmulator
//
//  Springboard-style home screen with app grid.
//

import UIKit
import UniformTypeIdentifiers

class AppsListViewController: UIViewController,
                      UICollectionViewDataSource,
                      UICollectionViewDelegate,
                      UIDocumentPickerDelegate {

    private var springboardCollectionView: UICollectionView!
    private let emptyStateLabel = UILabel()
    private var lastLayoutWidth: CGFloat = 0

    /// Directory where imported JARs are stored
    private static var gamesDirectory: String {
        documentsDirectory + "/games"
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Animated blob background
        let bg = AnimatedBackgroundView()
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // "+" button — import JAR from Files
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in
                self?.addAppTapped()
            }
        )

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 10

        springboardCollectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: layout
        )

        springboardCollectionView.dataSource = self
        springboardCollectionView.delegate = self
        springboardCollectionView.backgroundColor = .clear
        springboardCollectionView.alwaysBounceVertical = true
        springboardCollectionView.showsVerticalScrollIndicator = false

        springboardCollectionView.register(
            SpringboardCell.self,
            forCellWithReuseIdentifier: SpringboardCell.reuseID
        )

        springboardCollectionView.contentInsetAdjustmentBehavior = .always
        springboardCollectionView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(springboardCollectionView)

        NSLayoutConstraint.activate([
            springboardCollectionView.topAnchor.constraint(equalTo: view.topAnchor),
            springboardCollectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            springboardCollectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            springboardCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Empty state
        emptyStateLabel.text = "No Games Yet\nTap + to add a .jar file"
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.font = .systemFont(ofSize: 17)
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(
                equalTo: view.centerYAnchor,
                constant: -40
            ),
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: 40
            ),
        ])

        // Ensure games directory exists
        try? FileManager.default.createDirectory(
            atPath: Self.gamesDirectory,
            withIntermediateDirectories: true
        )

        scanApps()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        scanApps()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let width = springboardCollectionView.bounds.width

        guard width > 0, width != lastLayoutWidth else {
            return
        }

        lastLayoutWidth = width

        let columns: CGFloat = 4
        let iconSize = SpringboardCell.iconSize
        let cellWidth = (width + iconSize) / (columns + 1)
        let horizontalInset = (cellWidth - iconSize) / 2

        guard let layout = springboardCollectionView.collectionViewLayout
                as? UICollectionViewFlowLayout else {
            return
        }

        layout.itemSize = CGSize(width: cellWidth, height: 96)

        layout.sectionInset = UIEdgeInsets(
            top: 20,
            left: horizontalInset,
            bottom: 20,
            right: horizontalInset
        )
    }

    // ============================================================
    // MARK: - Import JAR from Files
    // ============================================================

    private func addAppTapped() {
        // JAR is a ZIP-based Java archive and is not consistently registered
        // as a system UTType by every Files provider. Use .data and validate
        // the extension after selection.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.data],
            asCopy: true
        )

        picker.delegate = self
        picker.allowsMultipleSelection = true

        present(picker, animated: true)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        let fm = FileManager.default

        let gamesURL = URL(
            fileURLWithPath: Self.gamesDirectory,
            isDirectory: true
        )

        var importedNames: [String] = []
        var failures: [String] = []

        do {
            try fm.createDirectory(
                at: gamesURL,
                withIntermediateDirectories: true
            )
        } catch {
            showImportResult(
                title: "Import Failed",
                message: "Cannot create the games folder. \(error.localizedDescription)"
            )
            return
        }

        for sourceURL in urls {
            let fileName = sourceURL.lastPathComponent

            // Accept both .jar and .JAR.
            guard sourceURL.pathExtension.lowercased() == "jar" else {
                failures.append("\(fileName): not a .jar file")
                continue
            }

            let accessing = sourceURL.startAccessingSecurityScopedResource()

            defer {
                if accessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let destinationURL = gamesURL.appendingPathComponent(fileName)

            let temporaryURL = gamesURL.appendingPathComponent(
                ".import-\(UUID().uuidString).tmp"
            )

            do {
                // Copy to a temporary file first.
                // Existing game is preserved if the new copy fails.
                try fm.copyItem(
                    at: sourceURL,
                    to: temporaryURL
                )

                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }

                try fm.moveItem(
                    at: temporaryURL,
                    to: destinationURL
                )

                importedNames.append(fileName)

                print("[Swift] Imported JAR: \(fileName)")

            } catch {
                try? fm.removeItem(at: temporaryURL)

                failures.append(
                    "\(fileName): \(error.localizedDescription)"
                )

                print("[Swift] Failed to import \(fileName): \(error)")
            }
        }

        if !importedNames.isEmpty {
            scanApps()
        }

        var messageParts: [String] = []

        if !importedNames.isEmpty {
            messageParts.append(
                "Imported \(importedNames.count) JAR file(s):\n"
                + importedNames.joined(separator: "\n")
            )
        }

        if !failures.isEmpty {
            messageParts.append(
                "Could not import:\n"
                + failures.joined(separator: "\n")
            )
        }

        if messageParts.isEmpty {
            messageParts.append("No files were selected.")
        }

        let title = importedNames.isEmpty
            ? "No JAR Imported"
            : "Import Complete"

        showImportResult(
            title: title,
            message: messageParts.joined(separator: "\n\n")
        )
    }

    private func showImportResult(
        title: String,
        message: String
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let alert = UIAlertController(
                title: title,
                message: message,
                preferredStyle: .alert
            )

            alert.addAction(
                UIAlertAction(title: "OK", style: .default)
            )

            self.present(alert, animated: true)
        }
    }

    // ============================================================
    // MARK: - App scanning (Documents/games/)
    // ============================================================

    struct AppInfo {
        let name: String
        let path: String
        let fileName: String
        let version: String?
        let vendor: String?
        let icon: UIImage
    }

    private var apps: [AppInfo] = []

    private func scanApps() {
        let gamesDir = Self.gamesDirectory

        DispatchQueue.global(qos: .userInitiated).async {

            var jarPaths: [(name: String, path: String)] = []

            if let files = try? FileManager.default.contentsOfDirectory(
                atPath: gamesDir
            ) {
                for file in files
                where URL(fileURLWithPath: file)
                    .pathExtension.lowercased() == "jar" {

                    let name = URL(fileURLWithPath: file)
                        .deletingPathExtension()
                        .lastPathComponent

                    jarPaths.append((
                        name: name,
                        path: gamesDir + "/" + file
                    ))
                }
            }

            var unsorted = jarPaths.map {
                jar -> (String, String, String, String?, String?, UIImage?) in

                let meta = JARMetadata.read(from: jar.path)
                let jarIcon = meta?.readIcon(from: jar.path)

                let fileName = URL(fileURLWithPath: jar.path).lastPathComponent
                let appName = meta?.midletName ?? jar.name

                return (
                    appName,
                    jar.path,
                    fileName,
                    meta?.version,
                    meta?.vendor,
                    jarIcon
                )
            }

            unsorted.sort {
                $0.0.localizedCaseInsensitiveCompare($1.0)
                    == .orderedAscending
            }

            let scannedApps = unsorted.enumerated().map { index, item in
                AppInfo(
                    name: item.0,
                    path: item.1,
                    fileName: item.2,
                    version: item.3,
                    vendor: item.4,
                    icon: Self.springboardIcon(
                        item.5,
                        name: item.0,
                        index: index
                    )
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                self.apps = scannedApps
                self.springboardCollectionView.reloadData()
                self.emptyStateLabel.isHidden = !scannedApps.isEmpty

                print(
                    "[Swift] Found \(scannedApps.count) MIDlet JARs in \(gamesDir)"
                )
            }
        }
    }

    // ============================================================
    // MARK: - Icon generation
    // ============================================================

    private static let iconSize: CGFloat = SpringboardCell.iconSize

    private static let placeholderGradients: [(UIColor, UIColor)] = [
        (
            UIColor(red: 0.20, green: 0.40, blue: 0.90, alpha: 1),
            UIColor(red: 0.35, green: 0.60, blue: 1.00, alpha: 1)
        ),
        (
            UIColor(red: 0.00, green: 0.68, blue: 0.63, alpha: 1),
            UIColor(red: 0.20, green: 0.85, blue: 0.60, alpha: 1)
        ),
        (
            UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1),
            UIColor(red: 1.00, green: 0.75, blue: 0.28, alpha: 1)
        ),
        (
            UIColor(red: 0.88, green: 0.22, blue: 0.28, alpha: 1),
            UIColor(red: 1.00, green: 0.42, blue: 0.48, alpha: 1)
        ),
        (
            UIColor(red: 0.58, green: 0.28, blue: 0.85, alpha: 1),
            UIColor(red: 0.72, green: 0.48, blue: 1.00, alpha: 1)
        ),
        (
            UIColor(red: 0.22, green: 0.30, blue: 0.80, alpha: 1),
            UIColor(red: 0.38, green: 0.48, blue: 0.95, alpha: 1)
        ),
        (
            UIColor(red: 0.90, green: 0.28, blue: 0.52, alpha: 1),
            UIColor(red: 1.00, green: 0.48, blue: 0.68, alpha: 1)
        ),
        (
            UIColor(red: 0.15, green: 0.65, blue: 0.42, alpha: 1),
            UIColor(red: 0.28, green: 0.82, blue: 0.55, alpha: 1)
        )
    ]

    private static func springboardIcon(
        _ jarIcon: UIImage?,
        name: String,
        index: Int
    ) -> UIImage {

        let size = CGSize(width: iconSize, height: iconSize)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)

            UIBezierPath(
                roundedRect: rect,
                cornerRadius: SpringboardCell.iconCornerRadius
            ).addClip()

            if let image = jarIcon {
                UIColor(white: 0.22, alpha: 1).setFill()
                UIBezierPath(rect: rect).fill()
                image.draw(in: rect)

            } else {
                let pair = placeholderGradients[
                    index % placeholderGradients.count
                ]

                let cgContext = context.cgContext
                let colorSpace = CGColorSpaceCreateDeviceRGB()

                if let gradient = CGGradient(
                    colorsSpace: colorSpace,
                    colors: [pair.0.cgColor, pair.1.cgColor] as CFArray,
                    locations: [0, 1]
                ) {
                    cgContext.drawLinearGradient(
                        gradient,
                        start: .zero,
                        end: CGPoint(x: iconSize, y: iconSize),
                        options: []
                    )
                }

                let letter = String(name.prefix(1)).uppercased()

                let attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                    .font: UIFont.systemFont(
                        ofSize: iconSize * 0.42,
                        weight: .semibold
                    )
                ]

                let textSize = (letter as NSString)
                    .size(withAttributes: attributes)

                (letter as NSString).draw(
                    at: CGPoint(
                        x: (iconSize - textSize.width) / 2,
                        y: (iconSize - textSize.height) / 2
                    ),
                    withAttributes: attributes
                )
            }

            let borderPath = UIBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                cornerRadius: SpringboardCell.iconCornerRadius - 0.5
            )

            UIColor(white: 1.0, alpha: 0.12).setStroke()
            borderPath.lineWidth = 1
            borderPath.stroke()
        }
    }

    // ============================================================
    // MARK: - UICollectionView
    // ============================================================

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        apps.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: SpringboardCell.reuseID,
            for: indexPath
        ) as! SpringboardCell

        let app = apps[indexPath.item]
        cell.configure(name: app.name, icon: app.icon)

        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {

        guard let indexPath = indexPaths.first else {
            return nil
        }

        let app = apps[indexPath.item]

        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in

            let ssEnabled = Self.is3DSupersampling(for: app)

            let toggle3D = UIAction(
                title: ssEnabled
                    ? "Disable 3D Enhancement"
                    : "Enable 3D Enhancement",
                subtitle: ssEnabled
                    ? "Lower quality, but closer to original"
                    : "Smoother 3D, but not original-accurate",
                image: UIImage(systemName: "cube"),
                state: ssEnabled ? .on : .off
            ) { _ in
                Self.set3DSupersampling(!ssEnabled, for: app)
            }

            let clearData = UIAction(
                title: "Clear Game Data",
                image: UIImage(systemName: "eraser")
            ) { _ in
                self?.confirmClearGameData(for: app)
            }

            let delete = UIAction(
                title: "Delete",
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self?.confirmDeleteApp(at: indexPath)
            }

            let currentRes = Self.resolution(for: app)

            let resActions = Self.resolutionOptions.map { option in
                UIAction(
                    title: option.label,
                    state: (
                        option.w == currentRes.w
                        && option.h == currentRes.h
                    ) ? .on : .off
                ) { _ in
                    Self.setResolution(
                        w: option.w,
                        h: option.h,
                        for: app
                    )
                }
            }

            let customResolution = UIAction(
                title: "Custom Resolution...",
                image: UIImage(systemName: "slider.horizontal.3")
            ) { [weak self] _ in
                self?.promptCustomResolution(for: app)
            }

            let resMenu = UIMenu(
                title: "Screen Resolution",
                image: UIImage(systemName: "aspectratio"),
                children: resActions + [customResolution]
            )

            let currentFps = Self.fpsLimit(for: app)

            let fpsActions = Self.fpsLimitOptions.map { option in
                UIAction(
                    title: option.label,
                    state: option.value == currentFps ? .on : .off
                ) { _ in
                    Self.setFpsLimit(option.value, for: app)
                }
            }

            let fpsMenu = UIMenu(
                title: "FPS Limit",
                subtitle: "High FPS may break some games",
                image: UIImage(systemName: "gauge.with.needle"),
                children: fpsActions
            )

            let settings = UIMenu(
                options: .displayInline,
                children: [toggle3D, resMenu, fpsMenu]
            )

            let actions = UIMenu(
                options: .displayInline,
                children: [clearData, delete]
            )

            return UIMenu(children: [settings, actions])
        })
    }

    // ============================================================
    // MARK: - Per-game settings
    // ============================================================

    private static func gameId(for app: AppInfo) -> String {
        let jarName = URL(
            fileURLWithPath: app.path
        ).deletingPathExtension().lastPathComponent

        return jarName.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]",
            with: "_",
            options: .regularExpression
        )
    }

    static func is3DSupersampling(for app: AppInfo) -> Bool {
        UserDefaults.standard.object(
            forKey: "ss3d_\(gameId(for: app))"
        ) as? Bool ?? true
    }

    static func set3DSupersampling(_ enabled: Bool, for app: AppInfo) {
        UserDefaults.standard.set(
            enabled,
            forKey: "ss3d_\(gameId(for: app))"
        )
    }

    private static let resolutionOptions: [(label: String, w: Int, h: Int)] = [
        ("101×80",   101,  80),
        ("128×128",  128, 128),
        ("128×160",  128, 160),
        ("132×176",  132, 176),
        ("160×128",  160, 128),
        ("176×208",  176, 208),
        ("176×220",  176, 220),
        ("208×208",  208, 208),
        ("220×220",  220, 220),
        ("240×266",  240, 266),
        ("240×320",  240, 320),
        ("240×400",  240, 400),
        ("320×480",  320, 480),
        ("352×416",  352, 416),
        ("360×640",  360, 640),
        ("480×800",  480, 800)
    ]

    static func resolution(for app: AppInfo) -> (w: Int, h: Int) {
        let gameID = gameId(for: app)

        let width = UserDefaults.standard.object(
            forKey: "resW_\(gameID)"
        ) as? Int ?? 240

        let height = UserDefaults.standard.object(
            forKey: "resH_\(gameID)"
        ) as? Int ?? 320

        return (width, height)
    }

    private static func setResolution(
        w: Int,
        h: Int,
        for app: AppInfo
    ) {
        let gameID = gameId(for: app)

        UserDefaults.standard.set(w, forKey: "resW_\(gameID)")
        UserDefaults.standard.set(h, forKey: "resH_\(gameID)")
    }

    private static let fpsLimitOptions: [(label: String, value: Int)] = [
        ("Unlimited", 0),
        ("15 FPS", 15),
        ("20 FPS", 20),
        ("30 FPS", 30),
        ("60 FPS", 60)
    ]

    static func fpsLimit(for app: AppInfo) -> Int {
        UserDefaults.standard.object(
            forKey: "fpsLimit_\(gameId(for: app))"
        ) as? Int ?? 60
    }

    private static func setFpsLimit(
        _ fps: Int,
        for app: AppInfo
    ) {
        UserDefaults.standard.set(
            fps,
            forKey: "fpsLimit_\(gameId(for: app))"
        )
    }

    private static var documentsDirectory: String {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!.path
    }

    // ============================================================
    // MARK: - Custom resolution
    // ============================================================

    private func promptCustomResolution(for app: AppInfo) {
        let current = Self.resolution(for: app)

        let alert = UIAlertController(
            title: "Custom J2ME Resolution",
            message: "Enter the virtual screen width and height.",
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.placeholder = "Width"
            field.keyboardType = .numberPad
            field.text = "\(current.w)"
        }

        alert.addTextField { field in
            field.placeholder = "Height"
            field.keyboardType = .numberPad
            field.text = "\(current.h)"
        }

        alert.addAction(
            UIAlertAction(title: "Cancel", style: .cancel)
        )

        alert.addAction(
            UIAlertAction(title: "Apply", style: .default) { [weak self] _ in

                guard let fields = alert.textFields,
                      fields.count == 2,
                      let widthText = fields[0].text,
                      let heightText = fields[1].text,
                      let width = Int(widthText),
                      let height = Int(heightText),
                      (1...4096).contains(width),
                      (1...4096).contains(height) else {

                    let error = UIAlertController(
                        title: "Invalid Resolution",
                        message: "Width and height must be between 1 and 4096.",
                        preferredStyle: .alert
                    )

                    error.addAction(
                        UIAlertAction(title: "OK", style: .default)
                    )

                    self?.present(error, animated: true)
                    return
                }

                Self.setResolution(
                    w: width,
                    h: height,
                    for: app
                )
            }
        )

        present(alert, animated: true)
    }

    // ============================================================
    // MARK: - Clear and delete
    // ============================================================

    private func confirmClearGameData(for app: AppInfo) {
        let alert = UIAlertController(
            title: "Clear Game Data",
            message: "Delete all save data for \(app.name)?",
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(title: "Cancel", style: .cancel)
        )

        alert.addAction(
            UIAlertAction(title: "Clear", style: .destructive) { _ in
                let gid = Self.gameId(for: app)

                try? FileManager.default.removeItem(
                    atPath: Self.documentsDirectory + "/Games Data/" + gid
                )
            }
        )

        present(alert, animated: true)
    }

    private func confirmDeleteApp(at indexPath: IndexPath) {
        let app = apps[indexPath.item]

        let alert = UIAlertController(
            title: "Delete Game",
            message: "Delete \(app.name) and all its save data?",
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(title: "Cancel", style: .cancel)
        )

        alert.addAction(
            UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in

                guard let self else { return }

                let gid = Self.gameId(for: app)

                try? FileManager.default.removeItem(
                    atPath: Self.documentsDirectory + "/Games Data/" + gid
                )

                try? FileManager.default.removeItem(
                    atPath: app.path
                )

                self.springboardCollectionView.performBatchUpdates {
                    self.apps.remove(at: indexPath.item)
                    self.springboardCollectionView.deleteItems(at: [indexPath])
                }

                self.emptyStateLabel.isHidden = !self.apps.isEmpty
            }
        )

        present(alert, animated: true)
    }

    // ============================================================
    // MARK: - Launch game
    // ============================================================

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {
        let app = apps[indexPath.item]

        let render3dScale = Self.is3DSupersampling(for: app) ? 3 : 1
        let res = Self.resolution(for: app)
        let fps = Self.fpsLimit(for: app)

        let gameVC = GameViewController(
            jarPath: app.path,
            appName: app.name,
            appIcon: app.icon,
            canvasWidth: res.w,
            canvasHeight: res.h,
            render3dScale: render3dScale,
            fpsLimit: fps
        )

        gameVC.modalPresentationStyle = .fullScreen

        let itemIndex = indexPath.item

        // Zoom transition is available on iOS 18 and later only.
        // iOS 16.4 and iOS 17 use standard full-screen presentation.
        if #available(iOS 18.0, *) {
            let options = UIViewController.Transition.ZoomOptions()
            options.interactiveDismissShouldBegin = { _ in false }

            options.alignmentRectProvider = { context in
                guard let gvc = context.zoomedViewController as? GameViewController,
                      let placeholder = gvc.placeholderIconView else {
                    return .null
                }

                return placeholder.frame
            }

            gameVC.preferredTransition = .zoom(options: options) {
                [weak self] _ in

                guard let self,
                      let cell = self.springboardCollectionView.cellForItem(
                        at: IndexPath(item: itemIndex, section: 0)
                      ) as? SpringboardCell else {
                    return nil
                }

                return cell.iconView
            }
        }

        present(gameVC, animated: true)
    }
}
