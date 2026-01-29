import SwiftUI

public extension View {
    func onOpenLink(_ handler: @escaping (URL) -> OpenURLAction.Result) -> some View {
        environment(\.openURL, OpenURLAction { url in
            
            return handler(url)
        })
    }

    func onOpenLink(_ handler: @escaping (URL) -> Void) -> some View {
        onOpenLink { url in
            handler(url)
            return .handled
        }
    }
}
