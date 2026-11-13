import AppKit
import SwiftUI

enum AppTheme {
    static let background = Color(red: 18 / 255, green: 20 / 255, blue: 22 / 255)
    static let sidebar = Color(red: 23 / 255, green: 25 / 255, blue: 29 / 255)
    static let surface = Color(red: 27 / 255, green: 30 / 255, blue: 34 / 255)
    static let raised = Color(red: 36 / 255, green: 40 / 255, blue: 45 / 255)
    static let accent = Color(red: 167 / 255, green: 154 / 255, blue: 255 / 255)
    static let text = Color(red: 242 / 255, green: 244 / 255, blue: 247 / 255)
    static let muted = Color(red: 168 / 255, green: 176 / 255, blue: 186 / 255)
    static let windowSize = NSSize(width: 980, height: 680)
    static let minimumWindowSize = NSSize(width: 860, height: 600)
    static let sidebarWidth: CGFloat = 190
    static let spacing: CGFloat = 8
    static let radius: CGFloat = 16
    static let controlRadius: CGFloat = 10
    static let pagePadding: CGFloat = 32
    static let titleSize: CGFloat = 28
    static let bodySize: CGFloat = 13
    static let motionDuration: Double = 0.15
}

// Native button styles keep keyboard activation and the platform focus indicator.
// Cards share one surface rather than introducing a separate color per feature.
extension View {
    func appCard() -> some View {
        padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.radius).strokeBorder(.white.opacity(0.07)))
    }
}
