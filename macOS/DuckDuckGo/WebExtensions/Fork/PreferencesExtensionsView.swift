//
//  PreferencesExtensionsView.swift
//
//  Copyright © 2026 AxxzyWasTaken. Licensed under the Apache License, Version 2.0.
//  Part of a modified fork of DuckDuckGo for Mac; not affiliated with Duck Duck Go, Inc.
//

import AppKit
import Combine
import PreferencesUI_macOS
import SwiftUI
import WebExtensions
import WebKit

@MainActor
final class ExtensionsPreferencesModel: ObservableObject {

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let version: String?
        let icon: NSImage?
        let isEnabled: Bool
        let isInToolbar: Bool
        let hasOptions: Bool
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isAvailable = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        let center = NotificationCenter.default
        var names: [Notification.Name] = []
        if #available(macOS 15.4, *) {
            names = [ExtensionToolbarController.actionDidUpdateNotification,
                     ExtensionToolbarController.hiddenDidChangeNotification]
        }
        Publishers.MergeMany(names.map { center.publisher(for: $0) })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    func refresh() {
        guard #available(macOS 15.4, *), let manager = NSApp.delegateTyped.webExtensionManager as? WebExtensionManager else {
            isAvailable = false
            rows = []
            return
        }
        isAvailable = true
        ExtensionManagerUpdates.shared.subscribe()
        let hidden = ExtensionToolbarController.hiddenIdentifiers
        rows = manager.installationStore.installedExtensions
            .filter { !$0.isEmbedded }
            .map { installed in
                let context = manager.context(for: installed.uniqueIdentifier)
                return Row(id: installed.uniqueIdentifier,
                           name: context?.webExtension.displayName ?? installed.name ?? installed.filename,
                           version: context?.webExtension.displayVersion ?? installed.version,
                           icon: context?.webExtension.icon(for: NSSize(width: 32, height: 32)),
                           isEnabled: manager.isExtensionEnabled(identifier: installed.uniqueIdentifier),
                           isInToolbar: !hidden.contains(installed.uniqueIdentifier),
                           hasOptions: context?.optionsPageURL != nil)
            }
    }

    func install() {
        guard #available(macOS 15.4, *) else { return }
        ExtensionInstaller.chooseAndInstall()
    }

    func installFromLink() {
        guard #available(macOS 15.4, *) else { return }
        ExtensionInstaller.promptForStoreURL()
    }

    func setEnabled(_ enabled: Bool, for row: Row) {
        guard #available(macOS 15.4, *), let manager = NSApp.delegateTyped.webExtensionManager as? WebExtensionManager else { return }
        Task { @MainActor in
            try? await manager.setExtensionEnabled(enabled, identifier: row.id)
            refresh()
        }
    }

    func setInToolbar(_ visible: Bool, for row: Row) {
        guard #available(macOS 15.4, *) else { return }
        if visible {
            ExtensionToolbarController.hiddenIdentifiers.remove(row.id)
        } else {
            ExtensionToolbarController.hiddenIdentifiers.insert(row.id)
        }
    }

    func openOptions(for row: Row) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionInstaller.openOptions(identifier: row.id)
    }

    func remove(_ row: Row) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionInstaller.confirmAndRemove(identifier: row.id)
        refresh()
    }
}

extension Preferences {

    struct ExtensionsView: View {
        @StateObject private var model = ExtensionsPreferencesModel()

        var body: some View {
            PreferencePane("Extensions") {
                PreferencePaneSection {
                    Text("Chrome and Firefox extensions run on WebKit's extension engine. Most Manifest V3 extensions work; ones that need Chrome's blocking webRequest (like the original uBlock Origin) don't.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Install from File…") { model.install() }
                        Button("Install from Link…") { model.installFromLink() }
                    }
                    .disabled(!model.isAvailable)
                }

                PreferencePaneSection("Installed") {
                    if model.rows.isEmpty {
                        Text(model.isAvailable ? "No extensions installed." : "Extensions need macOS 15.4 or later.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(model.rows) { row in
                        ExtensionRow(row: row, model: model)
                        if row != model.rows.last {
                            Divider()
                        }
                    }
                }
            }
            .onAppear { model.refresh() }
        }
    }

    private struct ExtensionRow: View {
        let row: ExtensionsPreferencesModel.Row
        let model: ExtensionsPreferencesModel

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let icon = row.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "puzzlepiece.extension").resizable().foregroundColor(.secondary)
                    }
                }
                .frame(width: 24, height: 24)
                .opacity(row.isEnabled ? 1 : 0.4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).fontWeight(.medium)
                    if let version = row.version {
                        Text("Version \(version)").font(.caption).foregroundColor(.secondary)
                    }
                }

                Spacer()

                Toggle("Show in toolbar", isOn: Binding(get: { row.isInToolbar }, set: { model.setInToolbar($0, for: row) }))
                    .toggleStyle(.checkbox)
                    .disabled(!row.isEnabled)

                if row.hasOptions {
                    Button("Options") { model.openOptions(for: row) }
                        .disabled(!row.isEnabled)
                }
                Button("Remove") { model.remove(row) }

                Toggle("", isOn: Binding(get: { row.isEnabled }, set: { model.setEnabled($0, for: row) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(row.isEnabled ? "Turn off" : "Turn on")
            }
            .padding(.vertical, 4)
        }
    }
}
