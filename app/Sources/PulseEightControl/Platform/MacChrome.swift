import AppKit
import PulseEightCore
import PulseEightKit

/// Native macOS window chrome that SwiftCrossUI 0.10 has no API for: a preferences-style
/// toolbar (icon tabs with a selection pill, like Finder Settings), the window subtitle, and a
/// menu bar without the backend's default View/Help menus, tab items and duplicate commands.
/// Reaching for AppKit also gives us real keyboard shortcuts.
@MainActor
final class MacChrome: NSObject, NSToolbarDelegate, NSMenuDelegate {
    static let shared = MacChrome()

    private weak var model: AppModel?
    private weak var window: NSWindow?
    private var toolbar: NSToolbar?
    /// Keeps closure targets alive; NSMenuItem.target is weak.
    private var actions: [MenuAction] = []
    private var menuBar: NSMenu?

    private static let symbols: [Page: String] = [
        .routing: "square.grid.3x3",
        .hardware: "cpu",
    ]

    static let mainWindowTitle = "PulseEight Control"

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "PulseEight Control"
    }

    // MARK: Install

    func install(model: AppModel) async {
        guard self.model == nil else { return }
        self.model = model
        model.openSettingsWindow = { [weak model] in
            guard let model else { return }
            NativeSettings.show(model: model)
        }
        NSWindow.allowsAutomaticWindowTabbing = false

        // SwiftCrossUI creates the window after the first view appears; wait for it.
        for _ in 0..<60 {
            if let found = NSApp.windows.first(where: { $0.title == Self.mainWindowTitle }) {
                window = found
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let window else { return }

        window.tabbingMode = .disallowed
        let toolbar = NSToolbar(identifier: "PulseEightControl.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = Set(Page.allCases.map { NSToolbarItem.Identifier($0.rawValue) })
        window.toolbarStyle = .preference
        window.toolbar = toolbar
        self.toolbar = toolbar

        // The backend applies its own menu bar when the scene appears; replace it afterwards.
        try? await Task.sleep(nanoseconds: 300_000_000)
        installMenus()
        sync()
    }

    /// Pushes model state into the window: selected tab, subtitle, firmware badge.
    func sync() {
        guard let model, let toolbar, window != nil else { return }
        if NSApp.mainMenu !== menuBar { installMenus() }
        if let page = model.page {
            toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(page.rawValue)
        }
        let updates = model.updateCount
        if #available(macOS 26.0, *) {
            for item in toolbar.items where item.itemIdentifier.rawValue == Page.hardware.rawValue {
                item.badge = updates > 0 ? NSItemBadge.count(updates) : nil
            }
        }
    }

    // MARK: NSToolbarDelegate

    private var pageIdentifiers: [NSToolbarItem.Identifier] {
        Page.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { pageIdentifiers }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { pageIdentifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { pageIdentifiers }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let page = Page(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = page.description
        item.paletteLabel = page.description
        item.image = NSImage(systemSymbolName: Self.symbols[page] ?? "circle", accessibilityDescription: page.description)
        item.target = self
        item.action = #selector(selectPage(_:))
        return item
    }

    @objc private func selectPage(_ sender: NSToolbarItem) {
        model?.page = Page(rawValue: sender.itemIdentifier.rawValue)
    }

    // MARK: Menus

    private final class MenuAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    /// Re-evaluated each time a menu opens: check mark and enabled state.
    private var itemStates: [ObjectIdentifier: () -> (checked: Bool, enabled: Bool)] = [:]

    private func item(
        _ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
        selector: Selector? = nil,
        state: (() -> (checked: Bool, enabled: Bool))? = nil,
        handler: (() -> Void)? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if let handler {
            let action = MenuAction(handler)
            actions.append(action)
            item.target = action
            item.action = #selector(MenuAction.fire)
        }
        if let state { itemStates[ObjectIdentifier(item)] = state }
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem], dynamic: Bool = false) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = !dynamic
        if dynamic { submenu.delegate = self }
        items.forEach(submenu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        return holder
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if let state = itemStates[ObjectIdentifier(item)]?() {
                item.state = state.checked ? .on : .off
                item.isEnabled = state.enabled
            }
            if let submenu = item.submenu { menuNeedsUpdate(submenu) }
        }
    }

    // MARK: Menu helpers

    private var features: SystemFeatures? { model?.state?.system?.features }
    private var hasHost: Bool { model?.settings.matrix.host?.isEmpty == false }

    private var matrixAddress: String? {
        guard let config = model?.settings.matrix, let host = config.host, !host.isEmpty else { return nil }
        return config.port == 80 ? host : "\(host):\(config.port)"
    }

    private func showPage(_ page: Page) { model?.page = page }

    private func openWebInterface() {
        guard let address = matrixAddress, let url = URL(string: "http://\(address)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyAddress() {
        guard let address = matrixAddress else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    private func showSettingsFolder() {
        try? FileManager.default.createDirectory(at: ConfigPaths.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ConfigPaths.directory)
    }

    private func backlightItem(_ title: String, _ level: BacklightLevel) -> NSMenuItem {
        item(
            title,
            state: { [weak self] in
                guard let self, let features = self.features else { return (false, false) }
                let supported = features.backlightLED != nil && self.model?.adminConfigured == true
                return (features.backlight == level, supported)
            },
            handler: { [weak self] in self?.model?.setBacklight(level) }
        )
    }

    private func installMenus() {
        let name = Self.appName
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services

        let backlight = NSMenuItem(title: "Backlight", action: nil, keyEquivalent: "")
        let backlightMenu = NSMenu(title: "Backlight")
        backlightMenu.autoenablesItems = false
        backlightMenu.delegate = self
        [backlightItem("Off", .off), backlightItem("Dim", .low), backlightItem("Bright", .high)]
            .forEach(backlightMenu.addItem)
        backlight.submenu = backlightMenu

        func pageItem(_ title: String, _ key: String, _ page: Page) -> NSMenuItem {
            item(title, key, state: { [weak self] in (self?.model?.page == page, true) }) { [weak self] in
                self?.showPage(page)
            }
        }

        let windowItem = menu("Window", [
            item("Minimize", "m", selector: #selector(NSWindow.performMiniaturize(_:))),
            item("Zoom", selector: #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", selector: #selector(NSApplication.arrangeInFront(_:))),
        ])

        let bar = NSMenu()
        bar.addItem(menu(name, [
            item("About \(name)", selector: #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", ",", handler: { [weak self] in self?.model?.openSettings() }),
            .separator(),
            servicesItem,
            .separator(),
            item("Hide \(name)", "h", selector: #selector(NSApplication.hide(_:))),
            item("Hide Others", "h", [.command, .option], selector: #selector(NSApplication.hideOtherApplications(_:))),
            item("Show All", selector: #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", "q", selector: #selector(NSApplication.terminate(_:))),
        ]))
        bar.addItem(menu("File", [
            item("Close", "w", selector: #selector(NSWindow.performClose(_:))),
            .separator(),
            item("Open Matrix Web Interface", "o", [.command, .shift],
                 state: { [weak self] in (false, self?.hasHost == true) },
                 handler: { [weak self] in self?.openWebInterface() }),
            item("Show Settings Folder in Finder", handler: { [weak self] in self?.showSettingsFolder() }),
        ], dynamic: true))
        bar.addItem(menu("Edit", [
            item("Undo", "z", selector: Selector(("undo:"))),
            item("Redo", "z", [.command, .shift], selector: Selector(("redo:"))),
            .separator(),
            item("Cut", "x", selector: #selector(NSText.cut(_:))),
            item("Copy", "c", selector: #selector(NSText.copy(_:))),
            item("Paste", "v", selector: #selector(NSText.paste(_:))),
            item("Select All", "a", selector: #selector(NSText.selectAll(_:))),
        ]))
        bar.addItem(menu("View", [
            pageItem("Routing", "1", .routing),
            pageItem("Hardware", "2", .hardware),
            .separator(),
            item("Highlight Row and Column", state: { [weak self] in (self?.model?.settings.highlightGrid == true, true) }) {
                [weak self] in
                guard let model = self?.model else { return }
                model.setHighlightGrid(!model.settings.highlightGrid)
            },
            item("Show Status Bar", "/", state: { [weak self] in (self?.model?.settings.showStatusBar == true, true) }) {
                [weak self] in
                guard let model = self?.model else { return }
                model.setShowStatusBar(!model.settings.showStatusBar)
            },
        ], dynamic: true))
        bar.addItem(menu("Matrix", [
            item("Refresh Now", "r", state: { [weak self] in (false, self?.hasHost == true) }) { [weak self] in
                self?.model?.retry()
            },
            item("Reconnect", "r", [.command, .option], state: { [weak self] in (false, self?.hasHost == true) }) {
                [weak self] in self?.model?.reconnect()
            },
            .separator(),
            backlight,
            item("Status LED", state: { [weak self] in
                guard let self, let features = self.features else { return (false, false) }
                return (features.statusLEDOn == true, features.statusLED != nil && self.model?.adminConfigured == true)
            }) { [weak self] in
                guard let self, let on = self.features?.statusLEDOn else { return }
                self.model?.setStatusLED(on: !on)
            },
            .separator(),
            item("Copy Matrix Address", "c", [.command, .shift], state: { [weak self] in (false, self?.matrixAddress != nil) }) {
                [weak self] in self?.copyAddress()
            },
        ], dynamic: true))
        bar.addItem(windowItem)

        menuBar = bar
        NSApp.mainMenu = bar
        NSApp.servicesMenu = services
        NSApp.windowsMenu = windowItem.submenu
    }
}
