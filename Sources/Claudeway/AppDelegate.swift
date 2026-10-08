import AppKit
import ServiceManagement
import SwitcherCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: ProfileStore!
    private var coordinator: SwitchCoordinator!
    private var state: ProfileState?
    private var busy = false
    private var fatalError: String?
    private var usage: UsageController!
    private var usageTimer: Timer?
    private let transferNotifications = TransferNotifications()
    private var trigger: TriggerEngine?
    private var triggerSettings = TriggerSettings()
    private var triggerWindow: TriggerSettingsWindow?
    private var triggerError: String?
    private var pendingTriggerSamples: [UUID: AccountUsage] = [:]
    private var menuOpen = false
    private let demo = CommandLine.arguments.contains("--demo")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = BrandIcon.menuBar()
        statusItem.button?.imagePosition = .imageLeading
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = demo ? FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Claudeway-Demo-\(ProcessInfo.processInfo.processIdentifier)") : support
        // Preserve the pre-Claudeway data location so existing profiles remain available.
        store = ProfileStore(root: base.appendingPathComponent("ClaudeSwitcher"), live: base.appendingPathComponent("Claude"))
        coordinator = SwitchCoordinator(store: store, lifecycle: demo ? DemoLifecycle() : ClaudeProcess())
        usage = UsageController(root: store.root, live: store.live, demo: demo)
        usage.onChange = { [weak self] in guard let self, !self.menuOpen else { return }; self.refresh() }
        usage.onRefreshCompleted = { [weak self] samples in
            guard let self else { return }
            for sample in samples { self.pendingTriggerSamples[sample.profileID] = sample }
            self.triggerTick()
        }
        do {
            try store.acquireLock()
            if demo {
                try writeDemoLogin()
                state = try store.initialize(requireStopped: {})
                state = try store.add(L10n.text("Work"))
                if let id = state?.pending?.id {
                    try store.switchProfile(to: id, requireStopped: {})
                    try writeDemoLogin()
                    state = try store.finishAdding(requireStopped: {})
                }
                refresh()
            } else if store.needsRecovery || store.needsPreparation {
                run(L10n.text("Preparing shared profile…")) { try await self.coordinator.prepare() }
            } else {
                state = try store.load()
                refresh()
            }
        } catch {
            fatalError = error.localizedDescription
            refresh()
            showError(error)
        }
        if !demo {
            do {
                triggerSettings = try TriggerSettings.load(at: store.root)
                trigger = try TriggerEngine(root: store.root, backend: DesktopTriggerBackend(root: store.root, live: store.live))
                trigger?.onUsage = { [weak self] sample in self?.usage.accept(sample) }
                trigger?.onChange = { [weak self] in
                    guard let self else { return }
                    if let journal = self.trigger?.journal { self.triggerWindow?.update(journal) }
                    if !self.menuOpen { self.refresh() }
                }
            } catch { triggerError = L10n.text("Automatic window starts unavailable: check the settings and journal files") }
        }
        refresh()
        if let state { usage.refresh(state, allowKeychainPrompt: CommandLine.arguments.contains("--enable-live-usage")) }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.busy, let state = self.state else { return }
                self.triggerTick()
                if !self.busy { self.usage.refresh(state) }
            }
        }
        DispatchQueue.main.async { [weak self] in
            if CommandLine.arguments.contains("--trigger-settings") { self?.showTriggerSettings() }
            self?.triggerTick()
        }
    }

    private func item(_ title: String, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: "")
        result.target = self
        result.isEnabled = enabled && !busy
        return result
    }

    private func refresh(status: String? = nil) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.button?.title = busy ? " …" : ""
        statusItem.button?.toolTip = nil
        if demo { menu.addItem(item(L10n.text("Demo"), enabled: false)) }
        if let status { menu.addItem(item(status, enabled: false)) }
        if fatalError != nil { menu.addItem(item(L10n.text("Could not open profiles"), enabled: false)) }
        if store.needsRecovery || store.needsPreparation {
            menu.addItem(item(L10n.text("Prepare / recover shared profile…"), action: #selector(recover)))
        } else if fatalError == nil, let state {
            for profile in state.profiles {
                let row = item(profile.name, action: #selector(selectProfile(_:)), enabled: state.pending == nil || profile.id == state.pending?.id)
                row.representedObject = profile.id.uuidString
                row.view = UsageMenuRow(profile: profile, active: profile.id == state.activeID,
                    usage: usage.values[profile.id], error: usage.errors[profile.id], enabled: row.isEnabled) { [weak self] in
                        self?.selectProfile(id: profile.id)
                    }
                menu.addItem(row)
            }
            menu.addItem(.separator())
            if let pending = state.pending {
                menu.addItem(item(L10n.text("Sign into the new account in Claude"), enabled: false))
                menu.addItem(item(L10n.text("Done, signed in"), action: #selector(finishAdding), enabled: state.activeID == pending.id))
                menu.addItem(item(L10n.text("Cancel adding account"), action: #selector(cancelAdding)))
            } else {
                menu.addItem(item(L10n.text("Add account…"), action: #selector(addAccount)))
            }
            menu.addItem(item(usage.refreshing ? L10n.text("Refreshing…") : L10n.text("Refresh usage"), action: #selector(refreshUsage), enabled: !usage.refreshing))
        }
        if let state, state.pending == nil, let trigger {
            let submenu = NSMenu(); submenu.autoenablesItems = false
            for profile in state.profiles {
                let action = item(profile.name, action: #selector(triggerAccount(_:)))
                action.representedObject = profile.id.uuidString; submenu.addItem(action)
                if let record = trigger.journal.records[profile.id] {
                    let status = item(record.displayMessage, enabled: false); status.indentationLevel = 1; submenu.addItem(status)
                }
            }
            submenu.addItem(.separator())
            submenu.addItem(item(L10n.text("All accounts"), action: #selector(triggerAll)))
            let entry = item(trigger.running ? L10n.text("Starting usage window…") : L10n.text("Start usage window"))
            entry.submenu = submenu; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let settings = NSMenu(); settings.autoenablesItems = false
        let languages = NSMenu(); languages.autoenablesItems = false
        for language in AppLanguage.allCases {
            let choice = item(language.nativeName, action: #selector(selectLanguage(_:)))
            choice.representedObject = language.rawValue
            choice.state = L10n.preference == language ? .on : .off
            languages.addItem(choice)
        }
        let languageItem = item(L10n.text("Language")); languageItem.submenu = languages
        settings.addItem(languageItem)
        settings.addItem(.separator())
        settings.addItem(item(L10n.text("Automatic window starts…"), action: #selector(showTriggerSettings), enabled: trigger != nil && state?.pending == nil))
        if let triggerError { settings.addItem(item(L10n.message(triggerError), enabled: false)) }
        settings.addItem(item(L10n.text("Rename current account…"), action: #selector(renameAccount), enabled: state?.pending == nil))
        let login = item(L10n.text("Launch at login"), action: #selector(toggleLogin), enabled: !demo)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settings.addItem(login)
        settings.addItem(item(L10n.text("Shared settings and local chats"), enabled: false))
        settings.addItem(.separator())
        settings.addItem(item(L10n.text("Quit Claudeway"), action: #selector(quit)))
        let settingsItem = item(L10n.text("Settings")); settingsItem.submenu = settings; menu.addItem(settingsItem)
        statusItem.menu = menu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, let language = AppLanguage(rawValue: code) else { return }
        L10n.select(language)
        triggerWindow?.relocalize()
        if let trigger { triggerWindow?.update(trigger.journal) }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Use the existing rows while tracking; rebuilding an open native menu disrupts clicks.
        menuOpen = true
        for item in menu.items { (item.view as? UsageMenuRow)?.setMenuHighlighted(false) }
    }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for row in menu.items {
            (row.view as? UsageMenuRow)?.setMenuHighlighted(item === row)
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        for item in menu.items { (item.view as? UsageMenuRow)?.setMenuHighlighted(false) }
        DispatchQueue.main.async { [weak self] in self?.refresh(); self?.triggerTick() }
    }
    @objc private func refreshUsage() { if !busy, let state { usage.refresh(state, force: true, allowKeychainPrompt: true) } }

    private func run(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        _ = coordinator.takeTransferReport()
        usage.pause()
        pendingTriggerSamples.removeAll()
        busy = true
        refresh(status: label)
        Task { @MainActor in
            do {
                try await action()
                state = try store.load()
                fatalError = nil
                if !demo, let report = coordinator.takeTransferReport(),
                   let state, let active = state.profiles.first(where: { $0.id == state.activeID }) {
                    transferNotifications.post(report, account: active.name)
                }
            } catch {
                state = try? store.load()
                showError(error)
            }
            busy = false
            if let state { usage.refresh(state) }
            refresh()
        }
    }

    private func triggerTick() {
        guard !busy, !menuOpen, !usage.refreshing, fatalError == nil, !store.needsRecovery, !store.needsPreparation, let state, state.pending == nil, let trigger else { return }
        let samples = Array(pendingTriggerSamples.values)
        pendingTriggerSamples.removeAll()
        do { try trigger.observe(samples, profiles: state.profiles) }
        catch { triggerError = L10n.text("Could not save the window-start journal"); refresh(); return }
        let ids = trigger.automaticTargets(settings: triggerSettings, profiles: state.profiles, samples: samples)
        if !ids.isEmpty { startTrigger(ids, automatic: true); return }
        let verify = trigger.verificationTargets().filter { id in state.profiles.contains { $0.id == id } }
        if !verify.isEmpty { startTrigger(verify, verifyOnly: true) }

    }
    private func startTrigger(_ ids: [UUID], automatic: Bool = false, verifyOnly: Bool = false) {
        guard !busy, fatalError == nil, !store.needsRecovery, !store.needsPreparation, let state, state.pending == nil, let trigger else { return }
        busy = true; usage.pause(); refresh()
        Task { @MainActor in
            do { try await trigger.run(profiles: state.profiles, ids: ids, automatic: automatic, verifyOnly: verifyOnly, allowPrompt: !automatic && !verifyOnly) }
            catch {
                triggerError = L10n.text("Could not save the window-start journal")
                if !automatic && !verifyOnly { showError(error) }
            }
            busy = false; usage.reloadPolling(); refresh()
        }
    }
    @objc private func triggerAccount(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        startTrigger([id])
    }
    @objc private func triggerAll() { if let state { startTrigger(state.profiles.map(\.id)) } }
    @objc private func showTriggerSettings() {
        guard !busy, let state, let trigger else { return }
        triggerWindow = TriggerSettingsWindow(settings: triggerSettings, profiles: state.profiles) { [weak self] settings in
            guard let self else { return }
            try settings.save(at: self.store.root); self.triggerSettings = settings
            if !self.busy, let state = self.state { self.usage.refresh(state, force: true, allowKeychainPrompt: true) }
        }
        triggerWindow?.update(trigger.journal)
        NSApp.activate(ignoringOtherApps: true); triggerWindow?.showWindow(nil); triggerWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        selectProfile(id: id)
    }

    private func selectProfile(id: UUID) {
        run(L10n.text("Switching…")) { try await self.coordinator.select(id) }
    }

    @objc private func addAccount() {
        guard !busy, let name = askName(title: L10n.text("Add account"), value: "", message: L10n.text("Enter a name, such as Personal or Work. Claude will restart at the sign-in screen with shared settings. Sign into the account, then choose “Done, signed in” in the menu.")) else { return }
        run(L10n.text("Adding account…")) {
            let next = try self.store.add(name)
            self.state = next
            if let id = next.pending?.id { try await self.coordinator.select(id) }
        }
    }

    @objc private func finishAdding() {
        guard !busy else { return }
        run(L10n.text("Saving login…")) { try await self.coordinator.finishAdding() }
    }

    @objc private func cancelAdding() {
        guard let pending = state?.pending else { return }
        run(L10n.text("Returning to the original account…")) {
            try await self.coordinator.select(pending.previousID)
            self.state = try self.store.cancelAdding()
        }
    }

    @objc private func renameAccount() {
        guard !busy, let state, let current = state.profiles.first(where: { $0.id == state.activeID }),
              let name = askName(title: L10n.text("Rename profile"), value: current.name, message: L10n.text("This name is only displayed in Claudeway.")) else { return }
        do { self.state = try store.rename(current.id, to: name); refresh() } catch { showError(error) }
    }

    private func askName(title: String, value: String, message: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("Save"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 24))
        input.stringValue = value
        input.placeholderString = L10n.text("Account name")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
    }

    @objc private func recover() {
        run(L10n.text("Recovering…")) { try await self.coordinator.recover() }
    }

    @objc private func toggleLogin() {
        guard !busy, !demo else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
            refresh()
        } catch { showError(error) }
    }

    private func writeDemoLogin() throws {
        let data = try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": UUID().uuidString, "oauth:tokenCache": "demo-not-a-real-token"])
        try FileManager.default.createDirectory(at: store.live, withIntermediateDirectories: true)
        try data.write(to: store.live.appendingPathComponent("config.json"), options: .atomic)
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Claudeway"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }

    @objc private func quit() { if !busy { NSApp.terminate(nil) } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        busy ? .terminateCancel : .terminateNow
    }
}
