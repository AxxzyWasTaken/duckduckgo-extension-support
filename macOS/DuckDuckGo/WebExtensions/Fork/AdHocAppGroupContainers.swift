//
//  AdHocAppGroupContainers.swift
//
//  Copyright © 2026 AxxzyWasTaken. Licensed under the Apache License, Version 2.0.
//  Part of a modified fork of DuckDuckGo for Mac; not affiliated with Duck Duck Go, Inc.
//

import Foundation
import ObjectiveC

/// macOS only lets a process use an App Group container when its signature proves the group
/// belongs to its team. An ad-hoc signed build has no team, so every container lookup succeeds
/// but writing into it fails, and upstream treats that as fatal.
///
/// The fork's helpers that shared those containers (VPN, Personal Information Removal) aren't
/// shipped, so the containers only need to be private to the app: point every lookup at a folder
/// under the app's own Application Support directory instead.
enum AdHocAppGroupContainers {

    static func install() {
        let selector = #selector(FileManager.containerURL(forSecurityApplicationGroupIdentifier:))
        let replacement = #selector(FileManager.fork_containerURL(forSecurityApplicationGroupIdentifier:))
        guard let original = class_getInstanceMethod(FileManager.self, selector),
              let swapped = class_getInstanceMethod(FileManager.self, replacement) else {
            assertionFailure("NSFileManager container lookup not found")
            return
        }
        method_exchangeImplementations(original, swapped)
    }

    static func directory(for groupIdentifier: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "DuckDuckGo-fork", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(groupIdentifier, isDirectory: true)
    }
}

extension FileManager {

    @objc dynamic func fork_containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        let url = AdHocAppGroupContainers.directory(for: groupIdentifier)
        try? createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
