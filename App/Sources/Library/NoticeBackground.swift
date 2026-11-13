import SwiftUI

extension View {
    /// The look of a notice above the list of connections.
    func noticeBackground() -> some View {
        modifier(NoticeBackground())
    }
}

/// On macOS 26 a notice is part of the content: an inset, rounded callout
/// below the toolbar's glass, not a band of bar material that would read as
/// part of the toolbar (HIG Layout, Visual hierarchy: no solid or
/// semi-opaque background beneath a bar). Earlier systems keep the band.
private struct NoticeBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else {
            content
                .padding(12)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
        }
    }
}
