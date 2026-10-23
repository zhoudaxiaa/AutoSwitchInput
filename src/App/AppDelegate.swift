import Cocoa

/// 只负责 AppKit 生命周期，业务都在 AppController 里。
///
/// 因为是 LSUIElement 应用（不在 Dock 显示），有两点必须自己处理：
///  1. applicationShouldHandleReopen 通常不会被调用，要接管 kAEReopenApplication
///  2. 第二实例被拉起时，要通知已在运行的实例弹窗，然后自己退出
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = AppController()

    /// 启动时刻：用来区分「用户点了 App」和「启动时系统补发的 reopen」
    private let launchedAt = Date()

    func applicationWillFinishLaunching(_ note: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showWindowNote),
            name: kShowWindowNote, object: nil, suspensionBehavior: .deliverImmediately)

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 单实例：已经在跑就通知它弹窗，然后自己退出
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: kBundleSelf)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                kShowWindowNote, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }

        controller.start()
    }

    func applicationWillTerminate(_ note: Notification) {
        controller.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 刚启动时 LaunchServices 也会发一次 reopen，别因此弹窗
        if Date().timeIntervalSince(launchedAt) < 1.5 { return true }
        controller.openSettings()
        return true
    }

    /// LSUIElement 应用不会走 applicationShouldHandleReopen，
    /// 必须自己接管「重新打开」Apple Event，否则窗口关掉后再点 App 没反应。
    @objc func handleReopenEvent(_ event: NSAppleEventDescriptor,
                                 withReply reply: NSAppleEventDescriptor) {
        if Date().timeIntervalSince(launchedAt) < 1.5 { return }
        controller.openSettings()
    }

    @objc func showWindowNote() {
        DispatchQueue.main.async { self.controller.openSettings() }
    }
}
