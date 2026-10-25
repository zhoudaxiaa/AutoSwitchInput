import Foundation

/// 纯判定入口：位置规则 > 应用规则 > 默认输入法。焦点由调用方提供。
enum SourceResolver {
    static func desired(for bundle: String, config: Config, fingerprint: FocusFingerprint? = nil) -> String? {
        if let fingerprint = fingerprint,
           let rule = ContextRuleEngine.best(in: config.contextRules(for: bundle), for: fingerprint) {
            return rule.source
        }
        return config.apps[bundle] ?? config.defaultSource
    }

    /// 运行时读取独立于判定，避免在主线程等待 AX。失败后本轮不切换，等待下一事件。
    @discardableResult
    static func resolve(for bundle: String, config: Config,
                        completion: @escaping (String?) -> Void) -> FocusProbe.Request? {
        guard config.hasContextRules(for: bundle) else {
            completion(desired(for: bundle, config: config))
            return nil
        }
        return FocusProbe.retryAsync(bundle: bundle, requireFrontmost: true) { fp in
            completion(desired(for: bundle, config: config, fingerprint: fp))
        } onGiveUp: {
            completion(nil)
        }
    }
}
