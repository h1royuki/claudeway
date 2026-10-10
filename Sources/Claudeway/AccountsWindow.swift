import AppKit
import SwitcherCore

/// One stable window; periodic usage updates never discard an unfinished rename.
@MainActor final class AccountsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let stack = NSStackView()
    private let heading = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let pendingLabel = NSTextField(wrappingLabelWithString: "")
    private let pendingBox = NSStackView()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var listHeight: NSLayoutConstraint!
    private let editor = NSStackView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField(string: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()
    private let saveButton = NSButton()
    private let removeButton = NSButton()
    private let selectButton = NSButton()
    private let finishButton = NSButton()
    private let cancelButton = NSButton()
    private var state: ProfileState?
    private var selectedID: UUID?
    private var busy = false
    private var available = false
    private var updating = false
    private var dirtyName = false
    private let onAdd: () -> Void
    private let onRename: (UUID, String) throws -> Void
    private let onRemove: (UUID) -> Void
    private let onSelect: (UUID) -> Void
    private let onFinish: () -> Void
    private let onCancel: () -> Void

    init(add: @escaping () -> Void, rename: @escaping (UUID, String) throws -> Void,
         remove: @escaping (UUID) -> Void, select: @escaping (UUID) -> Void,
         finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        onAdd = add; onRename = rename; onRemove = remove; onSelect = select; onFinish = finish; onCancel = cancel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)
        ])
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading, spacer, addButton]); header.orientation = .horizontal
        header.widthAnchor.constraint(equalToConstant: 556).isActive = true; stack.addArrangedSubview(header)
        subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
        subtitle.widthAnchor.constraint(equalToConstant: 556).isActive = true; stack.addArrangedSubview(subtitle)

        pendingBox.orientation = .vertical; pendingBox.alignment = .leading; pendingBox.spacing = 8
        pendingLabel.widthAnchor.constraint(equalToConstant: 556).isActive = true
        pendingLabel.font = .systemFont(ofSize: 12)
        pendingBox.addArrangedSubview(pendingLabel)
        let pendingActions = NSStackView(views: [finishButton, cancelButton]); pendingActions.spacing = 8
        pendingBox.addArrangedSubview(pendingActions); stack.addArrangedSubview(pendingBox)

        empty.alignment = .center; empty.font = .systemFont(ofSize: 14)
        empty.widthAnchor.constraint(equalToConstant: 556).isActive = true
        stack.addArrangedSubview(empty)
        table.headerView = nil; table.rowHeight = 42; table.intercellSpacing = NSSize(width: 12, height: 2)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false; table.allowsMultipleSelection = false
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); nameColumn.width = 358
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status")); statusColumn.width = 164
        table.addTableColumn(nameColumn); table.addTableColumn(statusColumn)
        table.dataSource = self; table.delegate = self
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 556).isActive = true
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 90); listHeight.isActive = true
        stack.addArrangedSubview(scroll)

        editor.orientation = .vertical; editor.alignment = .leading; editor.spacing = 8
        nameLabel.font = .systemFont(ofSize: 11); nameLabel.textColor = .secondaryLabelColor
        editor.addArrangedSubview(nameLabel)
        nameField.widthAnchor.constraint(equalToConstant: 438).isActive = true
        nameField.isEditable = true; nameField.isSelectable = true
        nameField.delegate = self; nameField.target = self; nameField.action = #selector(saveName)
        let editRow = NSStackView(views: [nameField, saveButton]); editRow.spacing = 8
        editor.addArrangedSubview(editRow)
        let actions = NSStackView(views: [selectButton, removeButton]); actions.spacing = 8
        editor.addArrangedSubview(actions); stack.addArrangedSubview(editor)
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.widthAnchor.constraint(equalToConstant: 556).isActive = true
        stack.addArrangedSubview(errorLabel)
        for (button, action) in [(addButton, #selector(addAccount)), (saveButton, #selector(saveName)),
                                 (removeButton, #selector(removeAccount)), (selectButton, #selector(selectAccount)),
                                 (finishButton, #selector(finishAdding)), (cancelButton, #selector(cancelAdding))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        removeButton.hasDestructiveAction = true
        relocalize(); update(state: nil, busy: false, available: false)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func relocalize() {
        window?.title = L10n.text("Accounts"); heading.stringValue = L10n.text("Accounts")
        subtitle.stringValue = L10n.text("Add accounts, change their names, or remove them from Claudeway.")
        addButton.title = L10n.text("Add account…"); saveButton.title = L10n.text("Save")
        removeButton.title = L10n.text("Remove account…"); selectButton.title = L10n.text("Use this account")
        finishButton.title = L10n.text("Done, signed in"); cancelButton.title = L10n.text("Cancel adding account")
        nameLabel.stringValue = L10n.text("Account name"); nameField.placeholderString = L10n.text("Account name")
        nameField.setAccessibilityLabel(L10n.text("Account name")); table.setAccessibilityLabel(L10n.text("Accounts"))
        errorLabel.stringValue = L10n.message(errorLabel.stringValue)
        update(state: state, busy: busy, available: available)
    }

    func update(state: ProfileState?, busy: Bool, available: Bool) {
        let previousPending = self.state?.pending?.id
        self.state = state; self.busy = busy; self.available = available
        let profiles = state?.profiles ?? []
        let oldSelection = selectedID
        if let pending = state?.pending, pending.id != previousPending { selectedID = pending.id }
        if !profiles.contains(where: { $0.id == selectedID }) { selectedID = profiles.first?.id }
        if selectedID != oldSelection { dirtyName = false; errorLabel.stringValue = "" }
        updating = true
        table.reloadData()
        if let index = profiles.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        updating = false
        if !dirtyName { nameField.stringValue = profiles.first(where: { $0.id == selectedID })?.name ?? "" }
        let isEmpty = profiles.isEmpty
        listHeight.constant = CGFloat(min(266, max(90, profiles.count * 44 + 2)))
        empty.isHidden = !isEmpty; scroll.isHidden = isEmpty; editor.isHidden = isEmpty
        empty.stringValue = available ? L10n.text("No accounts yet. Click Add account to get started.") : L10n.text("Accounts are unavailable. Finish recovery from the menu, then return here.")
        pendingBox.isHidden = state?.pending == nil
        if state?.pending?.previousID == nil {
            pendingLabel.stringValue = L10n.text("Sign into the account you want to save in Claude, then click Done, signed in. Cancelling keeps your current Claude login.")
        } else {
            pendingLabel.stringValue = L10n.text("Sign into the new account in Claude, then click Done, signed in. Cancel returns to the previous account.")
        }
        updateButtons()
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 600, height: max(230, stack.fittingSize.height + 40)))
    }

    private func updateButtons() {
        let editable = available && !busy && state?.pending == nil
        addButton.isEnabled = editable
        nameField.isEnabled = editable && selectedID != nil
        saveButton.isEnabled = editable && selectedID != nil && dirtyName
        removeButton.isEnabled = editable && selectedID != nil
        selectButton.isEnabled = editable && selectedID != nil && selectedID != state?.activeID
        finishButton.isEnabled = available && !busy && state?.pending != nil && state?.pending?.id == state?.activeID
        cancelButton.isEnabled = available && !busy && state?.pending != nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { state?.profiles.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let state, state.profiles.indices.contains(row) else { return nil }
        let profile = state.profiles[row]
        let isName = tableColumn?.identifier.rawValue == "name"
        let label = NSTextField(labelWithString: isName ? profile.name : (state.pending?.id == profile.id ? L10n.text("Finish sign-in") : profile.id == state.activeID ? L10n.text("Active") : ""))
        label.font = .systemFont(ofSize: isName ? 13 : 11, weight: isName ? .medium : .regular)
        label.textColor = isName ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView(); cell.addSubview(label); cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let profiles = state?.profiles, profiles.indices.contains(table.selectedRow) else { return }
        selectedID = profiles[table.selectedRow].id; dirtyName = false; errorLabel.stringValue = ""
        nameField.stringValue = profiles[table.selectedRow].name; updateButtons()
    }
    func controlTextDidChange(_ obj: Notification) { dirtyName = true; errorLabel.stringValue = ""; updateButtons() }
    @objc private func saveName() {
        guard saveButton.isEnabled, let id = selectedID else { return }
        do {
            try onRename(id, nameField.stringValue)
            dirtyName = false
            update(state: state, busy: busy, available: available)
        } catch {
            errorLabel.stringValue = error.localizedDescription
            update(state: state, busy: busy, available: available)
        }
    }
    @objc private func addAccount() { if addButton.isEnabled { onAdd() } }
    @objc private func removeAccount() { if removeButton.isEnabled, let id = selectedID { onRemove(id) } }
    @objc private func selectAccount() { if selectButton.isEnabled, let id = selectedID { onSelect(id) } }
    @objc private func finishAdding() { if finishButton.isEnabled { onFinish() } }
    @objc private func cancelAdding() { if cancelButton.isEnabled { onCancel() } }
}
