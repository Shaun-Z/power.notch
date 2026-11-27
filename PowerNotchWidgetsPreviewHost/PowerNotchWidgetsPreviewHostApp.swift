//
//  PowerNotchWidgetsPreviewHostApp.swift
//  PowerNotchWidgetsPreviewHost
//
//  Debug-only macOS host app for live Xcode Canvas previews (#Preview)
//  and interactive desktop-widget testing without polluting powerNotch.app.
//

import SwiftUI

@main
struct PowerNotchWidgetsPreviewHostApp: App {
    var body: some Scene {
        WindowGroup("PowerNotch Widgets Preview") {
            PowerNotchWidgetsPreviewGalleryView()
        }
        .defaultSize(width: 740, height: 500)
    }
}
