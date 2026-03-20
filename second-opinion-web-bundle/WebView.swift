//
//  WebView.swift
//  SecondOpinion
//

import Foundation
import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let htmlFileName: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        config.userContentController.add(context.coordinator, name: "openURL")
        config.userContentController.add(context.coordinator, name: "shareText")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator

        loadHTML(into: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadHTML(into webView: WKWebView) {
        guard let fileURL = Bundle.main.url(forResource: htmlFileName, withExtension: "html") else {
            print("⚠️  Could not find \(htmlFileName).html in app bundle")
            return
        }
        let folderURL = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: folderURL)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

            if let url = navigationAction.request.url {
                let scheme = url.scheme ?? ""
                if scheme == "file" || scheme == "about" {
                    decisionHandler(.allow)
                    return
                }
                if scheme == "https" || scheme == "http" {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {

            if message.name == "shareText",
               let text = message.body as? String {
                let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    root.present(av, animated: true)
                }
                return
            }

            if message.name == "openURL",
               let urlString = message.body as? String,
               let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }
        }
    }
}
