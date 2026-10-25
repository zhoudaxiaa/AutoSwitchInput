import Foundation

/// 一个「位置」长什么样，存下来备查。
///
/// 为什么规则里要带这个：两个位置的特征可能一开始长得一模一样
/// （VS Code 的编辑器和 Copilot 聊天框都是 `native-edit-context`）。
/// 等第二个位置出现时，只有把两条祖先链摆在一起比，才知道从哪一层开始不同。
/// 没有快照就只能靠「通用类名单」猜，而名单永远漏项。
struct SpotSignature: Codable {
    var role: String = ""
    var identifier: String = ""
    /// 焦点元素自身的 DOM class
    var domClasses: [String] = []
    /// 祖先的 DOM class，由近及远
    var ancestorClasses: [String] = []
    /// 祖先的标题 / 描述，由近及远
    var ancestorTitles: [String] = []

    init() {}

    init(role: String, identifier: String, domClasses: [String],
         ancestorClasses: [String], ancestorTitles: [String]) {
        self.role = role
        self.identifier = identifier
        self.domClasses = domClasses
        self.ancestorClasses = ancestorClasses
        self.ancestorTitles = ancestorTitles
    }

    // 手写解码：字段缺失时回落到默认值，别让手工改过的配置整份失效
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier) ?? ""
        domClasses = try c.decodeIfPresent([String].self, forKey: .domClasses) ?? []
        ancestorClasses = try c.decodeIfPresent([String].self, forKey: .ancestorClasses) ?? []
        ancestorTitles = try c.decodeIfPresent([String].self, forKey: .ancestorTitles) ?? []
    }

    /// 由近及远的所有 class（去重）
    var allClasses: [String] {
        var seen = Set<String>()
        return (domClasses + ancestorClasses).filter { seen.insert($0).inserted }
    }
}

/// 应用内的细分规则：同一个应用，不同位置用不同输入法
struct ContextRule: Codable {
    var id: UUID = UUID()
    /// 自动生成规则按完整 class 匹配；旧配置保留子串匹配。
    var classExact: Bool = false
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
    /// 保存这条规则时，那个位置长什么样。
    /// 用来在「两个位置撞车」时自动找差异，以及日后重新定位。
    var signature: SpotSignature? = nil

    init(bundle: String, source: String) {
        self.bundle = bundle
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        classExact = try c.decodeIfPresent(Bool.self, forKey: .classExact) ?? false
        bundle = try c.decode(String.self, forKey: .bundle)
        source = try c.decode(String.self, forKey: .source)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
        titleContains = try c.decodeIfPresent(String.self, forKey: .titleContains)
        classContains = try c.decodeIfPresent(String.self, forKey: .classContains)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        signature = try c.decodeIfPresent(SpotSignature.self, forKey: .signature)
    }
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
    /// 只清理无效结构；暂时不可用的输入源保留，供界面提示和用户修复。
    func validated() -> Config {
        var c = self
        c.defaultSource = ContextRuleEngine.nonempty(c.defaultSource)
        c.apps = c.apps.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ContextRuleEngine.nonempty($0.value) != nil }
        if !c.watchdogInterval.isFinite || !(0.2...60).contains(c.watchdogInterval) {
            c.watchdogInterval = Config().watchdogInterval
        }
        c.verifyDelays = Array(c.verifyDelays.filter { $0.isFinite && (0.01...10).contains($0) }.prefix(10))
        c.contexts = c.contexts.filter {
            !$0.bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ContextRuleEngine.nonempty($0.source) != nil
                && ContextRuleEngine.specificity($0) > 0
        }
        var seen = Set<UUID>()
        for i in c.contexts.indices {
            c.contexts[i].source = c.contexts[i].source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !seen.insert(c.contexts[i].id).inserted { c.contexts[i].id = UUID() }
        }
        return c
    }

    var ruleBundles: Set<String> { Set(apps.keys).union(contexts.map(\.bundle)) }

    func contextRules(for bundle: String) -> [ContextRule] {
        contexts.filter { $0.bundle == bundle }
    }

    func hasContextRules(for bundle: String) -> Bool {
        contexts.contains { $0.bundle == bundle }
    }
}
