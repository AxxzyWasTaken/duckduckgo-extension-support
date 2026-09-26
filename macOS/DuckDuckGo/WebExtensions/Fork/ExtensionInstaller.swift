//
//  ExtensionInstaller.swift
//
//  Copyright © 2026 AxxzyWasTaken. Licensed under the Apache License, Version 2.0.
//  Part of a modified fork of DuckDuckGo for Mac; not affiliated with Duck Duck Go, Inc.
//

import AppKit
import UniformTypeIdentifiers
import WebExtensions
import WebKit
import ZIPFoundation

/// Installs extensions from a folder, .zip, Firefox .xpi, Chrome .crx, or a Chrome Web Store /
/// addons.mozilla.org page URL.
///
/// Everything is unpacked into a temporary folder first (folder installs are the path upstream's
/// manager handles most reliably), the user sees what the extension asks for, and only then is it
/// handed to `WebExtensionManager.installExtension(from:)`, which copies it into its own storage.
@available(macOS 15.4, *)
@MainActor
enum ExtensionInstaller {

    enum InstallError: LocalizedError {
        case unsupportedFile
        case invalidCRX
        case noManifest
        case unsupportedURL
        case downloadFailed(String)
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedFile: return "This file isn't a browser extension. Choose a folder, .zip, .xpi or .crx file."
            case .invalidCRX: return "This .crx file is damaged or isn't a Chrome extension."
            case .noManifest: return "No manifest.json was found in this extension."
            case .unsupportedURL: return "Paste a Chrome Web Store or addons.mozilla.org extension page link."
            case .downloadFailed(let reason): return "The extension couldn't be downloaded. \(reason)"
            case .unavailable: return "Extensions aren't available right now."
            }
        }
    }

    private static var manager: WebExtensionManaging? { NSApp.delegateTyped.webExtensionManager }

    // MARK: - Entry points

    static func chooseAndInstall(window: NSWindow? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Install Extension"
        panel.prompt = "Install"
        panel.message = "Choose an unpacked extension folder, or a .zip, .xpi (Firefox) or .crx (Chrome) file."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.folder, .zip] + ["xpi", "crx"].compactMap { UTType(filenameExtension: $0) }

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await install(from: url) }
        }
        if let window = window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    static func promptForStoreURL() {
        let alert = NSAlert()
        alert.messageText = "Install Extension from Link"
        alert.informativeText = "Paste the extension's page from the Chrome Web Store or addons.mozilla.org."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://chromewebstore.google.com/detail/…"
        if let clip = NSPasteboard.general.string(forType: .string), storeSource(for: clip) != nil {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                let file = try await download(from: text)
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                await install(from: file)
            } catch {
                present(error)
            }
        }
    }

    /// Installs from a local folder or archive. Shows the permission summary and any error.
    static func install(from url: URL) async {
        guard let manager else { return present(InstallError.unavailable) }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            let folder = try unpack(url, into: staging)
            let webExtension = try await WKWebExtension(resourceBaseURL: folder)
            guard confirmInstall(of: webExtension) else { return }
            try await manager.installExtension(from: folder)
        } catch {
            present(error)
        }
    }

    // MARK: - Unpacking

    /// Returns a folder containing `manifest.json`.
    static func unpack(_ url: URL, into staging: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let destination = staging.appendingPathComponent("extension", isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw InstallError.unsupportedFile }

        if isDirectory.boolValue {
            try fm.copyItem(at: url, to: destination)
        } else {
            switch url.pathExtension.lowercased() {
            case "zip", "xpi":
                try fm.unzipItem(at: url, to: destination)
            case "crx":
                let zip = staging.appendingPathComponent("extension.zip")
                try zipPayload(ofCRX: Data(contentsOf: url)).write(to: zip)
                try fm.unzipItem(at: zip, to: destination)
            default:
                throw InstallError.unsupportedFile
            }
        }
        return try manifestRoot(in: destination)
    }

    /// Strips the CRX2/CRX3 header, leaving the zip archive that follows it.
    static func zipPayload(ofCRX data: Data) throws -> Data {
        let bytes = [UInt8](data)
        func uint32(at offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        var start: Int?
        if bytes.count > 16, bytes[0..<4] == [0x43, 0x72, 0x32, 0x34] /* Cr24 */ {
            switch uint32(at: 4) {
            case 3: start = 12 + uint32(at: 8)
            case 2: start = 16 + uint32(at: 8) + uint32(at: 12)
            default: break
            }
        }
        if start == nil || start! + 4 > bytes.count || Array(bytes[start!..<start! + 4]) != zipMagic {
            start = (0..<max(0, bytes.count - 3)).first { Array(bytes[$0..<$0 + 4]) == zipMagic }
        }
        guard let start else { throw InstallError.invalidCRX }
        return data.subdata(in: start..<data.count)
    }

    /// Archives sometimes wrap everything in one top-level folder; find where manifest.json lives.
    private static func manifestRoot(in folder: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let children = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let dirs = children.filter { $0.lastPathComponent != "__MACOSX" && $0.hasDirectoryPath }
        if dirs.count == 1, fm.fileExists(atPath: dirs[0].appendingPathComponent("manifest.json").path) { return dirs[0] }
        throw InstallError.noManifest
    }

    // MARK: - Store links

    private enum StoreSource {
        case chrome(id: String)
        case firefox(slug: String)
    }

    private static func storeSource(for text: String) -> StoreSource? {
        guard let url = URL(string: text), let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "chromewebstore.google.com" || host == "chrome.google.com" {
            if let id = parts.last(where: { $0.count == 32 && $0.allSatisfy { ("a"..."p").contains($0) } }) {
                return .chrome(id: id)
            }
        }
        if host == "addons.mozilla.org", let index = parts.firstIndex(of: "addon"), index + 1 < parts.count {
            return .firefox(slug: parts[index + 1])
        }
        return nil
    }

    /// Downloads the store's package into a fresh temporary folder and returns the file.
    private static func download(from text: String) async throws -> URL {
        guard let source = storeSource(for: text) else { throw InstallError.unsupportedURL }

        let packageURL: URL
        let filename: String
        switch source {
        case .chrome(let id):
            var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
            let version = ProcessInfo.processInfo.environment["FORK_CRX_PRODVERSION"] ?? "140.0"
            components.queryItems = [
                .init(name: "response", value: "redirect"),
                .init(name: "prodversion", value: version),
                .init(name: "acceptformat", value: "crx2,crx3"),
                .init(name: "x", value: "id=\(id)&uc"),
            ]
            packageURL = components.url!
            filename = "\(id).crx"
        case .firefox(let slug):
            let api = URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")!
            let (data, _) = try await URLSession.shared.data(from: api)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current_version"] as? [String: Any],
                  let file = current["file"] as? [String: Any],
                  let urlString = file["url"] as? String,
                  let url = URL(string: urlString) else {
                throw InstallError.downloadFailed("addons.mozilla.org didn't return a download for “\(slug)”.")
            }
            packageURL = url
            filename = "\(slug).xpi"
        }

        let (temp, response) = try await URLSession.shared.download(from: packageURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError.downloadFailed("The store answered with an error.")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("extension-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    // MARK: - Permission summary

    private static func confirmInstall(of webExtension: WKWebExtension) -> Bool {
        let name = webExtension.displayName ?? "This extension"
        let alert = NSAlert()
        alert.messageText = "Add “\(name)”?"
        if let icon = webExtension.icon(for: NSSize(width: 64, height: 64)) {
            alert.icon = icon
        }
        alert.informativeText = permissionSummary(for: webExtension)
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func permissionSummary(for webExtension: WKWebExtension) -> String {
        var lines: [String] = []
        if let version = webExtension.displayVersion ?? webExtension.version {
            lines.append("Version \(version)")
        }

        let patterns = webExtension.allRequestedMatchPatterns
        if patterns.contains(where: \.matchesAllHosts) || patterns.contains(where: { $0.host == "*" }) {
            lines.append("• Read and change data on all websites")
        } else if !patterns.isEmpty {
            let hosts = Set(patterns.compactMap(\.host)).sorted()
            let shown = hosts.prefix(5).joined(separator: ", ")
            lines.append("• Read and change data on: \(shown)\(hosts.count > 5 ? " and \(hosts.count - 5) more" : "")")
        }

        let descriptions: [WKWebExtension.Permission: String] = [
            .tabs: "Read your open tabs and their addresses",
            .webNavigation: "See your browsing activity",
            .declarativeNetRequest: "Block or change network requests",
            .declarativeNetRequestWithHostAccess: "Block or change network requests",
            .cookies: "Read and change cookies",
            .clipboardWrite: "Write to the clipboard",
            .nativeMessaging: "Talk to other apps on this Mac",
            .scripting: "Run scripts on pages",
            .storage: "Store data",
            .unlimitedStorage: "Store unlimited data",
            .alarms: "Run in the background on a schedule",
            .contextMenus: "Add items to right-click menus",
            .menus: "Add items to right-click menus",
            .activeTab: "Access the current page when you click it",
        ]
        let described = Set(webExtension.requestedPermissions.compactMap { descriptions[$0] }).sorted()
        lines.append(contentsOf: described.map { "• \($0)" })

        let others = webExtension.requestedPermissions.filter { descriptions[$0] == nil }.map(\.rawValue).sorted()
        if !others.isEmpty {
            lines.append("• Other: \(others.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Extensions run with the access they ask for. Only add ones you trust.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Management helpers

    static func openOptions(identifier: String) {
        guard let url = manager?.context(for: identifier)?.optionsPageURL else { return }
        Application.appDelegate.windowControllersManager.show(url: url, source: .ui, newTab: true)
    }

    static func confirmAndRemove(identifier: String) {
        guard let manager else { return }
        let name = manager.extensionName(for: identifier) ?? "this extension"
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "Its settings and data will be deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try manager.uninstallExtension(identifier: identifier)
            ExtensionToolbarController.hiddenIdentifiers.remove(identifier)
        } catch {
            present(error)
        }
    }

    private static func present(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The extension couldn't be added."
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

// MARK: - Menu actions

extension AppDelegate {

    @MainActor @objc func installWebExtension(_ sender: Any?) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionInstaller.chooseAndInstall()
    }

    @MainActor @objc func installWebExtensionFromLink(_ sender: Any?) {
        guard #available(macOS 15.4, *) else { return }
        ExtensionInstaller.promptForStoreURL()
    }
}
