//
//  WebView.swift
//  SecondOpinion
//

import Foundation
import SwiftUI
import WebKit
import CoreLocation

struct WebView: UIViewRepresentable {
    let htmlFileName: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        config.userContentController.add(context.coordinator, name: "openURL")
        config.userContentController.add(context.coordinator, name: "shareText")
        config.userContentController.add(context.coordinator, name: "getLocation")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator

        context.coordinator.webView = webView
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

        // Inject airport data after page loads
        if let airportURL = Bundle.main.url(forResource: "airports", withExtension: "json"),
           let airportData = try? String(contentsOf: airportURL, encoding: .utf8) {
            let js = "window._airportDataRaw = \(airportData);"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, CLLocationManagerDelegate {

        weak var webView: WKWebView?
        var locationManager: CLLocationManager?

        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {
            // Inject airport data once page is fully loaded
            if let airportURL = Bundle.main.url(forResource: "airports", withExtension: "json"),
               let airportData = try? String(contentsOf: airportURL, encoding: .utf8) {
                let js = "window._airportDataRaw = \(airportData);"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }

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
                    av.popoverPresentationController?.sourceView = root.view
                    av.popoverPresentationController?.sourceRect = CGRect(
                        x: root.view.bounds.midX,
                        y: root.view.bounds.midY,
                        width: 0, height: 0
                    )
                    root.present(av, animated: true)
                }
                return
            }

            if message.name == "openURL",
               let urlString = message.body as? String,
               let url = URL(string: urlString) {
                UIApplication.shared.open(url)
                return
            }

            if message.name == "getLocation" {
                let manager = CLLocationManager()
                manager.delegate = self
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                self.locationManager = manager

                let status = manager.authorizationStatus
                if status == .notDetermined {
                    manager.requestWhenInUseAuthorization()
                } else if status == .authorizedWhenInUse || status == .authorizedAlways {
                    manager.requestLocation()
                } else {
                    sendLocationToJS(lat: nil, lon: nil)
                }
            }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            } else if manager.authorizationStatus == .denied ||
                      manager.authorizationStatus == .restricted {
                sendLocationToJS(lat: nil, lon: nil)
            }
        }

        func locationManager(_ manager: CLLocationManager,
                             didUpdateLocations locations: [CLLocation]) {
            guard let loc = locations.first else {
                sendLocationToJS(lat: nil, lon: nil)
                return
            }
            sendLocationToJS(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            self.locationManager = nil
        }

        func locationManager(_ manager: CLLocationManager,
                             didFailWithError error: Error) {
            sendLocationToJS(lat: nil, lon: nil)
            self.locationManager = nil
        }

        func sendLocationToJS(lat: Double?, lon: Double?) {
            let js: String
            if let lat = lat, let lon = lon {
                js = "window.onNativeLocation && window.onNativeLocation(\(lat), \(lon));"
            } else {
                js = "window.onNativeLocation && window.onNativeLocation(null, null);"
            }
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
}
