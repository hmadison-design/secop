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
        config.userContentController.add(context.coordinator, name: "sharePDF")
        config.userContentController.add(context.coordinator, name: "getLocation")
        config.userContentController.add(context.coordinator, name: "reverseGeocode")
        config.userContentController.add(context.coordinator, name: "fetchMetar")  // ← new

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
                return
            }

            if message.name == "reverseGeocode",
               let body = message.body as? [String: Any],
               let lat = body["lat"] as? Double,
               let lon = body["lon"] as? Double {
                reverseGeocode(lat: lat, lon: lon)
                return
            }

            if message.name == "fetchMetar",
               let body = message.body as? [String: Any],
               let lat = body["lat"] as? Double,
               let lon = body["lon"] as? Double {
                fetchMetar(lat: lat, lon: lon)
                return
            }

            if message.name == "sharePDF",
               let htmlContent = message.body as? String {
                generateAndSharePDF(htmlContent: htmlContent)
                return
            }
        }

        // MARK: - METAR fetch

        func fetchMetar(lat: Double, lon: Double) {
            let deg = 100.0 / 69.0   // ~100 statute miles in degrees
            let minLat = lat - deg, maxLat = lat + deg
            let minLon = lon - deg, maxLon = lon + deg

            let urlString = "https://aviationweather.gov/api/data/metar"
                + "?bbox=\(minLat),\(minLon),\(maxLat),\(maxLon)&format=json"
            guard let url = URL(string: urlString) else {
                sendMetarToJS(result: nil); return
            }

            let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self else { return }

                guard error == nil,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      !json.isEmpty
                else {
                    self.sendMetarToJS(result: nil); return
                }

                // Find the closest station with a rawOb
                let R = 3958.8
                var closest: [String: Any]? = nil
                var closestDist = Double.infinity

                for m in json {
                    guard let rawOb = m["rawOb"] as? String else { continue }
                    guard !rawOb.isEmpty else { continue }
                    let mlat = (m["lat"] as? Double) ?? (m["latitude"] as? Double) ?? Double.nan
                    let mlon = (m["lon"] as? Double) ?? (m["longitude"] as? Double) ?? Double.nan
                    guard mlat.isFinite && mlon.isFinite else { continue }

                    let dLat = (mlat - lat) * .pi / 180
                    let dLon = (mlon - lon) * .pi / 180
                    let a = sin(dLat/2)*sin(dLat/2)
                          + cos(lat * .pi/180) * cos(mlat * .pi/180)
                          * sin(dLon/2)*sin(dLon/2)
                    let dist = R * 2 * atan2(sqrt(a), sqrt(1-a))

                    if dist < closestDist {
                        closestDist = dist
                        closest = m
                    }
                }

                guard let rawOb = closest?["rawOb"] as? String, !rawOb.isEmpty else {
                    self.sendMetarToJS(result: nil); return
                }

                // Strip any existing "METAR " prefix from rawOb before we add our own
                let trimmed = rawOb
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "^METAR\\s+", with: "", options: .regularExpression)

                // Truncate after altimeter reading (A#### or Q####)
                if let range = trimmed.range(of: #"\b[AQ]\d{4}\b"#,
                                             options: .regularExpression) {
                    let truncated = "METAR " + String(trimmed[trimmed.startIndex..<range.upperBound])
                    self.sendMetarToJS(result: truncated)
                } else {
                    self.sendMetarToJS(result: "METAR " + trimmed)
                }
            }
            task.resume()
        }

        func sendMetarToJS(result: String?) {
            let js: String
            if let metar = result {
                // Escape backslashes and single quotes for JS string safety
                let safe = metar
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'",  with: "\\'")
                js = "window.onNativeMetar && window.onNativeMetar('\(safe)');"
            } else {
                js = "window.onNativeMetar && window.onNativeMetar(null);"
            }
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        // MARK: - PDF generation

        func generateAndSharePDF(htmlContent: String) {
            DispatchQueue.main.async {
                // Wrap content in a standalone HTML document with the same styling
                let fullHTML = """
                <!DOCTYPE html>
                <html>
                <head>
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <style>
                  * { box-sizing: border-box; }
                  body {
                    margin: 0;
                    padding: 20px;
                    font: 15px/1.5 system-ui, -apple-system, sans-serif;
                    color: #0d1b2a;
                    background: #ffffff;
                  }
                  h1 { font-size: 1.25rem; margin: 0 0 4px; color: #1a2f45; }
                  h2 { font-size: 1.05rem; margin: 14px 0 6px; color: #1a2f45; }
                  .pmuted { color: #5a7184; font-size: .9rem; margin-bottom: 8px; }
                  .pbox {
                    background: #f0f6ff;
                    border: 1px solid #dce4ed;
                    border-radius: 12px;
                    padding: 12px;
                    margin-top: 10px;
                  }
                  .pgrid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 10px; }
                  b { color: #1a2f45; }
                  .warn  { color: #b87000; }
                  .muted { color: #5a7184; }
                  div + div { margin-top: 3px; }
                </style>
                </head>
                <body>
                \(htmlContent)
                </body>
                </html>
                """

                // Create an off-screen WKWebView wide enough for iPhone content
                let offScreenView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 10))
                offScreenView.navigationDelegate = PDFDelegate.shared
                offScreenView.isHidden = true

                // Attach to window so it actually renders
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = scene.windows.first {
                    window.addSubview(offScreenView)
                }

                PDFDelegate.shared.onReady = { [weak offScreenView] in
                    guard let view = offScreenView else { return }

                    // Measure the full rendered content height
                    view.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                        let contentHeight = (result as? CGFloat) ?? 1200
                        // Resize to full content height so nothing is clipped
                        view.frame = CGRect(x: 0, y: 0, width: 390, height: contentHeight + 40)

                        // Small delay to allow reflow after resize
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            let config = WKPDFConfiguration()
                            config.rect = view.bounds

                            view.createPDF(configuration: config) { [weak self] result in
                                view.removeFromSuperview()
                                switch result {
                                case .success(let data):
                                    self?.sharePDFData(data)
                                case .failure:
                                    DispatchQueue.main.async {
                                        self?.webView?.evaluateJavaScript(
                                            "window.onPDFFailed && window.onPDFFailed();",
                                            completionHandler: nil
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                offScreenView.loadHTMLString(fullHTML, baseURL: nil)
            }
        }

        func sharePDFData(_ data: Data) {
            let fileName = "SecondOpinion_\(Int(Date().timeIntervalSince1970)).pdf"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            do {
                try data.write(to: tempURL)
            } catch {
                return
            }

            DispatchQueue.main.async {
                let av = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    av.popoverPresentationController?.sourceView = root.view
                    av.popoverPresentationController?.sourceRect = CGRect(
                        x: root.view.bounds.midX,
                        y: root.view.bounds.midY,
                        width: 0, height: 0
                    )
                    av.completionWithItemsHandler = { _, _, _, _ in
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    root.present(av, animated: true)
                }
            }
        }

        // MARK: - Reverse geocoding

        func reverseGeocode(lat: Double, lon: Double) {
            let location = CLLocation(latitude: lat, longitude: lon)
            let geocoder = CLGeocoder()

            // 10-second timeout — if geocoder doesn't respond, send "Unavailable"
            var didRespond = false
            let timeoutTimer = DispatchWorkItem {
                if !didRespond {
                    didRespond = true
                    self.sendGeocodeToJS(result: "Unavailable")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeoutTimer)

            geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, error in
                guard let self = self else { return }

                timeoutTimer.cancel()
                guard !didRespond else { return }
                didRespond = true

                guard error == nil, let placemark = placemarks?.first else {
                    self.sendGeocodeToJS(result: "Unavailable")
                    return
                }

                let countryCode = placemark.isoCountryCode ?? ""

                // Outside US and Canada
                guard countryCode == "US" || countryCode == "CA" else {
                    self.sendGeocodeToJS(result: "Outside US/Canada")
                    return
                }

                let place  = placemark.locality
                          ?? placemark.subAdministrativeArea
                          ?? placemark.administrativeArea
                          ?? "Unavailable"
                let region = placemark.administrativeArea ?? ""

                let result = region.isEmpty ? place : "\(place), \(region)"
                self.sendGeocodeToJS(result: result)
            }
        }

        func sendGeocodeToJS(result: String) {
            let safe = result
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'",  with: "\\'")
            let js = "window.onNativeGeocode && window.onNativeGeocode('\(safe)');"
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        // MARK: - CLLocationManagerDelegate

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

// MARK: - PDFDelegate
class PDFDelegate: NSObject, WKNavigationDelegate {
    static let shared = PDFDelegate()
    var onReady: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let callback = onReady
        onReady = nil
        callback?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onReady = nil
    }
}
