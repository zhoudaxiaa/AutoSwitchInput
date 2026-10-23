import Foundation

/// 开机启动：写一个 LaunchAgent plist。
///
/// 注意：**不能**在这里 bootstrap。bootstrap 会立刻拉起第二个实例，
/// 而第二实例退出时会用空配置覆盖 config.json —— v1.2 丢配置就是这么来的。
/// 只写 plist，下次登录由 launchd 加载即可。
enum LaunchAgent {

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: AppPaths.loginAgentURL.path)
    }

    static func install() {
        let exe = Bundle.main.executablePath
            ?? "/Applications/自动切换输入法.app/Contents/MacOS/AutoSwitchInput"
        let plist: [String: Any] = [
            "Label": kBundleSelf,
            "ProgramArguments": [exe, "--silent"],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        let url = AppPaths.loginAgentURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: url)
            log("✎ 开启开机启动（下次登录生效）")
        }
    }

    static func uninstall() {
        run(["bootout", "gui/\(getuid())", AppPaths.loginAgentURL.path])
        try? FileManager.default.removeItem(at: AppPaths.loginAgentURL)
        log("✎ 关闭开机启动")
    }

    static func toggle() {
        isInstalled ? uninstall() : install()
    }

    private static func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
