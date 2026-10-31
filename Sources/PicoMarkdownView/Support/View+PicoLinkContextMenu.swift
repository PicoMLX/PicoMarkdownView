#if os(macOS)
import AppKit
import SwiftUI

public extension View {
    /// Customizes the native context menu for the Markdown link under the
    /// pointer, including links in tables and inline tags. Called on the main
    /// actor each time a menu opens, with the URL, visible label and default
    /// menu. Add, remove or reorder items to supply app-specific destinations
    /// such as a new tab, a new window or a code review.
    ///
    /// Links have useful default menus without this modifier. The default
    /// Open action follows `onOpenLink` / `onTagTap`; browser and Open With
    /// actions explicitly use the selected external application.
    func linkContextMenu(_ customize: @escaping (URL, String, NSMenu) -> Void) -> some View {
        environment(\.picoLinkContextMenu, customize)
    }
}

extension EnvironmentValues {
    @Entry var picoLinkContextMenu: ((URL, String, NSMenu) -> Void)? = nil
}
#endif
