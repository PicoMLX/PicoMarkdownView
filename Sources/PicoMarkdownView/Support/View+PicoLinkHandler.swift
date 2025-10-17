import SwiftUI

public extension View {
    func onOpenLink(_ handler: @escaping (URL) -> OpenURLAction.Result) -> some View {
        environment(\.openURL, OpenURLAction { url in
            
            guard url.fragment == nil else {
                // TODO: Add support for # link
                return .discarded
            }
            
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
