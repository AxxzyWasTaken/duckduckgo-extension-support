//
//  WebExtensionManager+Enablement.swift
//
//  Copyright © 2026 AxxzyWasTaken. Licensed under the Apache License, Version 2.0.
//  Part of a modified fork of DuckDuckGo for Mac; not affiliated with Duck Duck Go, Inc.
//

import Foundation
import os.log
import WebKit

/// Lets the user switch an installed extension off without uninstalling it.
/// Disabled extensions stay in the installation store and on disk but are never loaded.
@available(macOS 15.4, iOS 18.4, *)
extension WebExtensionManager {

    /// Posted with the extension context whenever its toolbar action (icon, badge, title, enabled state) changes.
    public static let actionDidUpdateNotification = Notification.Name("WebExtensionManager.actionDidUpdate")
    /// Posted with the extension context when it calls `runtime.openOptionsPage()`.
    public static let openOptionsPageNotification = Notification.Name("WebExtensionManager.openOptionsPage")

    private static let disabledIdentifiersKey = "fork.webExtensions.disabledIdentifiers"

    public static var disabledIdentifiers: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledIdentifiersKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledIdentifiersKey) }
    }

    public func isExtensionEnabled(identifier: String) -> Bool {
        !Self.disabledIdentifiers.contains(identifier)
    }

    @MainActor
    public func setExtensionEnabled(_ enabled: Bool, identifier: String) async throws {
        guard installationStore.installedExtension(withUniqueIdentifier: identifier) != nil else { return }

        if enabled {
            Self.disabledIdentifiers.remove(identifier)
            _ = try await loader.loadWebExtension(identifier: identifier, into: controller)
            unloadGuard.recordLoad(of: identifier)
        } else {
            Self.disabledIdentifiers.insert(identifier)
            if context(for: identifier) != nil {
                await unloadGuard.awaitSettled(context(for: identifier))
                try loader.unloadExtension(identifier: identifier, from: controller)
                unregisterHandlers(for: identifier)
            }
        }
        Logger.webExtensions.info("Extension '\(identifier)' \(enabled ? "enabled" : "disabled")")
        notifyUpdate()
    }
}
