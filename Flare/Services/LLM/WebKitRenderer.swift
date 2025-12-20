//
//  WebKitRenderer.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation
import WebKit

struct DetectedAPICall {
    let url: String
    let method: String
    let requestBody: String?
    let headers: [String: String]?
    let response: String?
}

@MainActor
class WebKitRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var renderContinuation: CheckedContinuation<RenderResult, Error>?
    private var loadTimeout: Task<Void, Never>?

    struct RenderResult {
        let html: String
        let detectedAPICalls: [DetectedAPICall]
    }

    func renderWithAPIDetection(from url: URL, waitTime: TimeInterval = 5.0) async throws -> RenderResult {
        return try await withCheckedThrowingContinuation { continuation in
            self.renderContinuation = continuation

            // Create headless WebView with custom config
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.mediaTypesRequiringUserActionForPlayback = .all

            let interceptScript = """
            (function() {
                window.__apiCalls = [];

                // Intercept fetch
                const originalFetch = window.fetch;
                window.fetch = function(...args) {
                    const url = typeof args[0] === 'string' ? args[0] : args[0].url;
                    const options = args[1] || {};
                    const method = options.method || 'GET';

                    let body = null;
                    if (options.body) {
                        if (typeof options.body === 'string') {
                            body = options.body;
                        } else {
                            try {
                                body = JSON.stringify(options.body);
                            } catch (e) {
                                body = '[could not stringify body]';
                            }
                        }
                    }

                    // Convert Headers object to plain object
                    let headers = {};
                    if (options.headers) {
                        if (options.headers instanceof Headers) {
                            options.headers.forEach((value, key) => {
                                headers[key] = value;
                            });
                        } else {
                            headers = options.headers;
                        }
                    }

                    window.__apiCalls.push({
                        url: url,
                        method: method,
                        body: body,
                        headers: headers,
                        type: 'fetch'
                    });

                    return originalFetch.apply(this, args);
                };

                // Intercept XMLHttpRequest
                const originalXHROpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                    this.__url = url;
                    this.__method = method;
                    return originalXHROpen.apply(this, arguments);
                };

                const originalXHRSend = XMLHttpRequest.prototype.send;
                XMLHttpRequest.prototype.send = function(body) {
                    if (this.__url) {
                        window.__apiCalls.push({
                            url: this.__url,
                            method: this.__method || 'GET',
                            body: body || null,
                            headers: {},
                            type: 'xhr'
                        });
                    }
                    return originalXHRSend.apply(this, arguments);
                };

                console.log('[Interceptor] Network interception enabled');
            })();
            """

            let userScript = WKUserScript(source: interceptScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(userScript)

            webView = WKWebView(frame: .zero, configuration: config)
            webView?.navigationDelegate = self

            print("[WebKitRenderer] Loading with API interception: \(url.absoluteString)")

            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            webView?.load(request)

            loadTimeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                if self.renderContinuation != nil {
                    print("[WebKitRenderer] Timeout reached, extracting data...")
                    await self.extractRenderResult()
                }
            }
        }
    }

    func renderHTML(from url: URL, waitTime: TimeInterval = 5.0) async throws -> String {
        let result = try await renderWithAPIDetection(from: url, waitTime: waitTime)
        return result.html
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            print("[WebKitRenderer] Page loaded, waiting for JavaScript execution...")

            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            print("[WebKitRenderer] Extracting data...")
            if self.renderContinuation != nil {
                await self.extractRenderResult()
            } else {
                await self.extractHTML()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            print("[WebKitRenderer] Navigation failed: \(error.localizedDescription)")
            continuation?.resume(throwing: error)
            continuation = nil
            loadTimeout?.cancel()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            print("[WebKitRenderer] Provisional navigation failed: \(error.localizedDescription)")
            continuation?.resume(throwing: error)
            continuation = nil
            loadTimeout?.cancel()
        }
    }

    // MARK: - Private

    private func extractRenderResult() async {
        guard let webView = webView, let continuation = renderContinuation else { return }

        do {
            let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
            let apiCallsJSON = try await webView.evaluateJavaScript("JSON.stringify(window.__apiCalls || [])") as? String ?? "[]"

            print("[WebKitRenderer] Extracted \(html.count) characters of rendered HTML")
            print("[WebKitRenderer] API calls JSON: \(apiCallsJSON.prefix(500))")

            var detectedCalls: [DetectedAPICall] = []
            if let data = apiCallsJSON.data(using: .utf8),
               let calls = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {

                for call in calls {
                    if let url = call["url"] as? String,
                       let method = call["method"] as? String {

                        // Expanded list of job-related URL patterns
                        let jobPatterns = [
                            "job", "jobs",
                            "career", "careers",
                            "position", "positions",
                            "opening", "openings",
                            "requisition", "requisitions",
                            "posting", "postings",
                            "vacancy", "vacancies",
                            "opportunity", "opportunities",
                            "search",
                            "api",
                            "graphql",
                            "hiring",
                            "talent",
                            "recruit",
                            "apply",
                            "listing", "listings",
                            "role", "roles",
                            "employment",
                            "work",
                            "team"
                        ]

                        // Patterns to exclude (likely not job-related)
                        let excludePatterns = [
                            "analytics",
                            "tracking",
                            "telemetry",
                            "beacon",
                            "pixel",
                            "ad",
                            "ads",
                            "facebook",
                            "google-analytics",
                            "gtag",
                            "hotjar",
                            "segment"
                        ]

                        let urlLower = url.lowercased()
                        let isJobRelated = jobPatterns.contains { urlLower.contains($0) }
                        let isExcluded = excludePatterns.contains { urlLower.contains($0) }

                        if isJobRelated && !isExcluded {
                            let body = call["body"] as? String
                            let headers = call["headers"] as? [String: String]

                            print("[WebKitRenderer] Detected API call: \(method) \(url)")
                            if let body = body {
                                print("[WebKitRenderer]   Body: \(body.prefix(200))...")
                            }

                            detectedCalls.append(DetectedAPICall(
                                url: url,
                                method: method,
                                requestBody: body,
                                headers: headers,
                                response: nil
                            ))
                        }
                    }
                }
            }

            print("[WebKitRenderer] Detected \(detectedCalls.count) API calls")

            let result = RenderResult(html: html, detectedAPICalls: detectedCalls)

            self.renderContinuation?.resume(returning: result)
            self.renderContinuation = nil
            loadTimeout?.cancel()
            self.webView = nil

        } catch {
            print("[WebKitRenderer] Failed to extract data: \(error.localizedDescription)")
            continuation.resume(throwing: error)
            self.renderContinuation = nil
            loadTimeout?.cancel()
        }
    }

    private func extractHTML() async {
        guard let webView = webView, let continuation = continuation else { return }

        do {
            let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""

            print("[WebKitRenderer] Extracted \(html.count) characters of rendered HTML")

            self.continuation?.resume(returning: html)
            self.continuation = nil
            loadTimeout?.cancel()
            self.webView = nil

        } catch {
            print("[WebKitRenderer] Failed to extract HTML: \(error.localizedDescription)")
            continuation.resume(throwing: error)
            self.continuation = nil
            loadTimeout?.cancel()
        }
    }
}
