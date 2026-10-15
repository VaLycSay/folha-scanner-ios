import SwiftUI

// CamScanner 7.27 inspired palette with both light-surface editor tokens and dark home shell tokens.
enum ScannerAppearance {
    static let accent = Color(red: 0.09, green: 0.79, blue: 0.61) // #17C99B
    static let canvas = Color(.systemGroupedBackground)
    static let surface = Color(.systemBackground)
    static let mutedInk = Color(.secondaryLabel)

    // CamScanner 7.27 Dark Shell Tokens
    static let darkCanvas = Color(red: 0.067, green: 0.071, blue: 0.078)   // #111214
    static let darkSurface = Color(red: 0.110, green: 0.114, blue: 0.125)  // #1C1D20
    static let darkElevated = Color(red: 0.153, green: 0.161, blue: 0.180) // #27292E
    static let darkInk = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let darkMuted = Color(red: 0.60, green: 0.63, blue: 0.68)
    static let vipGold = Color(red: 0.96, green: 0.78, blue: 0.31)
}
