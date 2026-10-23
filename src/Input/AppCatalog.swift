import AppKit
import Foundation

/// 本地已安装应用索引：bundleID -> .app 路径。
/// LaunchServices 偶尔查不到（刚装、被移动过），这里兜一层。
private let appURLIndex: [String: URL] = {
    var map: [String: URL] = [:]
    let fm = FileManager.default
    let roots = ["/Applications", "/System/Applications", "/Applications/Utilities",
                 NSHomeDirectory() + "/Applications"]
    for root in roots {
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for e in entries where e.hasSuffix(".app") {
            let url = URL(fileURLWithPath: root).appendingPathComponent(e)
            if let bid = Bundle(url: url)?.bundleIdentifier { map[bid] = url }
        }
    }
    return map
}()

func appDisplayInfo(for bundle: String) -> (name: String, icon: NSImage) {
    let fallbackIcon = NSImage(named: NSImage.applicationIconName) ?? NSImage()

    // 正在运行的进程能直接给出本地化名称和图标（最准）
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
        let name = running.localizedName ?? bundle
        return (name, running.icon ?? fallbackIcon)
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        ?? appURLIndex[bundle] {
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
    return (bundle, fallbackIcon)
}

/// 该 bundle id 在本机是否存在（规则可能是旧版遗留的僵尸项）
func appExists(_ bundle: String) -> Bool {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty { return true }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil { return true }
    return appURLIndex[bundle] != nil
}
