
//
//  AppsListViewController.swift
//  JarBox
//
//  JAR launcher with rename, custom icon and duplicate install.
//

import UIKit
import UniformTypeIdentifiers

class AppsListViewController: UIViewController,
                              UICollectionViewDataSource,
                              UICollectionViewDelegate,
                              UIDocumentPickerDelegate {

    // MARK: - Views

    private var springboardCollectionView: UICollectionView!
    private let emptyStateLabel = UILabel()
    private var lastLayoutWidth: CGFloat = 0

    private var animatedBackgroundView: AnimatedBackgroundView?

    // MARK: - Toolbar

    private var duplicateInstallBarButtonItem: UIBarButtonItem!

    // When this value is not nil, the document picker is selecting an icon.
    // Otherwise, it is importing JAR files.
    private var pendingIconAppID: String?

    // MARK: - App data

    struct AppInfo {
        let name: String
        let path: String
        let fileName: String
        let version: String?
        let vendor: String?
        let icon: UIImage
    }

    private var allApps: [AppInfo] = []
    private var apps: [AppInfo] = []

    // MARK: - Directories

    private static var documentsDirectory: String {
        FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!.path
    }

    private static var gamesDirectory: String {
        documentsDirectory + "/games"
    }

    private static var iconsDirectory: String {
        documentsDirectory + "/Game Icons"
    }

    // MARK: - UserDefaults keys

    private static func gameId(forPath path: String) -> String {
        let name = URL(fileURLWithPath: path)
            .deletingPathExtension()
            .lastPathComponent

        return name.replacingOccurrences(
            of: "[^a-zA-Z0-9._-]",
            with: "_",
            options: .regularExpression
        )
    }

    private static func gameId(for app: AppInfo) -> String {
        gameId(forPath: app.path)
    }

    private static func displayNameKey(_ id: String) -> String {
        "jarbox_display_name_\(id)"
    }

    private static func customIconPath(for id: String) -> String {
        iconsDirectory + "/\(id).png"
    }

    private static func hasCustomIcon(for app: AppInfo) -> Bool {
        FileManager.default.fileExists(
            atPath: customIconPath(for: gameId(for: app))
        )
    }

    // MARK: - View controller

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black

        setupBackground()
        setupToolbar()
        setupCollectionView()
        setupEmptyState()
        createDirectories()

        scanApps()
    }

    private func setupBackground() {
        let background = AnimatedBackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false

        animatedBackgroundView = background

        view.addSubview(background)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupToolbar() {

        let addButton = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in
                self?.addAppTapped()
            }
        )

        addButton.accessibilityLabel = "Import JAR"

        duplicateInstallBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(duplicateInstalledJARTapped)
        )

        duplicateInstallBarButtonItem.accessibilityLabel =
            "Install another copy of a JAR"

        navigationItem.rightBarButtonItems = [
            addButton,
            duplicateInstallBarButtonItem
        ]
    }

    private func setupCollectionView() {

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
            springboardCollectionView.topAnchor.constraint(
                equalTo: view.topAnchor
            ),
            springboardCollectionView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor
            ),
            springboardCollectionView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor
            ),
            springboardCollectionView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor
            )
        ])
    }

    private func setupEmptyState() {

        emptyStateLabel.text = "No Games Yet\nTap + to add a .jar file"
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.font = .systemFont(ofSize: 17)
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(
                equalTo: view.centerXAnchor
            ),
            emptyStateLabel.centerYAnchor.constraint(
                equalTo: view.centerYAnchor,
                constant: -40
            ),
            emptyStateLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: 40
            )
        ])
    }

    private func createDirectories() {

        try? FileManager.default.createDirectory(
            atPath: Self.gamesDirectory,
            withIntermediateDirectories: true
        )

        try? FileManager.default.createDirectory(
            atPath: Self.iconsDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Background lifecycle

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        animatedBackgroundView?.resumeAnimations()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        animatedBackgroundView?.pauseAnimations()
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

        layout.itemSize = CGSize(
            width: cellWidth,
            height: 96
        )

        layout.sectionInset = UIEdgeInsets(
            top: 20,
            left: horizontalInset,
            bottom: 20,
            right: horizontalInset
        )
    }

    // MARK: - Import JAR

    private func addAppTapped() {

        pendingIconAppID = nil

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

        // Icon selection mode.
        if let appID = pendingIconAppID {

            pendingIconAppID = nil

            guard let imageURL = urls.first else {
                return
            }

            saveCustomIcon(
                from: imageURL,
                for: appID
            )

            return
        }

        // Normal JAR import mode.
        importJARFiles(urls)
    }

    func documentPickerWasCancelled(
        _ controller: UIDocumentPickerViewController
    ) {
        pendingIconAppID = nil
    }

    private func importJARFiles(_ urls: [URL]) {

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

            // Never overwrite an existing JAR.
            // Re-importing an identical filename creates a new installation.
            let destinationURL = uniqueJARDestination(
                for: fileName,
                in: gamesURL
            )

            let temporaryURL = gamesURL.appendingPathComponent(
                ".import-\(UUID().uuidString).tmp"
            )

            do {

                try fm.copyItem(
                    at: sourceURL,
                    to: temporaryURL
                )

                try fm.moveItem(
                    at: temporaryURL,
                    to: destinationURL
                )

                importedNames.append(destinationURL.lastPathComponent)

                print("[Swift] Imported JAR: \(destinationURL.lastPathComponent)")

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

        showImportResult(
            title: importedNames.isEmpty
                ? "No JAR Imported"
                : "Import Complete",
            message: messageParts.joined(separator: "\n\n")
        )
    }

    // Returns the original name if available.
    // If it already exists, creates a different internal installation name.
    private func uniqueJARDestination(
        for fileName: String,
        in directory: URL
    ) -> URL {

        let original = directory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(
            atPath: original.path
        ) else {
            return original
        }

        let originalURL = URL(fileURLWithPath: fileName)
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension.isEmpty
            ? "jar"
            : originalURL.pathExtension

        let uniqueName = "\(stem)__install_\(UUID().uuidString).\(ext)"

        return directory.appendingPathComponent(uniqueName)
    }

    // MARK: - Import result

    private func showImportResult(
        title: String,
        message: String
    ) {

        DispatchQueue.main.async { [weak self] in

            guard let self else {
                return
            }

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

    // MARK: - Scan installed JARs

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

            let unsorted = jarPaths.map {
                jar -> (
                    String,
                    String,
                    String,
                    String?,
                    String?,
                    UIImage?
                ) in

                let meta = JARMetadata.read(from: jar.path)
                let jarIcon = meta?.readIcon(from: jar.path)

                let fileName = URL(
                    fileURLWithPath: jar.path
                ).lastPathComponent

                let appName = meta?.midletName ?? jar.name

                return (
                    appName,
                    jar.path,
                    fileName,
                    meta?.version,
                    meta?.vendor,
                    jarIcon
                )

            }.sorted {
                $0.0.localizedCaseInsensitiveCompare($1.0)
                    == .orderedAscending
            }

            let scannedApps = unsorted.enumerated().map {
                index, item -> AppInfo in

                let id = Self.gameId(forPath: item.1)

                let savedName = UserDefaults.standard.string(
                    forKey: Self.displayNameKey(id)
                )

                let displayName: String

                if let savedName,
                   !savedName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                   ).isEmpty {
                    displayName = savedName
                } else {
                    displayName = item.0
                }

                let customIcon = UIImage(
                    contentsOfFile: Self.customIconPath(for: id)
                )

                let finalIcon = Self.springboardIcon(
                    customIcon ?? item.5,
                    name: displayName,
                    index: index
                )

                return AppInfo(
                    name: displayName,
                    path: item.1,
                    fileName: item.2,
                    version: item.3,
                    vendor: item.4,
                    icon: finalIcon
                )
            }

            DispatchQueue.main.async { [weak self] in

                guard let self else {
                    return
                }

                // All installed JARs are shown.
                // There is no hidden-JAR filter anymore.
                self.allApps = scannedApps
                self.apps = scannedApps

                self.springboardCollectionView.reloadData()

                self.updateEmptyState()

                print(
                    "[Swift] Found \(scannedApps.count) JAR installations"
                )
            }
        }
    }

    private func updateEmptyState() {

        if allApps.isEmpty {

            emptyStateLabel.text =
                "No Games Yet\nTap + to add a .jar file"
        }

        emptyStateLabel.isHidden = !apps.isEmpty
    }

    // MARK: - Duplicate installation

    // This button is outside the app grid.
    // It lets the user select an installed JAR and create another installation.
    @objc private func duplicateInstalledJARTapped() {

        guard !allApps.isEmpty else {

            showImportResult(
                title: "No JAR Installed",
                message: "Import a JAR before creating another installation."
            )

            return
        }

        let alert = UIAlertController(
            title: "Install Another Copy",
            message: "Choose the JAR you want to install again.",
            preferredStyle: .actionSheet
        )

        let sortedApps = allApps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }

        for app in sortedApps {

            let title = "\(app.name)  [\(app.fileName)]"

            alert.addAction(
                UIAlertAction(
                    title: title,
                    style: .default
                ) { [weak self] _ in

                    self?.duplicateApp(app)
                }
            )
        }

        alert.addAction(
            UIAlertAction(
                title: "Cancel",
                style: .cancel
            )
        )

        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = duplicateInstallBarButtonItem
        }

        present(alert, animated: true)
    }

    private func duplicateApp(_ app: AppInfo) {

        let fm = FileManager.default

        let sourceURL = URL(fileURLWithPath: app.path)

        guard fm.fileExists(atPath: sourceURL.path) else {

            showImportResult(
                title: "Cannot Duplicate",
                message: "The original JAR file no longer exists."
            )

            return
        }

        let gamesURL = URL(
            fileURLWithPath: Self.gamesDirectory,
            isDirectory: true
        )

        let originalStem = sourceURL
            .deletingPathExtension()
            .lastPathComponent

        let extensionName = sourceURL.pathExtension.isEmpty
            ? "jar"
            : sourceURL.pathExtension

        let uniqueName =
            "\(originalStem)__copy_\(UUID().uuidString).\(extensionName)"

        let destinationURL = gamesURL.appendingPathComponent(uniqueName)

        do {

            try fm.createDirectory(
                at: gamesURL,
                withIntermediateDirectories: true
            )

            // Copy only the JAR itself.
            // Do not copy RMS/account data from the original installation.
            try fm.copyItem(
                at: sourceURL,
                to: destinationURL
            )

            let oldID = Self.gameId(for: app)
            let newID = Self.gameId(forPath: destinationURL.path)

            let newDisplayName = uniqueDisplayName(
                basedOn: "\(app.name) (Copy)"
            )

            UserDefaults.standard.set(
                newDisplayName,
                forKey: Self.displayNameKey(newID)
            )

            // Keep a custom icon on the duplicated installation.
            let oldIconURL = URL(
                fileURLWithPath: Self.customIconPath(for: oldID)
            )

            let newIconURL = URL(
                fileURLWithPath: Self.customIconPath(for: newID)
            )

            if fm.fileExists(atPath: oldIconURL.path) {

                try? fm.createDirectory(
                    at: newIconURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                try? fm.copyItem(
                    at: oldIconURL,
                    to: newIconURL
                )
            }

            // Copy display/per-game configuration,
            // but deliberately keep saved game data separate.
            Self.copyGameSettings(
                from: oldID,
                to: newID
            )

            scanApps()

            showImportResult(
                title: "Installation Created",
                message:
                    "\(newDisplayName) was installed as a separate copy.\n\n"
                    + "It has its own save data and account."
            )

        } catch {

            showImportResult(
                title: "Duplicate Failed",
                message: error.localizedDescription
            )
        }
    }

    private func uniqueDisplayName(basedOn base: String) -> String {

        let existingNames = Set(allApps.map { $0.name })

        if !existingNames.contains(base) {
            return base
        }

        var index = 2

        while existingNames.contains("\(base) \(index)") {
            index += 1
        }

        return "\(base) \(index)"
    }

    private static func copyGameSettings(
        from oldID: String,
        to newID: String
    ) {

        let defaults = UserDefaults.standard

        let keys = [
            "ss3d_",
            "resW_",
            "resH_",
            "fpsLimit_"
        ]

        for prefix in keys {

            let oldKey = prefix + oldID
            let newKey = prefix + newID

            if let value = defaults.object(forKey: oldKey) {
                defaults.set(value, forKey: newKey)
            }
        }
    }

    // MARK: - Rename JAR

    private func renameApp(_ app: AppInfo) {

        let alert = UIAlertController(
            title: "Rename JAR",
            message: "Change the name shown on the home screen.",
            preferredStyle: .alert
        )

        alert.addTextField { field in
            field.text = app.name
            field.placeholder = "JAR name"
            field.clearButtonMode = .whileEditing
        }

        alert.addAction(
            UIAlertAction(
                title: "Cancel",
                style: .cancel
            )
        )

        alert.addAction(
            UIAlertAction(
                title: "Save",
                style: .default
            ) { [weak self] _ in

                guard let self,
                      let text = alert.textFields?.first?.text else {
                    return
                }

                let newName = text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

                guard !newName.isEmpty else {
                    return
                }

                let id = Self.gameId(for: app)

                UserDefaults.standard.set(
                    newName,
                    forKey: Self.displayNameKey(id)
                )

                self.scanApps()
            }
        )

        present(alert, animated: true)
    }

    // MARK: - Custom icon

    private func changeIcon(for app: AppInfo) {

        pendingIconAppID = Self.gameId(for: app)

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.image],
            asCopy: true
        )

        picker.delegate = self
        picker.allowsMultipleSelection = false

        present(picker, animated: true)
    }

    private func saveCustomIcon(
        from imageURL: URL,
        for appID: String
    ) {

        let accessing = imageURL.startAccessingSecurityScopedResource()

        defer {
            if accessing {
                imageURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: imageURL),
              let image = UIImage(data: data),
              let pngData = image.pngData() else {

            showImportResult(
                title: "Icon Error",
                message: "The selected image could not be opened."
            )

            return
        }

        let iconDirectory = URL(
            fileURLWithPath: Self.iconsDirectory,
            isDirectory: true
        )

        let destinationURL = URL(
            fileURLWithPath: Self.customIconPath(for: appID)
        )

        do {

            try FileManager.default.createDirectory(
                at: iconDirectory,
                withIntermediateDirectories: true
            )

            try pngData.write(
                to: destinationURL,
                options: .atomic
            )

            scanApps()

        } catch {

            showImportResult(
                title: "Icon Error",
                message: error.localizedDescription
            )
        }
    }

    private func resetCustomIcon(for app: AppInfo) {

        let id = Self.gameId(for: app)

        try? FileManager.default.removeItem(
            atPath: Self.customIconPath(for: id)
        )

        scanApps()
    }

    // MARK: - Icon generation

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

        let size = CGSize(
            width: iconSize,
            height: iconSize
        )

        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in

            let rect = CGRect(
                origin: .zero,
                size: size
            )

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
                        end: CGPoint(
                            x: iconSize,
                            y: iconSize
                        ),
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

    // MARK: - Collection view

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

        cell.configure(
            name: app.name,
            icon: app.icon
        )

        return cell
    }

    // MARK: - Long press menu
    //
    // IMPORTANT:
    // iOS 16 can crash when a UIContextMenu contains deeply nested UIMenus
    // (for example: Settings -> Screen Resolution -> item) and the submenu
    // is opened and immediately collapsed again.
    //
    // Keep the grouped layout, but limit the hierarchy to ONE submenu level.
    // This preserves:
    //   Manage JAR >
    //   Settings >
    //   FPS Limit >
    //   Clear / Delete
    //
    // Screen Resolution options are kept inside Settings instead of creating
    // another nested UIMenu.

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {

        guard let indexPath = indexPaths.first,
              indexPath.section >= 0,
              indexPath.item >= 0,
              indexPath.item < apps.count else {
            return nil
        }

        // Capture the JAR path, not only the array position.
        // If scanApps() reloads the collection while the context menu is open,
        // the old IndexPath can become invalid.
        let appPath = apps[indexPath.item].path

        return UIContextMenuConfiguration(
            identifier: NSString(string: appPath),
            previewProvider: nil,
            actionProvider: { [weak self] _ in

                guard let self else {
                    return nil
                }

                // Resolve the current AppInfo from its stable path.
                // Never access apps[indexPath.item] from a delayed menu action.
                guard let app = self.apps.first(where: {
                    $0.path == appPath
                }) else {
                    return nil
                }

                // =========================================================
                // MANAGE JAR
                // =========================================================

                let rename = UIAction(
                    title: "Rename",
                    image: UIImage(systemName: "pencil")
                ) { [weak self] _ in
                    guard let self else { return }
                    self.renameApp(app)
                }

                let changeIcon = UIAction(
                    title: "Change Icon...",
                    image: UIImage(systemName: "photo")
                ) { [weak self] _ in
                    guard let self else { return }
                    self.changeIcon(for: app)
                }

                var manageChildren: [UIMenuElement] = [
                    rename,
                    changeIcon
                ]

                if Self.hasCustomIcon(for: app) {
                    let resetIcon = UIAction(
                        title: "Restore Original Icon",
                        image: UIImage(
                            systemName: "arrow.uturn.backward"
                        )
                    ) { [weak self] _ in
                        guard let self else { return }
                        self.resetCustomIcon(for: app)
                    }

                    manageChildren.append(resetIcon)
                }

                let duplicate = UIAction(
                    title: "Duplicate Install",
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in
                    guard let self else { return }
                    self.duplicateApp(app)
                }

                manageChildren.append(duplicate)

                let manageMenu = UIMenu(
                    title: "Manage JAR",
                    image: UIImage(systemName: "app"),
                    children: manageChildren
                )

                // =========================================================
                // SETTINGS
                // =========================================================

                let ssEnabled = Self.is3DSupersampling(for: app)

                let toggle3D = UIAction(
                    title: ssEnabled
                        ? "Disable 3D Enhancement"
                        : "Enable 3D Enhancement",
                    image: UIImage(systemName: "cube"),
                    state: ssEnabled ? .on : .off
                ) { _ in
                    Self.set3DSupersampling(
                        !ssEnabled,
                        for: app
                    )
                }

                // IMPORTANT:
                // Do NOT put these resolution actions inside another UIMenu.
                // That creates Settings -> Screen Resolution -> item, which
                // is the nested hierarchy that is unsafe on iOS 16.
                let currentRes = Self.resolution(for: app)

                var settingsChildren: [UIMenuElement] = [
                    toggle3D
                ]

                let resolutionHeader = UIAction(
                    title: "Screen Resolution",
                    image: UIImage(systemName: "aspectratio"),
                    attributes: [.disabled]
                ) { _ in }

                settingsChildren.append(resolutionHeader)

                let resActions = Self.resolutionOptions.map { option in
                    UIAction(
                        title: option.label,
                        state: (
                            option.w == currentRes.w &&
                            option.h == currentRes.h
                        ) ? .on : .off
                    ) { _ in
                        Self.setResolution(
                            w: option.w,
                            h: option.h,
                            for: app
                        )
                    }
                }

                settingsChildren.append(contentsOf: resActions)

                let customResolution = UIAction(
                    title: "Custom Resolution...",
                    image: UIImage(
                        systemName: "slider.horizontal.3"
                    )
                ) { [weak self] _ in
                    guard let self else { return }
                    self.promptCustomResolution(for: app)
                }

                settingsChildren.append(customResolution)

                // ONE level only:
                // Settings -> actions
                let settingsMenu = UIMenu(
                    title: "Settings",
                    image: UIImage(systemName: "gearshape"),
                    children: settingsChildren
                )

                // =========================================================
                // FPS
                // =========================================================

                let currentFps = Self.fpsLimit(for: app)

                let fpsActions = Self.fpsLimitOptions.map { option in
                    UIAction(
                        title: option.label,
                        state: option.value == currentFps
                            ? .on
                            : .off
                    ) { _ in
                        Self.setFpsLimit(
                            option.value,
                            for: app
                        )
                    }
                }

                let fpsMenu = UIMenu(
                    title: "FPS Limit",
                    image: UIImage(systemName: "speedometer"),
                    children: fpsActions
                )

                // =========================================================
                // DATA / DELETE
                // =========================================================

                let clearData = UIAction(
                    title: "Clear Game Data",
                    image: UIImage(systemName: "eraser")
                ) { [weak self] _ in
                    guard let self else { return }
                    self.confirmClearGameData(for: app)
                }

                let delete = UIAction(
                    title: "Delete",
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    guard let self else { return }
                    self.confirmDeleteApp(for: app)
                }

                let actions = UIMenu(
                    options: .displayInline,
                    children: [
                        clearData,
                        delete
                    ]
                )

                // =========================================================
                // ROOT MENU
                // =========================================================

                // Keep the original grouped appearance.
                // The only structural change is that Settings no longer
                // contains a second UIMenu for Screen Resolution.
                return UIMenu(
                    children: [
                        manageMenu,
                        settingsMenu,
                        fpsMenu,
                        actions
                    ]
                )
            }
        )
    }

    // MARK: - Per-game settings

    static func is3DSupersampling(for app: AppInfo) -> Bool {

        UserDefaults.standard.object(
            forKey: "ss3d_\(gameId(for: app))"
        ) as? Bool ?? false
    }

    static func set3DSupersampling(
        _ enabled: Bool,
        for app: AppInfo
    ) {

        UserDefaults.standard.set(
            enabled,
            forKey: "ss3d_\(gameId(for: app))"
        )
    }

    private static let resolutionOptions: [
        (label: String, w: Int, h: Int)
    ] = [

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

    static func resolution(
        for app: AppInfo
    ) -> (w: Int, h: Int) {

        let id = gameId(for: app)

        let width = UserDefaults.standard.object(
            forKey: "resW_\(id)"
        ) as? Int ?? 240

        let height = UserDefaults.standard.object(
            forKey: "resH_\(id)"
        ) as? Int ?? 320

        return (width, height)
    }

    private static func setResolution(
        w: Int,
        h: Int,
        for app: AppInfo
    ) {

        let id = gameId(for: app)

        UserDefaults.standard.set(
            w,
            forKey: "resW_\(id)"
        )

        UserDefaults.standard.set(
            h,
            forKey: "resH_\(id)"
        )
    }

    private static let fpsLimitOptions: [
        (label: String, value: Int)
    ] = [

        ("Không giới hạn", 0),
        ("15 FPS", 15),
        ("20 FPS", 20),
        ("30 FPS", 30),
        ("45 FPS", 45)
    ]

    static func fpsLimit(for app: AppInfo) -> Int {

        let key = "fpsLimit_\(gameId(for: app))"

        guard let saved = UserDefaults.standard.object(
            forKey: key
        ) as? Int else {
            return 30
        }

        switch saved {

        case 0, 15, 20, 30, 45:
            return saved

        default:
            return 30
        }
    }

    private static func setFpsLimit(
        _ fps: Int,
        for app: AppInfo
    ) {

        let safeFPS = fpsLimitOptions.contains {
            $0.value == fps
        } ? fps : 30

        UserDefaults.standard.set(
            safeFPS,
            forKey: "fpsLimit_\(gameId(for: app))"
        )
    }

    // MARK: - Custom resolution

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
            UIAlertAction(
                title: "Apply",
                style: .default
            ) { [weak self] _ in

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

    // MARK: - Clear game data

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
            UIAlertAction(
                title: "Clear",
                style: .destructive
            ) { _ in

                let id = Self.gameId(for: app)

                let savePath =
                    Self.documentsDirectory
                    + "/Games Data/"
                    + id

                try? FileManager.default.removeItem(
                    atPath: savePath
                )
            }
        )

        present(alert, animated: true)
    }

    // MARK: - Delete JAR

    private func confirmDeleteApp(for app: AppInfo) {

        let alert = UIAlertController(
            title: "Delete Game",
            message: "Delete \(app.name) and all its save data?",
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(title: "Cancel", style: .cancel)
        )

        alert.addAction(
            UIAlertAction(
                title: "Delete",
                style: .destructive
            ) { [weak self] _ in

                guard let self else {
                    return
                }

                let id = Self.gameId(for: app)

                let savePath =
                    Self.documentsDirectory
                    + "/Games Data/"
                    + id

                try? FileManager.default.removeItem(
                    atPath: savePath
                )

                try? FileManager.default.removeItem(
                    atPath: app.path
                )

                try? FileManager.default.removeItem(
                    atPath: Self.customIconPath(for: id)
                )

                UserDefaults.standard.removeObject(
                    forKey: Self.displayNameKey(id)
                )

                UserDefaults.standard.removeObject(
                    forKey: "ss3d_\(id)"
                )

                UserDefaults.standard.removeObject(
                    forKey: "resW_\(id)"
                )

                UserDefaults.standard.removeObject(
                    forKey: "resH_\(id)"
                )

                UserDefaults.standard.removeObject(
                    forKey: "fpsLimit_\(id)"
                )

                self.scanApps()
            }
        )

        present(alert, animated: true)
    }

    // MARK: - Launch game

    func collectionView(
        _ collectionView: UICollectionView,
        didSelectItemAt indexPath: IndexPath
    ) {

        let app = apps[indexPath.item]

        let render3dScale =
            Self.is3DSupersampling(for: app) ? 3 : 1

        let resolution = Self.resolution(for: app)
        let fps = Self.fpsLimit(for: app)

        let gameVC = GameViewController(
            jarPath: app.path,
            appName: app.name,
            appIcon: app.icon,
            canvasWidth: resolution.w,
            canvasHeight: resolution.h,
            render3dScale: render3dScale,
            fpsLimit: fps
        )

        gameVC.modalPresentationStyle = .fullScreen

        let itemIndex = indexPath.item

        if #available(iOS 18.0, *) {

            let options = UIViewController.Transition.ZoomOptions()

            options.interactiveDismissShouldBegin = { _ in
                false
            }

            options.alignmentRectProvider = { context in

                guard let gvc = context.zoomedViewController
                        as? GameViewController,
                      let placeholder = gvc.placeholderIconView else {
                    return .null
                }

                return placeholder.frame
            }

            gameVC.preferredTransition = .zoom(options: options) {
                [weak self] _ in

                guard let self,
                      let cell = self.springboardCollectionView.cellForItem(
                        at: IndexPath(
                            item: itemIndex,
                            section: 0
                        )
                      ) as? SpringboardCell else {
                    return nil
                }

                return cell.iconView
            }
        }

        present(gameVC, animated: true)
    }
}