import AppKit
import SwitcherCore

@MainActor final class TriggerSettingsWindow: NSWindowController {
    private let enabled = NSButton(checkboxWithTitle: "Автоматически запускать окна лимитов", target: nil, action: nil)
    private var accounts: [(UUID, NSButton, NSTextField)] = []
    private let saveAction: (TriggerSettings) throws -> Void
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    init(settings: TriggerSettings, profiles: [Profile], save: @escaping (TriggerSettings) throws -> Void) {
        saveAction = save
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 380 + profiles.count * 48),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Автозапуск окон"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
                                     stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
                                     stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        enabled.state = settings.enabled ? .on : .off; stack.addArrangedSubview(enabled)
        let description = NSTextField(wrappingLabelWithString: "После обновления лимитов: если пятичасовое окно не запущено, отправить короткий запрос. Проверка повторяется после каждого сброса, в любое время суток.")
        description.font = .systemFont(ofSize: 11); description.textColor = .secondaryLabelColor
        description.widthAnchor.constraint(equalToConstant: 392).isActive = true; stack.addArrangedSubview(description)
        let title = NSTextField(labelWithString: "Аккаунты"); title.font = .systemFont(ofSize: 12, weight: .semibold); stack.addArrangedSubview(title)
        for profile in profiles {
            let button = NSButton(checkboxWithTitle: profile.name, target: nil, action: nil)
            button.state = settings.profiles.contains(profile.id) ? .on : .off
            let status = NSTextField(wrappingLabelWithString: "Ещё не запускали")
            status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
            status.widthAnchor.constraint(equalToConstant: 388).isActive = true
            let row = NSStackView(views: [button, status]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 3
            accounts.append((profile.id, button, status)); stack.addArrangedSubview(row)
        }
        let note = NSTextField(wrappingLabelWithString: "Короткий запрос немного расходует лимит. Уже идущее окно не перезапускается. Если вход истёк, потребуется открыть аккаунт в Claude. Для работы после входа в macOS включите автозапуск Claudeway.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 392).isActive = true; stack.addArrangedSubview(note)
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.widthAnchor.constraint(equalToConstant: 392).isActive = true; stack.addArrangedSubview(errorLabel)
        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(saveSettings)); saveButton.bezelStyle = .rounded; saveButton.keyEquivalent = "\r"
        stack.addArrangedSubview(saveButton)
        // Let AppKit measure Russian wrapping instead of relying on a fixed height.
        window.contentView!.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 440, height: stack.fittingSize.height + 48))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ journal: TriggerJournal) {
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        for (id, _, label) in accounts {
            if let record = journal.records[id] { label.stringValue = record.message + " · " + formatter.string(from: record.date) }
            else { label.stringValue = "Ещё не запускали" }
        }
        fitContent()
    }
    private func fitContent() {
        window?.contentView?.layoutSubtreeIfNeeded()
        if let stack = window?.contentView?.subviews.first as? NSStackView {
            window?.setContentSize(NSSize(width: 440, height: stack.fittingSize.height + 48))
        }
    }
    @objc private func saveSettings() {
        var settings = TriggerSettings()
        settings.enabled = enabled.state == .on
        settings.profiles = Set(accounts.filter { $0.1.state == .on }.map { $0.0 })
        if settings.enabled && settings.profiles.isEmpty {
            errorLabel.stringValue = "Выберите хотя бы один аккаунт."; fitContent(); return
        }
        do { try saveAction(settings); close() }
        catch { errorLabel.stringValue = "Не удалось сохранить настройки."; fitContent() }
    }
}
