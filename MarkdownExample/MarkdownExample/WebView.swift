//
//  WebView.swift
//  MarkdownExample
//
//  Created by Ronald Mannak on 10/15/25.
//

import Foundation
import SwiftUI
import WebKit

#if os(iOS)
typealias WebViewRepresentable = UIViewRepresentable
#elseif os(macOS)
typealias WebViewRepresentable = NSViewRepresentable
#endif

struct WebView: WebViewRepresentable {
   
    public init(url: URL) {
        self.url = url
        self.configuration = { _ in }
    }

    public init(
        url: URL? = nil,
        configuration: @escaping (WKWebView) -> Void = { _ in }) {
        self.url = url
        self.configuration = configuration
    }

    private let url: URL?
    private let configuration: (WKWebView) -> Void    
    
#if os(iOS)
    public func makeUIView(context: Context) -> WKWebView {
        makeView()
    }
    
    public func updateUIView(_ uiView: WKWebView, context: Context) {}
#endif
    
#if os(macOS)
    public func makeNSView(context: Context) -> WKWebView {
        makeView()
    }
    
    public func updateNSView(_ view: WKWebView, context: Context) {}
#endif
}

private extension WebView {
    
    func makeView() -> WKWebView {
        let view = WKWebView()
        configuration(view)
        tryLoad(url, into: view)
        return view
    }

    func tryLoad(_ url: URL?, into view: WKWebView) {
        guard let url = url else { return }
        view.load(URLRequest(url: url))
    }
}
