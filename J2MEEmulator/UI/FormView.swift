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

    // Native-form item tracking.
    // The index is the serialized J2ME form-item index used by j2me_ui.m,
    // so edited UIKit values can be committed back to the live Java
    // Form/ChoiceGroup/TextField before the command event.
    private struct ChoiceControl {
        let nativeIndex: Int
        let groupID: Int
        let choiceType: Int32
        let button: UIButton
    }

    private struct TextControl {
        let nativeIndex: Int
        let field: UITextField
    }

    private var choiceControls: [ChoiceControl] = []
    private var textControls: [TextControl] = []

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
            scrollView.leadingAnchor.constraint(
                equalTo: leadingAnchor
            ),
            scrollView.trailingAnchor.constraint(
                equalTo: trailingAnchor
            ),
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
        choiceControls.removeAll()
        textControls.removeAll()

        // Title
        titleLabel.text = String(
            cString: j2me_ui_get_form_title()
        )

        // Items
        let count = j2me_ui_get_form_item_count()

        var nextChoiceGroupID = 0
        var lastChoiceLabel = ""
        var lastChoiceType: Int32 = -1
        var previousWasChoice = false

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
                // STRING
                addStringItem(
                    label: label,
                    text: text
                )

                previousWasChoice = false

            case 1:
                // TEXTFIELD
                addTextField(
                    label: label,
                    text: text,
                    nativeIndex: i,
                    constraints: j2me_ui_get_form_item_param2(
                        Int32(i)
                    )
                )

                previousWasChoice = false

            case 2:
                // CHOICEGROUP
                //
                // J2ME choiceType:
                // EXCLUSIVE = 1
                // MULTIPLE  = 2

                let choiceType =
                    j2me_ui_get_form_item_param1(Int32(i))

                let selected =
                    j2me_ui_get_form_item_param2(Int32(i)) != 0

                if !previousWasChoice ||
                    label != lastChoiceLabel ||
                    choiceType != lastChoiceType {

                    nextChoiceGroupID += 1
                }

                addChoiceItem(
                    label: label,
                    text: text,
                    nativeIndex: i,
                    groupID: nextChoiceGroupID,
                    choiceType: choiceType,
                    selected: selected
                )

                lastChoiceLabel = label
                lastChoiceType = choiceType
                previousWasChoice = true

            default:
                addStringItem(
                    label: label,
                    text: text
                )

                previousWasChoice = false
            }
        }

        // Existing game commands: Save, Cancel, etc.
        let cmdCount = j2me_ui_get_command_count()

        for i in 0..<cmdCount {
            let cmdLabel = String(
                cString: j2me_ui_get_command_label(Int32(i))
            )

            let cmdId =
                j2me_ui_get_command_id(Int32(i))

            let cmdType =
                j2me_ui_get_command_type(Int32(i))

            let btn = UIButton(type: .system)

            btn.accessibilityIdentifier =
                "j2me-command-type-\(cmdType)"

            btn.setTitle(
                cmdLabel,
                for: .normal
            )

            btn.titleLabel?.font =
                .boldSystemFont(ofSize: 16)

            btn.tag = Int(cmdId)

            btn.backgroundColor = .systemBlue
            btn.setTitleColor(
                .white,
                for: .normal
            )

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
            labelView.font =
                .boldSystemFont(ofSize: 14)
            labelView.textColor =
                .secondaryLabel

            container.addArrangedSubview(labelView)
        }

        if !text.isEmpty {
            let textView = UILabel()

            textView.text = text
            textView.font =
                .systemFont(ofSize: 16)
            textView.numberOfLines = 0

            container.addArrangedSubview(textView)
        }

        stackView.addArrangedSubview(container)
    }

    // MARK: - Choice / checkbox item

    private func addChoiceItem(
        label: String,
        text: String,
        nativeIndex: Int,
        groupID: Int,
        choiceType: Int32,
        selected: Bool
    ) {
        let row = UIStackView()

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10

        row.layoutMargins = UIEdgeInsets(
            top: 4,
            left: 0,
            bottom: 4,
            right: 0
        )

        row.isLayoutMarginsRelativeArrangement = true

        let button = UIButton(type: .system)

        button.accessibilityLabel = text
        button.accessibilityValue =
            selected ? "Đã chọn" : "Chưa chọn"

        button.titleLabel?.font =
            .systemFont(
                ofSize: 16,
                weight: .regular
            )

        button.setTitle(
            text,
            for: .normal
        )

        button.setTitleColor(
            .label,
            for: .normal
        )

        button.contentHorizontalAlignment =
            .leading

        button.titleLabel?.numberOfLines = 0

        button.tintColor = .systemBlue

        button.semanticContentAttribute =
            .forceLeftToRight

        button.imageEdgeInsets = UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: 0,
            right: 8
        )

        button.tag = selected ? 1 : 0

        let isExclusive =
            choiceType == 1

        let symbol = selected
            ? (
                isExclusive
                ? "largecircle.fill.circle"
                : "checkmark.square.fill"
            )
            : (
                isExclusive
                ? "circle"
                : "square"
            )

        button.setImage(
            UIImage(systemName: symbol),
            for: .normal
        )

        button.addAction(
            UIAction { [weak self, weak button] _ in
                guard
                    let self,
                    let button
                else {
                    return
                }

                if isExclusive {
                    // Only one option in this ChoiceGroup
                    // can remain selected.
                    for control in self.choiceControls
                        where control.groupID == groupID &&
                              control.button !== button {

                        self.setChoiceButton(
                            control.button,
                            selected: false
                        )
                    }

                    self.setChoiceButton(
                        button,
                        selected: true
                    )

                } else {
                    self.setChoiceButton(
                        button,
                        selected: button.tag != 1
                    )
                }
            },
            for: .touchUpInside
        )

        choiceControls.append(
            ChoiceControl(
                nativeIndex: nativeIndex,
                groupID: groupID,
                choiceType: choiceType,
                button: button
            )
        )

        if !label.isEmpty {
            let labelView = UILabel()

            labelView.text = label
            labelView.font =
                .systemFont(
                    ofSize: 14,
                    weight: .medium
                )

            labelView.textColor =
                .secondaryLabel

            labelView.numberOfLines = 0

            labelView.setContentHuggingPriority(
                .defaultLow,
                for: .horizontal
            )

            labelView.setContentCompressionResistancePriority(
                .defaultLow,
                for: .horizontal
            )

            row.addArrangedSubview(labelView)
        }

        row.addArrangedSubview(button)

        stackView.addArrangedSubview(row)
    }

    private func setChoiceButton(
        _ button: UIButton,
        selected: Bool
    ) {
        button.tag = selected ? 1 : 0

        button.accessibilityValue =
            selected ? "Đã chọn" : "Chưa chọn"

        let control =
            choiceControls.first {
                $0.button === button
            }

        let isExclusive =
            control?.choiceType == 1

        let symbol = selected
            ? (
                isExclusive
                ? "largecircle.fill.circle"
                : "checkmark.square.fill"
            )
            : (
                isExclusive
                ? "circle"
                : "square"
            )

        button.setImage(
            UIImage(systemName: symbol),
            for: .normal
        )
    }

    // MARK: - Text field

    private func addTextField(
        label: String,
        text: String,
        nativeIndex: Int,
        constraints: Int32
    ) {
        let container = UIStackView()

        container.axis = .vertical
        container.spacing = 4

        if !label.isEmpty {
            let labelView = UILabel()

            labelView.text = label
            labelView.font =
                .boldSystemFont(ofSize: 14)

            labelView.textColor =
                .secondaryLabel

            container.addArrangedSubview(labelView)
        }

        let tf = UITextField()

        tf.text = text
        tf.borderStyle = .roundedRect
        tf.font = .systemFont(ofSize: 16)
        tf.clearButtonMode = .whileEditing

        // J2ME TextField constraint values are packed here.
        let baseConstraint =
            Int(constraints) & 0xFFFF

        let isPassword =
            (Int(constraints) & 0x10000) != 0

        switch baseConstraint {

        case 2:
            // TextField.NUMERIC
            // iOS does not expose a literal J2ME T9 keyboard.
            // Use the numeric keypad.
            tf.keyboardType = .numberPad

        case 3:
            // PHONENUMBER
            tf.keyboardType = .phonePad

        case 5:
            // DECIMAL
            tf.keyboardType = .decimalPad

        case 1:
            // EMAILADDR
            tf.keyboardType = .emailAddress

        case 4:
            // URL
            tf.keyboardType = .URL

        default:
            tf.keyboardType = .default
        }

        tf.isSecureTextEntry =
            isPassword

        tf.addTarget(
            self,
            action: #selector(textFieldChanged(_:)),
            for: .editingChanged
        )

        container.addArrangedSubview(tf)
        stackView.addArrangedSubview(container)

        textControls.append(
            TextControl(
                nativeIndex: nativeIndex,
                field: tf
            )
        )
    }

    // MARK: - Commands

    @objc private func commandTapped(
        _ sender: UIButton
    ) {
        // Commit the edited form state before the command
        // reaches Java.
        //
        // Cancel/Back/Exit/Stop intentionally discard
        // native edits.

        let commandType: Int32

        if let identifier =
            sender.accessibilityIdentifier {

            let prefix =
                "j2me-command-type-"

            if identifier.hasPrefix(prefix) {
                let value =
                    String(
                        identifier.dropFirst(
                            prefix.count
                        )
                    )

                commandType =
                    Int32(value) ?? 1
            } else {
                commandType = 1
            }

        } else {
            commandType = 1
        }

        endEditing(true)

        if commandType != 2 && // BACK
            commandType != 3 && // CANCEL
            commandType != 6 && // STOP
            commandType != 7 {  // EXIT

            commitFormEdits()
        }

        let cmdId =
            Int32(sender.tag)

        j2me_input_post_key(
            Int32(J2ME_UI_COMMAND_ACTION),
            cmdId
        )
    }

    private func commitFormEdits() {

        // TextField values
        for control in textControls {
            let value =
                control.field.text ?? ""

            j2me_ui_set_form_item_text(
                Int32(control.nativeIndex),
                value
            )
        }

        // ChoiceGroup values
        for control in choiceControls {
            let selected =
                control.button.tag == 1

            j2me_ui_set_form_item_selected(
                Int32(control.nativeIndex),
                selected ? 1 : 0
            )
        }

        // Type 13 is consumed by Display before
        // the following command event.
        j2me_input_post_key(
            Int32(J2ME_UI_FORM_COMMIT),
            0
        )
    }

    @objc private func textFieldChanged(
        _ sender: UITextField
    ) {
        // The actual Java TextField update happens atomically
        // on command commit, preserving the value seen by the
        // MIDlet command handler.
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
        backgroundColor =
            .systemBackground

        titleLabel.font =
            .boldSystemFont(ofSize: 18)

        titleLabel.textAlignment =
            .center

        titleLabel.translatesAutoresizingMaskIntoConstraints =
            false

        addSubview(titleLabel)

        tableView.dataSource =
            self

        tableView.delegate =
            self

        tableView.translatesAutoresizingMaskIntoConstraints =
            false

        addSubview(tableView)

        commandBar.axis =
            .horizontal

        commandBar.spacing =
            12

        commandBar.distribution =
            .fillEqually

        commandBar.translatesAutoresizingMaskIntoConstraints =
            false

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

            tableView.leadingAnchor.constraint(
                equalTo: leadingAnchor
            ),

            tableView.trailingAnchor.constraint(
                equalTo: trailingAnchor
            ),

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
        titleLabel.text =
            String(
                cString: j2me_ui_get_form_title()
            )

        items.removeAll()

        let count =
            j2me_ui_get_list_item_count()

        for i in 0..<count {
            items.append(
                String(
                    cString:
                        j2me_ui_get_list_item(
                            Int32(i)
                        )
                )
            )
        }

        tableView.reloadData()

        // Commands
        commandBar.arrangedSubviews.forEach {
            commandBar.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        commandButtons.removeAll()

        let cmdCount =
            j2me_ui_get_command_count()

        for i in 0..<cmdCount {
            let cmdLabel =
                String(
                    cString:
                        j2me_ui_get_command_label(
                            Int32(i)
                        )
                )

            let cmdId =
                j2me_ui_get_command_id(
                    Int32(i)
                )

            let btn =
                UIButton(type: .system)

            btn.setTitle(
                cmdLabel,
                for: .normal
            )

            btn.tag =
                Int(cmdId)

            btn.backgroundColor =
                .systemBlue

            btn.setTitleColor(
                .white,
                for: .normal
            )

            btn.layer.cornerRadius =
                8

            btn.addTarget(
                self,
                action: #selector(commandTapped(_:)),
                for: .touchUpInside
            )

            commandBar.addArrangedSubview(btn)
            commandButtons.append(btn)
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

        let cell =
            tableView.dequeueReusableCell(
                withIdentifier: "cell"
            )
            ?? UITableViewCell(
                style: .default,
                reuseIdentifier: "cell"
            )

        var content =
            cell.defaultContentConfiguration()

        content.text =
            items[indexPath.row]

        cell.contentConfiguration =
            content

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

    @objc private func commandTapped(
        _ sender: UIButton
    ) {
        j2me_input_post_key(
            Int32(J2ME_UI_COMMAND_ACTION),
            Int32(sender.tag)
        )
    }
}
