//
//  ApplicationRelauncher.swift
//  powerNotch
//
//  Created by Corentin132 on 03/10/2025.
//

import AppKit

enum ApplicationRelauncher {
    static func restart() {
        let workspace = NSWorkspace.shared
        let bundleURL = Bundle.main.bundleURL
        let candidate = bundleURL.pathExtension.lowercased() == "app"
            ? bundleURL
            : Bundle.main.bundleIdentifier.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        guard let appURL = candidate else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        workspace.openApplication(at: appURL, configuration: configuration, completionHandler: nil)

        NSApplication.shared.terminate(nil)
    }
}
