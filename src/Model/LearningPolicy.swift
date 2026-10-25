import Foundation

/// TIS 通知没有用户来源标记：用激活保护窗排除应用恢复输入法的常见情况。
/// 是否临时尊重切换，与是否把结果写入规则是两个独立决定。
struct LearningPolicy {
    private var activationAt: Date = .distantPast
    private var activationBundle: String?

    mutating func activated(_ bundle: String, at date: Date = Date()) {
        activationBundle = bundle
        activationAt = date
    }

    func shouldRespectChange(bundle: String, config: Config, at date: Date = Date()) -> Bool {
        config.enabled && bundle != kBundleSelf && !config.excluded.contains(bundle)
            && bundle == activationBundle && date.timeIntervalSince(activationAt) > 1
    }

    func shouldLearn(bundle: String, config: Config) -> Bool {
        config.learn && !config.hasContextRules(for: bundle)
            && (config.apps[bundle] != nil || config.learnCreatesRules)
    }
}
