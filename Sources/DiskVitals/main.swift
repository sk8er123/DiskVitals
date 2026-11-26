// 앱을 시작하고 창을 띄우며 --screenshot 옵션으로 창 사진을 저장하는 진입점
import AppKit
import SwiftUI

let arguments = CommandLine.arguments

// 관리자 권한으로 실행된 표면 검사 작업자: 창 없이 검사만 하고 끝낸다
if let i = arguments.firstIndex(of: "--scan-worker") {
    exit(ScanWorker.run(Array(arguments[(i + 1)...])))
}
let screenshotPath: String? = {
    guard let i = arguments.firstIndex(of: "--screenshot"), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let store = DriveStore()
    let scanner = SurfaceScanner()
    private var frameCount = 0
    private var waitStarted = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let hosting = NSHostingView(rootView: ContentView().environmentObject(store).environmentObject(scanner))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1140, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DiskVitals"
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false

        store.refresh()

        if let path = screenshotPath {
            // 포커스를 가져오지 않고 창만 앞으로 내놓는다
            window.orderFrontRegardless()
            startScreenshotTimer(path: path)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { scanner.cancel() }

    @objc func refreshDrives(_ sender: Any?) { store.refresh() }

    // MARK: - Screenshot

    private func startScreenshotTimer(path: String) {
        waitStarted = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            self.frameCount += 1
            self.window.contentView?.needsDisplay = true
            let waited = Date().timeIntervalSince(self.waitStarted)
            let ready = self.frameCount >= 120 && (!self.store.isLoading || waited > 15)
            if ready {
                timer.invalidate()
                // 데이터가 그려질 시간을 조금 더 준다
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.saveScreenshot(to: path) }
            }
        }
    }

    private func saveScreenshot(to path: String) {
        guard let view = window.contentView else { exit(1) }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write("screenshot: could not create bitmap\n".data(using: .utf8)!)
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            exit(0)
        } catch {
            FileHandle.standardError.write("screenshot: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DiskVitals", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DiskVitals", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit DiskVitals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let refresh = NSMenuItem(title: "Refresh Drives", action: #selector(refreshDrives(_:)), keyEquivalent: "r")
        refresh.target = self
        viewMenu.addItem(refresh)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(screenshotPath == nil ? .regular : .accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
