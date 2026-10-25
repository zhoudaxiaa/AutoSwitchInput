import Foundation

/// 配置的读写。落盘前先备份，读盘失败时回退到备份。
enum ConfigStore {

    /// 恢复直接写主文件，不经过备份轮换；即使写入失败，有效备份仍保留。
    static func load(url: URL = AppPaths.configURL, backup: URL = AppPaths.configBackupURL) -> Config? {
        if let c = decode(url) { return c }
        if let c = decode(backup) {
            log("⚠️ 主配置读取失败，已从备份恢复（\(c.apps.count) 条规则）")
            do { try encoded(c).write(to: url, options: .atomic) }
            catch { log("✗ 恢复主配置失败，已保留备份：\(error)") }
            return c
        }
        if FileManager.default.fileExists(atPath: url.path) {
            log("✗ 主配置与备份均不可读，请检查配置文件")
        }
        return nil
    }

    @discardableResult
    static func save(_ config: Config, url: URL = AppPaths.configURL,
                     backup: URL = AppPaths.configBackupURL) -> Bool {
        do {
            let data = try encoded(config.validated())
            // 只有可解码的旧主配置才有资格替换备份，且备份自身原子写入。
            if let previous = try? Data(contentsOf: url),
               (try? JSONDecoder().decode(Config.self, from: previous)) != nil {
                try previous.write(to: backup, options: .atomic)
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log("✗ 保存配置失败：\(error)")
            return false
        }
    }

    private static func decode(_ url: URL) -> Config? {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        return config.validated()
    }

    private static func encoded(_ config: Config) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
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
