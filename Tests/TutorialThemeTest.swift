import WebKit
import AppKit

// Loads the tutorial in WebKit and runs Tests/tutorial_check.js against it.
// The script lives in its own file so its escaping never collides with Swift
// string literals (a repeated source of broken builds).
@main struct TutorialThemeTest {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        guard CommandLine.arguments.count >= 3 else {
            print("usage: TutorialThemeTest <index.html> <check.js>")
            exit(2)
        }
        let html = URL(fileURLWithPath: CommandLine.arguments[1])
        let scriptPath = CommandLine.arguments[2]
        guard let script = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            print("FAIL | could not read the check script")
            exit(1)
        }

        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
        let delegate = Delegate(script: script)
        web.navigationDelegate = delegate
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())

        let deadline = Date().addingTimeInterval(40)
        while !delegate.done && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        exit(delegate.ok ? 0 : 1)
    }

    final class Delegate: NSObject, WKNavigationDelegate {
        var done = false
        var ok = false
        let script: String

        init(script: String) { self.script = script }

        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            w.evaluateJavaScript(script) { result, error in
                if let error { print("JS ERROR: \(error)") }
                if let text = result as? String {
                    print(text)
                    self.ok = !text.contains("FAIL") && text.contains("PASS")
                }
                self.done = true
            }
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
            print("FAIL | page failed to load: \(e.localizedDescription)"); self.done = true
        }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            print("FAIL | page failed to load: \(e.localizedDescription)"); self.done = true
        }
    }
}
