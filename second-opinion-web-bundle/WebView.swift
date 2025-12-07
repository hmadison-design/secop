//
//  WebView.swift
//  SecondOpinion
//
//  Created by Harvey Madison on 12/6/25.
//

import Foundation
import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let htmlFileName: String   // e.g., "index"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)

        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear

        loadHTML(into: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // For now, nothing to update dynamically.
    }

    private func loadHTML(into webView: WKWebView) {
        guard let fileURL = Bundle.main.url(forResource: htmlFileName, withExtension: "html") else {
            print("⚠️ Could not find \(htmlFileName).html in app bundle")
            return
        }

        // Allow WKWebView to read other files in the same folder (CSS, JS, images)
        let folderURL = fileURL.deletingLastPathComponent()

        webView.loadFileURL(fileURL, allowingReadAccessTo: folderURL)
    }
}
