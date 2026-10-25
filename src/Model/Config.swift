import Foundation

/// 应用内的细分规则：同一个应用，不同位置用不同输入法
struct ContextRule: Codable {
    var bundle: String
    var source: String
    /// 精确匹配 AXRole，例如 AXTextArea（仅在拿不到 DOM class / identifier 时才写）
    var role: String? = nil
    /// AXIdentifier 包含匹配
    var identifier: String? = nil
    /// 焦点元素自身或其祖先的标题包含该词
    var titleContains: String? = nil
    /// 焦点元素自身或其祖先的 DOM class 包含该词（Electron 应用的稳定标识）。
    /// 祖先也算 —— 同一个应用里不同输入区往往只有祖先 class 不同。
    var classContains: String? = nil
    /// 给用户看的备注，例如「终端」
    var note: String? = nil
}

struct Config: Codable {
    var enabled: Bool = true
    var learn: Bool = true
    var learnCreatesRules: Bool = false
    var defaultSource: String? = nil
    var apps: [String: String] = [:]
    var excluded: [String] = [
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        kBundleSelf,
    ]
    var verifyDelays: [Double] = [0.06, 0.18, 0.45]
    var watchdogInterval: Double = 1.5
    /// 界面语言："zh-Hans" / "en"，nil = 跟随系统
    var language: String? = nil
    /// 应用内的细分规则（VS Code 终端 / 编辑器分别用不同输入法）
    var contexts: [ContextRule] = []

    init() {}

    // 手写解码器：字段缺失时回落到默认值，避免手工改配置后整份配置失效
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        learn = try c.decodeIfPresent(Bool.self, forKey: .learn) ?? d.learn
        learnCreatesRules = try c.decodeIfPresent(Bool.self, forKey: .learnCreatesRules) ?? d.learnCreatesRules
        defaultSource = try c.decodeIfPresent(String.self, forKey: .defaultSource)
        apps = try c.decodeIfPresent([String: String].self, forKey: .apps) ?? d.apps
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? d.excluded
        verifyDelays = try c.decodeIfPresent([Double].self, forKey: .verifyDelays) ?? d.verifyDelays
        watchdogInterval = try c.decodeIfPresent(Double.self, forKey: .watchdogInterval) ?? d.watchdogInterval
        language = try c.decodeIfPresent(String.self, forKey: .language)
        contexts = try c.decodeIfPresent([ContextRule].self, forKey: .contexts) ?? d.contexts
    }
}

extension Config {
    func contextRules(for bundle: String) -> [ContextRule] {
        contexts.filter { $0.bundle == bundle }
    }

    func hasContextRules(for bundle: String) -> Bool {
        contexts.contains { $0.bundle == bundle }
    }
}
