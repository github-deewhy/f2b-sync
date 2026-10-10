import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Syncing status…")
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private let logButton = NSButton(title: "Show Log", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)

    private var process: Process?
    private var buffer = ""
    private var timer: Timer?
    private var target = 0.0
    private var shown = 0.0
    private var doneReceived = false
    private var finalOK = false
    private var finalMessage = ""
    private let logPath = NSHomeDirectory() + "/Library/Logs/f2b_sync.log"

    // MARK: Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        startSync()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if let p = process, p.isRunning { p.terminate() }
    }

    // MARK: UI
    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit F2B Sync",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "F2B Sync"
        window.center()
        window.isReleasedWhenClosed = false
        guard let v = window.contentView else { return }

        iconView.frame = NSRect(x: 24, y: 160, width: 64, height: 64)
        iconView.image = NSApp.applicationIconImage

        titleLabel.frame = NSRect(x: 104, y: 192, width: 332, height: 26)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 18)

        statusLabel.frame = NSRect(x: 104, y: 166, width: 332, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        bar.frame = NSRect(x: 24, y: 128, width: 412, height: 12)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = 0

        detailLabel.frame = NSRect(x: 24, y: 58, width: 412, height: 54)
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.isHidden = true

        for b in [logButton, retryButton, closeButton] {
            b.bezelStyle = .rounded
            b.target = self
            b.isHidden = true
        }
        logButton.frame = NSRect(x: 24, y: 16, width: 100, height: 30)
        logButton.action = #selector(showLog)
        retryButton.frame = NSRect(x: 240, y: 16, width: 90, height: 30)
        retryButton.action = #selector(retry)
        closeButton.frame = NSRect(x: 346, y: 16, width: 90, height: 30)
        closeButton.action = #selector(closeApp)
        closeButton.keyEquivalent = "\r"

        for sub in [iconView, titleLabel, statusLabel, bar, detailLabel, logButton, retryButton, closeButton] as [NSView] {
            v.addSubview(sub)
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Sync process
    private func startSync() {
        timer?.invalidate()
        buffer = ""
        target = 0
        shown = 0
        doneReceived = false
        finalOK = false
        finalMessage = ""
        bar.doubleValue = 0
        titleLabel.stringValue = "Syncing status…"
        statusLabel.stringValue = "Starting…"
        detailLabel.isHidden = true
        logButton.isHidden = true
        retryButton.isHidden = true
        closeButton.isHidden = true

        timer = Timer.scheduledTimer(timeInterval: 0.03, target: self,
                                     selector: #selector(tick), userInfo: nil, repeats: true)

        guard let script = Bundle.main.url(forResource: "f2b_sync", withExtension: "sh") else {
            complete(ok: false, message: "f2b_sync.sh is missing from the app bundle.")
            return
        }

        let p = Process()
        p.executableURL = script
        p.arguments = ["--progress", "--quiet"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let s = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self?.consume(s) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let status = Int(proc.terminationStatus)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.complete(ok: status == 0,
                               message: status == 0 ? "Finished."
                                   : "The sync script stopped unexpectedly (exit code \(status)). See the log for details.")
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            complete(ok: false, message: "Could not start the sync script: \(error.localizedDescription)")
        }
    }

    private func consume(_ text: String) {
        buffer += text
        while let r = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<r.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("@@PROGRESS ") {
            let rest = String(line.dropFirst("@@PROGRESS ".count))
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = parts.first, let pct = Double(first) {
                target = max(target, pct)
                if parts.count > 1 { statusLabel.stringValue = String(parts[1]) }
            }
        } else if line.hasPrefix("@@DONE ") {
            let rest = String(line.dropFirst("@@DONE ".count))
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let code = Int(parts.first.map(String.init) ?? "1") ?? 1
            let msg = parts.count > 1 ? String(parts[1]) : ""
            complete(ok: code == 0, message: msg)
        }
    }

    private func complete(ok: Bool, message: String) {
        if doneReceived { return }
        doneReceived = true
        finalOK = ok
        finalMessage = message
        if ok { target = 100 } else { showResult() }
    }

    // MARK: Smooth progress
    @objc private func tick() {
        if shown < target {
            shown = min(target, shown + max(0.5, (target - shown) * 0.12))
        } else if !doneReceived {
            let cap = min(target + 18, 95)       // slow crawl between stages
            if shown < cap { shown += 0.05 }
        }
        bar.doubleValue = shown
        if doneReceived && finalOK && shown >= 99.9 { showResult() }
    }

    private func showResult() {
        timer?.invalidate()
        if finalOK {
            bar.doubleValue = 100
            titleLabel.stringValue = "✅ Sync complete"
            statusLabel.stringValue = "f2b_status.json is up to date"
        } else {
            titleLabel.stringValue = "❌ Sync failed"
            statusLabel.stringValue = "Nothing was changed"
        }
        detailLabel.stringValue = finalMessage
        detailLabel.isHidden = false
        logButton.isHidden = false
        closeButton.isHidden = false
        retryButton.isHidden = finalOK
        window.makeFirstResponder(nil)
    }

    // MARK: Actions
    @objc private func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc private func retry() { startSync() }
    @objc private func closeApp() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
