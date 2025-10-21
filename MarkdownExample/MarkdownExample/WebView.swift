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
struct WebView: UIViewRepresentable {
    let url: URL
    var configure: ((WKWebViewConfiguration) -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        configure?(config)                               // <- apply BEFORE init
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#else
struct WebView: NSViewRepresentable {
    let url: URL
    var configure: ((WKWebViewConfiguration) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        configure?(config)                               // <- apply BEFORE init
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#endif

private extension WebView {
    
//    func makeView() -> WKWebView {
//        let view = WKWebView()
//        configuration(view)
//        tryLoad(url, into: view)
//        return view
//    }

    func tryLoad(_ url: URL?, into view: WKWebView) {
        guard let url = url else { return }
        view.load(URLRequest(url: url))
    }
}
