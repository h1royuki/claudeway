import AppKit
import SwitcherCore

@MainActor final class TransferSettingsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var settings: TransferSettings
    private let projects: [TransferProject]
    private var filtered: [TransferProject] = []
    private let saveAction: (TransferSettings) throws -> Void
    private let mode = NSPopUpButton()
    private let search = NSSearchField()
    private let table = NSTableView()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let all = NSButton()
    private let none = NSButton()
    private let saveButton = NSButton()
    private var busy = false

    init(settings: TransferSettings, projects: [TransferProject], error: String? = nil,
         save: @escaping (TransferSettings) throws -> Void) {
        self.settings = settings; saveAction = save
        let known = Set(projects.map(\.path))
        // Keep checked projects visible even when a drive is disconnected or
        // their last chat was removed; saving must not silently lose selections.
        self.projects = (projects + settings.projects.subtracting(known).map { TransferProject(path: $0, chatCount: 0) })
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = window.contentView!
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        mode.target = self; mode.action = #selector(changeTransferMode)
        stack.addArrangedSubview(mode)
        explanation.font = .systemFont(ofSize: 12); explanation.textColor = .secondaryLabelColor
        stack.addArrangedSubview(explanation)
        search.delegate = self; stack.addArrangedSubview(search)
        table.headerView = nil; table.rowHeight = 50; table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .none; table.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("project")); column.width = 500
        table.addTableColumn(column); table.dataSource = self; table.delegate = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder; scroll.autohidesScrollers = true
        stack.addArrangedSubview(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor; stack.addArrangedSubview(empty)
        all.target = self; all.action = #selector(selectVisibleProjects); all.bezelStyle = .rounded
        none.target = self; none.action = #selector(selectNone); none.bezelStyle = .rounded
        saveButton.target = self; saveButton.action = #selector(saveSettings); saveButton.bezelStyle = .rounded; saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        let actions = NSStackView(views: [all, none, spacer, saveButton]); actions.orientation = .horizontal
        stack.addArrangedSubview(actions)
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.stringValue = error ?? ""; stack.addArrangedSubview(errorLabel)
        for view in [mode, explanation, search, scroll, empty, actions, errorLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        relocalize(); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func relocalize() {
        window?.title = L10n.text("Chat transfer")
        mode.removeAllItems()
        mode.addItems(withTitles: [L10n.text("All projects"), L10n.text("Selected projects only"), L10n.text("Transfer disabled")])
        mode.selectItem(at: TransferSettings.Mode.allCases.firstIndex(of: settings.mode)!)
        explanation.stringValue = L10n.text("Copy and update local Code chats when switching accounts. Excluded projects and existing copies stay untouched. Cloud chats and project files are not transferred.")
        search.placeholderString = L10n.text("Find a project")
        all.title = L10n.text("Select all"); none.title = L10n.text("Deselect all"); saveButton.title = L10n.text("Save")
        errorLabel.stringValue = L10n.message(errorLabel.stringValue)
        reload()
    }
    func setBusy(_ value: Bool) {
        guard busy != value else { return }
        busy = value; reload()
    }
    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = projects.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
        let selecting = settings.mode == .selected && !busy
        mode.isEnabled = !busy; saveButton.isEnabled = !busy
        all.isEnabled = selecting && !filtered.isEmpty; none.isEnabled = selecting && !filtered.isEmpty
        empty.stringValue = projects.isEmpty
            ? L10n.text("Projects appear here after local Code chats are created.")
            : (filtered.isEmpty ? L10n.text("No matching projects") : L10n.text("Selected: %@ of %@", String(settings.projects.count), String(projects.count)))
        if !projects.isEmpty && !filtered.isEmpty {
            switch settings.mode {
            case .all: empty.stringValue = L10n.text("New projects are included automatically.")
            case .disabled: empty.stringValue = L10n.text("Transfer disabled")
            case .selected: empty.stringValue += " · " + L10n.text("New projects must be selected manually.")
            }
        }
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let project = filtered[row]
        let button = NSButton(checkboxWithTitle: project.name, target: self, action: #selector(toggleProject(_:)))
        button.tag = row; button.state = settings.includes(project.path) ? .on : .off
        button.isEnabled = !busy && settings.mode == .selected
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.setAccessibilityLabel(project.path)
        let path = NSTextField(labelWithString: project.path); path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let count = NSTextField(labelWithString: L10n.text("Chats: %@", String(project.chatCount)))
        count.font = .systemFont(ofSize: 11); count.textColor = .secondaryLabelColor
        let header = NSStackView(views: [button, NSView(), count]); header.orientation = .horizontal
        let cell = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false; path.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(header); cell.addSubview(path)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            path.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 28),
            path.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            path.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2)
        ])
        return cell
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    @objc private func changeTransferMode() {
        settings.mode = TransferSettings.Mode.allCases[mode.indexOfSelectedItem]; reload()
    }
    @objc private func toggleProject(_ sender: NSButton) {
        guard !busy, settings.mode == .selected, filtered.indices.contains(sender.tag) else { return }
        let path = filtered[sender.tag].path
        if sender.state == .on { settings.projects.insert(path) } else { settings.projects.remove(path) }
        reload()
    }
    @objc private func selectVisibleProjects() { settings.projects.formUnion(filtered.map(\.path)); reload() }
    @objc private func selectNone() { settings.projects.subtract(filtered.map(\.path)); reload() }
    @objc private func saveSettings() {
        guard !busy else { return }
        do { try saveAction(settings); close() }
        catch { errorLabel.stringValue = error.localizedDescription }
    }
}
