import AppKit

/// Light or dark, the two looks every snapshot is taken in. The raw value is the file name's suffix.
public enum Appearance: String, CaseIterable, Sendable {
    case light
    case dark

    /// AppKit's name for this look.
    public var name: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// Switches the whole app to this look.
    @MainActor
    public func apply() {
        NSApp.appearance = NSAppearance(named: name)
    }
}
