import AppKit
import Foundation

/// 抓焦点的两个入口，区别只在「是否要求该应用处于前台」。
enum FocusProbe {

    static func runningApp(bundle: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    /// 判定规则用：必须确认该应用就是当前前台，
    /// 否则拿到的可能是它失焦前的残留焦点元素，会误判位置。
    static func fingerprint(ofFrontmost bundle: String) -> FocusFingerprint? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundle else { return nil }
        return focusedFingerprint(pid: front.processIdentifier)
    }

    /// 面板展示用：不管前台是谁，只要在运行就抓
    static func fingerprint(ofRunning bundle: String) -> FocusFingerprint? {
        guard let app = runningApp(bundle: bundle) else { return nil }
        return focusedFingerprint(pid: app.processIdentifier)
    }

    /// 当前前台应用（排除本应用）
    static func frontmostExternal() -> (bundle: String, pid: pid_t)? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier,
              bundle != kBundleSelf else { return nil }
        return (bundle, front.processIdentifier)
    }
}
