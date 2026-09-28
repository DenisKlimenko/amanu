import AppKit

extension NSView {
    /// Every view under this one, depth first — how the window tests find a
    /// control by what it says or by its identifier.
    var allDescendants: [NSView] {
        subviews + subviews.flatMap(\.allDescendants)
    }
}
