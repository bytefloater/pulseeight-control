#if os(macOS)
    import AppKit

    /// Native macOS window chrome that SwiftCrossUI 0.10 has no API for: a preferences-style
    /// toolbar (icon tabs with a selection pill, like Finder Settings), the window subtitle, and a
    /// menu bar without the backend's default View/Help menus, tab items and duplicate commands.
    /// Reaching for AppKit also gives us real keyboard shortcuts.
    @MainActor
    final class MacChrome: NSObject, NSToolbarDelegate {
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
            .settings: "gearshape",
        ]

        private static var appName: String {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "PulseEight Control"
        }

        // MARK: Install

        func install(model: AppModel) async {
            guard self.model == nil else { return }
            self.model = model
            NSWindow.allowsAutomaticWindowTabbing = false

            // SwiftCrossUI creates the window after the first view appears; wait for it.
            for _ in 0..<60 {
                if let found = NSApp.windows.first(where: { $0.canBecomeMain }) {
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
            guard let model, let toolbar, let window else { return }
            if NSApp.mainMenu !== menuBar { installMenus() }
            if let page = model.page {
                toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(page.rawValue)
            }
            let updates = model.state?.updates.count ?? 0
            // Before macOS 26 there is no toolbar badge, so the firmware count rides in the subtitle.
            var subtitle = model.connectionShort
            if updates > 0, #unavailable(macOS 26.0) { subtitle += " · \(updates) firmware update\(updates == 1 ? "" : "s")" }
            window.subtitle = subtitle
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

        private func item(
            _ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
            selector: Selector? = nil, handler: (() -> Void)? = nil
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            if let handler {
                let action = MenuAction(handler)
                actions.append(action)
                item.target = action
                item.action = #selector(MenuAction.fire)
            }
            return item
        }

        private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let submenu = NSMenu(title: title)
            items.forEach(submenu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = submenu
            return holder
        }

        private func installMenus() {
            let name = Self.appName
            let services = NSMenu(title: "Services")
            let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            servicesItem.submenu = services
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
                item("Settings…", ",") { [weak self] in self?.model?.page = .settings },
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
            ]))
            bar.addItem(menu("Edit", [
                item("Undo", "z", selector: Selector(("undo:"))),
                item("Redo", "z", [.command, .shift], selector: Selector(("redo:"))),
                .separator(),
                item("Cut", "x", selector: #selector(NSText.cut(_:))),
                item("Copy", "c", selector: #selector(NSText.copy(_:))),
                item("Paste", "v", selector: #selector(NSText.paste(_:))),
                item("Select All", "a", selector: #selector(NSText.selectAll(_:))),
            ]))
            bar.addItem(menu("Matrix", [
                item("Refresh Now", "r") { [weak self] in self?.model?.retry() },
                .separator(),
                item("Routing", "1") { [weak self] in self?.model?.page = .routing },
                item("Hardware", "2") { [weak self] in self?.model?.page = .hardware },
            ]))
            bar.addItem(windowItem)

            menuBar = bar
            NSApp.mainMenu = bar
            NSApp.servicesMenu = services
            NSApp.windowsMenu = windowItem.submenu
        }
    }
#endif
