
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
    // Do not use UIKit UIMenu/UIContextMenu here.
    //
    // The crash log from iOS 16.4 shows:
    //   EXC_BAD_ACCESS
    //   objc_setAssociatedObject
    //   _UIContextMenuView _setHighlightedIndexPath:playFeedback:
    //   _UIContextMenuView _handleSelectionGesture:
    //
    // Therefore the crash happens inside Apple's context-menu UI while
    // highlighting/selecting an item. The safest fix is to keep the same
    // grouped/expandable menu appearance but render it as our own UIView.
    //
    // This also means the menu no longer creates nested UIMenu objects.

    private var customMenuOverlay: UIView?
    private weak var customMenuPanel: UIView?
    private var customMenuApp: AppInfo?

    private func dismissCustomMenu() {
        customMenuOverlay?.removeFromSuperview()
        customMenuOverlay = nil
        customMenuPanel = nil
        customMenuApp = nil
    }

    private func makeMenuButton(
        title: String,
        imageName: String?,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 11,
            leading: 14,
            bottom: 11,
            trailing: 14
        )
        config.imagePadding = 10
        config.baseForegroundColor = destructive
            ? .systemRed
            : .label

        config.title = title

        if let imageName {
            config.image = UIImage(systemName: imageName)
        }

        let button = UIButton(configuration: config)

        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .systemFont(
            ofSize: 16,
            weight: .regular
        )

        button.accessibilityLabel = title

        button.addAction(
            UIAction { [weak self] _ in
                guard self != nil else {
                    return
                }
                action()
            },
            for: .touchUpInside
        )

        return button
    }

    private func makeExpandableMenuButton(
        title: String,
        imageName: String,
        expanded: Bool,
        toggle: @escaping (UIButton) -> Void
    ) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 12,
            leading: 14,
            bottom: 12,
            trailing: 14
        )
        config.imagePadding = 10
        config.baseForegroundColor = .label
        config.title = title
        config.image = UIImage(systemName: imageName)

        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading

        button.titleLabel?.font = .systemFont(
            ofSize: 16,
            weight: .semibold
        )

        button.accessibilityLabel = title

        button.addAction(
            UIAction { [weak button] _ in
                guard let button else {
                    return
                }
                toggle(button)
            },
            for: .touchUpInside
        )

        return button
    }

    private func setChevron(
        on button: UIButton,
        expanded: Bool
    ) {
        var config = button.configuration
        config?.image = UIImage(
            systemName: expanded
                ? "chevron.down"
                : "chevron.right"
        )
        config?.imagePadding = 10
        button.configuration = config
    }

    private func addMenuSeparator(
        to stack: UIStackView
    ) {
        let separator = UIView()
        separator.backgroundColor = UIColor.separator
            .withAlphaComponent(0.45)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        stack.addArrangedSubview(separator)
    }

    private func addSubmenuItem(
        title: String,
        imageName: String?,
        destructive: Bool = false,
        to stack: UIStackView,
        action: @escaping () -> Void
    ) {
        let button = makeMenuButton(
            title: title,
            imageName: imageName,
            destructive: destructive,
            action: action
        )

        stack.addArrangedSubview(button)
    }

    private func showCustomMenu(
        for app: AppInfo,
        at point: CGPoint
    ) {
        dismissCustomMenu()

        guard let window = view.window else {
            return
        }

        customMenuApp = app

        let overlay = UIView(frame: window.bounds)
        overlay.backgroundColor = .clear
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let outsideTap = UITapGestureRecognizer(
            target: self,
            action: #selector(customMenuOutsideTapped(_:))
        )
        overlay.addGestureRecognizer(outsideTap)

        let panel = UIVisualEffectView(
            effect: UIBlurEffect(style: .systemMaterialDark)
        )

        panel.layer.cornerRadius = 16
        panel.clipsToBounds = true
        panel.layer.borderWidth = 0.5
        panel.layer.borderColor = UIColor.white
            .withAlphaComponent(0.18)
            .cgColor

        panel.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(panel)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false

        let rootStack = UIStackView()
        rootStack.axis = .vertical
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView.addSubview(scroll)
        scroll.addSubview(rootStack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(
                equalTo: panel.contentView.topAnchor
            ),
            scroll.leadingAnchor.constraint(
                equalTo: panel.contentView.leadingAnchor
            ),
            scroll.trailingAnchor.constraint(
                equalTo: panel.contentView.trailingAnchor
            ),
            scroll.bottomAnchor.constraint(
                equalTo: panel.contentView.bottomAnchor
            ),

            rootStack.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor
            ),
            rootStack.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor
            ),
            rootStack.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor
            ),
            rootStack.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor
            ),
            rootStack.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor
            )
        ])

        // -------------------------------------------------------------
        // Manage JAR >
        // -------------------------------------------------------------

        let manageItems = UIStackView()
        manageItems.axis = .vertical
        manageItems.spacing = 0
        manageItems.isHidden = false
        manageItems.isLayoutMarginsRelativeArrangement = true
        manageItems.layoutMargins = UIEdgeInsets(
            top: 0,
            left: 20,
            bottom: 0,
            right: 0
        )

        addSubmenuItem(
            title: "Rename",
            imageName: "pencil",
            to: manageItems
        ) { [weak self] in
            self?.dismissCustomMenu()
            self?.renameApp(app)
        }

        addSubmenuItem(
            title: "Change Icon...",
            imageName: "photo",
            to: manageItems
        ) { [weak self] in
            self?.dismissCustomMenu()
            self?.changeIcon(for: app)
        }

        if Self.hasCustomIcon(for: app) {
            addSubmenuItem(
                title: "Restore Original Icon",
                imageName: "arrow.uturn.backward",
                to: manageItems
            ) { [weak self] in
                self?.dismissCustomMenu()
                self?.resetCustomIcon(for: app)
            }
        }

        addSubmenuItem(
            title: "Duplicate Install",
            imageName: "doc.on.doc",
            to: manageItems
        ) { [weak self] in
            self?.dismissCustomMenu()
            self?.duplicateApp(app)
        }

        manageItems.isHidden = true

        let manageButton = makeExpandableMenuButton(
            title: "Manage JAR",
            imageName: "app",
            expanded: false
        ) { [weak manageItems, weak self] button in
            guard let manageItems else {
                return
            }

            let expanding = manageItems.isHidden
            manageItems.isHidden = !expanding

            self?.setChevron(
                on: button,
                expanded: expanding
            )
        }

        rootStack.addArrangedSubview(manageButton)
        rootStack.addArrangedSubview(manageItems)

        // -------------------------------------------------------------
        // Settings >
        // -------------------------------------------------------------

        let settingsItems = UIStackView()
        settingsItems.axis = .vertical
        settingsItems.spacing = 0
        settingsItems.isHidden = true
        settingsItems.isLayoutMarginsRelativeArrangement = true
        settingsItems.layoutMargins = UIEdgeInsets(
            top: 0,
            left: 20,
            bottom: 0,
            right: 0
        )

        let ssEnabled = Self.is3DSupersampling(for: app)

        addSubmenuItem(
            title: ssEnabled
                ? "Disable 3D Enhancement"
                : "Enable 3D Enhancement",
            imageName: "cube",
            to: settingsItems
        ) {
            Self.set3DSupersampling(
                !ssEnabled,
                for: app
            )
            self.dismissCustomMenu()
        }

        // Screen Resolution >
        let resolutionItems = UIStackView()
        resolutionItems.axis = .vertical
        resolutionItems.spacing = 0
        resolutionItems.isHidden = true
        resolutionItems.isLayoutMarginsRelativeArrangement = true
        resolutionItems.layoutMargins = UIEdgeInsets(
            top: 0,
            left: 20,
            bottom: 0,
            right: 0
        )

        let currentRes = Self.resolution(for: app)

        for option in Self.resolutionOptions {
            addSubmenuItem(
                title: option.label
                    + (
                        option.w == currentRes.w &&
                        option.h == currentRes.h
                        ? "  ✓"
                        : ""
                    ),
                imageName: nil,
                to: resolutionItems
            ) {
                Self.setResolution(
                    w: option.w,
                    h: option.h,
                    for: app
                )
                self.dismissCustomMenu()
            }
        }

        addSubmenuItem(
            title: "Custom Resolution...",
            imageName: "slider.horizontal.3",
            to: resolutionItems
        ) { [weak self] in
            self?.dismissCustomMenu()
            self?.promptCustomResolution(for: app)
        }

        let resolutionButton = makeExpandableMenuButton(
            title: "Screen Resolution",
            imageName: "aspectratio",
            expanded: false
        ) { [weak resolutionItems, weak self] button in
            guard let resolutionItems else {
                return
            }

            let expanding = resolutionItems.isHidden
            resolutionItems.isHidden = !expanding

            self?.setChevron(
                on: button,
                expanded: expanding
            )
        }

        settingsItems.addArrangedSubview(resolutionButton)
        settingsItems.addArrangedSubview(resolutionItems)

        let settingsButton = makeExpandableMenuButton(
            title: "Settings",
            imageName: "gearshape",
            expanded: false
        ) { [weak settingsItems, weak self] button in
            guard let settingsItems else {
                return
            }

            let expanding = settingsItems.isHidden
            settingsItems.isHidden = !expanding

            self?.setChevron(
                on: button,
                expanded: expanding
            )
        }

        rootStack.addArrangedSubview(settingsButton)
        rootStack.addArrangedSubview(settingsItems)

        // -------------------------------------------------------------
        // FPS Limit >
        // -------------------------------------------------------------

        let fpsItems = UIStackView()
        fpsItems.axis = .vertical
        fpsItems.spacing = 0
        fpsItems.isHidden = true
        fpsItems.isLayoutMarginsRelativeArrangement = true
        fpsItems.layoutMargins = UIEdgeInsets(
            top: 0,
            left: 20,
            bottom: 0,
            right: 0
        )

        let currentFps = Self.fpsLimit(for: app)

        for option in Self.fpsLimitOptions {
            addSubmenuItem(
                title: option.label
                    + (option.value == currentFps ? "  ✓" : ""),
                imageName: nil,
                to: fpsItems
            ) {
                Self.setFpsLimit(
                    option.value,
                    for: app
                )
                self.dismissCustomMenu()
            }
        }

        let fpsButton = makeExpandableMenuButton(
            title: "FPS Limit",
            imageName: "speedometer",
            expanded: false
        ) { [weak fpsItems, weak self] button in
            guard let fpsItems else {
                return
            }

            let expanding = fpsItems.isHidden
            fpsItems.isHidden = !expanding

            self?.setChevron(
                on: button,
                expanded: expanding
            )
        }

        rootStack.addArrangedSubview(fpsButton)
        rootStack.addArrangedSubview(fpsItems)

        // -------------------------------------------------------------
        // Bottom actions
        // -------------------------------------------------------------

        addMenuSeparator(to: rootStack)

        addSubmenuItem(
            title: "Clear Game Data",
            imageName: "eraser",
            to: rootStack
        ) { [weak self] in
            self?.dismissCustomMenu()
            self?.confirmClearGameData(for: app)
        }

        addSubmenuItem(
            title: "Delete",
            imageName: "trash",
            destructive: true,
            to: rootStack
        ) { [weak self] in
            self?.dismissCustomMenu()
            self?.confirmDeleteApp(for: app)
        }

        window.addSubview(overlay)

        customMenuOverlay = overlay
        customMenuPanel = panel

        let maxWidth = min(
            window.bounds.width - 32,
            360
        )

        let maxHeight = min(
            window.bounds.height - 80,
            620
        )

        // Position near the pressed cell, but keep the entire panel on-screen.
        let targetX = min(
            max(16, point.x - maxWidth * 0.5),
            window.bounds.width - maxWidth - 16
        )

        let targetY = min(
            max(16, point.y),
            window.bounds.height - maxHeight - 16
        )

        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(
                equalToConstant: maxWidth
            ),
            panel.heightAnchor.constraint(
                lessThanOrEqualToConstant: maxHeight
            ),
            panel.leadingAnchor.constraint(
                equalTo: overlay.leadingAnchor,
                constant: targetX
            ),
            panel.topAnchor.constraint(
                equalTo: overlay.topAnchor,
                constant: targetY
            ),
            panel.bottomAnchor.constraint(
                lessThanOrEqualTo: overlay.bottomAnchor,
                constant: -16
            )
        ])

        overlay.alpha = 0

        UIView.animate(
            withDuration: 0.12,
            animations: {
                overlay.alpha = 1
            }
        )
    }

    @objc private func customMenuOutsideTapped(
        _ recognizer: UITapGestureRecognizer
    ) {
        guard let overlay = customMenuOverlay else {
            return
        }

        let location = recognizer.location(in: overlay)

        if let panel = customMenuPanel,
           panel.frame.contains(location) {
            return
        }

        dismissCustomMenu()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {

        guard
            let indexPath = indexPaths.first,
            indexPath.item >= 0,
            indexPath.item < apps.count
        else {
            return nil
        }

        let app = apps[indexPath.item]

        // IMPORTANT:
        // Return nil. Never construct UIMenu/UIAction here.
        // The custom UIView menu above replaces UIKit's context menu.
        //
        // `point` is in the collection view coordinate space, while our
        // custom overlay is attached to the window.
        let windowPoint: CGPoint
        if let window = view.window {
            windowPoint = collectionView.convert(point, to: window)
        } else {
            windowPoint = point
        }

        showCustomMenu(for: app, at: windowPoint)

        return nil
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