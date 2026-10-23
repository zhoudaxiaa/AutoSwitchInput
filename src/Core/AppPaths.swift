import Foundation

/// 所有落盘位置集中在这里，避免路径字符串散落在各处
enum AppPaths {

    /// 配置与诊断文件
    static let supportDir: URL = {
        let d = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/InputGuard")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var configURL: URL { supportDir.appendingPathComponent("config.json") }

    /// 每次写盘前留一份，任何事故都能手工恢复
    static var configBackupURL: URL { supportDir.appendingPathComponent("config.json.bak") }

    /// 「诊断：导出焦点特征」的输出文件
    static var focusDumpURL: URL { supportDir.appendingPathComponent("ax-focus.txt") }

    /// 存在这个文件时，右键菜单才显示诊断项（普通用户看不到）
    static var debugAXMarkerURL: URL { supportDir.appendingPathComponent("debug-ax") }

    static let logFileURL: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AutoSwitchInput.log")
    }()

    /// `open -a` 启动无法透传命令行参数，截图指令通过这个信号文件传递
    static let shotSignalFile = "/tmp/autoswitch_shot.txt"

    static var loginAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(kBundleSelf).plist")
    }
}
