import Cocoa
import WebKit

// Tomato Timer Lab for Mac: a small native shell around the same page the Windows app uses.

func supportDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("TomatoTimerLab", isDirectory: true)
}

func hexColor(_ hex: String, fallback: NSColor) -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let n = UInt32(s, radix: 16) else { return fallback }
    return NSColor(calibratedRed: CGFloat((n >> 16) & 255) / 255,
                   green: CGFloat((n >> 8) & 255) / 255,
                   blue: CGFloat(n & 255) / 255, alpha: 1)
}

// Serves the page and photos from the app itself, so nothing needs a server or a browser.
final class SiteHandler: NSObject, WKURLSchemeHandler {
    let bundleSite: URL
    let userSite: URL

    override init() {
        bundleSite = Bundle.main.resourceURL!.appendingPathComponent("site", isDirectory: true)
        userSite = supportDir().appendingPathComponent("site", isDirectory: true)
        super.init()
    }

    func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "json": return "application/json"
        case "js": return "text/javascript"
        case "css": return "text/css"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let rel = String(path.dropFirst())
        if rel.contains("..") { urlSchemeTask.didFailWithError(URLError(.badURL)); return }
        // Use the downloaded copy only when it is at least as new as the one built into the app.
        func ver(_ dir: URL) -> Int {
            guard let t = try? String(contentsOf: dir.appendingPathComponent("version.txt"), encoding: .utf8) else { return 0 }
            return Int(t.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let order = ver(userSite) >= ver(bundleSite) ? [userSite, bundleSite] : [bundleSite, userSite]
        for base in order {
            let file = base.appendingPathComponent(rel)
            if let data = try? Data(contentsOf: file) {
                let ext = file.pathExtension
                let type = mime(ext)
                let charset: String? = (type.hasPrefix("text/") || type == "application/json") ? "utf-8" : nil
                let resp = URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: charset)
                urlSchemeTask.didReceive(resp)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                return
            }
        }
        urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

// The small always-on-top timer: tomato icon, time, play/pause. Follows you across Spaces and full-screen apps.
final class MiniPanel: NSPanel {
    var onToggle: (() -> Void)?
    var onClosed: (() -> Void)?
    let timeLabel = NSTextField(labelWithString: "25:00")
    let button = NSButton(frame: NSRect(x: 128, y: 11, width: 34, height: 34))
    let closeButton = NSButton(frame: NSRect(x: 168, y: 33, width: 16, height: 16))
    let iconView = NSImageView(frame: NSRect(x: 10, y: 12, width: 32, height: 32))
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 190, height: 56))
    let tagLabel = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 190, height: 56),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        box.wantsLayer = true
        box.layer?.cornerRadius = 16
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = NSColor(calibratedRed: 0.082, green: 0.075, blue: 0.059, alpha: 0.96).cgColor
        box.layer?.borderWidth = 2
        box.layer?.borderColor = NSColor(calibratedRed: 1, green: 0.42, blue: 0.29, alpha: 1).cgColor
        contentView = box

        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        box.addSubview(iconView)

        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)
        timeLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        timeLabel.frame = NSRect(x: 48, y: 12, width: 78, height: 32)
        box.addSubview(timeLabel)

        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 17
        button.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.42, blue: 0.29, alpha: 1).cgColor
        button.title = "\u{25B6}"
        button.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        button.contentTintColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        button.target = self
        button.action = #selector(tapped)
        box.addSubview(button)

        // The task you are working on, in small text above the timer. Hidden when the page sends only a mode name.
        tagLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        tagLabel.textColor = NSColor(calibratedWhite: 0.86, alpha: 1)
        tagLabel.alignment = .center
        tagLabel.lineBreakMode = .byWordWrapping
        tagLabel.maximumNumberOfLines = 3
        tagLabel.cell?.wraps = true
        tagLabel.cell?.isScrollable = false
        tagLabel.frame = NSRect(x: 12, y: 58, width: 166, height: 16)
        tagLabel.isHidden = true
        box.addSubview(tagLabel)

        closeButton.isBordered = false
        closeButton.title = "\u{2715}"
        closeButton.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        closeButton.contentTintColor = NSColor(calibratedWhite: 0.6, alpha: 1)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        box.addSubview(closeButton)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.maxX - 190 - 24, y: f.minY + 24))
        }
    }

    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }

    @objc func tapped() { onToggle?() }

    @objc func closeTapped() { close() }

    override func close() {
        super.close()
        onClosed?()
    }

    func update(time: String, running: Bool, accent: String, tag: String) {
        timeLabel.stringValue = time
        box.toolTip = tag
        let modeNames = ["focus", "short break", "long break"]
        let showTask = !tag.isEmpty && !modeNames.contains(tag.lowercased())
        tagLabel.stringValue = showTask ? tag : ""
        tagLabel.isHidden = !showTask
        var wantH: CGFloat = 56
        if showTask {
            // Wrap the task over up to 3 lines so all of it shows; the panel grows upward to fit.
            let font = tagLabel.font ?? NSFont.systemFont(ofSize: 11, weight: .semibold)
            let r = (tag as NSString).boundingRect(with: NSSize(width: 166, height: 1000),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: [.font: font])
            let textH = min(ceil(r.height) + 2, 48)
            tagLabel.frame = NSRect(x: 12, y: 58, width: 166, height: textH)
            wantH = 58 + textH + 8
        }
        if abs(frame.size.height - wantH) > 1 {
            setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: 190, height: wantH), display: true)
        }
        button.title = running ? "\u{275A}\u{275A}" : "\u{25B6}"
        let c = hexColor(accent, fallback: NSColor(calibratedRed: 1, green: 0.42, blue: 0.29, alpha: 1))
        button.layer?.backgroundColor = c.cgColor
        box.layer?.borderColor = c.cgColor
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var mini: MiniPanel?

    // Lets the page use the same host messages it uses in the Windows app.
    let shim = """
    (function () {
      if (window.chrome && window.chrome.webview) return;
      var listeners = [];
      window.chrome = window.chrome || {};
      window.__tomatoMac = true;
      window.chrome.webview = {
        postMessage: function (m) { window.webkit.messageHandlers.host.postMessage(String(m)); },
        addEventListener: function (t, f) { if (t === 'message') listeners.push(f); },
        removeEventListener: function (t, f) { listeners = listeners.filter(function (x) { return x !== f; }); }
      };
      window.__hostReceive = function (s) { listeners.forEach(function (f) { f({ data: s }); }); };
    })();
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SiteHandler(), forURLScheme: "tomato")
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "host")
        config.userContentController.addUserScript(
            WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Tomato Timer"
        window.minSize = NSSize(width: 380, height: 560)
        window.backgroundColor = NSColor(calibratedRed: 0.086, green: 0.075, blue: 0.059, alpha: 1)
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("TomatoTimerMain")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        web.load(URLRequest(url: URL(string: "tomato://app/index.html")!))

        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.checkForUpdate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { mini?.close() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide Tomato Timer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Tomato Timer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window"); winItem.submenu = win
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    // MARK: messages from the page

    func send(_ message: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [message], options: []),
              var json = String(data: data, encoding: .utf8) else { return }
        json.removeFirst(); json.removeLast()   // strip the [ ] to leave a JS string literal
        web.evaluateJavaScript("window.__hostReceive && window.__hostReceive(\(json))", completionHandler: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let msg = message.body as? String else { return }
        let p = msg.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard let kind = p.first else { return }
        if kind == "pip", p.count > 1 {
            if p[1] == "open" { openMini() } else { mini?.close() }
        } else if kind == "state", p.count >= 5 {
            mini?.update(time: p[1], running: p[2] == "1", accent: p[3], tag: p[4])
        } else if kind == "notify", p.count >= 3 {
            notice(title: p[1], body: p[2])
        } else if kind == "save", p.count >= 3 {
            saveFile(name: p[1], base64: p[2])
        } else if kind == "openfile", p.count >= 3 {
            openFile(name: p[1], base64: p[2])
        } else if kind == "autostart", p.count >= 2 {
            setAutostart(p[1] == "on")
        } else if kind == "link", p.count >= 2 {
            // Web addresses only: Meta Business Suite, Drive links and the like open in the normal browser.
            if let url = URL(string: p[1]), let scheme = url.scheme?.lowercased() {
                if scheme == "https" || scheme == "http" {
                    NSWorkspace.shared.open(url)
                } else if scheme == "claude" || scheme == "chatgpt" {
                    // Launch the installed desktop app; if it isn't installed, fall back to the website.
                    if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                        NSWorkspace.shared.open(url)
                    } else if let web = URL(string: scheme == "claude" ? "https://claude.ai/new" : "https://chatgpt.com/") {
                        NSWorkspace.shared.open(web)
                    }
                }
            }
        }
    }

    // Opens a file from the Files tab in whatever program the Mac uses for it (Pages, Preview, Word...).
    // Programs and scripts are never launched this way; those go through the Save box instead.
    // Open at login: a small LaunchAgent that opens this app when you log in (removed again when switched off).
    func setAutostart(_ on: Bool) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let file = dir.appendingPathComponent("app.tomatotimer.lab.autostart.plist")
        if on {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let plist: [String: Any] = ["Label": "app.tomatotimer.lab.autostart",
                                        "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                                        "RunAtLoad": true]
            if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? d.write(to: file, options: .atomic)
            }
        } else {
            try? fm.removeItem(at: file)
        }
    }

    func openFile(name: String, base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        var clean = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
        if clean.isEmpty { clean = "file" }
        let ext = (clean as NSString).pathExtension.lowercased()
        let blocked = ["app", "command", "sh", "zsh", "bash", "pkg", "dmg", "scpt", "workflow", "terminal", "jar", "py", "pl", "rb", "js", "exe", "bat", "cmd", "action", "tool", "webloc", "url", "html", "htm", "svg"]
        if blocked.contains(ext) { saveFile(name: clean, base64: base64); return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TomatoTimerLab-open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(clean)
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {}
    }

    // Lets the page save a file (the task log spreadsheet) through a normal Save box.
    func saveFile(name: String, base64: String) {
        guard let data = Data(base64Encoded: base64) else { send("savecancel"); return }
        send("saveopen")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if name.lowercased().hasSuffix(".csv") { panel.allowedFileTypes = ["csv"] }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url)
                    self.send("saved|" + url.path)
                } catch {
                    self.send("savecancel")
                }
            } else {
                self.send("savecancel")
            }
        }
    }

    func openMini() {
        if mini != nil { return }
        let m = MiniPanel()
        m.onToggle = { [weak self] in self?.send("toggle") }
        m.onClosed = { [weak self] in self?.mini = nil; self?.send("pipclosed") }
        mini = m
        m.orderFrontRegardless()
    }

    func notice(title: String, body: String) {
        func esc(_ s: String) -> String {
            return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
        NSApp.requestUserAttention(.criticalRequest)
    }

    // MARK: page dialogs and windows

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = message
        a.runModal()
        completionHandler()
    }

    // Lets the calendar's "Attach file" button open the normal file chooser.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        return nil
    }

    // MARK: updates from GitHub (applies next time the app opens)

    var restartAsked = false
    // Bump native-version.txt on GitHub together with TomatoTimer.swift when the Mac app itself changes.
    let nativeVersion = 2

    func askRestart() {
        if restartAsked { return }
        restartAsked = true
        let alert = NSAlert()
        alert.messageText = "Update ready"
        alert.informativeText = "A new version of Tomato Timer Lab has been downloaded. Restart now to start using it? (A running timer will reset.)"
        alert.addButton(withTitle: "Restart now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let path = Bundle.main.bundlePath
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$1\"", "sh", path]
            try? p.run()
            NSApp.terminate(nil)
        }
    }

    func checkForUpdate() {
        let fm = FileManager.default
        let support = supportDir()
        let site = support.appendingPathComponent("site", isDirectory: true)
        var base = ""
        let cfgFiles = [support.appendingPathComponent("update-url.txt"),
                        Bundle.main.resourceURL!.appendingPathComponent("update-url.txt")]
        for f in cfgFiles {
            if let s = try? String(contentsOf: f, encoding: .utf8) {
                base = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !base.isEmpty { break }
            }
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.isEmpty { return }

        func readVersion(_ url: URL) -> Int {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let bundled = readVersion(Bundle.main.resourceURL!.appendingPathComponent("site/version.txt"))
        let installed = readVersion(site.appendingPathComponent("version.txt"))
        let local = max(bundled, installed)
        let stamp = String(Int(Date().timeIntervalSince1970))

        func fetch(_ path: String) -> Data? {
            guard let url = URL(string: base + "/" + path + "?t=" + stamp) else { return nil }
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let sem = DispatchSemaphore(value: 0)
            var out: Data?
            URLSession.shared.dataTask(with: req) { d, r, _ in
                if let h = r as? HTTPURLResponse, h.statusCode == 200 { out = d }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 25)
            return out
        }

        defer { rebuildNativeIfNeeded(fetch) }
        guard let vdata = fetch("version.txt"),
              let vtext = String(data: vdata, encoding: .utf8) else { return }
        let vstr = vtext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let remote = Int(vstr), remote > local else { return }
        guard let page = fetch("index.html"), page.count > 20000,
              let text = String(data: page, encoding: .utf8), text.contains("Tomato Timer") else { return }
        do {
            try fm.createDirectory(at: site, withIntermediateDirectories: true)
            try page.write(to: site.appendingPathComponent("index.html"), options: .atomic)
            try vstr.write(to: site.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
            DispatchQueue.main.async { [weak self] in
                self?.askRestart()
            }
        } catch {}
    }

    // Rebuilds the Mac app itself from GitHub when the native code changed (needs Apple's Command Line Tools,
    // which the installer already required). The old app stays in place if anything fails.
    func rebuildNativeIfNeeded(_ fetch: (String) -> Data?) {
        guard let vd = fetch("native-version.txt"),
              let vs = String(data: vd, encoding: .utf8),
              let remote = Int(vs.trimmingCharacters(in: .whitespacesAndNewlines)),
              remote > nativeVersion else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/swiftc"),
              let src = fetch("TomatoTimer.swift"), src.count > 5000,
              let text = String(data: src, encoding: .utf8), text.contains("NSApplication") else { return }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tomato-rebuild-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let swiftFile = work.appendingPathComponent("TomatoTimer.swift")
            let outBin = work.appendingPathComponent("TomatoTimerLab")
            try src.write(to: swiftFile)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            p.arguments = ["-O", "-swift-version", "5", "-o", outBin.path, swiftFile.path, "-framework", "Cocoa", "-framework", "WebKit"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0, fm.fileExists(atPath: outBin.path) else { try? fm.removeItem(at: work); return }
            let target = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TomatoTimerLab")
            let staged = target.deletingLastPathComponent().appendingPathComponent("TomatoTimerLab.new")
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: outBin, to: staged)
            _ = try fm.replaceItemAt(target, withItemAt: staged)
            let cs = Process()
            cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            cs.arguments = ["--force", "--deep", "-s", "-", Bundle.main.bundlePath]
            cs.standardOutput = FileHandle.nullDevice
            cs.standardError = FileHandle.nullDevice
            try? cs.run()
            cs.waitUntilExit()
            try? fm.removeItem(at: work)
            DispatchQueue.main.async { [weak self] in self?.askRestart() }
        } catch { try? fm.removeItem(at: work) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
