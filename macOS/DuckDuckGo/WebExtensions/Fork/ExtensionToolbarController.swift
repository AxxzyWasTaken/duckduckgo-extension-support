//
//  ExtensionToolbarController.swift
//
//  Copyright © 2026 AxxzyWasTaken. Licensed under the Apache License, Version 2.0.
//  Part of a modified fork of DuckDuckGo for Mac; not affiliated with Duck Duck Go, Inc.
//

import AppKit
import Combine
import WebExtensions
import WebKit

/// Puts one toolbar button per user-installed web extension into a navigation bar's `menuButtons` stack.
///
/// Buttons carry `context.uniqueIdentifier` as their identifier, which is what upstream's
/// `WebExtensionWindowTabProvider.presentPopup` looks for when anchoring an action popup.
@available(macOS 15.4, *)
@MainActor
final class ExtensionToolbarController {

    static let actionDidUpdateNotification = Notification.Name("ExtensionToolbarController.actionDidUpdate")
    static let hiddenDidChangeNotification = Notification.Name("ExtensionToolbarController.hiddenDidChange")

    private static let hiddenKey = "fork.extensions.hiddenToolbarIdentifiers"
    private static let buttonSize: CGFloat = 28
    private static let iconSize = NSSize(width: 16, height: 16)

    private weak var stackView: NSStackView?
    private let themeManager: ThemeManaging
    private let selectedTab: () -> Tab?
    private var buttons: [String: ExtensionToolbarButton] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(stackView: NSStackView, themeManager: ThemeManaging, selectedTab: @escaping () -> Tab?) {
        self.stackView = stackView
        self.themeManager = themeManager
        self.selectedTab = selectedTab

        NotificationCenter.default.publisher(for: Self.actionDidUpdateNotification)
            .merge(with: NotificationCenter.default.publisher(for: Self.hiddenDidChangeNotification),
                   NotificationCenter.default.publisher(for: WebExtensionManager.actionDidUpdateNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    /// Call once the extension manager exists. Safe to call repeatedly.
    func start() {
        reload()
        ExtensionManagerUpdates.shared.subscribe()
    }

    // MARK: - Hidden-from-toolbar list

    static var hiddenIdentifiers: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: hiddenKey)
            NotificationCenter.default.post(name: hiddenDidChangeNotification, object: nil)
        }
    }

    // MARK: - Rebuild

    private var manager: WebExtensionManaging? {
        NSApp.delegateTyped.webExtensionManager
    }

    /// User-installed extensions (not DuckDuckGo's bundled ones), in a stable order.
    private func visibleContexts() -> [WKWebExtensionContext] {
        guard let manager else { return [] }
        let hidden = Self.hiddenIdentifiers
        let order = manager.webExtensionIdentifiers
        return manager.loadedExtensions
            .filter { $0.duckDuckGoWebExtensionType == nil && !hidden.contains($0.uniqueIdentifier) }
            .sorted { (order.firstIndex(of: $0.uniqueIdentifier) ?? .max) < (order.firstIndex(of: $1.uniqueIdentifier) ?? .max) }
    }

    func reload() {
        guard let stackView else { return }
        let contexts = visibleContexts()
        let wanted = Set(contexts.map(\.uniqueIdentifier))

        for (identifier, button) in buttons where !wanted.contains(identifier) {
            if stackView.arrangedSubviews.contains(button) { stackView.removeArrangedSubview(button) }
            button.removeFromSuperview()
            buttons[identifier] = nil
        }

        for (offset, context) in contexts.enumerated() {
            let button = buttons[context.uniqueIdentifier] ?? makeButton(for: context)
            let current = stackView.arrangedSubviews.firstIndex(of: button)
            if current != offset {
                // NSStackView asserts when removing a view it doesn't arrange (e.g. a new button).
                if current != nil { stackView.removeArrangedSubview(button) }
                stackView.insertArrangedSubview(button, at: min(offset, stackView.arrangedSubviews.count))
            }
            update(button, with: context)
        }
    }

    func applyTheme() {
        for button in buttons.values {
            style(button)
        }
    }

    private func makeButton(for context: WKWebExtensionContext) -> ExtensionToolbarButton {
        let button = ExtensionToolbarButton(frame: NSRect(x: 0, y: 0, width: Self.buttonSize, height: Self.buttonSize))
        button.identifier = NSUserInterfaceItemIdentifier(context.uniqueIdentifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .shadowlessSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.menu = contextMenu(for: context.uniqueIdentifier)
        style(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
        buttons[context.uniqueIdentifier] = button
        return button
    }

    private func style(_ button: ExtensionToolbarButton) {
        let theme = themeManager.theme
        button.normalTintColor = theme.colorsProvider.iconsColor
        button.mouseOverColor = theme.colorsProvider.buttonMouseOverColor
        button.setCornerRadius(theme.toolbarButtonsCornerRadius)
    }

    private func update(_ button: ExtensionToolbarButton, with context: WKWebExtensionContext) {
        let action = context.action(for: selectedTab())
        let name = context.webExtension.displayShortName ?? context.webExtension.displayName ?? ""
        button.image = action?.icon(for: Self.iconSize) ?? context.webExtension.actionIcon(for: Self.iconSize)
            ?? context.webExtension.icon(for: Self.iconSize)
        let label = action?.label ?? ""
        button.toolTip = label.isEmpty ? name : label
        button.setAccessibilityLabel(name)
        button.badgeText = action?.badgeText ?? ""
        button.isEnabled = action?.isEnabled ?? true
    }

    // MARK: - Actions

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue, let context = manager?.context(for: identifier) else { return }
        // WebKit decides: it fires `action.onClicked` or calls the controller delegate's
        // `presentActionPopup`, which upstream anchors to this button.
        context.performAction(for: selectedTab())
    }

    private func contextMenu(for identifier: String) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = ExtensionContextMenuDelegate.shared
        menu.identifier = NSUserInterfaceItemIdentifier(identifier)
        return menu
    }
}

/// Fans the manager's single-consumer `extensionUpdates` stream out as a notification, so every
/// window's toolbar can listen.
@available(macOS 15.4, *)
@MainActor
final class ExtensionManagerUpdates {
    static let shared = ExtensionManagerUpdates()
    private var task: Task<Void, Never>?
    private weak var subscribedManager: WebExtensionManaging?
    private var optionsObserver: NSObjectProtocol?

    func subscribe() {
        guard let manager = NSApp.delegateTyped.webExtensionManager, manager !== subscribedManager else { return }
        subscribedManager = manager
        task?.cancel()
        if optionsObserver == nil {
            optionsObserver = NotificationCenter.default.addObserver(forName: WebExtensionManager.openOptionsPageNotification,
                                                                     object: nil, queue: .main) { note in
                guard let context = note.object as? WKWebExtensionContext else { return }
                let identifier = context.uniqueIdentifier
                MainActor.assumeIsolated { ExtensionInstaller.openOptions(identifier: identifier) }
            }
        }
        task = Task { @MainActor in
            for await _ in manager.extensionUpdates {
                NotificationCenter.default.post(name: ExtensionToolbarController.actionDidUpdateNotification, object: nil)
            }
        }
    }
}

// MARK: - Right-click menu

@available(macOS 15.4, *)
@MainActor
final class ExtensionContextMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ExtensionContextMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let identifier = menu.identifier?.rawValue,
              let context = NSApp.delegateTyped.webExtensionManager?.context(for: identifier) else { return }

        let title = NSMenuItem(title: context.webExtension.displayName ?? "Extension", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let actionItems = context.action(for: nil)?.menuItems ?? []
        if !actionItems.isEmpty {
            menu.addItem(.separator())
            actionItems.forEach { menu.addItem($0) }
        }

        menu.addItem(.separator())
        if context.optionsPageURL != nil {
            menu.addItem(item("Options…", #selector(openOptions(_:)), identifier))
        }
        menu.addItem(item("Hide from Toolbar", #selector(hide(_:)), identifier))
        menu.addItem(item("Manage Extensions…", #selector(manage(_:)), identifier))
        menu.addItem(.separator())
        menu.addItem(item("Remove “\(context.webExtension.displayName ?? "Extension")”…", #selector(remove(_:)), identifier))
    }

    private func item(_ title: String, _ action: Selector, _ identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = identifier
        return item
    }

    @objc private func openOptions(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        ExtensionInstaller.openOptions(identifier: identifier)
    }

    @objc private func hide(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        ExtensionToolbarController.hiddenIdentifiers.insert(identifier)
    }

    @objc private func manage(_ sender: NSMenuItem) {
        Application.appDelegate.windowControllersManager.showPreferencesTab(withSelectedPane: .extensions)
    }

    @objc private func remove(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        ExtensionInstaller.confirmAndRemove(identifier: identifier)
    }
}

// MARK: - Button

/// A toolbar button that draws the extension's badge text as a small pill over the icon.
@available(macOS 15.4, *)
final class ExtensionToolbarButton: MouseOverButton {

    var badgeText: String = "" {
        didSet {
            guard badgeText != oldValue else { return }
            badgeLabel.stringValue = badgeText
            badgeLabel.isHidden = badgeText.isEmpty
        }
    }

    private lazy var badgeLabel: NSTextField = {
        let label = BadgeLabel(labelWithString: "")
        label.font = .systemFont(ofSize: 8, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.systemRed.cgColor
        label.layer?.cornerRadius = 5
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 1),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
            label.heightAnchor.constraint(equalToConstant: 10),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 10),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 26),
        ])
        return label
    }()

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return super.rightMouseDown(with: event) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    private final class BadgeLabel: NSTextField {
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width += 6
            return size
        }
    }
}
