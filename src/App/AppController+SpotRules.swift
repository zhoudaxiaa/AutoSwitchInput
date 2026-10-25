import Foundation

// 「此处」规则：给光标所在的那个位置单独指定输入法
extension AppController {

    /// source 传 nil 表示清除该位置的规则（回到「跟随应用」）
    func setSpotRule(bundle: String, source: String?, fp: FocusFingerprint) {
        let matched = ContextRuleEngine.best(in: config.contextRules(for: bundle), for: fp)
        // 备注按「此刻焦点在哪」现算，不要继承 matched 的：
        // 一旦 matched 是条误匹配的旧规则，新规则会被冠上别人的名字
        // （Copilot 聊天框被标成「编辑器」就是这么来的）
        let label = ContextRuleEngine.displayLabel(fp, matchedNote: matched?.note)
        // 删除只操作实际命中的规则，不触发冲突收窄或重新推导位置。
        guard let source = source else {
            if let matched = matched { removeContextRule(id: matched.id) }
            return
        }

        // 先做冲突消解：两个位置特征撞车时，把彼此都收窄到各自独有的 class。
        // 只收窄新的那个是不够的 —— 旧规则还留在原地继续吃掉新位置。
        let res = ContextRuleEngine.resolveSpot(bundle: bundle, fp: fp, rules: config.contexts)
        for note in res.notes { log("◻︎ \(bundle) \(note)") }
        for n in res.narrowings {
            guard config.contexts.indices.contains(n.index) else { continue }
            config.contexts[n.index].classContains = n.to
            config.contexts[n.index].classExact = true
            config.contexts[n.index].identifier = nil
            config.contexts[n.index].titleContains = nil
        }

        var probe = ContextRuleEngine.make(bundle: bundle, source: source,
                                           fp: fp, note: label, classOverride: res.classForNew)

        // 匹配条件变化后仍保留位置身份；删除不再依赖数组下标。
        if let existing = config.contexts.first(where: {
            $0.bundle == bundle && ContextRuleEngine.isSameSpot($0, fp)
                && ContextRuleEngine.matches($0, fp)
        }) {
            probe.id = existing.id
        }
        config.contexts.removeAll {
            $0.bundle == bundle && ($0.id == probe.id || ContextRuleEngine.sameSpot($0, probe))
        }

        config.contexts.append(probe)
        let how = ContextRuleEngine.conditionDescription(probe)
        log("✎ 位置规则 \(bundle) [\(probe.note ?? "-")] → \(source) via \(how)")

        engine.clearUserOverride()
        commitConfig(reason: "位置规则变更")
    }

    func removeContextRule(id: UUID) {
        guard let index = config.contexts.firstIndex(where: { $0.id == id }) else { return }
        let rule = config.contexts.remove(at: index)
        log("✎ 删除位置规则 \(rule.bundle) [\(rule.note ?? "-")]")
        engine.clearUserOverride()
        commitConfig(reason: "删除位置规则")
    }

    func setContextSource(id: UUID, source: String) {
        guard let index = config.contexts.firstIndex(where: { $0.id == id }) else { return }
        config.contexts[index].source = source
        engine.clearUserOverride()
        commitConfig(reason: "修改位置输入法")
    }

    func clearContextRules(for bundle: String) {
        guard config.hasContextRules(for: bundle) else { return }
        config.contexts.removeAll { $0.bundle == bundle }
        engine.clearUserOverride()
        commitConfig(reason: "清除位置规则")
    }
}
