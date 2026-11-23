//
//  sizeMatters.swift
//  powerNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 26
/// Extra vertical headroom in the window to accommodate downward Dynamic Island offsets
/// configured in Developer Options without clipping the expanded card or rim glow.
let dynamicIslandMaxVerticalOffset: CGFloat = 24
/// Horizontal margin reserved in the window for outward-diffusing rim halos
let rimGlowHorizontalPadding: CGFloat = 18
/// Maximum horizontal flare width of the hanging notch's concave top meniscus ears
let openNotchEarMaxInset: CGFloat = 22
let openNotchSize: CGSize = .init(width: 640, height: 226)
let windowSize: CGSize = .init(
    width: openNotchSize.width + openNotchEarMaxInset * 2 + rimGlowHorizontalPadding * 2,
    height: openNotchSize.height + shadowPadding + dynamicIslandMaxVerticalOffset
)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

/// Returns the physical hardware notch dimensions in points for the specified display
/// by querying `NSScreen.safeAreaInsets.top` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
/// Returns `nil` for displays without a physical hardware notch.
@MainActor func getPhysicalNotchSize(screenUUID: String? = nil) -> CGSize? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    guard let screen = selectedScreen, screen.safeAreaInsets.top > 0 else {
        return nil
    }

    let notchHeight = screen.safeAreaInsets.top
    let notchWidth: CGFloat
    if let topLeftWidth = screen.auxiliaryTopLeftArea?.width,
       let topRightWidth = screen.auxiliaryTopRightArea?.width
    {
        notchWidth = max(0, screen.frame.width - topLeftWidth - topRightWidth)
    } else {
        notchWidth = notchHeight * 5.2
    }

    return CGSize(width: notchWidth, height: notchHeight)
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    var notchHeight: CGFloat = 32
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBarHeight > 0 {
            notchHeight = menuBarHeight
        } else if screen.safeAreaInsets.top > 0 {
            notchHeight = screen.safeAreaInsets.top
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
