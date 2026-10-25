import Cocoa

/// 调试钩子：截图、焦点导出、popover 自检。
/// 正常启动时 runIfNeeded 直接返回 false，什么都不做。
enum DebugHooks {

    /// 返回 true 表示这条启动已经被调试模式接管（进程随后退出），主流程不该继续
    @discardableResult
    static func runIfNeeded(controller: AppController) -> Bool {
        if runEnvHooks(controller) { return true }
        if runSignalFileHook(controller) { return true }
        return runArgumentHooks(controller)
    }

    // MARK: 环境变量（open -a 启动时也能用）

    private static func runEnvHooks(_ controller: AppController) -> Bool {
        let env = ProcessInfo.processInfo.environment

        if let shot = env["AUTOSWITCH_PANEL_SHOT"], !shot.isEmpty {
            Snapshots.panel(to: shot, host: controller, demoBundle: nil)
            NSApp.terminate(nil)
            return true
        }
        if let shot = env["AUTOSWITCH_WINDOW_SHOT"], !shot.isEmpty {
            Snapshots.window(to: shot)
            NSApp.terminate(nil)
            return true
        }
        return false
    }

    // MARK: 信号文件
    //
    // `open -a` 无法透传命令行参数，而 TCC 只认「由 LaunchServices 拉起的本应用」，
    // 所以从命令行直接跑二进制做 AX 相关的事会拿不到授权。
    // 折中办法：把指令写进 /tmp/autoswitch_shot.txt，启动时读一次就删。
    //
    //   第 1 行：输出路径
    //   第 2 行：模式（panel / window / axdump）
    //   第 3 行：bundle id（panel 用）或延迟秒数（axdump 用）
    //   第 4 行：界面语言（system / zh-Hans / en）

    private static func runSignalFileHook(_ controller: AppController) -> Bool {
        guard let content = try? String(contentsOfFile: AppPaths.shotSignalFile, encoding: .utf8) else {
            return false
        }
        try? FileManager.default.removeItem(atPath: AppPaths.shotSignalFile)

        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let target = lines.first, !target.isEmpty else { return false }

        let mode = lines.count > 1 ? lines[1] : ""

        if mode == "axdump" {
            Snapshots.focusDump(to: target,
                                bundleID: lines.count > 2 && !lines[2].isEmpty ? lines[2] : nil,
                                delay: lines.count > 3 ? (Double(lines[3]) ?? 2) : 2)
            return true
        }

        if mode == "axdeep" {
            Snapshots.deepProbe(to: target,
                                bundleID: lines.count > 2 && !lines[2].isEmpty ? lines[2] : nil,
                                delay: lines.count > 3 ? (Double(lines[3]) ?? 2) : 2)
            return true
        }

        if lines.count > 3, !lines[3].isEmpty, lines[3] != "system" {
            setAppLanguage(lines[3])
            controller.rebuildSettingsWindow()
            log("debug: language=\(lines[3])")
        }

        if mode == "panel" {
            Snapshots.panel(to: target, host: controller,
                            demoBundle: lines.count > 2 ? lines[2] : nil)
        } else {
            Snapshots.window(to: target)
        }
        NSApp.terminate(nil)
        return true
    }

    // MARK: 命令行参数

    private static func runArgumentHooks(_ controller: AppController) -> Bool {
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--panel-snapshot"), idx + 1 < args.count {
            Snapshots.panel(to: args[idx + 1], host: controller, demoBundle: nil)
            NSApp.terminate(nil)
            return true
        }
        if let idx = args.firstIndex(of: "--window-snapshot"), idx + 1 < args.count {
            Snapshots.window(to: args[idx + 1])
            NSApp.terminate(nil)
            return true
        }
        // --ax-dump <输出路径> [bundle id] [延迟秒]
        if let idx = args.firstIndex(of: "--ax-dump"), idx + 1 < args.count {
            let bundle = idx + 2 < args.count ? args[idx + 2] : nil
            let delay = idx + 3 < args.count ? (Double(args[idx + 3]) ?? 3) : 3
            Snapshots.focusDump(to: args[idx + 1], bundleID: bundle, delay: delay)
            return true
        }
        // --ax-deep <输出路径> [bundle id] [延迟秒]
        if let idx = args.firstIndex(of: "--ax-deep"), idx + 1 < args.count {
            let bundle = idx + 2 < args.count ? args[idx + 2] : nil
            let delay = idx + 3 < args.count ? (Double(args[idx + 3]) ?? 3) : 3
            Snapshots.deepProbe(to: args[idx + 1], bundleID: bundle, delay: delay)
            return true
        }
        if args.contains("--popover-demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                controller.togglePopover()
                log("popover demo: shown=\(controller.popoverShown)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
            }
            controller.startWatchdog()
            controller.refreshStatusTitle()
            return true
        }
        return false
    }
}
