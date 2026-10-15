import SwiftUI
import UIKit

// Independent palette informed by official imagery, not copied artwork.
enum ScannerAppearance {
    static let accent = Color(red: 0.00, green: 0.68, blue: 0.64)
    static let canvas = Color(.systemGroupedBackground)
    static let surface = Color(.systemBackground)
    static let mutedInk = Color(.secondaryLabel)
    // Separate header, library and action surfaces visible in the supplied
    // dark-mode recording; light mode retains native readable surfaces.
    static let homeBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.10, alpha: 1) : .systemBackground
    })
    static let librarySurface = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.14, alpha: 1) : .secondarySystemGroupedBackground
    })
    static let actionSurface = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) : .secondarySystemGroupedBackground
    })
}
