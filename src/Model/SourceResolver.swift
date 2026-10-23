import Foundation

/// 「这个应用此刻该用哪个输入法」的唯一判定入口。
///
/// 优先级：应用内细分规则 > 应用规则 > 默认输入法。
/// 所有触发路径（激活 / 焦点变化 / 看门狗）都必须走这里，
/// 否则看门狗会把细分规则刚切好的结果又按应用规则纠回去。
enum SourceResolver {

    static func desired(for bundle: String, config: Config) -> String? {
        contextSource(for: bundle, config: config)
            ?? config.apps[bundle]
            ?? config.defaultSource
    }

    /// 只在该应用有细分规则、且它就是当前前台时才去读焦点（读 AX 有开销）
    static func contextSource(for bundle: String, config: Config) -> String? {
        guard config.hasContextRules(for: bundle) else { return nil }
        guard let fp = FocusProbe.fingerprint(ofFrontmost: bundle) else { return nil }
        return ContextRuleEngine.best(in: config.contextRules(for: bundle), for: fp)?.source
    }
}
