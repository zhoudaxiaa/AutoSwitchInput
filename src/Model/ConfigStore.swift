import Foundation

/// 配置的读写。落盘前先备份，读盘失败时回退到备份。
enum ConfigStore {

    /// 读主配置；主配置缺失或损坏时回退到备份。都没有则返回 nil。
    static func load() -> Config? {
        if let data = try? Data(contentsOf: AppPaths.configURL),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            return c
        }
        if let data = try? Data(contentsOf: AppPaths.configBackupURL),
           let c = try? JSONDecoder().decode(Config.self, from: data) {
            log("⚠️ 主配置读取失败，已从备份恢复（\(c.apps.count) 条规则）")
            save(c)
            return c
        }
        return nil
    }

    static func save(_ config: Config) {
        let url = AppPaths.configURL
        // 落盘前先留一份备份，任何时候都能手工恢复
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = AppPaths.configBackupURL
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(config) {
            try? d.write(to: url, options: .atomic)
        }
    }

    /// 从旧版 AutoSwitchInput Lite 的沙盒容器里读取规则，无缝迁移。
    /// 返回迁移的条数。
    @discardableResult
    static func importLegacyRules(into config: inout Config) -> Int {
        let p = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/cn.better365.AutoSwitchInputLite/Data/Library/Preferences/cn.better365.AutoSwitchInputLite.plist")
        guard let dict = NSDictionary(contentsOf: p),
              let autoInput = dict["autoInput"] as? [String: Any] else {
            log("未找到旧应用配置，从空白开始")
            return 0
        }
        var n = 0
        for (bundle, v) in autoInput {
            if let d = v as? [String: Any], let id = d["id"] as? String, !id.isEmpty {
                config.apps[bundle] = id
                n += 1
            }
        }
        log("已从旧版迁移 \(n) 条规则")
        return n
    }
}
