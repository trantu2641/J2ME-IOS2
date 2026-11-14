
//
//  FormView.swift
//  J2MEEmulator
//
//  Displays J2ME Forms/Lists/Alerts using native UIKit views.
//

import UIKit

class FormView: UIView, UIGestureRecognizerDelegate {

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let titleLabel = UILabel()
    private var commandButtons: [UIButton] = []
    private let commandBar = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .systemBackground

        // Title
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Scroll + Stack for items
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.alignment = .fill
        stackView.layoutMargins = UIEdgeInsets(
            top: 12,
            left: 16,
            bottom: 12,
            right: 16
        )
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        // Command bar at bottom
        commandBar.axis = .horizontal
        commandBar.spacing = 12
        commandBar.distribution = .fillEqually
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandBar)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 16
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -16
            ),

            scrollView.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: 8
            ),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: commandBar.topAnchor,
                constant: -8
            ),

            stackView.topAnchor.constraint(
                equalTo: scrollView.topAnchor
            ),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.leadingAnchor
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.trailingAnchor
            ),
            stackView.bottomAnchor.constraint(
                equalTo: scrollView.bottomAnchor
            ),
            stackView.widthAnchor.constraint(
                equalTo: scrollView.widthAnchor
            ),

            commandBar.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 16
            ),
            commandBar.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -16
            ),
            commandBar.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor,
                constant: -8
            ),
            commandBar.heightAnchor.constraint(
                equalToConstant: 44
            )
        ])

        // Tap outside text fields to dismiss keyboard.
        let outsideTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleOutsideTap(_:))
        )

        outsideTap.cancelsTouchesInView = false
        outsideTap.delaysTouchesBegan = false
        outsideTap.delegate = self

        addGestureRecognizer(outsideTap)
    }

    // MARK: - Dismiss keyboard on outside tap

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {

        // Do not dismiss when the user taps inside a text field.
        var touchedView = touch.view

        while let current = touchedView, current !== self {
            if current is UITextField {
                return false
            }

            touchedView = current.superview
        }

        return true
    }

    @objc private func handleOutsideTap(
        _ gestureRecognizer: UITapGestureRecognizer
    ) {
        guard gestureRecognizer.state == .ended else {
            return
        }

        // Hide the iOS keyboard.
        endEditing(true)
    }

    // MARK: - Build form

    func buildFromNativeData() {
        // Clear previous content
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        commandBar.arrangedSubviews.forEach {
            commandBar.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        commandButtons.removeAll()

        // Title
        titleLabel.text = String(
            cString: j2me_ui_get_form_title()
        )

        // Items
        let count = j2me_ui_get_form_item_count()

        for i in 0..<count {
            let itemType = j2me_ui_get_form_item_type(Int32(i))

            let label = String(
                cString: j2me_ui_get_form_item_label(Int32(i))
            )

            let text = String(
                cString: j2me_ui_get_form_item_text(Int32(i))
            )

            switch itemType {
            case 0:
                addStringItem(label: label, text: text)

            case 1:
                addTextField(label: label, text: text)

            case 2:
                // ChoiceGroup items are rendered as native check controls.
                // intParam1 = J2ME choice type (EXCLUSIVE/MULTIPLE),
                // intParam2 = initial selected state.
                let choiceType = j2me_ui_get_form_item_param1(Int32(i))
                let selected = j2me_ui_get_form_item_param2(Int32(i)) != 0
                addChoiceItem(
                    label: label,
                    text: text,
                    choiceType: choiceType,
                    selected: selected
                )

            default:
                addStringItem(label: label, text: text)
            }
        }

        // Existing game commands: Save, Cancel, etc.
        let cmdCount = j2me_ui_get_command_count()

        for i in 0..<cmdCount {
            let cmdLabel = String(
                cString: j2me_ui_get_command_label(Int32(i))
            )

            let cmdId = j2me_ui_get_command_id(Int32(i))

            let btn = UIButton(type: .system)

            btn.setTitle(cmdLabel, for: .normal)
            btn.titleLabel?.font = .boldSystemFont(ofSize: 16)
            btn.tag = Int(cmdId)
            btn.backgroundColor = .systemBlue
            btn.setTitleColor(.white, for: .normal)
            btn.layer.cornerRadius = 8

            btn.addTarget(
                self,
                action: #selector(commandTapped(_:)),
                for: .touchUpInside
            )

            commandBar.addArrangedSubview(btn)
            commandButtons.append(btn)
        }
    }

    // MARK: - String item

    private func addStringItem(
        label: String,
        text: String
    ) {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 2

        if !label.isEmpty {
            let labelView = UILabel()
            labelView.text = label
            labelView.font = .boldSystemFont(ofSize: 14)
            labelView.textColor = .secondaryLabel

            container.addArrangedSubview(labelView)
        }

        if !text.isEmpty {
            let textView = UILabel()
            textView.text = text
            textView.font = .systemFont(ofSize: 16)
            textView.numberOfLines = 0

            container.addArrangedSubview(textView)
        }

        stackView.addArrangedSubview(container)
    }

    // MARK: - Choice / checkbox item

    private func addChoiceItem(
        label: String,
        text: String,
        choiceType: Int32,
        selected: Bool
    ) {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.layoutMargins = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        row.isLayoutMarginsRelativeArrangement = true

        if !label.isEmpty {
            let labelView = UILabel()
            labelView.text = label
            labelView.font = .systemFont(ofSize: 14, weight: .medium)
            labelView.textColor = .secondaryLabel
            labelView.numberOfLines = 0
            labelView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            labelView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(labelView)
        }

        let button = UIButton(type: .system)
        button.accessibilityLabel = text
        button.accessibilityValue = selected ? "Đã chọn" : "Chưa chọn"
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        button.setTitle(text, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 0

        let isExclusive = (choiceType == 1) // Choice.EXCLUSIVE
        button.setImage(
            UIImage(systemName: selected
                ? (isExclusive ? "largecircle.fill.circle" : "checkmark.square.fill")
                : (isExclusive ? "circle" : "square")
            ),
            for: .normal
        )
        button.tintColor = .systemBlue
        button.semanticContentAttribute = .forceLeftToRight
        button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        button.tag = selected ? 1 : 0

        button.addAction(
            UIAction { [weak button] _ in
                guard let button else { return }

                let checked = button.tag == 1
                let newChecked = !checked
                button.tag = newChecked ? 1 : 0
                button.accessibilityValue = newChecked ? "Đã chọn" : "Chưa chọn"

                let symbol = newChecked
                    ? (isExclusive ? "largecircle.fill.circle" : "checkmark.square.fill")
                    : (isExclusive ? "circle" : "square")

                button.setImage(UIImage(systemName: symbol), for: .normal)
            },
            for: .touchUpInside
        )

        row.addArrangedSubview(button)
        stackView.addArrangedSubview(row)
    }

    // MARK: - Text field

    private func addTextField(
        label: String,
        text: String
    ) {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 4

        if !label.isEmpty {
            let labelView = UILabel()
            labelView.text = label
            labelView.font = .boldSystemFont(ofSize: 14)
            labelView.textColor = .secondaryLabel

            container.addArrangedSubview(labelView)
        }

        let tf = UITextField()
        tf.text = text
        tf.borderStyle = .roundedRect
        tf.font = .systemFont(ofSize: 16)

        tf.addTarget(
            self,
            action: #selector(textFieldChanged(_:)),
            for: .editingChanged
        )

        container.addArrangedSubview(tf)
        stackView.addArrangedSubview(container)
    }

    // MARK: - Commands

    @objc private func commandTapped(_ sender: UIButton) {
        // Hide keyboard before executing the command.
        endEditing(true)

        let cmdId = Int32(sender.tag)

        j2me_input_post_key(
            Int32(J2ME_UI_COMMAND_ACTION),
            cmdId
        )
    }

    @objc private func textFieldChanged(
        _ sender: UITextField
    ) {
        // Existing text field synchronization placeholder.
        // TODO: associate with specific Item index for multi-TextField forms.
        // TextField value changed — TODO: sync back to Java Item.
    }
}

// ============================================================
// List view
// ============================================================

class J2MEListView: UIView,
    UITableViewDataSource,
    UITableViewDelegate {

    private let titleLabel = UILabel()
    private let tableView = UITableView()
    private var items: [String] = []
    private var commandButtons: [UIButton] = []
    private let commandBar = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .systemBackground

        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tableView)

        commandBar.axis = .horizontal
        commandBar.spacing = 12
        commandBar.distribution = .fillEqually
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandBar)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor,
                constant: 8
            ),
            titleLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 16
            ),
            titleLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -16
            ),

            tableView.topAnchor.constraint(
                equalTo: titleLabel.bottomAnchor,
                constant: 8
            ),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(
                equalTo: commandBar.topAnchor,
                constant: -8
            ),

            commandBar.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 16
            ),
            commandBar.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -16
            ),
            commandBar.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor,
                constant: -8
            ),
            commandBar.heightAnchor.constraint(
                equalToConstant: 44
            )
        ])
    }

    func buildFromNativeData() {
        titleLabel.text = String(
            cString: j2me_ui_get_form_title()
        )

        items.removeAll()

        let count = j2me_ui_get_list_item_count()

        for i in 0..<count {
            items.append(
                String(cString: j2me_ui_get_list_item(Int32(i)))
            )
        }

        tableView.reloadData()

        // Commands
        commandBar.arrangedSubviews.forEach {
            commandBar.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        commandButtons.removeAll()

        let cmdCount = j2me_ui_get_command_count()

        for i in 0..<cmdCount {
            let cmdLabel = String(
                cString: j2me_ui_get_command_label(Int32(i))
            )

            let cmdId = j2me_ui_get_command_id(Int32(i))

            let btn = UIButton(type: .system)

            btn.setTitle(cmdLabel, for: .normal)
            btn.tag = Int(cmdId)
            btn.backgroundColor = .systemBlue
            btn.setTitleColor(.white, for: .normal)
            btn.layer.cornerRadius = 8

            btn.addTarget(
                self,
                action: #selector(commandTapped(_:)),
                for: .touchUpInside
            )

            commandBar.addArrangedSubview(btn)
        }
    }

    func tableView(
        _ tableView: UITableView,
        numberOfRowsInSection section: Int
    ) -> Int {
        return items.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {

        let cell = tableView.dequeueReusableCell(
            withIdentifier: "cell"
        ) ?? UITableViewCell(
            style: .default,
            reuseIdentifier: "cell"
        )

        var content = cell.defaultContentConfiguration()
        content.text = items[indexPath.row]
        cell.contentConfiguration = content

        return cell
    }

    func tableView(
        _ tableView: UITableView,
        didSelectRowAt indexPath: IndexPath
    ) {
        j2me_input_post_key(
            Int32(J2ME_UI_LIST_SELECT),
            Int32(indexPath.row)
        )
    }

    @objc private func commandTapped(_ sender: UIButton) {
        j2me_input_post_key(
            Int32(J2ME_UI_COMMAND_ACTION),
            Int32(sender.tag)
        )
    }
}
